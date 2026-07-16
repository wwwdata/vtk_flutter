#ifndef VTK_FLUTTER_CALLBACK_RENDER_TARGET_H_
#define VTK_FLUTTER_CALLBACK_RENDER_TARGET_H_

#include "render_target.h"

#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>

namespace vtk_flutter {
class FrameCallbackFailure final : public std::runtime_error {
public:
  FrameCallbackFailure(int32_t code, std::string message);

  int32_t Code() const;

private:
  int32_t code_;
};

// Copies tightly packed, bottom-up VTK RGBA pixels into a validated top-down
// caller frame. Exposed internally so the byte-level contract can be tested
// independently of a graphics driver.
void CopyRgbaBottomUpToFrame(const std::uint8_t *source,
                             const VtkFlutterViewport &viewport,
                             const VtkFlutterCpuFrameV2 &frame);

class CallbackRenderTarget final : public RenderTarget {
public:
  explicit CallbackRenderTarget(const VtkFlutterFrameCallbacksV2 &callbacks);
  ~CallbackRenderTarget() override;

  CallbackRenderTarget(const CallbackRenderTarget &) = delete;
  CallbackRenderTarget &operator=(const CallbackRenderTarget &) = delete;

  void Render(PreparedView view, const VtkFlutterViewport &viewport,
              VtkFlutterMetrics &metrics) override;

private:
  class Impl;

  VtkFlutterFrameCallbacksV2 callbacks_{};
  std::unique_ptr<Impl> impl_;
};
} // namespace vtk_flutter

#endif // VTK_FLUTTER_CALLBACK_RENDER_TARGET_H_
