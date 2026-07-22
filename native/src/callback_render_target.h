#ifndef VTK_FLUTTER_CALLBACK_RENDER_TARGET_H_
#define VTK_FLUTTER_CALLBACK_RENDER_TARGET_H_

#include "vtk_flutter.h"

#include <vtkSmartPointer.h>

#include <array>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

VTK_ABI_NAMESPACE_BEGIN
class vtkRenderer;
VTK_ABI_NAMESPACE_END

namespace vtk_flutter {
struct RenderLayer {
  vtkSmartPointer<vtkRenderer> renderer;
  std::array<double, 4> viewport;
};

class FrameCallbackFailure final : public std::runtime_error {
public:
  FrameCallbackFailure(int32_t code, std::string message);

  int32_t Code() const;

private:
  int32_t code_;
};

void CopyRgbaBottomUpToFrame(const std::uint8_t *source,
                             const VtkFlutterViewport &viewport,
                             const VtkFlutterCpuFrame &frame);

class CallbackRenderTarget final {
public:
  explicit CallbackRenderTarget(const VtkFlutterFrameCallbacks &callbacks);
  ~CallbackRenderTarget();

  CallbackRenderTarget(const CallbackRenderTarget &) = delete;
  CallbackRenderTarget &operator=(const CallbackRenderTarget &) = delete;

  void Render(const std::vector<RenderLayer> &layers,
              const VtkFlutterViewport &viewport, std::uint32_t primary_layer,
              VtkFlutterFrameMetrics &metrics);

private:
  class Impl;

  VtkFlutterFrameCallbacks callbacks_{};
  std::unique_ptr<Impl> impl_;
};
} // namespace vtk_flutter

#endif // VTK_FLUTTER_CALLBACK_RENDER_TARGET_H_
