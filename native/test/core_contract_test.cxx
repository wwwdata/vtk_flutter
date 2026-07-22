#include "callback_render_target.h"
#include "session.h"
#include "vtk_flutter.h"

// clang-format off
#include <vtk_nlohmannjson.h>
#include VTK_NLOHMANN_JSON(json.hpp)
// clang-format on

#include <algorithm>
#include <array>
#include <atomic>
#include <barrier>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <future>
#include <iostream>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

extern "C" int vtk_flutter_public_header_contract(void);

namespace {
void Require(bool condition, std::string_view message) {
  if (!condition) {
    throw std::runtime_error(std::string(message));
  }
}

void RequireOk(int32_t result, const VtkFlutterStatus &status,
               std::string_view operation) {
  if (result != VTK_FLUTTER_STATUS_OK) {
    throw std::runtime_error(std::string(operation) + ": " + status.message);
  }
}

struct SessionGuard {
  SessionGuard() = default;
  SessionGuard(const SessionGuard &) = delete;
  SessionGuard &operator=(const SessionGuard &) = delete;
  SessionGuard(SessionGuard &&other) noexcept : value(other.value) {
    other.value = nullptr;
  }
  SessionGuard &operator=(SessionGuard &&) = delete;
  ~SessionGuard() { vtk_flutter_session_destroy(value); }
  VtkFlutterSession *value = nullptr;
};

VtkFlutterObjectHandle CreateObject(VtkFlutterSession *session,
                                    const char *class_name) {
  VtkFlutterObjectHandle object = 0;
  VtkFlutterStatus status{};
  RequireOk(vtk_flutter_object_create(session, class_name, &object, &status),
            status, class_name);
  Require(object != 0, "VTK returned an invalid object handle");
  return object;
}

nlohmann::json Invoke(VtkFlutterSession *session,
                      VtkFlutterObjectHandle object, const char *method,
                      const nlohmann::json &arguments = nlohmann::json::array()) {
  char *result = nullptr;
  VtkFlutterStatus status{};
  const auto arguments_text = arguments.dump();
  RequireOk(vtk_flutter_object_invoke(session, object, method,
                                      arguments_text.c_str(), &result, &status),
            status, method);
  Require(result != nullptr, "VTK returned no invocation result");
  const auto parsed = nlohmann::json::parse(result);
  vtk_flutter_string_free(result);
  return parsed;
}

VtkFlutterObjectHandle ResultHandle(const nlohmann::json &value) {
  Require(value.is_object() && value.contains("Id"),
          "VTK result contains no object handle");
  return value["Id"].get<VtkFlutterObjectHandle>();
}

SessionGuard CreateSession() {
  SessionGuard session;
  VtkFlutterStatus status{};
  RequireOk(vtk_flutter_session_create(&session.value, &status), status,
            "session_create");
  Require(session.value != nullptr, "VTK returned no session");
  return session;
}

struct FrameHarness {
  std::vector<std::uint8_t> pixels;
  std::vector<std::uint8_t> presented_pixels;
  int begin_count = 0;
  int end_count = 0;
  int cancel_count = 0;
  int32_t end_result = VTK_FLUTTER_STATUS_OK;
};

int32_t VTK_FLUTTER_CALL BeginFrame(void *user_data,
                                    const VtkFlutterViewport *viewport,
                                    VtkFlutterCpuFrame *frame,
                                    VtkFlutterStatus *) {
  auto &harness = *static_cast<FrameHarness *>(user_data);
  ++harness.begin_count;
  harness.pixels.assign(
      static_cast<std::size_t>(viewport->width) * viewport->height * 4U, 0U);
  frame->struct_size = sizeof(VtkFlutterCpuFrame);
  frame->version = VTK_FLUTTER_CPU_FRAME_VERSION;
  frame->pixels = harness.pixels.data();
  frame->capacity_bytes = harness.pixels.size();
  frame->row_bytes = static_cast<std::uint64_t>(viewport->width) * 4U;
  frame->pixel_format = VTK_FLUTTER_PIXEL_FORMAT_RGBA8888;
  return VTK_FLUTTER_STATUS_OK;
}

int32_t VTK_FLUTTER_CALL EndFrame(void *user_data,
                                  const VtkFlutterFrameMetrics *,
                                  VtkFlutterStatus *) {
  auto &harness = *static_cast<FrameHarness *>(user_data);
  ++harness.end_count;
  if (harness.end_result == VTK_FLUTTER_STATUS_OK) {
    harness.presented_pixels = harness.pixels;
  }
  return harness.end_result;
}

void VTK_FLUTTER_CALL CancelFrame(void *user_data) {
  ++static_cast<FrameHarness *>(user_data)->cancel_count;
}

void TestPublicHeader() {
  Require(vtk_flutter_public_header_contract() == 1,
          "public C header contract failed");
  Require(vtk_flutter_abi_version() == VTK_FLUTTER_ABI_VERSION,
          "ABI version mismatch");
  const auto *api = vtk_flutter_get_presentation_api();
  Require(api != nullptr, "presentation API is missing");
  Require(api->version == VTK_FLUTTER_PRESENTATION_API_VERSION,
          "presentation API version mismatch");
  Require(api->struct_size >= sizeof(VtkFlutterPresentationApi),
          "presentation API is truncated");
  Require(api->session_is_valid != nullptr,
          "presentation API session validation is missing");

  VtkFlutterStatus status{};
  VtkFlutterSession *session = nullptr;
  RequireOk(vtk_flutter_session_create(&session, &status), status,
            "session_create");
  RequireOk(api->session_is_valid(session, &status), status,
            "session_is_valid");
  vtk_flutter_session_destroy(session);
  Require(api->session_is_valid(session, &status) ==
              VTK_FLUTTER_STATUS_INVALID_STATE,
          "a destroyed session remained valid");
  vtk_flutter_session_destroy(session);
}

void TestCpuFrameCopy() {
  const VtkFlutterViewport viewport{2, 2};
  const std::array<std::uint8_t, 16> bottom_up{
      1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 13, 14, 15, 16, 17, 18,
  };
  std::array<std::uint8_t, 16> top_down{};
  const VtkFlutterCpuFrame frame{
      sizeof(VtkFlutterCpuFrame),
      VTK_FLUTTER_CPU_FRAME_VERSION,
      top_down.data(),
      top_down.size(),
      8,
      VTK_FLUTTER_PIXEL_FORMAT_RGBA8888,
  };
  vtk_flutter::CopyRgbaBottomUpToFrame(bottom_up.data(), viewport, frame);
  const std::array<std::uint8_t, 16> expected{
      11, 12, 13, 14, 15, 16, 17, 18, 1, 2, 3, 4, 5, 6, 7, 8,
  };
  Require(top_down == expected, "CPU frame was not vertically flipped");
}

void TestGenericSession() {
  auto session = CreateSession();
  const std::array<const char *, 19> classes{
      "vtkImageReslice",
      "vtkImageMapToWindowLevelColors",
      "vtkImageActor",
      "vtkImageProperty",
      "vtkSmartVolumeMapper",
      "vtkColorTransferFunction",
      "vtkPiecewiseFunction",
      "vtkVolumeProperty",
      "vtkVolume",
      "vtkFlyingEdges3D",
      "vtkPolyDataConnectivityFilter",
      "vtkWindowedSincPolyDataFilter",
      "vtkPolyDataMapper",
      "vtkActor",
      "vtkProperty",
      "vtkRenderer",
      "vtkCamera",
      "vtkImageSliceMapper",
      "vtkContourFilter",
  };
  for (const auto *class_name : classes) {
    CreateObject(session.value, class_name);
  }

  VtkFlutterObjectHandle unsupported = 0;
  VtkFlutterStatus status{};
  const auto result = vtk_flutter_object_create(
      session.value, "vtkDefinitelyNotAClass", &unsupported, &status);
  Require(result == VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
          "unsupported class was accepted");

  const auto renderer = CreateObject(session.value, "vtkRenderer");
  char *invocation_result = nullptr;
  status = {};
  const auto invalid_invocation = vtk_flutter_object_invoke(
      session.value, renderer, "DefinitelyNotAMethod", "[]",
      &invocation_result, &status);
  Require(invalid_invocation == VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
          "failed invocation was reported as successful");
  Require(invocation_result == nullptr,
          "failed invocation returned a result");

  status = {};
  RequireOk(vtk_flutter_object_destroy(session.value, renderer, &status),
            status, "first object destroy");
  status = {};
  RequireOk(vtk_flutter_object_destroy(session.value, renderer, &status),
            status, "idempotent object destroy");
}

void TestSessionConcurrency() {
  using namespace std::chrono_literals;

  auto first = CreateSession();
  auto second = CreateSession();
  std::promise<void> first_entered;
  std::promise<void> release_first;
  auto first_entered_future = first_entered.get_future();
  auto release_first_future = release_first.get_future().share();
  int32_t first_result = VTK_FLUTTER_STATUS_INTERNAL_ERROR;
  VtkFlutterStatus first_status{};
  std::thread first_operation([&] {
    first_result = vtk_flutter::testing::WithLiveSession(
        first.value, &first_status, [&](vtk_flutter::Session &) {
          first_entered.set_value();
          release_first_future.wait();
        });
  });

  if (first_entered_future.wait_for(2s) != std::future_status::ready) {
    release_first.set_value();
    first_operation.join();
    throw std::runtime_error("first session operation did not start");
  }

  std::promise<void> second_entered;
  auto second_entered_future = second_entered.get_future();
  int32_t second_result = VTK_FLUTTER_STATUS_INTERNAL_ERROR;
  VtkFlutterStatus second_status{};
  std::thread second_operation([&] {
    second_result = vtk_flutter::testing::WithLiveSession(
        second.value, &second_status,
        [&](vtk_flutter::Session &) { second_entered.set_value(); });
  });

  const auto sessions_overlapped =
      second_entered_future.wait_for(2s) == std::future_status::ready;
  release_first.set_value();
  first_operation.join();
  second_operation.join();

  Require(sessions_overlapped,
          "an operation on one session blocked another session");
  RequireOk(first_result, first_status, "first concurrent operation");
  RequireOk(second_result, second_status, "second concurrent operation");

  auto lifetime_session = CreateSession();
  auto *lifetime_handle = lifetime_session.value;
  lifetime_session.value = nullptr;
  std::promise<void> lifetime_entered;
  std::promise<void> release_lifetime;
  auto lifetime_entered_future = lifetime_entered.get_future();
  auto release_lifetime_future = release_lifetime.get_future().share();
  VtkFlutterObjectHandle created_after_destroy = 0;
  int32_t lifetime_result = VTK_FLUTTER_STATUS_INTERNAL_ERROR;
  VtkFlutterStatus lifetime_status{};
  std::thread lifetime_operation([&] {
    lifetime_result = vtk_flutter::testing::WithLiveSession(
        lifetime_handle, &lifetime_status, [&](vtk_flutter::Session &session) {
          lifetime_entered.set_value();
          release_lifetime_future.wait();
          created_after_destroy = session.CreateObject("vtkActor");
        });
  });

  if (lifetime_entered_future.wait_for(2s) != std::future_status::ready) {
    release_lifetime.set_value();
    lifetime_operation.join();
    vtk_flutter_session_destroy(lifetime_handle);
    throw std::runtime_error("lifetime test operation did not start");
  }

  std::promise<void> destroy_returned;
  auto destroy_returned_future = destroy_returned.get_future();
  std::thread destroy([&] {
    vtk_flutter_session_destroy(lifetime_handle);
    destroy_returned.set_value();
  });
  const auto destroyed_while_in_flight =
      destroy_returned_future.wait_for(2s) == std::future_status::ready;

  VtkFlutterStatus invalid_status{};
  const auto invalid_result =
      destroyed_while_in_flight
          ? vtk_flutter::testing::WithLiveSession(
                lifetime_handle, &invalid_status, [](vtk_flutter::Session &) {})
          : VTK_FLUTTER_STATUS_OK;
  release_lifetime.set_value();
  lifetime_operation.join();
  destroy.join();

  Require(destroyed_while_in_flight,
          "session destroy waited for an in-flight operation");
  Require(invalid_result == VTK_FLUTTER_STATUS_INVALID_STATE,
          "destroyed session accepted a new operation");
  RequireOk(lifetime_result, lifetime_status,
            "operation retained across session destroy");
  Require(created_after_destroy != 0,
          "in-flight operation lost its session during destroy");
}

struct SessionLifecycleBarrier {
  explicit SessionLifecycleBarrier(
      vtk_flutter::testing::SessionLifecyclePhase lifecycle_phase)
      : phase(lifecycle_phase) {}

  vtk_flutter::testing::SessionLifecyclePhase phase;
  std::mutex mutex;
  std::condition_variable condition;
  int waiting = 0;
  int contended = 0;
  int entered = 0;
  bool release = false;
};

SessionLifecycleBarrier *g_session_lifecycle_barrier = nullptr;

void SessionLifecycleHook(vtk_flutter::testing::SessionLifecyclePhase phase,
                          vtk_flutter::testing::SessionLifecycleMoment moment) {
  auto *barrier = g_session_lifecycle_barrier;
  if (barrier == nullptr || barrier->phase != phase) {
    return;
  }
  std::unique_lock lock(barrier->mutex);
  if (moment == vtk_flutter::testing::SessionLifecycleMoment::waiting) {
    ++barrier->waiting;
    barrier->condition.notify_all();
    return;
  }
  if (moment == vtk_flutter::testing::SessionLifecycleMoment::contended) {
    ++barrier->contended;
    barrier->condition.notify_all();
    return;
  }
  ++barrier->entered;
  barrier->condition.notify_all();
  if (barrier->entered == 1) {
    barrier->condition.wait(lock, [&] { return barrier->release; });
  }
}

template <typename First, typename Second>
void RequireSerializedLifecycle(
    vtk_flutter::testing::SessionLifecyclePhase phase, First first,
    Second second, std::string_view message) {
  using namespace std::chrono_literals;

  SessionLifecycleBarrier barrier(phase);
  g_session_lifecycle_barrier = &barrier;
  vtk_flutter::testing::SetSessionLifecycleHook(SessionLifecycleHook);
  std::thread first_thread(std::move(first));
  {
    std::unique_lock lock(barrier.mutex);
    const auto started = barrier.condition.wait_for(
        lock, 2s, [&] { return barrier.entered == 1; });
    if (!started) {
      barrier.release = true;
      barrier.condition.notify_all();
      lock.unlock();
      first_thread.join();
      vtk_flutter::testing::SetSessionLifecycleHook(nullptr);
      g_session_lifecycle_barrier = nullptr;
      throw std::runtime_error(
          "first session lifecycle operation did not start");
    }
  }

  std::thread second_thread(std::move(second));
  bool contender_blocked = false;
  bool serialized = false;
  {
    std::unique_lock lock(barrier.mutex);
    contender_blocked = barrier.condition.wait_for(
        lock, 2s,
        [&] { return barrier.waiting == 2 && barrier.contended == 1; });
    serialized = contender_blocked && barrier.entered == 1;
    barrier.release = true;
    barrier.condition.notify_all();
  }
  first_thread.join();
  second_thread.join();
  vtk_flutter::testing::SetSessionLifecycleHook(nullptr);
  g_session_lifecycle_barrier = nullptr;

  Require(contender_blocked,
          "second session lifecycle operation did not contend");
  Require(serialized, message);
}

void TestSessionLifecycle() {
  VtkFlutterSession *first = nullptr;
  VtkFlutterSession *second = nullptr;
  VtkFlutterStatus first_status{};
  VtkFlutterStatus second_status{};
  int32_t first_result = VTK_FLUTTER_STATUS_INTERNAL_ERROR;
  int32_t second_result = VTK_FLUTTER_STATUS_INTERNAL_ERROR;
  RequireSerializedLifecycle(
      vtk_flutter::testing::SessionLifecyclePhase::construction,
      [&] { first_result = vtk_flutter_session_create(&first, &first_status); },
      [&] {
        second_result = vtk_flutter_session_create(&second, &second_status);
      },
      "VTK session construction was not globally serialized");
  RequireOk(first_result, first_status, "first concurrent session_create");
  RequireOk(second_result, second_status, "second concurrent session_create");

  RequireSerializedLifecycle(
      vtk_flutter::testing::SessionLifecyclePhase::destruction,
      [&] { vtk_flutter_session_destroy(first); },
      [&] { vtk_flutter_session_destroy(second); },
      "VTK session destruction was not globally serialized");

  constexpr int thread_count = 4;
  constexpr int iterations = 8;
  std::barrier start(thread_count);
  std::atomic_bool stress_succeeded = true;
  std::array<std::thread, thread_count> threads;
  for (auto &thread : threads) {
    thread = std::thread([&] {
      start.arrive_and_wait();
      for (int iteration = 0; iteration < iterations; ++iteration) {
        VtkFlutterSession *session = nullptr;
        VtkFlutterStatus status{};
        if (vtk_flutter_session_create(&session, &status) !=
                VTK_FLUTTER_STATUS_OK ||
            session == nullptr) {
          stress_succeeded = false;
          return;
        }
        vtk_flutter_session_destroy(session);
      }
    });
  }
  for (auto &thread : threads) {
    thread.join();
  }
  Require(stress_succeeded, "concurrent session lifecycle stress failed");
}

VtkFlutterRenderLayer RenderLayer(VtkFlutterObjectHandle renderer, double left,
                                  double bottom, double right, double top) {
  return {
      sizeof(VtkFlutterRenderLayer),
      VTK_FLUTTER_RENDER_LAYER_VERSION,
      renderer,
      left,
      bottom,
      right,
      top,
  };
}

std::array<std::uint8_t, 4> PixelAt(const std::vector<std::uint8_t> &pixels,
                                    int width, int x, int y) {
  const auto offset = (static_cast<std::size_t>(y) * width + x) * 4U;
  return {pixels[offset], pixels[offset + 1U], pixels[offset + 2U],
          pixels[offset + 3U]};
}

void RequireColor(const std::array<std::uint8_t, 4> &pixel,
                  const std::array<std::uint8_t, 4> &expected,
                  std::string_view message) {
  constexpr int tolerance = 2;
  for (std::size_t component = 0; component < pixel.size(); ++component) {
    Require(std::abs(static_cast<int>(pixel[component]) -
                     static_cast<int>(expected[component])) <= tolerance,
            message);
  }
}

void RequireInvalidLayout(VtkFlutterSession *session,
                          const VtkFlutterRenderLayer *layers,
                          std::uint32_t layer_count,
                          const VtkFlutterViewport &viewport,
                          std::uint32_t primary_layer, FrameHarness &harness,
                          std::string_view message) {
  const auto begin_count = harness.begin_count;
  const auto presented_pixels = harness.presented_pixels;
  VtkFlutterFrameMetrics metrics{};
  metrics.frame_bytes = 1U;
  metrics.world_to_clip_valid = 1;
  VtkFlutterStatus status{};
  const auto result =
      vtk_flutter_session_render_layout(session, layers, layer_count, &viewport,
                                        primary_layer, &metrics, &status);
  Require(result == VTK_FLUTTER_STATUS_INVALID_ARGUMENT, message);
  Require(harness.begin_count == begin_count,
          "invalid layout began a frame transaction");
  Require(harness.presented_pixels == presented_pixels,
          "invalid layout changed the last presented frame");
  Require(metrics.frame_bytes == 0 && metrics.world_to_clip_valid == 0,
          "invalid layout returned partial metrics");
}

void TestLayoutRender() {
  auto session = CreateSession();
  const auto lower_left = CreateObject(session.value, "vtkRenderer");
  Invoke(session.value, lower_left, "SetBackground",
         nlohmann::json::array({1.0, 0.0, 0.0}));
  Invoke(session.value, lower_left, "SetBackgroundAlpha",
         nlohmann::json::array({1.0}));
  const auto upper_right = CreateObject(session.value, "vtkRenderer");
  Invoke(session.value, upper_right, "SetBackground",
         nlohmann::json::array({0.0, 1.0, 0.0}));
  Invoke(session.value, upper_right, "SetBackgroundAlpha",
         nlohmann::json::array({1.0}));

  FrameHarness harness;
  const VtkFlutterFrameCallbacks callbacks{
      sizeof(VtkFlutterFrameCallbacks),
      VTK_FLUTTER_FRAME_CALLBACKS_VERSION,
      &harness,
      BeginFrame,
      EndFrame,
      CancelFrame,
  };
  const auto *api = vtk_flutter_get_presentation_api();
  VtkFlutterStatus status{};
  VtkFlutterTextureTarget *target = nullptr;
  RequireOk(api->texture_target_create(&callbacks, &target, &status), status,
            "texture_target_create");
  RequireOk(api->session_attach_texture_target(session.value, target, &status),
            status, "session_attach_texture_target");

  constexpr VtkFlutterViewport viewport{64, 64};
  const std::array layers{
      RenderLayer(upper_right, 0.5, 0.5, 1.0, 1.0),
      RenderLayer(lower_left, 0.0, 0.0, 0.5, 0.25),
  };
  VtkFlutterFrameMetrics layout_metrics{};
  RequireOk(vtk_flutter_session_render_layout(session.value, layers.data(),
                                              layers.size(), &viewport, 1U,
                                              &layout_metrics, &status),
            status, "session_render_layout");
  Require(harness.begin_count == 1 && harness.end_count == 1 &&
              harness.cancel_count == 0,
          "layout did not use one frame transaction");
  Require(layout_metrics.world_to_clip_valid == 1,
          "layout omitted the primary world-to-clip matrix");
  RequireColor(PixelAt(harness.presented_pixels, viewport.width, 16, 56),
               {255, 0, 0, 255},
               "bottom-left VTK viewport was not rendered in the lower cell");
  RequireColor(PixelAt(harness.presented_pixels, viewport.width, 48, 16),
               {0, 255, 0, 255},
               "top-right VTK viewport was not rendered in the upper cell");
  RequireColor(PixelAt(harness.presented_pixels, viewport.width, 16, 16),
               {0, 0, 0, 0},
               "uncovered top-left pixels were not transparently cleared");
  RequireColor(PixelAt(harness.presented_pixels, viewport.width, 48, 48),
               {0, 0, 0, 0},
               "uncovered bottom-right pixels were not transparently cleared");

  auto invalid_second = layers;
  invalid_second[1].renderer = std::numeric_limits<std::uint32_t>::max();
  RequireInvalidLayout(session.value, invalid_second.data(),
                       invalid_second.size(), viewport, 0U, harness,
                       "an invalid second renderer was accepted");

  auto oversized_descriptor = layers;
  oversized_descriptor[0].struct_size =
      sizeof(VtkFlutterRenderLayer) + sizeof(std::uint32_t);
  RequireInvalidLayout(session.value, oversized_descriptor.data(),
                       oversized_descriptor.size(), viewport, 0U, harness,
                       "a non-exact render layer struct_size was accepted");

  auto unsupported_version = layers;
  ++unsupported_version[0].version;
  RequireInvalidLayout(session.value, unsupported_version.data(),
                       unsupported_version.size(), viewport, 0U, harness,
                       "an unsupported render layer version was accepted");

  auto duplicate = layers;
  duplicate[1].renderer = duplicate[0].renderer;
  RequireInvalidLayout(session.value, duplicate.data(), duplicate.size(),
                       viewport, 0U, harness,
                       "a duplicate renderer was accepted");

  auto overlapping = layers;
  overlapping[1].right = 0.75;
  overlapping[1].top = 0.75;
  RequireInvalidLayout(session.value, overlapping.data(), overlapping.size(),
                       viewport, 0U, harness,
                       "overlapping render viewports were accepted");

  auto non_finite = layers;
  non_finite[0].left = std::numeric_limits<double>::infinity();
  RequireInvalidLayout(session.value, non_finite.data(), non_finite.size(),
                       viewport, 0U, harness,
                       "a non-finite viewport was accepted");

  auto out_of_range = layers;
  out_of_range[1].top = 1.01;
  RequireInvalidLayout(session.value, out_of_range.data(), out_of_range.size(),
                       viewport, 0U, harness,
                       "an out-of-range viewport was accepted");

  auto inverted = layers;
  inverted[0].right = inverted[0].left;
  RequireInvalidLayout(session.value, inverted.data(), inverted.size(),
                       viewport, 0U, harness, "an empty viewport was accepted");

  auto vertically_inverted = layers;
  vertically_inverted[0].top = vertically_inverted[0].bottom;
  RequireInvalidLayout(session.value, vertically_inverted.data(),
                       vertically_inverted.size(), viewport, 0U, harness,
                       "a vertically empty viewport was accepted");

  RequireInvalidLayout(session.value, layers.data(), 0U, viewport, 0U, harness,
                       "an empty layout was accepted");
  RequireInvalidLayout(session.value, layers.data(),
                       VTK_FLUTTER_MAX_RENDER_LAYERS + 1U, viewport, 0U,
                       harness, "more than 64 render layers were accepted");
  RequireInvalidLayout(session.value, layers.data(), layers.size(), viewport,
                       layers.size(), harness,
                       "an invalid primary layer was accepted");

  const auto wrong_type = CreateObject(session.value, "vtkActor");
  auto non_renderer = layers;
  non_renderer[1].renderer = wrong_type;
  RequireInvalidLayout(session.value, non_renderer.data(), non_renderer.size(),
                       viewport, 0U, harness,
                       "a non-renderer object was accepted");

  RequireInvalidLayout(session.value, nullptr, 1U, viewport, 0U, harness,
                       "a null render layer array was accepted");

  const auto presented_before_failure = harness.presented_pixels;
  harness.end_result = VTK_FLUTTER_STATUS_INTERNAL_ERROR;
  VtkFlutterFrameMetrics failed_metrics{};
  const auto failed_render = vtk_flutter_session_render_layout(
      session.value, layers.data(), layers.size(), &viewport, 1U,
      &failed_metrics, &status);
  Require(failed_render == VTK_FLUTTER_STATUS_INTERNAL_ERROR,
          "end_frame failure was not propagated");
  Require(harness.cancel_count == 1,
          "failed layout did not cancel its frame transaction");
  Require(harness.presented_pixels == presented_before_failure,
          "failed layout replaced the last complete frame");

  harness.end_result = VTK_FLUTTER_STATUS_OK;
  constexpr VtkFlutterViewport primary_viewport{32, 16};
  VtkFlutterFrameMetrics legacy_metrics{};
  RequireOk(vtk_flutter_session_render(session.value, lower_left,
                                       &primary_viewport, &legacy_metrics,
                                       &status),
            status, "legacy session_render after failed layout");
  Require(legacy_metrics.world_to_clip_valid == 1,
          "legacy render omitted world-to-clip matrix");
  RequireColor(PixelAt(harness.presented_pixels, primary_viewport.width, 1, 1),
               {255, 0, 0, 255},
               "legacy render did not use the complete viewport");
  RequireColor(PixelAt(harness.presented_pixels, primary_viewport.width, 30,
                       14),
               {255, 0, 0, 255},
               "legacy render retained the previous layout viewport");
  for (std::size_t index = 0; index < 16; ++index) {
    Require(std::abs(layout_metrics.world_to_clip[index] -
                     legacy_metrics.world_to_clip[index]) < 1e-12,
            "layout transform did not use the primary viewport aspect ratio");
  }
  Require(harness.begin_count == 3 && harness.end_count == 3 &&
              harness.cancel_count == 1,
          "renderers were not reusable after a failed layout");

  RequireOk(api->session_detach_texture_target(session.value, target, &status),
            status, "session_detach_texture_target");
  RequireOk(api->texture_target_destroy(target, &status), status,
            "texture_target_destroy");
}

void TestSurfaceRender() {
  auto session = CreateSession();
  constexpr int dimension = 24;
  std::vector<std::int16_t> values(dimension * dimension * dimension);
  for (int z = 0; z < dimension; ++z) {
    for (int y = 0; y < dimension; ++y) {
      for (int x = 0; x < dimension; ++x) {
        const auto dx = x - dimension / 2;
        const auto dy = y - dimension / 2;
        const auto dz = z - dimension / 2;
        values[static_cast<std::size_t>(
            z * dimension * dimension + y * dimension + x)] =
            dx * dx + dy * dy + dz * dz < 64 ? 1000 : -1000;
      }
    }
  }

  VtkFlutterImageData image{};
  image.values = values.data();
  image.value_count = values.size();
  image.byte_count = values.size() * sizeof(std::int16_t);
  image.scalar_type = VTK_FLUTTER_SCALAR_INT16;
  image.component_count = 1;
  image.dimensions[0] = dimension;
  image.dimensions[1] = dimension;
  image.dimensions[2] = dimension;
  image.spacing[0] = 1.0;
  image.spacing[1] = 1.0;
  image.spacing[2] = 1.0;
  image.direction[0] = 1.0;
  image.direction[4] = 1.0;
  image.direction[8] = 1.0;
  VtkFlutterObjectHandle image_handle = 0;
  VtkFlutterStatus status{};
  RequireOk(vtk_flutter_image_data_create(session.value, &image,
                                          &image_handle, &status),
            status, "image_data_create");

  const auto surface = CreateObject(session.value, "vtkFlyingEdges3D");
  Invoke(session.value, surface, "SetInputData",
         nlohmann::json::array({{{"Id", image_handle}}}));
  Invoke(session.value, surface, "SetValue",
         nlohmann::json::array({0, 0.0}));
  const auto output =
      ResultHandle(Invoke(session.value, surface, "GetOutputPort",
                          nlohmann::json::array({0})));

  const auto mapper = CreateObject(session.value, "vtkPolyDataMapper");
  Invoke(session.value, mapper, "SetInputConnection",
         nlohmann::json::array({0, {{"Id", output}}}));
  Invoke(session.value, mapper, "ScalarVisibilityOff");

  const auto actor = CreateObject(session.value, "vtkActor");
  Invoke(session.value, actor, "SetMapper",
         nlohmann::json::array({{{"Id", mapper}}}));
  const auto renderer = CreateObject(session.value, "vtkRenderer");
  Invoke(session.value, renderer, "AddActor",
         nlohmann::json::array({{{"Id", actor}}}));
  Invoke(session.value, renderer, "SetBackground",
         nlohmann::json::array({0.05, 0.08, 0.12}));
  Invoke(session.value, renderer, "ResetCamera");

  FrameHarness harness;
  const VtkFlutterFrameCallbacks callbacks{
      sizeof(VtkFlutterFrameCallbacks),
      VTK_FLUTTER_FRAME_CALLBACKS_VERSION,
      &harness,
      BeginFrame,
      EndFrame,
      CancelFrame,
  };
  const auto *api = vtk_flutter_get_presentation_api();
  VtkFlutterTextureTarget *target = nullptr;
  RequireOk(api->texture_target_create(&callbacks, &target, &status), status,
            "texture_target_create");
  RequireOk(api->session_attach_texture_target(session.value, target, &status),
            status, "session_attach_texture_target");

  const VtkFlutterViewport viewport{96, 96};
  VtkFlutterFrameMetrics metrics{};
  RequireOk(vtk_flutter_session_render(session.value, renderer, &viewport,
                                       &metrics, &status),
            status, "session_render");
  Require(harness.begin_count == 1 && harness.end_count == 1 &&
              harness.cancel_count == 0,
          "frame callback transaction failed");
  Require(std::any_of(harness.pixels.begin(), harness.pixels.end(),
                      [](std::uint8_t value) { return value != 0; }),
          "rendered frame is blank");
  Require(metrics.world_to_clip_valid == 1,
          "render omitted world-to-clip matrix");

  RequireOk(api->session_detach_texture_target(session.value, target, &status),
            status, "session_detach_texture_target");
  RequireOk(api->texture_target_destroy(target, &status), status,
            "texture_target_destroy");
}
} // namespace

int main(int argc, char **argv) {
  try {
    Require(argc == 2, "one test case name is required");
    const std::string_view test_case = argv[1];
    if (test_case == "public_header") {
      TestPublicHeader();
    } else if (test_case == "cpu_frame_copy") {
      TestCpuFrameCopy();
    } else if (test_case == "generic_session") {
      TestGenericSession();
    } else if (test_case == "session_concurrency") {
      TestSessionConcurrency();
    } else if (test_case == "session_lifecycle") {
      TestSessionLifecycle();
    } else if (test_case == "surface_render") {
      TestLayoutRender();
      TestSurfaceRender();
    } else {
      throw std::runtime_error("unknown test case");
    }
    return EXIT_SUCCESS;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return EXIT_FAILURE;
  }
}
