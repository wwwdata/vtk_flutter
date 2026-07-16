#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
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

using flutter::EncodableList;
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

EncodableValue SessionArguments(int width, int height,
                                std::int64_t core_api_address) {
  return EncodableValue(EncodableMap{
      {Key("width"), EncodableValue(width)},
      {Key("height"), EncodableValue(height)},
      {Key("coreApiAddress"), EncodableValue(core_api_address)},
  });
}

EncodableValue CameraRequest(int mode, double zoom) {
  return EncodableValue(EncodableMap{
      {Key("mode"), EncodableValue(mode)},
      {Key("windowCenter"), EncodableValue(350.0)},
      {Key("windowWidth"), EncodableValue(1800.0)},
      {Key("cameraAzimuthDegrees"), EncodableValue(25.0)},
      {Key("cameraElevationDegrees"), EncodableValue(18.0)},
      {Key("cameraZoom"), EncodableValue(zoom)},
  });
}

void VTK_FLUTTER_CALL StatusClear(VtkFlutterStatus *status) {
  if (status != nullptr) {
    *status = {};
  }
}

std::int32_t VTK_FLUTTER_CALL SessionCreate(VtkFlutterSession **,
                                            VtkFlutterStatus *) {
  return VTK_FLUTTER_STATUS_OK;
}

void VTK_FLUTTER_CALL SessionDestroy(VtkFlutterSession *) {}

std::int32_t VTK_FLUTTER_CALL ValidateVolume(const VtkFlutterVolume *,
                                             VtkFlutterStatus *) {
  return VTK_FLUTTER_STATUS_OK;
}

std::int32_t VTK_FLUTTER_CALL SessionSetVolume(VtkFlutterSession *,
                                               const VtkFlutterVolume *,
                                               VtkFlutterStatus *) {
  return VTK_FLUTTER_STATUS_OK;
}

std::int32_t VTK_FLUTTER_CALL
ValidateRenderRequest(const VtkFlutterRenderRequest *, VtkFlutterStatus *) {
  return VTK_FLUTTER_STATUS_OK;
}

std::int32_t VTK_FLUTTER_CALL SessionRender(VtkFlutterSession *,
                                            const VtkFlutterRenderRequest *,
                                            VtkFlutterMetrics *,
                                            VtkFlutterStatus *) {
  return VTK_FLUTTER_STATUS_OK;
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

std::int32_t VTK_FLUTTER_CALL TargetCreate(const VtkFlutterFrameCallbacksV2 *,
                                           VtkFlutterTextureTarget **,
                                           VtkFlutterStatus *) {
  return VTK_FLUTTER_STATUS_OK;
}

std::int32_t VTK_FLUTTER_CALL TargetDestroy(VtkFlutterTextureTarget *,
                                            VtkFlutterStatus *) {
  return VTK_FLUTTER_STATUS_OK;
}

VtkFlutterCoreApiV2 CompleteCoreApi() {
  return {
      sizeof(VtkFlutterCoreApiV2),
      VTK_FLUTTER_CORE_API_VERSION_2,
      StatusClear,
      SessionCreate,
      SessionDestroy,
      ValidateVolume,
      SessionSetVolume,
      ValidateRenderRequest,
      SessionRender,
      AttachTarget,
      DetachTarget,
      TargetCreate,
      TargetDestroy,
  };
}

} // namespace

TEST(VtkFlutterCodec, ReportsAllCapabilities) {
  const auto capabilities = windows::CapabilitiesMap();
  const auto &modes =
      std::get<EncodableList>(ValueAt(capabilities, "renderModes"));

  ASSERT_EQ(modes.size(), 3U);
  EXPECT_EQ(std::get<std::int32_t>(modes[0]), 1);
  EXPECT_EQ(std::get<std::int32_t>(modes[1]), 2);
  EXPECT_EQ(std::get<std::int32_t>(modes[2]), 3);
  EXPECT_EQ(std::get<std::int64_t>(ValueAt(capabilities, "maxVolumeBytes")),
            256LL * 1024LL * 1024LL);
  EXPECT_TRUE(std::get<bool>(ValueAt(capabilities, "supportsExternalTexture")));
}

TEST(VtkFlutterCodec, DecodesBoundedViewport) {
  const auto arguments = Viewport(640, 320);
  const auto viewport = windows::DecodeViewport(&arguments);

  EXPECT_EQ(viewport.width, 640);
  EXPECT_EQ(viewport.height, 320);

  const auto invalid = Viewport(0, 320);
  EXPECT_THROW(windows::DecodeViewport(&invalid), std::invalid_argument);
}

TEST(VtkFlutterCodec, RequiresPositiveCoreApiAddress) {
  const auto api = CompleteCoreApi();
  const auto valid = SessionArguments(
      640, 320,
      static_cast<std::int64_t>(reinterpret_cast<std::uintptr_t>(&api)));
  const auto zero = SessionArguments(640, 320, 0);

  EXPECT_EQ(windows::DecodeCoreApiAddress(&valid),
            reinterpret_cast<std::uintptr_t>(&api));
  EXPECT_THROW(windows::DecodeCoreApiAddress(&zero), std::invalid_argument);
  const auto missing = Viewport(640, 320);
  EXPECT_THROW(windows::DecodeCoreApiAddress(&missing), std::invalid_argument);
}

TEST(VtkFlutterCoreApi, ValidatesVersionSizeAndCompleteTable) {
  auto api = CompleteCoreApi();
  EXPECT_EQ(
      &windows::ValidateCoreApiAddress(reinterpret_cast<std::uintptr_t>(&api)),
      &api);

  api.version = VTK_FLUTTER_CORE_API_VERSION_2 + 1;
  EXPECT_THROW(
      windows::ValidateCoreApiAddress(reinterpret_cast<std::uintptr_t>(&api)),
      std::invalid_argument);
  api = CompleteCoreApi();
  api.struct_size = offsetof(VtkFlutterCoreApiV2, texture_target_destroy);
  EXPECT_THROW(
      windows::ValidateCoreApiAddress(reinterpret_cast<std::uintptr_t>(&api)),
      std::invalid_argument);
  api = CompleteCoreApi();
  api.texture_target_destroy = nullptr;
  EXPECT_THROW(
      windows::ValidateCoreApiAddress(reinterpret_cast<std::uintptr_t>(&api)),
      std::invalid_argument);
}

TEST(WindowsFrameTarget, PublishesTopDownRgbaStorageOnlyOnEnd) {
  windows::WindowsFrameTarget target;
  auto callbacks = target.Callbacks();
  const VtkFlutterViewport viewport{2, 2};
  VtkFlutterCpuFrameV2 frame{};
  VtkFlutterStatus status{};

  ASSERT_EQ(
      callbacks.begin_frame(callbacks.user_data, &viewport, &frame, &status),
      VTK_FLUTTER_STATUS_OK);
  EXPECT_EQ(frame.struct_size, sizeof(VtkFlutterCpuFrameV2));
  EXPECT_EQ(frame.version, VTK_FLUTTER_CPU_FRAME_VERSION_2);
  EXPECT_EQ(frame.row_bytes, 8U);
  EXPECT_EQ(frame.capacity_bytes, 16U);
  EXPECT_EQ(frame.pixel_format, VTK_FLUTTER_PIXEL_FORMAT_RGBA8888);
  ASSERT_NE(frame.pixels, nullptr);
  EXPECT_EQ(target.LatestFrame(), nullptr);

  const std::vector<std::uint8_t> top_down_pixels{
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
  };
  std::copy(top_down_pixels.begin(), top_down_pixels.end(), frame.pixels);
  VtkFlutterMetrics metrics{};
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
  VtkFlutterCpuFrameV2 first{};
  VtkFlutterStatus status{};
  VtkFlutterMetrics metrics{};

  ASSERT_EQ(
      callbacks.begin_frame(callbacks.user_data, &viewport, &first, &status),
      VTK_FLUTTER_STATUS_OK);
  std::fill_n(first.pixels, 4, std::uint8_t{7});
  ASSERT_EQ(callbacks.end_frame(callbacks.user_data, &metrics, &status),
            VTK_FLUTTER_STATUS_OK);
  const auto published = target.LatestFrame();

  VtkFlutterCpuFrameV2 cancelled{};
  ASSERT_EQ(callbacks.begin_frame(callbacks.user_data, &viewport, &cancelled,
                                  &status),
            VTK_FLUTTER_STATUS_OK);
  std::fill_n(cancelled.pixels, 4, std::uint8_t{9});
  callbacks.cancel_frame(callbacks.user_data);

  EXPECT_EQ(target.LatestFrame(), published);
  EXPECT_EQ(target.SubmittedFrameId(), 1);
  VtkFlutterCpuFrameV2 replacement{};
  EXPECT_EQ(callbacks.begin_frame(callbacks.user_data, &viewport, &replacement,
                                  &status),
            VTK_FLUTTER_STATUS_OK);
  callbacks.cancel_frame(callbacks.user_data);
}

TEST(VtkFlutterCodec, PreservesCameraZoomForBothVolumeModes) {
  const VtkFlutterViewport viewport{640, 320};
  const auto volume_arguments = CameraRequest(2, 1.5);
  const auto locator_arguments = CameraRequest(3, 2.5);

  const auto volume = windows::DecodeRenderRequest(&volume_arguments, viewport);
  const auto locator =
      windows::DecodeRenderRequest(&locator_arguments, viewport);

  EXPECT_EQ(volume.mode, VTK_FLUTTER_RENDER_VOLUME_3D);
  EXPECT_DOUBLE_EQ(volume.camera_zoom, 1.5);
  EXPECT_EQ(locator.mode, VTK_FLUTTER_RENDER_VOLUME_LOCATOR);
  EXPECT_DOUBLE_EQ(locator.camera_zoom, 2.5);
}

TEST(VtkFlutterCodec, DecodesObliqueTypedVectors) {
  const VtkFlutterViewport viewport{800, 600};
  const EncodableValue arguments(EncodableMap{
      {Key("mode"), EncodableValue(1)},
      {Key("windowCenter"), EncodableValue(350.0)},
      {Key("windowWidth"), EncodableValue(1800.0)},
      {Key("planeOrigin"),
       EncodableValue(std::vector<double>{10.0, 20.0, 30.0})},
      {Key("planeNormal"),
       EncodableValue(std::vector<double>{0.0, 0.34, 0.94})},
  });

  const auto request = windows::DecodeRenderRequest(&arguments, viewport);

  EXPECT_EQ(request.mode, VTK_FLUTTER_RENDER_OBLIQUE_MPR);
  EXPECT_DOUBLE_EQ(request.plane_origin[0], 10.0);
  EXPECT_DOUBLE_EQ(request.plane_normal[1], 0.34);
  EXPECT_DOUBLE_EQ(request.camera_zoom, 1.0);
}

TEST(VtkFlutterCodec, OwnsDecodedVolumeBytes) {
  const EncodableValue arguments(EncodableMap{
      {Key("voxels"),
       EncodableValue(std::vector<std::uint8_t>{0, 0, 1, 0, 255, 255, 2, 0})},
      {Key("width"), EncodableValue(2)},
      {Key("height"), EncodableValue(2)},
      {Key("depth"), EncodableValue(1)},
      {Key("indexToPatient"), EncodableValue(std::vector<double>{
                                  1,
                                  0,
                                  0,
                                  0,
                                  0,
                                  1,
                                  0,
                                  0,
                                  0,
                                  0,
                                  1,
                                  0,
                                  0,
                                  0,
                                  0,
                                  1,
                              })},
  });

  const auto owned = windows::DecodeVolume(&arguments);
  const auto native = owned.NativeView();

  EXPECT_EQ(native.voxel_count, 4U);
  EXPECT_EQ(native.width, 2);
  EXPECT_EQ(native.height, 2);
  EXPECT_EQ(native.depth, 1);
  EXPECT_EQ(native.voxels[1], 1);
  EXPECT_EQ(native.voxels[2], -1);
  EXPECT_DOUBLE_EQ(native.index_to_patient[15], 1.0);
}

TEST(VtkFlutterPlugin, UsesSessionChannelContractWithoutRegistrar) {
  VtkFlutterPlugin plugin;
  EncodableMap capabilities;
  plugin.HandleMethodCall(
      MethodCall("capabilities", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&capabilities](const EncodableValue *result) {
            capabilities = std::get<EncodableMap>(*result);
          },
          nullptr, nullptr));

  EXPECT_EQ(std::get<std::int64_t>(ValueAt(capabilities, "maxVolumeBytes")),
            256LL * 1024LL * 1024LL);
}

TEST(VtkFlutterPlugin, RejectsCreateSessionWithoutCoreApiAddress) {
  VtkFlutterPlugin plugin;
  std::string error_code;
  const auto arguments = Viewport(640, 320);
  plugin.HandleMethodCall(
      MethodCall("createSession", std::make_unique<EncodableValue>(arguments)),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](const std::string &code, const std::string &,
                        const EncodableValue *) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "ffi_abi");
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
