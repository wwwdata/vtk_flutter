#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <gtest/gtest.h>

#include <vtk_flutter.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
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

EncodableValue SessionArguments(std::int64_t native_session_address) {
  return EncodableValue(EncodableMap{
      {Key("nativeSessionAddress"), EncodableValue(native_session_address)},
  });
}

std::int64_t Address(const void *pointer) {
  return static_cast<std::int64_t>(reinterpret_cast<std::uintptr_t>(pointer));
}

struct FakeTarget {
  VtkFlutterFrameCallbacks callbacks{};
  VtkFlutterSession *session = nullptr;
  bool destroyed = false;
};

std::vector<FakeTarget *> gTargets;
FakeTarget *gDestroyFailureTarget = nullptr;
int gDestroyFailuresRemaining = 0;
VtkFlutterSession *gDetachFailureSession = nullptr;
int gDetachFailuresRemaining = 0;

void ResetFakePresentation() {
  for (auto *target : gTargets) {
    delete target;
  }
  gTargets.clear();
  gDestroyFailureTarget = nullptr;
  gDestroyFailuresRemaining = 0;
  gDetachFailureSession = nullptr;
  gDetachFailuresRemaining = 0;
}

void VTK_FLUTTER_CALL StatusClear(VtkFlutterStatus *status) {
  if (status != nullptr) {
    *status = {};
  }
}

std::int32_t VTK_FLUTTER_CALL AttachTarget(VtkFlutterSession *session,
                                           VtkFlutterTextureTarget *target,
                                           VtkFlutterStatus *status) {
  StatusClear(status);
  auto *fake_target = reinterpret_cast<FakeTarget *>(target);
  if (session == nullptr || fake_target == nullptr || fake_target->destroyed) {
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  fake_target->session = session;
  return VTK_FLUTTER_STATUS_OK;
}

std::int32_t VTK_FLUTTER_CALL DetachTarget(VtkFlutterSession *session,
                                           VtkFlutterTextureTarget *target,
                                           VtkFlutterStatus *status) {
  StatusClear(status);
  if (session == gDetachFailureSession && gDetachFailuresRemaining > 0) {
    --gDetachFailuresRemaining;
    status->code = VTK_FLUTTER_STATUS_INTERNAL_ERROR;
    return VTK_FLUTTER_STATUS_INTERNAL_ERROR;
  }
  auto *fake_target = reinterpret_cast<FakeTarget *>(target);
  if (fake_target == nullptr || fake_target->destroyed ||
      fake_target->session != session) {
    return VTK_FLUTTER_STATUS_INVALID_STATE;
  }
  fake_target->session = nullptr;
  return VTK_FLUTTER_STATUS_OK;
}

std::int32_t VTK_FLUTTER_CALL
TargetCreate(const VtkFlutterFrameCallbacks *callbacks,
             VtkFlutterTextureTarget **target, VtkFlutterStatus *status) {
  StatusClear(status);
  if (callbacks == nullptr || target == nullptr) {
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  auto *fake_target = new FakeTarget();
  fake_target->callbacks = *callbacks;
  gTargets.push_back(fake_target);
  *target = reinterpret_cast<VtkFlutterTextureTarget *>(fake_target);
  return VTK_FLUTTER_STATUS_OK;
}

std::int32_t VTK_FLUTTER_CALL TargetDestroy(VtkFlutterTextureTarget *target,
                                            VtkFlutterStatus *status) {
  StatusClear(status);
  auto *fake_target = reinterpret_cast<FakeTarget *>(target);
  if (fake_target == gDestroyFailureTarget && gDestroyFailuresRemaining > 0) {
    --gDestroyFailuresRemaining;
    status->code = VTK_FLUTTER_STATUS_INTERNAL_ERROR;
    return VTK_FLUTTER_STATUS_INTERNAL_ERROR;
  }
  if (fake_target == nullptr || fake_target->destroyed ||
      fake_target->session != nullptr) {
    return VTK_FLUTTER_STATUS_INVALID_STATE;
  }
  fake_target->destroyed = true;
  return VTK_FLUTTER_STATUS_OK;
}

std::int32_t VTK_FLUTTER_CALL SessionIsValid(VtkFlutterSession *,
                                             VtkFlutterStatus *) {
  return VTK_FLUTTER_STATUS_OK;
}

VtkFlutterPresentationApi CompletePresentationApi() {
  return {
      sizeof(VtkFlutterPresentationApi),
      VTK_FLUTTER_PRESENTATION_API_VERSION,
      StatusClear,
      SessionIsValid,
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

class FakeViewHost final : public WindowsVtkViewHost {
public:
  bool IsAvailable() const noexcept override { return available; }
  bool IsOnPlatformThread() const noexcept override {
    return on_platform_thread;
  }

  std::int64_t RegisterTexture(flutter::TextureVariant *texture) override {
    if (!on_platform_thread) {
      registration_off_platform = true;
    }
    if (fail_next_registration) {
      fail_next_registration = false;
      return -1;
    }
    const auto texture_id = next_texture_id++;
    textures.emplace(texture_id, texture);
    registered_texture_ids.push_back(texture_id);
    return texture_id;
  }

  bool MarkTextureFrameAvailable(std::int64_t texture_id) override {
    marked_texture_ids.push_back(texture_id);
    return textures.contains(texture_id);
  }

  void UnregisterTexture(std::int64_t texture_id,
                         std::function<void()> callback) override {
    if (fail_next_unregistration) {
      fail_next_unregistration = false;
      throw std::runtime_error("Injected texture unregistration failure");
    }
    unregistered_texture_ids.push_back(texture_id);
    textures.erase(texture_id);
    if (defer_unregistrations) {
      pending_unregistrations.push_back(std::move(callback));
    } else {
      callback();
    }
  }

  bool PostToPlatform(std::function<void()> operation) override {
    if (fail_next_platform_post) {
      fail_next_platform_post = false;
      throw std::runtime_error("Injected platform dispatch failure");
    }
    ++posted_operation_count;
    if (dispatch_platform_operations_immediately) {
      operation();
      return true;
    }
    if (platform_post_succeeds) {
      std::lock_guard lock(platform_operations_mutex);
      pending_platform_operations.push_back(std::move(operation));
    }
    return platform_post_succeeds;
  }

  void DrainPlatformOperations() override {
    ++drain_call_count;
    std::vector<std::function<void()>> operations;
    {
      std::lock_guard lock(platform_operations_mutex);
      operations = std::move(pending_platform_operations);
      pending_platform_operations.clear();
    }
    for (auto &operation : operations) {
      operation();
    }
  }

  std::size_t PendingPlatformOperationCount() {
    std::lock_guard lock(platform_operations_mutex);
    return pending_platform_operations.size();
  }

  void CompleteNextUnregistration() {
    ASSERT_FALSE(pending_unregistrations.empty());
    auto callback = std::move(pending_unregistrations.front());
    pending_unregistrations.erase(pending_unregistrations.begin());
    callback();
  }

  void CompleteAllUnregistrations() {
    while (!pending_unregistrations.empty()) {
      CompleteNextUnregistration();
    }
  }

  bool available = true;
  bool on_platform_thread = true;
  bool fail_next_registration = false;
  bool fail_next_unregistration = false;
  bool defer_unregistrations = false;
  bool dispatch_platform_operations_immediately = true;
  bool platform_post_succeeds = true;
  bool fail_next_platform_post = false;
  bool registration_off_platform = false;
  int posted_operation_count = 0;
  std::atomic<int> drain_call_count = 0;
  std::int64_t next_texture_id = 1;
  std::unordered_map<std::int64_t, flutter::TextureVariant *> textures;
  std::vector<std::int64_t> registered_texture_ids;
  std::vector<std::int64_t> marked_texture_ids;
  std::vector<std::int64_t> unregistered_texture_ids;
  std::vector<std::function<void()>> pending_unregistrations;
  std::vector<std::function<void()>> pending_platform_operations;
  std::mutex platform_operations_mutex;
};

struct MethodResponse {
  bool completed = false;
  std::optional<EncodableValue> value;
  std::string error_code;
};

void Invoke(VtkFlutterPlugin &plugin, const char *method,
            const EncodableValue &arguments, MethodResponse &response) {
  plugin.HandleMethodCall(
      MethodCall(method, std::make_unique<EncodableValue>(arguments)),
      std::make_unique<MethodResultFunctions<>>(
          [&response](const EncodableValue *value) {
            response.completed = true;
            if (value != nullptr) {
              response.value = *value;
            }
          },
          [&response](const std::string &code, const std::string &,
                      const EncodableValue *) {
            response.completed = true;
            response.error_code = code;
          },
          nullptr));
}

const EncodableMap &ResponseMap(const MethodResponse &response) {
  return std::get<EncodableMap>(*response.value);
}

void CompleteFrame(FakeTarget *target, std::int32_t width) {
  VtkFlutterViewport viewport{width, 8};
  VtkFlutterCpuFrame frame{};
  VtkFlutterStatus status{};
  ASSERT_EQ(target->callbacks.begin_frame(target->callbacks.user_data,
                                          &viewport, &frame, &status),
            VTK_FLUTTER_STATUS_OK);
  ASSERT_NE(frame.pixels, nullptr);
  frame.pixels[0] = static_cast<std::uint8_t>(width);
  VtkFlutterFrameMetrics metrics{};
  ASSERT_EQ(target->callbacks.end_frame(target->callbacks.user_data, &metrics,
                                        &status),
            VTK_FLUTTER_STATUS_OK);
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
  const auto arguments = SessionArguments(4096);
  plugin.HandleMethodCall(
      MethodCall("disposeView", std::make_unique<EncodableValue>(arguments)),
      std::make_unique<MethodResultFunctions<>>(
          [&succeeded](const EncodableValue *) { succeeded = true; }, nullptr,
          nullptr));

  EXPECT_TRUE(succeeded);
}

TEST(VtkFlutterPlugin, RejectsStatusWithoutSessionAddress) {
  VtkFlutterPlugin plugin;
  std::string error_code;
  plugin.HandleMethodCall(
      MethodCall("status", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](const std::string &code, const std::string &,
                        const EncodableValue *) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "invalid_native_session");
}

TEST(VtkFlutterPlugin, RoutesTwoSessionsThroughIndependentViewLifecycles) {
  ResetFakePresentation();
  {
    auto host = std::make_unique<FakeViewHost>();
    auto *fake_host = host.get();
    fake_host->defer_unregistrations = true;
    VtkFlutterPlugin plugin(std::move(host));
    auto api = CompletePresentationApi();
    auto *first_session = reinterpret_cast<VtkFlutterSession *>(0x1000);
    auto *second_session = reinterpret_cast<VtkFlutterSession *>(0x2000);
    const auto first_arguments =
        ViewArguments(16, 8, Address(&api), Address(first_session));
    const auto second_arguments =
        ViewArguments(24, 8, Address(&api), Address(second_session));
    const auto first_address = SessionArguments(Address(first_session));
    const auto second_address = SessionArguments(Address(second_session));

    MethodResponse first_create;
    Invoke(plugin, "createView", first_arguments, first_create);
    MethodResponse second_create;
    Invoke(plugin, "createView", second_arguments, second_create);
    ASSERT_TRUE(first_create.completed);
    ASSERT_TRUE(second_create.completed);
    EXPECT_EQ(
        std::get<std::int64_t>(ValueAt(ResponseMap(first_create), "textureId")),
        1);
    EXPECT_EQ(std::get<std::int64_t>(
                  ValueAt(ResponseMap(second_create), "textureId")),
              2);
    ASSERT_EQ(gTargets.size(), 2U);
    EXPECT_EQ(gTargets[0]->session, first_session);
    EXPECT_EQ(gTargets[1]->session, second_session);

    MethodResponse repeated_create;
    Invoke(plugin, "createView", first_arguments, repeated_create);
    ASSERT_TRUE(repeated_create.completed);
    EXPECT_EQ(std::get<std::int64_t>(
                  ValueAt(ResponseMap(repeated_create), "textureId")),
              1);
    EXPECT_EQ(fake_host->registered_texture_ids,
              (std::vector<std::int64_t>{1, 2}));

    CompleteFrame(gTargets[0], 16);
    CompleteFrame(gTargets[1], 24);
    MethodResponse first_present;
    Invoke(plugin, "presentFrame", first_address, first_present);
    MethodResponse second_present;
    Invoke(plugin, "presentFrame", second_address, second_present);
    EXPECT_TRUE(first_present.completed);
    EXPECT_TRUE(second_present.completed);
    EXPECT_EQ(fake_host->marked_texture_ids, (std::vector<std::int64_t>{1, 2}));

    MethodResponse second_recreate;
    Invoke(plugin, "recreateGraphicsContext", second_address, second_recreate);
    ASSERT_TRUE(second_recreate.completed);
    EXPECT_EQ(std::get<std::int64_t>(ValueAt(ResponseMap(second_recreate),
                                             "graphicsContextGeneration")),
              2);
    ASSERT_EQ(gTargets.size(), 3U);
    EXPECT_EQ(gTargets[2]->session, second_session);

    MethodResponse first_resize;
    Invoke(plugin, "resize",
           EncodableValue(EncodableMap{
               {Key("nativeSessionAddress"),
                EncodableValue(Address(first_session))},
               {Key("width"), EncodableValue(32)},
               {Key("height"), EncodableValue(8)},
           }),
           first_resize);
    EXPECT_TRUE(first_resize.completed);
    EXPECT_TRUE(first_resize.error_code.empty());

    MethodResponse first_status;
    Invoke(plugin, "status", first_address, first_status);
    MethodResponse second_status;
    Invoke(plugin, "status", second_address, second_status);
    EXPECT_EQ(std::get<std::int64_t>(ValueAt(ResponseMap(first_status),
                                             "graphicsContextGeneration")),
              1);
    EXPECT_EQ(std::get<std::int64_t>(ValueAt(ResponseMap(second_status),
                                             "graphicsContextGeneration")),
              2);

    MethodResponse first_dispose;
    Invoke(plugin, "disposeView", first_address, first_dispose);
    EXPECT_FALSE(first_dispose.completed);
    EXPECT_EQ(fake_host->unregistered_texture_ids,
              (std::vector<std::int64_t>{1}));

    MethodResponse queued_first_create;
    Invoke(plugin, "createView", first_arguments, queued_first_create);
    EXPECT_FALSE(queued_first_create.completed);
    MethodResponse still_ready_second_status;
    Invoke(plugin, "status", second_address, still_ready_second_status);
    ASSERT_TRUE(still_ready_second_status.completed);
    EXPECT_TRUE(std::get<bool>(
        ValueAt(ResponseMap(still_ready_second_status), "ready")));

    fake_host->on_platform_thread = false;
    fake_host->CompleteNextUnregistration();
    fake_host->on_platform_thread = true;
    EXPECT_TRUE(first_dispose.completed);
    ASSERT_TRUE(queued_first_create.completed);
    EXPECT_EQ(std::get<std::int64_t>(
                  ValueAt(ResponseMap(queued_first_create), "textureId")),
              3);
    EXPECT_EQ(fake_host->textures.size(), 2U);
    EXPECT_EQ(fake_host->posted_operation_count, 1);

    MethodResponse absent_dispose;
    Invoke(plugin, "disposeView", SessionArguments(0x3000), absent_dispose);
    EXPECT_TRUE(absent_dispose.completed);
    EXPECT_TRUE(absent_dispose.error_code.empty());

    fake_host->defer_unregistrations = false;
    MethodResponse recreated_first_dispose;
    Invoke(plugin, "disposeView", first_address, recreated_first_dispose);
    MethodResponse second_dispose;
    Invoke(plugin, "disposeView", second_address, second_dispose);
    EXPECT_TRUE(recreated_first_dispose.completed);
    EXPECT_TRUE(second_dispose.completed);
  }
  ResetFakePresentation();
}

TEST(VtkFlutterPlugin, KeepsOtherSessionsUsableAcrossRetryableCleanupFailures) {
  ResetFakePresentation();
  {
    auto host = std::make_unique<FakeViewHost>();
    auto *fake_host = host.get();
    VtkFlutterPlugin plugin(std::move(host));
    auto api = CompletePresentationApi();
    auto *first_session = reinterpret_cast<VtkFlutterSession *>(0x4000);
    auto *second_session = reinterpret_cast<VtkFlutterSession *>(0x5000);
    const auto first_arguments =
        ViewArguments(16, 8, Address(&api), Address(first_session));
    const auto second_arguments =
        ViewArguments(24, 8, Address(&api), Address(second_session));
    const auto first_address = SessionArguments(Address(first_session));
    const auto second_address = SessionArguments(Address(second_session));

    MethodResponse first_create;
    Invoke(plugin, "createView", first_arguments, first_create);
    MethodResponse second_create;
    Invoke(plugin, "createView", second_arguments, second_create);
    ASSERT_TRUE(first_create.completed);
    ASSERT_TRUE(second_create.completed);
    ASSERT_EQ(gTargets.size(), 2U);

    gDestroyFailureTarget = gTargets[0];
    gDestroyFailuresRemaining = 1;
    MethodResponse failed_dispose;
    Invoke(plugin, "disposeView", first_address, failed_dispose);
    EXPECT_TRUE(failed_dispose.completed);
    EXPECT_EQ(failed_dispose.error_code, "vtk_internal_error");
    EXPECT_TRUE(fake_host->unregistered_texture_ids.empty());

    CompleteFrame(gTargets[1], 24);
    MethodResponse second_present;
    Invoke(plugin, "presentFrame", second_address, second_present);
    EXPECT_TRUE(second_present.completed);
    EXPECT_TRUE(second_present.error_code.empty());
    EXPECT_EQ(fake_host->marked_texture_ids, (std::vector<std::int64_t>{2}));

    MethodResponse retry_dispose;
    Invoke(plugin, "disposeView", first_address, retry_dispose);
    EXPECT_TRUE(retry_dispose.completed);
    EXPECT_TRUE(retry_dispose.error_code.empty());
    EXPECT_EQ(fake_host->unregistered_texture_ids,
              (std::vector<std::int64_t>{1}));

    gDestroyFailureTarget = gTargets[1];
    gDestroyFailuresRemaining = 2;
    MethodResponse recreation_with_deferred_cleanup;
    Invoke(plugin, "recreateGraphicsContext", second_address,
           recreation_with_deferred_cleanup);
    ASSERT_TRUE(recreation_with_deferred_cleanup.completed);
    EXPECT_TRUE(std::get<bool>(ValueAt(
        ResponseMap(recreation_with_deferred_cleanup), "cleanupPending")));
    ASSERT_EQ(gTargets.size(), 3U);
    EXPECT_EQ(gTargets[2]->session, second_session);

    CompleteFrame(gTargets[2], 24);
    MethodResponse present_after_recreation;
    Invoke(plugin, "presentFrame", second_address, present_after_recreation);
    EXPECT_TRUE(present_after_recreation.completed);

    MethodResponse failed_pending_cleanup;
    Invoke(plugin, "recreateGraphicsContext", second_address,
           failed_pending_cleanup);
    EXPECT_TRUE(failed_pending_cleanup.completed);
    EXPECT_EQ(failed_pending_cleanup.error_code, "vtk_context_failed");
    EXPECT_EQ(gTargets.size(), 3U);

    MethodResponse successful_retry;
    Invoke(plugin, "recreateGraphicsContext", second_address, successful_retry);
    ASSERT_TRUE(successful_retry.completed);
    EXPECT_TRUE(successful_retry.error_code.empty());
    EXPECT_EQ(std::get<std::int64_t>(ValueAt(ResponseMap(successful_retry),
                                             "graphicsContextGeneration")),
              3);

    MethodResponse second_dispose;
    Invoke(plugin, "disposeView", second_address, second_dispose);
    EXPECT_TRUE(second_dispose.completed);
  }
  ResetFakePresentation();
}

TEST(VtkFlutterPlugin, RetainsIncompleteCreationForRollbackRetry) {
  ResetFakePresentation();
  {
    auto host = std::make_unique<FakeViewHost>();
    auto *fake_host = host.get();
    fake_host->fail_next_registration = true;
    VtkFlutterPlugin plugin(std::move(host));
    auto api = CompletePresentationApi();
    auto *session = reinterpret_cast<VtkFlutterSession *>(0x6000);
    const auto view_arguments =
        ViewArguments(16, 8, Address(&api), Address(session));
    const auto session_arguments = SessionArguments(Address(session));
    gDetachFailureSession = session;
    gDetachFailuresRemaining = 1;

    MethodResponse failed_create;
    Invoke(plugin, "createView", view_arguments, failed_create);
    EXPECT_TRUE(failed_create.completed);
    EXPECT_EQ(failed_create.error_code, "vtk_internal_error");
    ASSERT_EQ(gTargets.size(), 1U);
    EXPECT_EQ(gTargets[0]->session, session);

    MethodResponse blocked_create;
    Invoke(plugin, "createView", view_arguments, blocked_create);
    EXPECT_TRUE(blocked_create.completed);
    EXPECT_EQ(blocked_create.error_code, "invalid_state");

    MethodResponse cleanup_retry;
    Invoke(plugin, "disposeView", session_arguments, cleanup_retry);
    EXPECT_TRUE(cleanup_retry.completed);
    EXPECT_TRUE(cleanup_retry.error_code.empty());

    MethodResponse successful_create;
    Invoke(plugin, "createView", view_arguments, successful_create);
    EXPECT_TRUE(successful_create.completed);
    EXPECT_TRUE(successful_create.error_code.empty());
    EXPECT_EQ(std::get<std::int64_t>(
                  ValueAt(ResponseMap(successful_create), "textureId")),
              1);

    MethodResponse dispose;
    Invoke(plugin, "disposeView", session_arguments, dispose);
    EXPECT_TRUE(dispose.completed);
  }
  ResetFakePresentation();
}

TEST(VtkFlutterPlugin, RestoresTextureStateWhenUnregistrationCannotStart) {
  ResetFakePresentation();
  {
    auto host = std::make_unique<FakeViewHost>();
    auto *fake_host = host.get();
    VtkFlutterPlugin plugin(std::move(host));
    auto api = CompletePresentationApi();
    auto *session = reinterpret_cast<VtkFlutterSession *>(0x7000);
    const auto view_arguments =
        ViewArguments(16, 8, Address(&api), Address(session));
    const auto session_arguments = SessionArguments(Address(session));

    MethodResponse create;
    Invoke(plugin, "createView", view_arguments, create);
    ASSERT_TRUE(create.completed);
    ASSERT_TRUE(create.error_code.empty());
    fake_host->fail_next_unregistration = true;

    MethodResponse failed_dispose;
    Invoke(plugin, "disposeView", session_arguments, failed_dispose);
    EXPECT_TRUE(failed_dispose.completed);
    EXPECT_EQ(failed_dispose.error_code, "vtk_internal_error");
    EXPECT_TRUE(fake_host->unregistered_texture_ids.empty());

    MethodResponse retained_status;
    Invoke(plugin, "status", session_arguments, retained_status);
    ASSERT_TRUE(retained_status.completed);
    EXPECT_FALSE(
        std::get<bool>(ValueAt(ResponseMap(retained_status), "ready")));
    EXPECT_FALSE(
        std::get<bool>(ValueAt(ResponseMap(retained_status), "disposing")));
    EXPECT_EQ(std::get<std::int64_t>(
                  ValueAt(ResponseMap(retained_status), "textureId")),
              1);

    MethodResponse retry_dispose;
    Invoke(plugin, "disposeView", session_arguments, retry_dispose);
    EXPECT_TRUE(retry_dispose.completed);
    EXPECT_TRUE(retry_dispose.error_code.empty());
    EXPECT_EQ(fake_host->unregistered_texture_ids,
              (std::vector<std::int64_t>{1}));
  }
  ResetFakePresentation();
}

TEST(VtkFlutterPlugin, CompletesTextureCleanupAfterPlatformWakeupFailure) {
  ResetFakePresentation();
  {
    auto host = std::make_unique<FakeViewHost>();
    auto *fake_host = host.get();
    fake_host->defer_unregistrations = true;
    VtkFlutterPlugin plugin(std::move(host));
    auto api = CompletePresentationApi();
    auto *session = reinterpret_cast<VtkFlutterSession *>(0x8000);
    const auto view_arguments =
        ViewArguments(16, 8, Address(&api), Address(session));
    const auto session_arguments = SessionArguments(Address(session));

    MethodResponse create;
    Invoke(plugin, "createView", view_arguments, create);
    ASSERT_TRUE(create.completed);
    MethodResponse dispose;
    Invoke(plugin, "disposeView", session_arguments, dispose);
    MethodResponse queued_create;
    Invoke(plugin, "createView", view_arguments, queued_create);
    EXPECT_FALSE(dispose.completed);
    EXPECT_FALSE(queued_create.completed);

    fake_host->on_platform_thread = false;
    fake_host->dispatch_platform_operations_immediately = false;
    fake_host->platform_post_succeeds = false;
    fake_host->CompleteNextUnregistration();
    EXPECT_TRUE(dispose.completed);
    EXPECT_TRUE(queued_create.completed);
    EXPECT_EQ(queued_create.error_code, "vtk_create_failed");
    EXPECT_EQ(fake_host->PendingPlatformOperationCount(), 0U);
    EXPECT_FALSE(fake_host->registration_off_platform);

    fake_host->on_platform_thread = true;
    MethodResponse retry_create;
    Invoke(plugin, "createView", view_arguments, retry_create);
    EXPECT_TRUE(retry_create.completed);
    EXPECT_TRUE(retry_create.error_code.empty());
    fake_host->defer_unregistrations = false;
    fake_host->dispatch_platform_operations_immediately = true;
    MethodResponse final_dispose;
    Invoke(plugin, "disposeView", session_arguments, final_dispose);
    EXPECT_TRUE(final_dispose.completed);
  }
  ResetFakePresentation();
}

TEST(VtkFlutterPlugin, WaitsForDelayedPlatformCleanupDuringDestruction) {
  ResetFakePresentation();
  MethodResponse dispose;
  {
    auto host = std::make_unique<FakeViewHost>();
    auto *fake_host = host.get();
    fake_host->defer_unregistrations = true;
    auto plugin = std::make_unique<VtkFlutterPlugin>(std::move(host));
    auto api = CompletePresentationApi();
    auto *session = reinterpret_cast<VtkFlutterSession *>(0x9000);
    const auto view_arguments =
        ViewArguments(16, 8, Address(&api), Address(session));
    const auto session_arguments = SessionArguments(Address(session));

    MethodResponse create;
    Invoke(*plugin, "createView", view_arguments, create);
    ASSERT_TRUE(create.completed);
    Invoke(*plugin, "disposeView", session_arguments, dispose);
    EXPECT_FALSE(dispose.completed);

    fake_host->on_platform_thread = false;
    fake_host->dispatch_platform_operations_immediately = false;
    const auto drain_count_before_destruction =
        fake_host->drain_call_count.load();
    std::thread destroyer([&plugin] { plugin.reset(); });
    while (fake_host->drain_call_count.load() ==
           drain_count_before_destruction) {
      std::this_thread::yield();
    }
    fake_host->CompleteNextUnregistration();
    destroyer.join();
  }
  EXPECT_TRUE(dispose.completed);
  EXPECT_TRUE(dispose.error_code.empty());
  ResetFakePresentation();
}

TEST(VtkFlutterPlugin, CompletesCleanupWhenPlatformDispatchThrows) {
  ResetFakePresentation();
  {
    auto host = std::make_unique<FakeViewHost>();
    auto *fake_host = host.get();
    fake_host->defer_unregistrations = true;
    VtkFlutterPlugin plugin(std::move(host));
    auto api = CompletePresentationApi();
    auto *session = reinterpret_cast<VtkFlutterSession *>(0xA000);
    const auto view_arguments =
        ViewArguments(16, 8, Address(&api), Address(session));
    const auto session_arguments = SessionArguments(Address(session));

    MethodResponse create;
    Invoke(plugin, "createView", view_arguments, create);
    ASSERT_TRUE(create.completed);
    MethodResponse dispose;
    Invoke(plugin, "disposeView", session_arguments, dispose);
    EXPECT_FALSE(dispose.completed);

    fake_host->on_platform_thread = false;
    fake_host->fail_next_platform_post = true;
    fake_host->CompleteNextUnregistration();
    EXPECT_TRUE(dispose.completed);
    EXPECT_TRUE(dispose.error_code.empty());

    fake_host->on_platform_thread = true;
    MethodResponse recreated;
    Invoke(plugin, "createView", view_arguments, recreated);
    EXPECT_TRUE(recreated.completed);
    EXPECT_TRUE(recreated.error_code.empty());

    fake_host->defer_unregistrations = false;
    MethodResponse final_dispose;
    Invoke(plugin, "disposeView", session_arguments, final_dispose);
    EXPECT_TRUE(final_dispose.completed);
  }
  ResetFakePresentation();
}

} // namespace vtk_flutter::test
