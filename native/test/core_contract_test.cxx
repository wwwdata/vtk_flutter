#include "c_contract_support.h"
#include "callback_render_target.h"
#include "session.h"
#include "volume_pipeline.h"
#include "vtk_flutter.h"

#include <vtkCamera.h>
#include <vtkImageData.h>
#include <vtkRenderer.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <future>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

namespace {
using namespace std::chrono_literals;

void Require(bool condition, std::string_view message) {
  if (!condition) {
    throw std::runtime_error(std::string(message));
  }
}

void RequireCode(int32_t actual, int32_t expected,
                 const VtkFlutterStatus &status, std::string_view operation) {
  if (actual == expected) {
    return;
  }
  throw std::runtime_error(std::string(operation) + " returned " +
                           std::to_string(actual) + ": " + status.message);
}

template <typename Action>
void RequireInvalidArgument(Action action, std::string_view message) {
  try {
    action();
  } catch (const std::invalid_argument &) {
    return;
  }
  throw std::runtime_error(std::string(message));
}

VtkFlutterVolume MakeVolume(std::vector<std::int16_t> &voxels) {
  VtkFlutterVolume volume{};
  volume.voxels = voxels.data();
  volume.voxel_count = voxels.size();
  volume.width = 2;
  volume.height = 3;
  volume.depth = 4;
  const double affine[16] = {0.5, 0.0, 0.0, -4.0, 0.0, 0.6, 0.0, 8.0,
                             0.0, 0.0, 1.2, 12.0, 0.0, 0.0, 0.0, 1.0};
  std::copy(std::begin(affine), std::end(affine),
            std::begin(volume.index_to_patient));
  return volume;
}

VtkFlutterRenderRequest MakeRequest(
    int32_t mode = VTK_FLUTTER_RENDER_OBLIQUE_MPR, int32_t width = 48,
    int32_t height = 32) {
  VtkFlutterRenderRequest request{};
  request.mode = mode;
  request.viewport = {width, height};
  request.window_center = 350.0;
  request.window_width = 1800.0;
  request.plane_normal[2] = 1.0;
  request.camera_azimuth_degrees = 61.0;
  request.camera_elevation_degrees = -11.0;
  request.camera_zoom = 1.75;
  return request;
}

class RecordingRenderTarget final : public vtk_flutter::RenderTarget {
public:
  void Render(vtk_flutter::PreparedView view,
              const VtkFlutterViewport &viewport,
              VtkFlutterMetrics &metrics) override {
    ++render_count;
    captured_view = std::move(view);
    captured_viewport = viewport;
    metrics.surface_allocation_bytes = metrics.frame_bytes + 128;
    metrics.patient_to_clip_valid =
        captured_view.capture_patient_to_clip ? 1 : 0;
  }

  int render_count = 0;
  vtk_flutter::PreparedView captured_view;
  VtkFlutterViewport captured_viewport{};
};

class ThrowingRenderTarget final : public vtk_flutter::RenderTarget {
public:
  void Render(vtk_flutter::PreparedView, const VtkFlutterViewport &,
              VtkFlutterMetrics &) override {
    throw std::runtime_error("legacy render target failure");
  }
};

void SetCallbackStatus(VtkFlutterStatus *status, int32_t code,
                       std::string_view message) {
  if (status == nullptr) {
    return;
  }
  status->code = code;
  const auto length =
      std::min(message.size(), sizeof(status->message) - std::size_t{1});
  std::copy_n(message.data(), length, status->message);
  status->message[length] = '\0';
}

struct CallbackHarness {
  std::vector<std::uint8_t> pixels;
  std::uint64_t row_bytes = 0;
  std::uint64_t capacity_bytes = 0;
  int32_t pixel_format = VTK_FLUTTER_PIXEL_FORMAT_RGBA8888;
  std::uint32_t frame_struct_size = sizeof(VtkFlutterCpuFrameV2);
  std::uint32_t frame_version = VTK_FLUTTER_CPU_FRAME_VERSION_2;
  int32_t begin_result = VTK_FLUTTER_STATUS_OK;
  int32_t end_result = VTK_FLUTTER_STATUS_OK;
  bool throw_begin = false;
  bool throw_end = false;
  bool throw_cancel = false;
  bool reenter = false;
  bool gate_first_begin = false;
  const VtkFlutterCoreApiV2 *api = nullptr;
  VtkFlutterSession *session = nullptr;
  const VtkFlutterRenderRequest *request = nullptr;
  std::atomic<int> begin_count{0};
  std::atomic<int> end_count{0};
  std::atomic<int> cancel_count{0};
  std::atomic<int> active_frames{0};
  std::atomic<int> maximum_active_frames{0};
  int32_t reentry_result = VTK_FLUTTER_STATUS_OK;
  VtkFlutterStatus reentry_status{};
  std::mutex gate_mutex;
  std::condition_variable gate_condition;
  bool first_begin_entered = false;
  bool release_first_begin = false;
};

void RecordMaximum(std::atomic<int> &maximum, int candidate) {
  auto observed = maximum.load();
  while (observed < candidate &&
         !maximum.compare_exchange_weak(observed, candidate)) {
  }
}

int32_t VTK_FLUTTER_CALL HarnessBeginFrame(
    void *user_data, const VtkFlutterViewport *viewport,
    VtkFlutterCpuFrameV2 *frame, VtkFlutterStatus *status) {
  auto &harness = *static_cast<CallbackHarness *>(user_data);
  const auto call = ++harness.begin_count;
  if (harness.throw_begin) {
    throw std::runtime_error("C++ begin_frame exception");
  }
  if (harness.gate_first_begin && call == 1) {
    std::unique_lock lock(harness.gate_mutex);
    harness.first_begin_entered = true;
    harness.gate_condition.notify_all();
    harness.gate_condition.wait(
        lock, [&harness] { return harness.release_first_begin; });
  }
  if (harness.begin_result != VTK_FLUTTER_STATUS_OK) {
    SetCallbackStatus(status, harness.begin_result, "begin_frame rejected");
    return harness.begin_result;
  }

  const auto active = ++harness.active_frames;
  RecordMaximum(harness.maximum_active_frames, active);

  if (harness.reenter) {
    VtkFlutterMetrics nested_metrics{};
    harness.reentry_result = harness.api->session_render(
        harness.session, harness.request, &nested_metrics,
        &harness.reentry_status);
  }

  frame->struct_size = harness.frame_struct_size;
  frame->version = harness.frame_version;
  frame->pixels = harness.pixels.data();
  frame->capacity_bytes = harness.capacity_bytes;
  frame->row_bytes = harness.row_bytes;
  frame->pixel_format = harness.pixel_format;
  Require(viewport->width > 0 && viewport->height > 0,
          "begin_frame received an invalid viewport");
  return VTK_FLUTTER_STATUS_OK;
}

int32_t VTK_FLUTTER_CALL HarnessEndFrame(
    void *user_data, const VtkFlutterMetrics *, VtkFlutterStatus *status) {
  auto &harness = *static_cast<CallbackHarness *>(user_data);
  ++harness.end_count;
  if (harness.throw_end) {
    throw std::runtime_error("C++ end_frame exception");
  }
  if (harness.end_result != VTK_FLUTTER_STATUS_OK) {
    SetCallbackStatus(status, harness.end_result, "end_frame rejected");
    return harness.end_result;
  }
  --harness.active_frames;
  return VTK_FLUTTER_STATUS_OK;
}

void VTK_FLUTTER_CALL HarnessCancelFrame(void *user_data) {
  auto &harness = *static_cast<CallbackHarness *>(user_data);
  ++harness.cancel_count;
  --harness.active_frames;
  if (harness.throw_cancel) {
    throw std::runtime_error("C++ cancel_frame exception");
  }
}

VtkFlutterFrameCallbacksV2 MakeHarnessCallbacks(CallbackHarness &harness) {
  return {
      sizeof(VtkFlutterFrameCallbacksV2),
      VTK_FLUTTER_FRAME_CALLBACKS_VERSION_2,
      &harness,
      HarnessBeginFrame,
      HarnessEndFrame,
      HarnessCancelFrame,
  };
}

void PrepareHarnessFrame(CallbackHarness &harness,
                         const VtkFlutterViewport &viewport,
                         std::uint64_t padding = 0) {
  harness.row_bytes =
      static_cast<std::uint64_t>(viewport.width) * 4ULL + padding;
  harness.capacity_bytes =
      harness.row_bytes * static_cast<std::uint64_t>(viewport.height);
  harness.pixels.assign(static_cast<std::size_t>(harness.capacity_bytes),
                        0xA5);
}

void TestCpuFrameCopyContract() {
  const VtkFlutterViewport viewport{2, 2};
  const std::array<std::uint8_t, 16> bottom_up_rgba{
      1,  2,  3,  4,  5,  6,  7,  8,
      11, 12, 13, 14, 15, 16, 17, 18,
  };
  constexpr std::uint8_t padding = 0xCC;
  std::array<std::uint8_t, 24> destination{};
  destination.fill(padding);
  VtkFlutterCpuFrameV2 frame{
      sizeof(VtkFlutterCpuFrameV2),
      VTK_FLUTTER_CPU_FRAME_VERSION_2,
      destination.data(),
      20,
      12,
      VTK_FLUTTER_PIXEL_FORMAT_RGBA8888,
  };

  vtk_flutter::CopyRgbaBottomUpToFrame(bottom_up_rgba.data(), viewport,
                                       frame);
  const std::array<std::uint8_t, 8> expected_top{11, 12, 13, 14,
                                                15, 16, 17, 18};
  const std::array<std::uint8_t, 8> expected_bottom{1, 2, 3, 4, 5, 6, 7, 8};
  Require(std::equal(expected_top.begin(), expected_top.end(),
                     destination.begin()),
          "RGBA copy did not flip the top row");
  Require(std::equal(expected_bottom.begin(), expected_bottom.end(),
                     destination.begin() + 12),
          "RGBA copy did not flip the bottom row");
  Require(std::all_of(destination.begin() + 8, destination.begin() + 12,
                      [](auto value) { return value == padding; }) &&
              std::all_of(destination.begin() + 20, destination.end(),
                          [](auto value) { return value == padding; }),
          "RGBA copy overwrote row padding");

  destination.fill(padding);
  frame.pixel_format = VTK_FLUTTER_PIXEL_FORMAT_BGRA8888;
  vtk_flutter::CopyRgbaBottomUpToFrame(bottom_up_rgba.data(), viewport,
                                       frame);
  const std::array<std::uint8_t, 8> expected_bgra_top{13, 12, 11, 14,
                                                     17, 16, 15, 18};
  const std::array<std::uint8_t, 8> expected_bgra_bottom{3, 2, 1, 4,
                                                        7, 6, 5, 8};
  Require(std::equal(expected_bgra_top.begin(), expected_bgra_top.end(),
                     destination.begin()) &&
              std::equal(expected_bgra_bottom.begin(),
                         expected_bgra_bottom.end(), destination.begin() + 12),
          "BGRA copy did not flip rows and swap red/blue exactly");
  Require(std::all_of(destination.begin() + 8, destination.begin() + 12,
                      [](auto value) { return value == padding; }),
          "BGRA copy overwrote row padding");

  const auto valid_frame = frame;
  RequireInvalidArgument(
      [&] {
        auto invalid = valid_frame;
        --invalid.struct_size;
        vtk_flutter::CopyRgbaBottomUpToFrame(bottom_up_rgba.data(), viewport,
                                             invalid);
      },
      "CPU frame accepted a truncated descriptor");
  RequireInvalidArgument(
      [&] {
        auto invalid = valid_frame;
        ++invalid.version;
        vtk_flutter::CopyRgbaBottomUpToFrame(bottom_up_rgba.data(), viewport,
                                             invalid);
      },
      "CPU frame accepted an unsupported version");
  RequireInvalidArgument(
      [&] {
        auto invalid = valid_frame;
        invalid.pixels = nullptr;
        vtk_flutter::CopyRgbaBottomUpToFrame(bottom_up_rgba.data(), viewport,
                                             invalid);
      },
      "CPU frame accepted null pixels");
  RequireInvalidArgument(
      [&] {
        auto invalid = valid_frame;
        invalid.pixel_format = 999;
        vtk_flutter::CopyRgbaBottomUpToFrame(bottom_up_rgba.data(), viewport,
                                             invalid);
      },
      "CPU frame accepted an unknown pixel format");
  RequireInvalidArgument(
      [&] {
        auto invalid = valid_frame;
        invalid.row_bytes = 7;
        vtk_flutter::CopyRgbaBottomUpToFrame(bottom_up_rgba.data(), viewport,
                                             invalid);
      },
      "CPU frame accepted a short row");
  RequireInvalidArgument(
      [&] {
        auto invalid = valid_frame;
        invalid.capacity_bytes = 19;
        vtk_flutter::CopyRgbaBottomUpToFrame(bottom_up_rgba.data(), viewport,
                                             invalid);
      },
      "CPU frame accepted capacity one byte below the exact requirement");
  RequireInvalidArgument(
      [&] {
        auto invalid = valid_frame;
        invalid.row_bytes = std::numeric_limits<std::uint64_t>::max();
        invalid.capacity_bytes = std::numeric_limits<std::uint64_t>::max();
        vtk_flutter::CopyRgbaBottomUpToFrame(bottom_up_rgba.data(), viewport,
                                             invalid);
      },
      "CPU frame accepted an overflowing padded layout");
  RequireInvalidArgument(
      [&] {
        vtk_flutter::CopyRgbaBottomUpToFrame(nullptr, viewport, valid_frame);
      },
      "CPU copy accepted null VTK pixels");
}

void TestPublicCAndLegacyMigrationContract() {
  static_assert(std::is_standard_layout_v<VtkFlutterViewport>);
  static_assert(std::is_standard_layout_v<VtkFlutterVolume>);
  static_assert(std::is_standard_layout_v<VtkFlutterRenderRequest>);
  static_assert(std::is_standard_layout_v<VtkFlutterMetrics>);
  static_assert(std::is_standard_layout_v<VtkFlutterStatus>);
  static_assert(std::is_standard_layout_v<VtkFlutterCpuFrameV2>);

  Require(vtk_flutter_abi_version() == 1U,
          "legacy C ABI version changed during migration");
  Require(vtk_flutter_public_header_is_c_compatible() == 0,
          "public header did not compile and operate as C11");
  const auto *api = vtk_flutter_get_core_api_v2();
  Require(api != nullptr && api->version == VTK_FLUTTER_CORE_API_VERSION_2 &&
              api->struct_size >= sizeof(VtkFlutterCoreApiV2),
          "v2 core table is unavailable");

  VtkFlutterStatus status{};
  VtkFlutterSession *session = nullptr;
  RequireCode(vtk_flutter_session_create(&session, &status),
              VTK_FLUTTER_STATUS_OK, status, "legacy session_create");
  Require(session != nullptr && status.message[0] == '\0',
          "legacy session_create did not clear status");

  std::vector<std::int16_t> voxels(24);
  for (std::size_t index = 0; index < voxels.size(); ++index) {
    voxels[index] = static_cast<std::int16_t>(index) - 12;
  }
  auto volume = MakeVolume(voxels);
  RequireCode(vtk_flutter_validate_volume(&volume, &status),
              VTK_FLUTTER_STATUS_OK, status, "legacy validate_volume");
  RequireCode(vtk_flutter_session_set_volume(session, &volume, &status),
              VTK_FLUTTER_STATUS_OK, status, "legacy session_set_volume");
  --volume.voxel_count;
  Require(vtk_flutter_validate_volume(&volume, &status) ==
                  VTK_FLUTTER_STATUS_INVALID_ARGUMENT &&
              status.message[0] != '\0',
          "legacy validation accepted an inconsistent voxel count");
  ++volume.voxel_count;
  volume.index_to_patient[0] = INFINITY;
  Require(vtk_flutter_validate_volume(&volume, &status) ==
              VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
          "legacy validation accepted a non-finite affine");
  volume.index_to_patient[0] = 0.5;

  vtk_flutter::VolumePipeline pipeline;
  pipeline.SetVolume(volume);
  const auto first_voxel = voxels.front();
  voxels.front() = 12345;
  Require(*static_cast<std::int16_t *>(pipeline.Image()->GetScalarPointer(
              0, 0, 0)) == first_voxel,
          "volume upload retained caller-owned voxel memory");
  voxels.front() = first_voxel;
  int dimensions[3]{};
  pipeline.Image()->GetDimensions(dimensions);
  double spacing[3]{};
  pipeline.Image()->GetSpacing(spacing);
  double origin[3]{};
  pipeline.Image()->GetOrigin(origin);
  Require(dimensions[0] == 2 && dimensions[1] == 3 && dimensions[2] == 4 &&
              std::abs(spacing[0] - 0.5) < 1e-12 &&
              std::abs(spacing[1] - 0.6) < 1e-12 &&
              std::abs(spacing[2] - 1.2) < 1e-12 && origin[0] == -4.0 &&
              origin[1] == 8.0 && origin[2] == 12.0,
          "volume pipeline did not preserve dimensions and affine geometry");

  auto request = MakeRequest(VTK_FLUTTER_RENDER_OBLIQUE_MPR);
  RequireCode(vtk_flutter_validate_render_request(&request, &status),
              VTK_FLUTTER_STATUS_OK, status,
              "legacy validate_render_request");
  request.plane_normal[2] = 0.0;
  Require(vtk_flutter_validate_render_request(&request, &status) ==
              VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
          "legacy validation accepted a zero oblique normal");
  request.plane_normal[2] = 1.0;
  request.viewport.width = 8193;
  Require(vtk_flutter_validate_render_request(&request, &status) ==
              VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
          "legacy validation accepted an oversized viewport");
  request.viewport.width = 48;
  request.camera_zoom = 5.01;
  Require(vtk_flutter_validate_render_request(&request, &status) ==
              VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
          "legacy validation accepted an out-of-range zoom");
  request.camera_zoom = 1.75;
  request.mode = 999;
  Require(vtk_flutter_validate_render_request(&request, &status) ==
              VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
          "legacy validation accepted an unknown mode");

  request = MakeRequest(VTK_FLUTTER_RENDER_VOLUME_LOCATOR);
  VtkFlutterMetrics metrics{};
  Require(vtk_flutter_session_render(session, &request, &metrics, &status) ==
              VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE,
          "legacy core-created session did not report a missing target");
  vtk_flutter_session_destroy(session);

  auto recording_target = std::make_unique<RecordingRenderTarget>();
  auto *recording_observer = recording_target.get();
  VtkFlutterSession legacy_platform_session(std::move(recording_target));
  RequireCode(vtk_flutter_session_set_volume(&legacy_platform_session, &volume,
                                             &status),
              VTK_FLUTTER_STATUS_OK, status, "legacy platform set_volume");
  RequireCode(vtk_flutter_session_render(&legacy_platform_session, &request,
                                         &metrics, &status),
              VTK_FLUTTER_STATUS_OK, status, "legacy platform render");
  Require(recording_observer->render_count == 1 &&
              recording_observer->captured_view.renderer != nullptr &&
              recording_observer->captured_viewport.width == 48 &&
              recording_observer->captured_viewport.height == 32 &&
              metrics.volume_bytes == voxels.size() * sizeof(std::int16_t) &&
              metrics.frame_bytes == 48ULL * 32ULL * 4ULL &&
              metrics.frame_width == 48 && metrics.frame_height == 32 &&
              metrics.patient_to_clip_valid == 1,
          "legacy in-process platform target behavior changed");

  VtkFlutterSession throwing_platform_session(
      std::make_unique<ThrowingRenderTarget>());
  Require(vtk_flutter_session_render(&throwing_platform_session, &request,
                                     &metrics, &status) ==
                  VTK_FLUTTER_STATUS_INTERNAL_ERROR &&
              std::string(status.message) == "legacy render target failure" &&
              metrics.frame_bytes == 0,
          "legacy render exception escaped or leaked partial metrics");
}

void TestCoreTableCreationAndLifecycle() {
  const auto *api = vtk_flutter_get_core_api_v2();
  VtkFlutterStatus status{};
  std::array<std::uint8_t, 4> pixel{};
  VtkFlutterTestFrameRecorder recorder{};
  recorder.pixels = pixel.data();
  recorder.capacity_bytes = pixel.size();
  recorder.row_bytes = 4;
  recorder.pixel_format = VTK_FLUTTER_PIXEL_FORMAT_RGBA8888;

  VtkFlutterTextureTarget *target = nullptr;
  RequireCode(vtk_flutter_test_create_target_from_c(api, &recorder, &target,
                                                    &status),
              VTK_FLUTTER_STATUS_OK, status, "C11 texture_target_create");
  Require(target != nullptr, "C11 texture_target_create returned null");
  RequireCode(vtk_flutter_test_destroy_target_from_c(api, target, &status),
              VTK_FLUTTER_STATUS_OK, status, "C11 texture_target_destroy");

  auto callbacks = vtk_flutter_test_frame_callbacks_v2(&recorder);
  target = reinterpret_cast<VtkFlutterTextureTarget *>(0x1);
  auto invalid_callbacks = callbacks;
  --invalid_callbacks.struct_size;
  Require(api->texture_target_create(&invalid_callbacks, &target, &status) ==
                  VTK_FLUTTER_STATUS_INVALID_ARGUMENT &&
              target == nullptr,
          "target creation accepted a truncated callback table");
  invalid_callbacks = callbacks;
  ++invalid_callbacks.version;
  Require(api->texture_target_create(&invalid_callbacks, &target, &status) ==
                  VTK_FLUTTER_STATUS_INVALID_ARGUMENT &&
              target == nullptr,
          "target creation accepted an unsupported callback version");
  invalid_callbacks = callbacks;
  invalid_callbacks.cancel_frame = nullptr;
  Require(api->texture_target_create(&invalid_callbacks, &target, &status) ==
                  VTK_FLUTTER_STATUS_INVALID_ARGUMENT &&
              target == nullptr,
          "target creation accepted an incomplete callback table");

  VtkFlutterSession *first_session = nullptr;
  VtkFlutterSession *second_session = nullptr;
  RequireCode(api->session_create(&first_session, &status),
              VTK_FLUTTER_STATUS_OK, status, "first session_create");
  RequireCode(api->session_create(&second_session, &status),
              VTK_FLUTTER_STATUS_OK, status, "second session_create");
  RequireCode(vtk_flutter_test_create_target_from_c(api, &recorder, &target,
                                                    &status),
              VTK_FLUTTER_STATUS_OK, status, "lifecycle target_create");
  VtkFlutterTextureTarget *second_target = nullptr;
  RequireCode(vtk_flutter_test_create_target_from_c(
                  api, &recorder, &second_target, &status),
              VTK_FLUTTER_STATUS_OK, status, "second target_create");

  RequireCode(api->session_attach_texture_target(first_session, target,
                                                 &status),
              VTK_FLUTTER_STATUS_OK, status, "first attach");
  RequireCode(api->session_attach_texture_target(first_session, target,
                                                 &status),
              VTK_FLUTTER_STATUS_OK, status, "idempotent attach");
  Require(api->session_attach_texture_target(second_session, target, &status) ==
              VTK_FLUTTER_STATUS_INVALID_STATE,
          "one texture target attached to two sessions");
  Require(api->session_attach_texture_target(first_session, second_target,
                                             &status) ==
              VTK_FLUTTER_STATUS_INVALID_STATE,
          "one session accepted two texture targets");
  Require(api->texture_target_destroy(target, &status) ==
              VTK_FLUTTER_STATUS_INVALID_STATE,
          "attached texture target was destroyed");
  RequireCode(api->session_detach_texture_target(first_session, target,
                                                 &status),
              VTK_FLUTTER_STATUS_OK, status, "first detach");
  RequireCode(api->session_detach_texture_target(first_session, target,
                                                 &status),
              VTK_FLUTTER_STATUS_OK, status, "idempotent detach");
  RequireCode(api->session_attach_texture_target(second_session, target,
                                                 &status),
              VTK_FLUTTER_STATUS_OK, status, "reattach to second session");
  RequireCode(api->session_detach_texture_target(second_session, target,
                                                 &status),
              VTK_FLUTTER_STATUS_OK, status, "second detach");
  RequireCode(api->texture_target_destroy(target, &status),
              VTK_FLUTTER_STATUS_OK, status, "detached target_destroy");

  RequireCode(api->session_attach_texture_target(first_session, second_target,
                                                 &status),
              VTK_FLUTTER_STATUS_OK, status, "attach before session destroy");
  api->session_destroy(first_session);
  RequireCode(api->texture_target_destroy(second_target, &status),
              VTK_FLUTTER_STATUS_OK, status,
              "session destruction did not detach target");
  api->session_destroy(second_session);
}

void TestRealOffscreenRenderingThroughC() {
  const auto *api = vtk_flutter_get_core_api_v2();
  VtkFlutterStatus status{};
  VtkFlutterSession *session = nullptr;
  RequireCode(api->session_create(&session, &status), VTK_FLUTTER_STATUS_OK,
              status, "offscreen session_create");
  std::vector<std::int16_t> voxels(24);
  for (std::size_t index = 0; index < voxels.size(); ++index) {
    voxels[index] = static_cast<std::int16_t>(index) - 12;
  }
  const auto volume = MakeVolume(voxels);
  RequireCode(api->session_set_volume(session, &volume, &status),
              VTK_FLUTTER_STATUS_OK, status, "offscreen session_set_volume");
  auto request = MakeRequest();
  request.plane_origin[0] = -3.75;
  request.plane_origin[1] = 8.6;
  request.plane_origin[2] = 13.8;
  constexpr std::uint64_t padding = 12;
  const auto row_bytes =
      static_cast<std::uint64_t>(request.viewport.width) * 4ULL + padding;
  std::vector<std::uint8_t> pixels(
      static_cast<std::size_t>(row_bytes) * request.viewport.height, 0xD7);
  VtkFlutterTestFrameRecorder recorder{};
  recorder.pixels = pixels.data();
  recorder.capacity_bytes = pixels.size();
  recorder.row_bytes = row_bytes;
  recorder.pixel_format = VTK_FLUTTER_PIXEL_FORMAT_RGBA8888;
  VtkFlutterTextureTarget *target = nullptr;
  RequireCode(vtk_flutter_test_create_target_from_c(api, &recorder, &target,
                                                    &status),
              VTK_FLUTTER_STATUS_OK, status, "offscreen target_create");
  RequireCode(api->session_attach_texture_target(session, target, &status),
              VTK_FLUTTER_STATUS_OK, status, "offscreen attach");

  VtkFlutterMetrics rgba_metrics{};
  RequireCode(api->session_render(session, &request, &rgba_metrics, &status),
              VTK_FLUTTER_STATUS_OK, status, "RGBA offscreen render");
  Require(recorder.begin_count == 1 && recorder.end_count == 1 &&
              recorder.cancel_count == 0 &&
              recorder.width == request.viewport.width &&
              recorder.height == request.viewport.height &&
              recorder.frame_bytes == 48ULL * 32ULL * 4ULL &&
              recorder.surface_allocation_bytes == pixels.size() &&
              rgba_metrics.surface_allocation_bytes == pixels.size() &&
              rgba_metrics.surface_unique_byte_values > 1 &&
              rgba_metrics.surface_changed_pixels > 0 &&
              rgba_metrics.surface_checksum == rgba_metrics.cpu_checksum,
          "real core-owned VTK render did not publish credible metrics");
  for (int row = 0; row < request.viewport.height; ++row) {
    const auto padding_begin =
        pixels.begin() + static_cast<std::ptrdiff_t>(row * row_bytes +
                                                    request.viewport.width * 4);
    Require(std::all_of(padding_begin,
                        pixels.begin() + static_cast<std::ptrdiff_t>(
                                             (row + 1) * row_bytes),
                        [](auto value) { return value == 0xD7; }),
            "real VTK render overwrote caller row padding");
  }
  const auto rgba_pixels = pixels;

  std::fill(pixels.begin(), pixels.end(), 0xD7);
  recorder.pixel_format = VTK_FLUTTER_PIXEL_FORMAT_BGRA8888;
  VtkFlutterMetrics bgra_metrics{};
  RequireCode(api->session_render(session, &request, &bgra_metrics, &status),
              VTK_FLUTTER_STATUS_OK, status, "BGRA offscreen render");
  for (int row = 0; row < request.viewport.height; ++row) {
    for (int column = 0; column < request.viewport.width; ++column) {
      const auto offset = static_cast<std::size_t>(row) * row_bytes +
                          static_cast<std::size_t>(column) * 4U;
      Require(pixels[offset] == rgba_pixels[offset + 2U] &&
                  pixels[offset + 1U] == rgba_pixels[offset + 1U] &&
                  pixels[offset + 2U] == rgba_pixels[offset] &&
                  pixels[offset + 3U] == rgba_pixels[offset + 3U],
              "real VTK BGRA render was not an exact red/blue conversion");
    }
  }

  RequireCode(api->session_detach_texture_target(session, target, &status),
              VTK_FLUTTER_STATUS_OK, status, "offscreen detach");
  RequireCode(vtk_flutter_test_destroy_target_from_c(api, target, &status),
              VTK_FLUTTER_STATUS_OK, status, "offscreen target_destroy");
  api->session_destroy(session);
}

struct HarnessFixture {
  explicit HarnessFixture(CallbackHarness &callback_harness)
      : harness(callback_harness), api(vtk_flutter_get_core_api_v2()) {
    VtkFlutterStatus status{};
    RequireCode(api->session_create(&session, &status),
                VTK_FLUTTER_STATUS_OK, status, "harness session_create");
    const auto callbacks = MakeHarnessCallbacks(harness);
    RequireCode(api->texture_target_create(&callbacks, &target, &status),
                VTK_FLUTTER_STATUS_OK, status, "harness target_create");
    RequireCode(api->session_attach_texture_target(session, target, &status),
                VTK_FLUTTER_STATUS_OK, status, "harness attach");
  }

  ~HarnessFixture() {
    VtkFlutterStatus status{};
    if (session != nullptr && target != nullptr) {
      api->session_detach_texture_target(session, target, &status);
    }
    if (target != nullptr) {
      api->texture_target_destroy(target, &status);
    }
    if (session != nullptr) {
      api->session_destroy(session);
    }
  }

  CallbackHarness &harness;
  const VtkFlutterCoreApiV2 *api;
  VtkFlutterSession *session = nullptr;
  VtkFlutterTextureTarget *target = nullptr;
};

void ResetHarnessCounts(CallbackHarness &harness) {
  harness.begin_count = 0;
  harness.end_count = 0;
  harness.cancel_count = 0;
  harness.active_frames = 0;
  harness.maximum_active_frames = 0;
}

void TestCallbackFailuresExceptionsAndCancellation() {
  auto request = MakeRequest(VTK_FLUTTER_RENDER_OBLIQUE_MPR, 24, 16);
  CallbackHarness harness;
  PrepareHarnessFrame(harness, request.viewport, 4);
  HarnessFixture fixture(harness);
  VtkFlutterMetrics metrics{};
  VtkFlutterStatus status{};

  harness.begin_result = VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  Require(fixture.api->session_render(fixture.session, &request, &metrics,
                                     &status) ==
                  VTK_FLUTTER_STATUS_INVALID_ARGUMENT &&
              std::string(status.message) == "begin_frame rejected" &&
              harness.begin_count == 1 && harness.end_count == 0 &&
              harness.cancel_count == 0 && metrics.frame_bytes == 0,
          "begin_frame failure was not contained without cancellation");

  ResetHarnessCounts(harness);
  harness.begin_result = VTK_FLUTTER_STATUS_OK;
  harness.end_result = VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE;
  Require(fixture.api->session_render(fixture.session, &request, &metrics,
                                     &status) ==
                  VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE &&
              std::string(status.message) == "end_frame rejected" &&
              harness.begin_count == 1 && harness.end_count == 1 &&
              harness.cancel_count == 1 && metrics.frame_bytes == 0,
          "end_frame failure did not cancel and clear partial metrics");

  ResetHarnessCounts(harness);
  harness.end_result = VTK_FLUTTER_STATUS_OK;
  harness.frame_version = VTK_FLUTTER_CPU_FRAME_VERSION_2 + 1;
  Require(fixture.api->session_render(fixture.session, &request, &metrics,
                                     &status) ==
                  VTK_FLUTTER_STATUS_INVALID_ARGUMENT &&
              harness.begin_count == 1 && harness.end_count == 0 &&
              harness.cancel_count == 1,
          "invalid callback frame descriptor was not cancelled");

  ResetHarnessCounts(harness);
  harness.frame_version = VTK_FLUTTER_CPU_FRAME_VERSION_2;
  harness.throw_begin = true;
  Require(fixture.api->session_render(fixture.session, &request, &metrics,
                                     &status) ==
                  VTK_FLUTTER_STATUS_INTERNAL_ERROR &&
              std::string(status.message) == "C++ begin_frame exception" &&
              harness.begin_count == 1 && harness.end_count == 0 &&
              harness.cancel_count == 0,
          "C++ begin_frame exception crossed the C seam");

  ResetHarnessCounts(harness);
  harness.throw_begin = false;
  harness.throw_end = true;
  harness.throw_cancel = true;
  Require(fixture.api->session_render(fixture.session, &request, &metrics,
                                     &status) ==
                  VTK_FLUTTER_STATUS_INTERNAL_ERROR &&
              std::string(status.message) == "C++ end_frame exception" &&
              harness.begin_count == 1 && harness.end_count == 1 &&
              harness.cancel_count == 1,
          "C++ end/cancel exceptions were not contained");
}

void TestSameSessionReentryIsRejected() {
  const auto request = MakeRequest(VTK_FLUTTER_RENDER_OBLIQUE_MPR, 24, 16);
  CallbackHarness harness;
  PrepareHarnessFrame(harness, request.viewport);
  HarnessFixture fixture(harness);
  harness.api = fixture.api;
  harness.session = fixture.session;
  harness.request = &request;
  harness.reenter = true;

  VtkFlutterMetrics metrics{};
  VtkFlutterStatus status{};
  RequireCode(fixture.api->session_render(fixture.session, &request, &metrics,
                                          &status),
              VTK_FLUTTER_STATUS_OK, status, "outer reentry render");
  Require(harness.reentry_result == VTK_FLUTTER_STATUS_INVALID_STATE &&
              std::string(harness.reentry_status.message) ==
                  "reentrant access to a session is not allowed" &&
              harness.begin_count == 1 && harness.end_count == 1 &&
              harness.cancel_count == 0,
          "same-session callback reentry was not rejected cleanly");
}

void TestConcurrentRendersAreSerialized() {
  const auto request = MakeRequest(VTK_FLUTTER_RENDER_OBLIQUE_MPR, 24, 16);
  CallbackHarness harness;
  PrepareHarnessFrame(harness, request.viewport);
  harness.gate_first_begin = true;
  harness.begin_result = VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  HarnessFixture fixture(harness);

  auto render = [&] {
    VtkFlutterMetrics metrics{};
    VtkFlutterStatus status{};
    const auto code = fixture.api->session_render(
        fixture.session, &request, &metrics, &status);
    return std::pair{code, std::string(status.message)};
  };
  auto first = std::async(std::launch::async, render);
  {
    std::unique_lock lock(harness.gate_mutex);
    Require(harness.gate_condition.wait_for(
                lock, 2s, [&harness] { return harness.first_begin_entered; }),
            "first concurrent render did not reach begin_frame");
  }
  auto second = std::async(std::launch::async, render);
  Require(second.wait_for(150ms) == std::future_status::timeout &&
              harness.begin_count == 1,
          "second render was not serialized behind the active operation");
  {
    std::lock_guard lock(harness.gate_mutex);
    harness.release_first_begin = true;
  }
  harness.gate_condition.notify_all();

  const auto first_result = first.get();
  const auto second_result = second.get();
  const auto concurrency_diagnostic =
      "concurrent renders: first=" + std::to_string(first_result.first) +
      " (" + first_result.second + "), second=" +
      std::to_string(second_result.first) + " (" + second_result.second +
      "), begin=" + std::to_string(harness.begin_count.load()) +
      ", end=" + std::to_string(harness.end_count.load()) +
      ", cancel=" + std::to_string(harness.cancel_count.load()) +
      ", max_active=" +
      std::to_string(harness.maximum_active_frames.load()) +
      ", active=" + std::to_string(harness.active_frames.load());
  Require(first_result.first == VTK_FLUTTER_STATUS_INVALID_ARGUMENT &&
              second_result.first == VTK_FLUTTER_STATUS_INVALID_ARGUMENT &&
              harness.begin_count == 2 && harness.end_count == 0 &&
              harness.cancel_count == 0 && harness.active_frames == 0,
          concurrency_diagnostic);
}
} // namespace

int main() {
  try {
    TestCpuFrameCopyContract();
    TestPublicCAndLegacyMigrationContract();
    TestCoreTableCreationAndLifecycle();
    TestRealOffscreenRenderingThroughC();
    TestCallbackFailuresExceptionsAndCancellation();
    TestSameSessionReentryIsRejected();
    TestConcurrentRendersAreSerialized();
    std::cout << "vtk_flutter native core contract: ok\n";
    return EXIT_SUCCESS;
  } catch (const std::exception &exception) {
    std::cerr << "vtk_flutter native core contract: " << exception.what()
              << '\n';
    return EXIT_FAILURE;
  }
}
