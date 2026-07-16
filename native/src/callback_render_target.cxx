#include "callback_render_target.h"

#include <vtkCamera.h>
#include <vtkMatrix4x4.h>
#include <vtkNew.h>
#include <vtkRenderer.h>
#include <vtkRendererCollection.h>
#include <vtkRenderWindow.h>
#include <vtkSmartPointer.h>
#include <vtkUnsignedCharArray.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <functional>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#if TARGET_OS_OSX
#include <vtkCocoaRenderWindow.h>
#endif
#endif

namespace vtk_flutter {
namespace {
using Clock = std::chrono::steady_clock;

constexpr std::size_t kCpuFrameV2Size = sizeof(VtkFlutterCpuFrameV2);

template <typename Duration> double Milliseconds(Duration duration) {
  return std::chrono::duration<double, std::milli>(duration).count();
}

bool IsStatusCode(int32_t code) {
  return code >= VTK_FLUTTER_STATUS_OK &&
         code <= VTK_FLUTTER_STATUS_INTERNAL_ERROR;
}

std::string CallbackMessage(const VtkFlutterStatus &status,
                            std::string_view fallback) {
  const auto *end = std::find(std::begin(status.message),
                              std::end(status.message), '\0');
  if (end == std::begin(status.message)) {
    return std::string(fallback);
  }
  return std::string(std::begin(status.message), end);
}

void CheckCallbackResult(int32_t code, const VtkFlutterStatus &status,
                         std::string_view fallback) {
  if (code == VTK_FLUTTER_STATUS_OK) {
    return;
  }
  const auto contained_code =
      IsStatusCode(code) ? code : VTK_FLUTTER_STATUS_INTERNAL_ERROR;
  throw FrameCallbackFailure(contained_code,
                             CallbackMessage(status, fallback));
}

std::uint64_t RequiredCapacity(const VtkFlutterViewport &viewport,
                               const VtkFlutterCpuFrameV2 &frame) {
  if (viewport.width <= 0 || viewport.height <= 0) {
    throw std::invalid_argument("positive CPU frame dimensions are required");
  }
  if (frame.struct_size < kCpuFrameV2Size ||
      frame.version != VTK_FLUTTER_CPU_FRAME_VERSION_2) {
    throw std::invalid_argument("unsupported CPU frame descriptor");
  }
  if (frame.pixels == nullptr) {
    throw std::invalid_argument("CPU frame pixels are required");
  }
  if (frame.pixel_format != VTK_FLUTTER_PIXEL_FORMAT_RGBA8888 &&
      frame.pixel_format != VTK_FLUTTER_PIXEL_FORMAT_BGRA8888) {
    throw std::invalid_argument("unsupported CPU frame pixel format");
  }

  const auto pixel_bytes = static_cast<std::uint64_t>(viewport.width) * 4ULL;
  if (frame.row_bytes < pixel_bytes) {
    throw std::invalid_argument("CPU frame row_bytes is too small");
  }
  const auto rows_before_last =
      static_cast<std::uint64_t>(viewport.height - 1);
  if (rows_before_last != 0 &&
      frame.row_bytes >
          (std::numeric_limits<std::uint64_t>::max() - pixel_bytes) /
              rows_before_last) {
    throw std::invalid_argument("CPU frame dimensions overflow");
  }
  const auto required = rows_before_last * frame.row_bytes + pixel_bytes;
  if (frame.capacity_bytes < required ||
      frame.capacity_bytes > std::numeric_limits<std::size_t>::max() ||
      frame.row_bytes > std::numeric_limits<std::size_t>::max()) {
    throw std::invalid_argument("CPU frame capacity is too small");
  }
  return required;
}

void CapturePatientToClip(vtkRenderer &renderer,
                          VtkFlutterMetrics &metrics) {
  auto *matrix = renderer.GetActiveCamera()
                     ->GetCompositeProjectionTransformMatrix(
                         renderer.GetTiledAspectRatio(), -1.0, 1.0);
  if (matrix == nullptr) {
    return;
  }
  for (int row = 0; row < 4; ++row) {
    for (int column = 0; column < 4; ++column) {
      metrics.patient_to_clip[row * 4 + column] =
          matrix->GetElement(row, column);
    }
  }
  metrics.patient_to_clip_valid = 1;
}

void PopulateContentEvidence(const VtkFlutterCpuFrameV2 &frame,
                             const VtkFlutterViewport &viewport,
                             VtkFlutterMetrics &metrics) {
  constexpr std::uint64_t kFnv1a64OffsetBasis = 14695981039346656037ULL;
  constexpr std::uint64_t kFnv1a64Prime = 1099511628211ULL;
  std::array<bool, 256> encountered_values{};
  std::uint64_t checksum = kFnv1a64OffsetBasis;
  std::uint64_t changed_pixels = 0;
  const std::array<std::uint8_t, 4> background{
      frame.pixels[0], frame.pixels[1], frame.pixels[2], frame.pixels[3]};
  const auto row_bytes = static_cast<std::size_t>(frame.row_bytes);
  for (int row = 0; row < viewport.height; ++row) {
    const auto *pixels =
        frame.pixels + static_cast<std::size_t>(row) * row_bytes;
    for (int column = 0; column < viewport.width; ++column) {
      bool changed = false;
      for (std::size_t channel = 0; channel < 4; ++channel) {
        const auto value = pixels[static_cast<std::size_t>(column) * 4U +
                                  channel];
        checksum ^= value;
        checksum *= kFnv1a64Prime;
        encountered_values[value] = true;
        changed = changed || value != background[channel];
      }
      if (changed) {
        ++changed_pixels;
      }
    }
  }
  const auto unique_values = static_cast<std::uint64_t>(
      std::count(encountered_values.begin(), encountered_values.end(), true));
  metrics.surface_checksum = checksum;
  metrics.surface_changed_pixels = changed_pixels;
  metrics.surface_unique_byte_values = unique_values;
  metrics.cpu_checksum = checksum;
  metrics.cpu_changed_pixels = changed_pixels;
  metrics.cpu_unique_byte_values = unique_values;
}

#if defined(__APPLE__)
struct MainThreadInvocation {
  std::function<void()> action;
  std::exception_ptr failure;
};

void InvokeOnMainThread(void *context) noexcept {
  auto &invocation = *static_cast<MainThreadInvocation *>(context);
  try {
    invocation.action();
  } catch (...) {
    invocation.failure = std::current_exception();
  }
}
#endif

void RunOnRenderThread(std::function<void()> action) {
#if defined(__APPLE__)
  if (pthread_main_np() != 0) {
    action();
    return;
  }
  MainThreadInvocation invocation{std::move(action), nullptr};
  dispatch_sync_f(dispatch_get_main_queue(), &invocation, InvokeOnMainThread);
  if (invocation.failure != nullptr) {
    std::rethrow_exception(invocation.failure);
  }
#else
  action();
#endif
}
} // namespace

class CallbackRenderTarget::Impl final {
public:
  Impl() {
    RunOnRenderThread([this] { InitializeWindow(); });
  }

  ~Impl() {
    try {
      RunOnRenderThread([this] {
        if (window_ != nullptr) {
          window_->Finalize();
        }
      });
    } catch (...) {
      // Destruction has no status channel and must not unwind across C.
    }
  }

  void Render(PreparedView view, const VtkFlutterViewport &viewport,
              const VtkFlutterCpuFrameV2 &frame,
              VtkFlutterMetrics &metrics) {
    RunOnRenderThread(
        [this, view = std::move(view), viewport, frame, &metrics]() mutable {
          RenderOnWorker(std::move(view), viewport, frame, metrics);
        });
  }

private:
  void InitializeWindow() {
    window_ = vtkSmartPointer<vtkRenderWindow>::New();
    if (window_ == nullptr) {
      throw std::runtime_error("VTK could not create a render window");
    }
    window_->SetWindowName("vtk_flutter_code_asset");
#if defined(__APPLE__) && TARGET_OS_OSX
    if (auto *cocoa_window = vtkCocoaRenderWindow::SafeDownCast(window_)) {
      // Offscreen readback needs Cocoa's OpenGL context, but not its hidden
      // NSWindow/vtkCocoaGLView pair. Avoiding that pair also keeps AppKit view
      // lifetime independent from this code asset's render-target lifetime.
      cocoa_window->SetConnectContextToNSView(false);
    }
#endif
    window_->SetShowWindow(false);
    window_->SetUseOffScreenBuffers(true);
    window_->SetAlphaBitPlanes(1);
    window_->SetMultiSamples(0);
    window_->SetSwapBuffers(0);
  }

  void RenderOnWorker(PreparedView view,
                      const VtkFlutterViewport &viewport,
                      const VtkFlutterCpuFrameV2 &frame,
                      VtkFlutterMetrics &metrics) {
    window_->SetSize(viewport.width, viewport.height);
    window_->GetRenderers()->RemoveAllItems();
    window_->AddRenderer(view.renderer);

    try {
      const auto render_started = Clock::now();
      window_->Render();
      const auto render_finished = Clock::now();

      if (view.capture_patient_to_clip) {
        CapturePatientToClip(*view.renderer, metrics);
      }

      vtkNew<vtkUnsignedCharArray> pixels;
      const auto readback_started = Clock::now();
      if (window_->GetRGBACharPixelData(0, 0, viewport.width - 1,
                                        viewport.height - 1, 0, pixels) == 0) {
        throw std::runtime_error("VTK framebuffer readback failed");
      }
      const auto expected_values =
          static_cast<vtkIdType>(viewport.width) * viewport.height * 4;
      if (pixels->GetNumberOfValues() < expected_values) {
        throw std::runtime_error("VTK framebuffer readback was incomplete");
      }
      CopyRgbaBottomUpToFrame(pixels->GetPointer(0), viewport, frame);
      const auto readback_finished = Clock::now();

      metrics.surface_allocation_bytes = frame.capacity_bytes;
      metrics.render_ms = Milliseconds(render_finished - render_started);
      metrics.gpu_sync_wait_ms = 0.0;
      metrics.cpu_readback_ms =
          Milliseconds(readback_finished - readback_started);
      PopulateContentEvidence(frame, viewport, metrics);
    } catch (...) {
      window_->RemoveRenderer(view.renderer);
      throw;
    }
    window_->RemoveRenderer(view.renderer);
  }

  vtkSmartPointer<vtkRenderWindow> window_;
};

FrameCallbackFailure::FrameCallbackFailure(int32_t code, std::string message)
    : std::runtime_error(std::move(message)), code_(code) {}

int32_t FrameCallbackFailure::Code() const { return code_; }

void CopyRgbaBottomUpToFrame(const std::uint8_t *source,
                             const VtkFlutterViewport &viewport,
                             const VtkFlutterCpuFrameV2 &frame) {
  if (source == nullptr) {
    throw std::invalid_argument("VTK source pixels are required");
  }
  RequiredCapacity(viewport, frame);
  const auto source_row_bytes =
      static_cast<std::size_t>(viewport.width) * 4U;
  const auto destination_row_bytes = static_cast<std::size_t>(frame.row_bytes);
  for (int row = 0; row < viewport.height; ++row) {
    const auto *source_row =
        source + static_cast<std::size_t>(viewport.height - 1 - row) *
                     source_row_bytes;
    auto *destination_row =
        frame.pixels + static_cast<std::size_t>(row) * destination_row_bytes;
    if (frame.pixel_format == VTK_FLUTTER_PIXEL_FORMAT_RGBA8888) {
      std::copy_n(source_row, source_row_bytes, destination_row);
      continue;
    }
    for (int column = 0; column < viewport.width; ++column) {
      const auto offset = static_cast<std::size_t>(column) * 4U;
      destination_row[offset] = source_row[offset + 2U];
      destination_row[offset + 1U] = source_row[offset + 1U];
      destination_row[offset + 2U] = source_row[offset];
      destination_row[offset + 3U] = source_row[offset + 3U];
    }
  }
}

CallbackRenderTarget::CallbackRenderTarget(
    const VtkFlutterFrameCallbacksV2 &callbacks)
    : callbacks_(callbacks), impl_(std::make_unique<Impl>()) {}

CallbackRenderTarget::~CallbackRenderTarget() = default;

void CallbackRenderTarget::Render(PreparedView view,
                                  const VtkFlutterViewport &viewport,
                                  VtkFlutterMetrics &metrics) {
  VtkFlutterCpuFrameV2 frame{};
  VtkFlutterStatus callback_status{};
  const auto begin_code = callbacks_.begin_frame(
      callbacks_.user_data, &viewport, &frame, &callback_status);
  CheckCallbackResult(begin_code, callback_status, "begin_frame failed");

  try {
    RequiredCapacity(viewport, frame);
    impl_->Render(std::move(view), viewport, frame, metrics);
    callback_status = {};
    const auto submit_started = Clock::now();
    const auto end_code = callbacks_.end_frame(callbacks_.user_data, &metrics,
                                                &callback_status);
    const auto submit_finished = Clock::now();
    metrics.surface_submit_ms =
        Milliseconds(submit_finished - submit_started);
    CheckCallbackResult(end_code, callback_status, "end_frame failed");
  } catch (...) {
    try {
      callbacks_.cancel_frame(callbacks_.user_data);
    } catch (...) {
      // Cancellation is best-effort; preserve the frame's original failure.
    }
    throw;
  }
}
} // namespace vtk_flutter
