#ifndef FLUTTER_PLUGIN_WINDOWS_VTK_RENDER_TARGET_H_
#define FLUTTER_PLUGIN_WINDOWS_VTK_RENDER_TARGET_H_

#include <flutter/texture_registrar.h>

#include <render_target.h>
#include <vtkSmartPointer.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

class vtkWin32OpenGLRenderWindow;

namespace vtk_flutter::windows {

struct PublishedFrame {
  std::int64_t id = 0;
  int width = 0;
  int height = 0;
  std::vector<std::uint8_t> rgba;
};

struct PresentationState {
  std::mutex mutex;
  std::shared_ptr<const PublishedFrame> latest;
  std::atomic<std::int64_t> submitted_frame_id = 0;
  std::atomic<std::int64_t> presented_count = 0;
  std::atomic<std::int64_t> presented_frame_id = 0;
};

class WindowsVtkRenderTarget final : public vtk_flutter::RenderTarget {
public:
  WindowsVtkRenderTarget(flutter::TextureRegistrar *texture_registrar,
                         std::shared_ptr<PresentationState> presentation,
                         std::int64_t graphics_context_generation = 1);
  ~WindowsVtkRenderTarget() override;

  WindowsVtkRenderTarget(const WindowsVtkRenderTarget &) = delete;
  WindowsVtkRenderTarget &operator=(const WindowsVtkRenderTarget &) = delete;

  void Render(vtk_flutter::PreparedView view,
              const VtkFlutterViewport &viewport,
              VtkFlutterMetrics &metrics) override;

  void SetTextureId(std::int64_t texture_id);
  std::int64_t FrameId() const;
  std::int64_t GraphicsContextGeneration() const;
  const std::string &GraphicsSupport() const;

private:
  void ValidateGraphicsContext();

  flutter::TextureRegistrar *texture_registrar_;
  std::shared_ptr<PresentationState> presentation_;
  vtkSmartPointer<vtkWin32OpenGLRenderWindow> window_;
  std::atomic<std::int64_t> texture_id_ = -1;
  std::int64_t graphics_context_generation_;
  std::string graphics_support_;
  std::mutex render_mutex_;
};

} // namespace vtk_flutter::windows

#endif // FLUTTER_PLUGIN_WINDOWS_VTK_RENDER_TARGET_H_
