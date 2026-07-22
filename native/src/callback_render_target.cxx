#include "callback_render_target.h"

#include <vtkCamera.h>
#if defined(__ANDROID__)
#include <vtkEGLRenderWindow.h>
#endif
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
#include <vector>

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

constexpr std::size_t kCpuFrameSize = sizeof(VtkFlutterCpuFrame);

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
                               const VtkFlutterCpuFrame &frame) {
  if (viewport.width <= 0 || viewport.height <= 0) {
    throw std::invalid_argument("positive CPU frame dimensions are required");
  }
  if (frame.struct_size < kCpuFrameSize ||
      frame.version != VTK_FLUTTER_CPU_FRAME_VERSION) {
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

void CaptureWorldToClip(vtkRenderer &renderer,
                        VtkFlutterFrameMetrics &metrics) {
  auto *matrix = renderer.GetActiveCamera()
                     ->GetCompositeProjectionTransformMatrix(
                         renderer.GetTiledAspectRatio(), -1.0, 1.0);
  if (matrix == nullptr) {
    return;
  }
  for (int row = 0; row < 4; ++row) {
    for (int column = 0; column < 4; ++column) {
      metrics.world_to_clip[row * 4 + column] =
          matrix->GetElement(row, column);
    }
  }
  metrics.world_to_clip_valid = 1;
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

class RendererAttachments final {
public:
  explicit RendererAttachments(vtkRenderWindow &window) : window_(window) {}

  RendererAttachments(const RendererAttachments &) = delete;
  RendererAttachments &operator=(const RendererAttachments &) = delete;

  ~RendererAttachments() noexcept {
    for (auto renderer = renderers_.rbegin(); renderer != renderers_.rend();
         ++renderer) {
      try {
        window_.RemoveRenderer(*renderer);
      } catch (...) {
      }
    }
  }

  void Add(const vtkSmartPointer<vtkRenderer> &renderer) {
    renderers_.push_back(renderer);
    window_.AddRenderer(renderer);
  }

private:
  vtkRenderWindow &window_;
  std::vector<vtkSmartPointer<vtkRenderer>> renderers_;
};
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

  void Render(const std::vector<RenderLayer> &layers,
              const VtkFlutterViewport &viewport, std::uint32_t primary_layer,
              const VtkFlutterCpuFrame &frame,
              VtkFlutterFrameMetrics &metrics) {
    RunOnRenderThread([this, layers, viewport, primary_layer, frame, &metrics] {
      RenderOnWorker(layers, viewport, primary_layer, frame, metrics);
    });
  }

private:
  void InitializeWindow() {
#if defined(__ANDROID__)
    // VTK's Android object-factory override for vtkRenderWindow recursively
    // re-enters vtkRenderWindow::New() when linked into the monolithic core.
    // The Android build has exactly one concrete backend, so construct it
    // directly and bypass that broken base-class override.
    window_ = vtkSmartPointer<vtkEGLRenderWindow>::New();
#else
    window_ = vtkSmartPointer<vtkRenderWindow>::New();
#endif
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

    clear_renderer_ = vtkSmartPointer<vtkRenderer>::New();
    if (clear_renderer_ == nullptr) {
      throw std::runtime_error("VTK could not create a clear renderer");
    }
    clear_renderer_->SetViewport(0.0, 0.0, 1.0, 1.0);
    clear_renderer_->SetLayer(0);
    clear_renderer_->SetBackground(0.0, 0.0, 0.0);
    clear_renderer_->SetBackgroundAlpha(0.0);
    clear_renderer_->SetGradientBackground(false);
    clear_renderer_->EraseOn();
  }

  void RenderOnWorker(const std::vector<RenderLayer> &layers,
                      const VtkFlutterViewport &viewport,
                      std::uint32_t primary_layer,
                      const VtkFlutterCpuFrame &frame,
                      VtkFlutterFrameMetrics &metrics) {
    window_->SetSize(viewport.width, viewport.height);
    window_->GetRenderers()->RemoveAllItems();
    RendererAttachments attachments(*window_);
    attachments.Add(clear_renderer_);
    for (const auto &layer : layers) {
      layer.renderer->SetViewport(layer.viewport.data());
      layer.renderer->SetLayer(0);
      attachments.Add(layer.renderer);
    }

    const auto render_started = Clock::now();
    window_->Render();
    const auto render_finished = Clock::now();

    CaptureWorldToClip(*layers[primary_layer].renderer, metrics);

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
  }

  vtkSmartPointer<vtkRenderWindow> window_;
  vtkSmartPointer<vtkRenderer> clear_renderer_;
};

FrameCallbackFailure::FrameCallbackFailure(int32_t code, std::string message)
    : std::runtime_error(std::move(message)), code_(code) {}

int32_t FrameCallbackFailure::Code() const { return code_; }

void CopyRgbaBottomUpToFrame(const std::uint8_t *source,
                             const VtkFlutterViewport &viewport,
                             const VtkFlutterCpuFrame &frame) {
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
    const VtkFlutterFrameCallbacks &callbacks)
    : callbacks_(callbacks), impl_(std::make_unique<Impl>()) {}

CallbackRenderTarget::~CallbackRenderTarget() = default;

void CallbackRenderTarget::Render(const std::vector<RenderLayer> &layers,
                                  const VtkFlutterViewport &viewport,
                                  std::uint32_t primary_layer,
                                  VtkFlutterFrameMetrics &metrics) {
  VtkFlutterCpuFrame frame{};
  VtkFlutterStatus callback_status{};
  const auto begin_code = callbacks_.begin_frame(
      callbacks_.user_data, &viewport, &frame, &callback_status);
  CheckCallbackResult(begin_code, callback_status, "begin_frame failed");

  try {
    RequiredCapacity(viewport, frame);
    impl_->Render(layers, viewport, primary_layer, frame, metrics);
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
