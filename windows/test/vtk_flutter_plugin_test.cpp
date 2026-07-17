#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <gtest/gtest.h>

#include <vtk_flutter.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <variant>
#include <vector>

#include "vtk_flutter_codec.h"
#include "vtk_flutter_plugin.h"
#include "windows_frame_target.h"

namespace vtk_flutter::test {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

EncodableValue Key(const char *value) { return EncodableValue(value); }

const EncodableValue &ValueAt(const EncodableMap &values, const char *key) {
  return values.at(Key(key));
}

EncodableValue Viewport(int width, int height) {
  return EncodableValue(EncodableMap{
      {Key("width"), EncodableValue(width)},
      {Key("height"), EncodableValue(height)},
  });
}

EncodableValue ViewArguments(int width, int height,
                             std::int64_t presentation_api_address,
                             std::int64_t native_session_address) {
  return EncodableValue(EncodableMap{
      {Key("width"), EncodableValue(width)},
      {Key("height"), EncodableValue(height)},
      {Key("presentationApiAddress"), EncodableValue(presentation_api_address)},
      {Key("nativeSessionAddress"), EncodableValue(native_session_address)},
  });
}

void VTK_FLUTTER_CALL StatusClear(VtkFlutterStatus *status) {
  if (status != nullptr) {
    *status = {};
  }
}

std::int32_t VTK_FLUTTER_CALL AttachTarget(VtkFlutterSession *,
                                           VtkFlutterTextureTarget *,
                                           VtkFlutterStatus *) {
  return VTK_FLUTTER_STATUS_OK;
}

std::int32_t VTK_FLUTTER_CALL DetachTarget(VtkFlutterSession *,
                                           VtkFlutterTextureTarget *,
                                           VtkFlutterStatus *) {
  return VTK_FLUTTER_STATUS_OK;
}

std::int32_t VTK_FLUTTER_CALL TargetCreate(const VtkFlutterFrameCallbacks *,
                                           VtkFlutterTextureTarget **,
                                           VtkFlutterStatus *) {
  return VTK_FLUTTER_STATUS_OK;
}

std::int32_t VTK_FLUTTER_CALL TargetDestroy(VtkFlutterTextureTarget *,
                                            VtkFlutterStatus *) {
  return VTK_FLUTTER_STATUS_OK;
}

VtkFlutterPresentationApi CompletePresentationApi() {
  return {
      sizeof(VtkFlutterPresentationApi),
      VTK_FLUTTER_PRESENTATION_API_VERSION,
      StatusClear,
      AttachTarget,
      DetachTarget,
      TargetCreate,
      TargetDestroy,
  };
}

bool IsNotImplemented(VtkFlutterPlugin &plugin, const char *method) {
  bool not_implemented = false;
  plugin.HandleMethodCall(
      MethodCall(method, std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          nullptr, nullptr, [&not_implemented]() { not_implemented = true; }));
  return not_implemented;
}

} // namespace

TEST(VtkFlutterCodec, ReportsOnlyGenericCapabilities) {
  const auto capabilities = windows::CapabilitiesMap();

  EXPECT_TRUE(std::get<bool>(ValueAt(capabilities, "supportsExternalTexture")));
  EXPECT_EQ(capabilities.find(Key("renderModes")), capabilities.end());
  EXPECT_EQ(capabilities.find(Key("maxVolumeBytes")), capabilities.end());
}

TEST(VtkFlutterCodec, DecodesBoundedViewport) {
  const auto arguments = Viewport(640, 320);
  const auto viewport = windows::DecodeViewport(&arguments);

  EXPECT_EQ(viewport.width, 640);
  EXPECT_EQ(viewport.height, 320);

  const auto invalid = Viewport(0, 320);
  EXPECT_THROW(windows::DecodeViewport(&invalid), std::invalid_argument);
}

TEST(VtkFlutterCodec, RequiresPositivePresentationAndSessionAddresses) {
  const auto api = CompletePresentationApi();
  const auto api_address =
      static_cast<std::int64_t>(reinterpret_cast<std::uintptr_t>(&api));
  const auto valid = ViewArguments(640, 320, api_address, 4096);

  EXPECT_EQ(windows::DecodePresentationApiAddress(&valid),
            reinterpret_cast<std::uintptr_t>(&api));
  EXPECT_EQ(windows::DecodeNativeSessionAddress(&valid), 4096U);

  const auto zero_api = ViewArguments(640, 320, 0, 4096);
  EXPECT_THROW(windows::DecodePresentationApiAddress(&zero_api),
               std::invalid_argument);
  const auto zero_session = ViewArguments(640, 320, api_address, 0);
  EXPECT_THROW(windows::DecodeNativeSessionAddress(&zero_session),
               std::invalid_argument);
}

TEST(VtkFlutterPresentationApi, ValidatesVersionSizeAndCompleteTable) {
  auto api = CompletePresentationApi();
  EXPECT_EQ(&windows::ValidatePresentationApiAddress(
                reinterpret_cast<std::uintptr_t>(&api)),
            &api);

  api.version = VTK_FLUTTER_PRESENTATION_API_VERSION + 1;
  EXPECT_THROW(windows::ValidatePresentationApiAddress(
                   reinterpret_cast<std::uintptr_t>(&api)),
               std::invalid_argument);
  api = CompletePresentationApi();
  api.struct_size = offsetof(VtkFlutterPresentationApi, texture_target_destroy);
  EXPECT_THROW(windows::ValidatePresentationApiAddress(
                   reinterpret_cast<std::uintptr_t>(&api)),
               std::invalid_argument);
  api = CompletePresentationApi();
  api.texture_target_destroy = nullptr;
  EXPECT_THROW(windows::ValidatePresentationApiAddress(
                   reinterpret_cast<std::uintptr_t>(&api)),
               std::invalid_argument);
}

TEST(WindowsFrameTarget, PublishesTopDownRgbaStorageOnlyOnEnd) {
  windows::WindowsFrameTarget target;
  auto callbacks = target.Callbacks();
  const VtkFlutterViewport viewport{2, 2};
  VtkFlutterCpuFrame frame{};
  VtkFlutterStatus status{};

  ASSERT_EQ(
      callbacks.begin_frame(callbacks.user_data, &viewport, &frame, &status),
      VTK_FLUTTER_STATUS_OK);
  EXPECT_EQ(callbacks.struct_size, sizeof(VtkFlutterFrameCallbacks));
  EXPECT_EQ(callbacks.version, VTK_FLUTTER_FRAME_CALLBACKS_VERSION);
  EXPECT_EQ(frame.struct_size, sizeof(VtkFlutterCpuFrame));
  EXPECT_EQ(frame.version, VTK_FLUTTER_CPU_FRAME_VERSION);
  EXPECT_EQ(frame.row_bytes, 8U);
  EXPECT_EQ(frame.capacity_bytes, 16U);
  EXPECT_EQ(frame.pixel_format, VTK_FLUTTER_PIXEL_FORMAT_RGBA8888);
  ASSERT_NE(frame.pixels, nullptr);
  EXPECT_EQ(target.LatestFrame(), nullptr);

  const std::vector<std::uint8_t> top_down_pixels{
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
  };
  std::copy(top_down_pixels.begin(), top_down_pixels.end(), frame.pixels);
  VtkFlutterFrameMetrics metrics{};
  ASSERT_EQ(callbacks.end_frame(callbacks.user_data, &metrics, &status),
            VTK_FLUTTER_STATUS_OK);

  const auto published = target.LatestFrame();
  ASSERT_NE(published, nullptr);
  EXPECT_EQ(published->id, 1);
  EXPECT_EQ(published->width, 2);
  EXPECT_EQ(published->height, 2);
  EXPECT_EQ(published->row_bytes, 8U);
  EXPECT_EQ(published->pixels, top_down_pixels);
}

TEST(WindowsFrameTarget, CancelDiscardsPendingStorageWithoutPublishing) {
  windows::WindowsFrameTarget target;
  auto callbacks = target.Callbacks();
  const VtkFlutterViewport viewport{1, 1};
  VtkFlutterCpuFrame first{};
  VtkFlutterStatus status{};
  VtkFlutterFrameMetrics metrics{};

  ASSERT_EQ(
      callbacks.begin_frame(callbacks.user_data, &viewport, &first, &status),
      VTK_FLUTTER_STATUS_OK);
  std::fill_n(first.pixels, 4, std::uint8_t{7});
  ASSERT_EQ(callbacks.end_frame(callbacks.user_data, &metrics, &status),
            VTK_FLUTTER_STATUS_OK);
  const auto published = target.LatestFrame();

  VtkFlutterCpuFrame cancelled{};
  ASSERT_EQ(callbacks.begin_frame(callbacks.user_data, &viewport, &cancelled,
                                  &status),
            VTK_FLUTTER_STATUS_OK);
  std::fill_n(cancelled.pixels, 4, std::uint8_t{9});
  callbacks.cancel_frame(callbacks.user_data);

  EXPECT_EQ(target.LatestFrame(), published);
  EXPECT_EQ(target.SubmittedFrameId(), 1);
  VtkFlutterCpuFrame replacement{};
  EXPECT_EQ(callbacks.begin_frame(callbacks.user_data, &viewport, &replacement,
                                  &status),
            VTK_FLUTTER_STATUS_OK);
  callbacks.cancel_frame(callbacks.user_data);
}

TEST(VtkFlutterPlugin, UsesGenericSessionChannelContractWithoutRegistrar) {
  VtkFlutterPlugin plugin;
  EncodableMap capabilities;
  plugin.HandleMethodCall(
      MethodCall("capabilities", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&capabilities](const EncodableValue *result) {
            capabilities = std::get<EncodableMap>(*result);
          },
          nullptr, nullptr));

  EXPECT_TRUE(std::get<bool>(ValueAt(capabilities, "supportsExternalTexture")));
}

TEST(VtkFlutterPlugin, RejectsCreateViewWithoutPresentationApiAddress) {
  VtkFlutterPlugin plugin;
  std::string error_code;
  const auto arguments = Viewport(640, 320);
  plugin.HandleMethodCall(
      MethodCall("createView", std::make_unique<EncodableValue>(arguments)),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](const std::string &code, const std::string &,
                        const EncodableValue *) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "invalid_presentation_api");
}

TEST(VtkFlutterPlugin, RejectsCreateViewWithoutNativeSessionAddress) {
  VtkFlutterPlugin plugin;
  const auto api = CompletePresentationApi();
  const auto arguments = ViewArguments(
      640, 320,
      static_cast<std::int64_t>(reinterpret_cast<std::uintptr_t>(&api)), 0);
  std::string error_code;
  plugin.HandleMethodCall(
      MethodCall("createView", std::make_unique<EncodableValue>(arguments)),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](const std::string &code, const std::string &,
                        const EncodableValue *) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "invalid_native_session");
}

TEST(VtkFlutterPlugin, RemovesLegacyProductAndSessionMethods) {
  VtkFlutterPlugin plugin;

  EXPECT_TRUE(IsNotImplemented(plugin, "createSession"));
  EXPECT_TRUE(IsNotImplemented(plugin, "setVolume"));
  EXPECT_TRUE(IsNotImplemented(plugin, "render"));
  EXPECT_TRUE(IsNotImplemented(plugin, "disposeSession"));
}

TEST(VtkFlutterPlugin, DisposesAbsentViewIdempotently) {
  VtkFlutterPlugin plugin;
  bool succeeded = false;
  plugin.HandleMethodCall(
      MethodCall("disposeView", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&succeeded](const EncodableValue *) { succeeded = true; }, nullptr,
          nullptr));

  EXPECT_TRUE(succeeded);
}

TEST(VtkFlutterPlugin, ReportsCompleteDisposedStatus) {
  VtkFlutterPlugin plugin;
  EncodableMap status;
  plugin.HandleMethodCall(
      MethodCall("status", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&status](const EncodableValue *result) {
            status = std::get<EncodableMap>(*result);
          },
          nullptr, nullptr));

  EXPECT_EQ(std::get<std::int64_t>(ValueAt(status, "textureId")), -1);
  EXPECT_FALSE(std::get<bool>(ValueAt(status, "ready")));
  EXPECT_FALSE(std::get<bool>(ValueAt(status, "initializing")));
  EXPECT_FALSE(std::get<bool>(ValueAt(status, "disposing")));
  EXPECT_EQ(std::get<int>(ValueAt(status, "pendingTextureUnregistrations")), 0);
  EXPECT_EQ(std::get<std::int64_t>(ValueAt(status, "presentedFrameCount")), 0);
  EXPECT_EQ(std::get<std::int64_t>(ValueAt(status, "presentedFrameId")), 0);
  EXPECT_EQ(
      std::get<std::int64_t>(ValueAt(status, "graphicsContextGeneration")), 0);
}

} // namespace vtk_flutter::test
