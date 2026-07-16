#include "windows_vtk_render_target.h"

#include <vtkCamera.h>
#include <vtkMatrix4x4.h>
#include <vtkNew.h>
#include <vtkRenderer.h>
#include <vtkRendererCollection.h>
#include <vtkUnsignedCharArray.h>
#include <vtkWin32OpenGLRenderWindow.h>

#include <windows.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <stdexcept>
#include <utility>

namespace vtk_flutter::windows {
namespace {

using Clock = std::chrono::steady_clock;

class CurrentContext final {
public:
  explicit CurrentContext(vtkWin32OpenGLRenderWindow *window)
      : window_(window) {
    window_->MakeCurrent();
  }

  ~CurrentContext() { window_->ReleaseCurrent(); }

private:
  vtkWin32OpenGLRenderWindow *window_;
};

template <typename Duration> double Milliseconds(Duration duration) {
  return std::chrono::duration<double, std::milli>(duration).count();
}

std::string OpenGlModulePath() {
  const auto module = GetModuleHandleA("opengl32.dll");
  if (module == nullptr) {
    return "not loaded";
  }
  char path[MAX_PATH]{};
  const auto length = GetModuleFileNameA(module, path, MAX_PATH);
  return length == 0 ? "path unavailable" : std::string(path, length);
}

void PopulateContentEvidence(const PublishedFrame &frame,
                             VtkFlutterMetrics &metrics) {
  constexpr std::uint64_t kFnv1a64OffsetBasis = 14695981039346656037ULL;
  constexpr std::uint64_t kFnv1a64Prime = 1099511628211ULL;
  std::array<bool, 256> encountered_values{};
  std::uint64_t checksum = kFnv1a64OffsetBasis;
  std::uint64_t changed_pixels = 0;
  const std::array<std::uint8_t, 4> background{frame.rgba[0], frame.rgba[1],
                                               frame.rgba[2], frame.rgba[3]};
  for (std::size_t offset = 0; offset < frame.rgba.size(); offset += 4) {
    bool changed = false;
    for (std::size_t channel = 0; channel < 4; ++channel) {
      const auto value = frame.rgba[offset + channel];
      checksum ^= value;
      checksum *= kFnv1a64Prime;
      encountered_values[value] = true;
      changed = changed || value != background[channel];
    }
    if (changed) {
      ++changed_pixels;
    }
  }
  metrics.surface_checksum = checksum;
  metrics.surface_changed_pixels = changed_pixels;
  metrics.surface_unique_byte_values = static_cast<std::uint64_t>(
      std::count(encountered_values.begin(), encountered_values.end(), true));
}

} // namespace

WindowsVtkRenderTarget::WindowsVtkRenderTarget(
    flutter::TextureRegistrar *texture_registrar,
    std::shared_ptr<PresentationState> presentation,
    std::int64_t graphics_context_generation)
    : texture_registrar_(texture_registrar),
      presentation_(std::move(presentation)),
      graphics_context_generation_(graphics_context_generation) {
  if (texture_registrar_ == nullptr || presentation_ == nullptr ||
      graphics_context_generation_ <= 0) {
    throw std::invalid_argument(
        "Windows VTK requires a texture registrar and presentation state");
  }
  window_ = vtkSmartPointer<vtkWin32OpenGLRenderWindow>::New();
  window_->SetWindowName("vtk_flutter Windows offscreen renderer");
  window_->SetShowWindow(false);
  window_->SetUseOffScreenBuffers(true);
  window_->SetAlphaBitPlanes(1);
  window_->SetMultiSamples(0);
  window_->SetSwapBuffers(0);
  window_->SetSize(1, 1);
  window_->Initialize();
  ValidateGraphicsContext();
  graphics_support_ =
      window_->GetOpenGLSupportMessage() + "\nopengl32=" + OpenGlModulePath();
  if (const char *capabilities = window_->ReportCapabilities()) {
    graphics_support_ += "\n";
    graphics_support_ += capabilities;
  }
  // Method-channel operations and exported C ABI calls may run on different
  // engine threads. Leave the WGL context unbound between operations so it can
  // be reacquired by either path.
  window_->ReleaseCurrent();
}

WindowsVtkRenderTarget::~WindowsVtkRenderTarget() {
  std::lock_guard lock(render_mutex_);
  if (window_ != nullptr) {
    window_->MakeCurrent();
    window_->GetRenderers()->RemoveAllItems();
    window_->Finalize();
    window_ = nullptr;
  }
}

void WindowsVtkRenderTarget::Render(vtk_flutter::PreparedView view,
                                    const VtkFlutterViewport &viewport,
                                    VtkFlutterMetrics &metrics) {
  std::lock_guard lock(render_mutex_);
  CurrentContext current_context(window_);
  static_cast<void>(current_context);
  window_->SetSize(viewport.width, viewport.height);
  window_->GetRenderers()->RemoveAllItems();
  window_->AddRenderer(view.renderer);

  const auto render_started = Clock::now();
  window_->Render();
  const auto render_finished = Clock::now();

  if (view.capture_patient_to_clip) {
    auto *matrix =
        view.renderer->GetActiveCamera()->GetCompositeProjectionTransformMatrix(
            view.renderer->GetTiledAspectRatio(), -1.0, 1.0);
    for (int row = 0; row < 4; ++row) {
      for (int column = 0; column < 4; ++column) {
        metrics.patient_to_clip[row * 4 + column] =
            matrix->GetElement(row, column);
      }
    }
    metrics.patient_to_clip_valid = 1;
  }

  vtkNew<vtkUnsignedCharArray> pixels;
  const auto readback_started = Clock::now();
  if (window_->GetRGBACharPixelData(0, 0, viewport.width - 1,
                                    viewport.height - 1, 0, pixels) == 0) {
    throw std::runtime_error("Windows VTK framebuffer readback failed");
  }

  auto frame = std::make_shared<PublishedFrame>();
  frame->id = ++presentation_->submitted_frame_id;
  frame->width = viewport.width;
  frame->height = viewport.height;
  frame->rgba.resize(static_cast<std::size_t>(viewport.width) *
                     static_cast<std::size_t>(viewport.height) * 4U);
  const auto *source = pixels->GetPointer(0);
  const auto row_bytes = static_cast<std::size_t>(viewport.width) * 4U;
  for (int row = 0; row < viewport.height; ++row) {
    const auto source_row =
        static_cast<std::size_t>(viewport.height - 1 - row) * row_bytes;
    const auto destination_row = static_cast<std::size_t>(row) * row_bytes;
    std::copy_n(source + source_row, row_bytes,
                frame->rgba.data() + destination_row);
  }
  const auto readback_finished = Clock::now();

  metrics.surface_allocation_bytes = frame->rgba.size();
  metrics.render_ms = Milliseconds(render_finished - render_started);
  metrics.surface_submit_ms = 0.0;
  metrics.gpu_sync_wait_ms = 0.0;
  metrics.cpu_readback_ms = Milliseconds(readback_finished - readback_started);
  PopulateContentEvidence(*frame, metrics);

  {
    std::lock_guard presentation_lock(presentation_->mutex);
    presentation_->latest = frame;
  }
  const auto texture_id = texture_id_.load();
  if (texture_id < 0 ||
      !texture_registrar_->MarkTextureFrameAvailable(texture_id)) {
    throw std::runtime_error("Flutter rejected the Windows VTK texture frame");
  }
}

void WindowsVtkRenderTarget::SetTextureId(std::int64_t texture_id) {
  texture_id_ = texture_id;
}

std::int64_t WindowsVtkRenderTarget::FrameId() const {
  return presentation_->submitted_frame_id.load();
}

std::int64_t WindowsVtkRenderTarget::GraphicsContextGeneration() const {
  return graphics_context_generation_;
}

const std::string &WindowsVtkRenderTarget::GraphicsSupport() const {
  return graphics_support_;
}

void WindowsVtkRenderTarget::ValidateGraphicsContext() {
  window_->MakeCurrent();
  if (!window_->IsCurrent()) {
    throw std::runtime_error(
        "Windows VTK could not make its OpenGL context current");
  }
  if (window_->SupportsOpenGL() == 0) {
    throw std::runtime_error("VTK requires OpenGL 3.2 or newer: " +
                             window_->GetOpenGLSupportMessage() +
                             " (opengl32=" + OpenGlModulePath() + ")");
  }
}

} // namespace vtk_flutter::windows
