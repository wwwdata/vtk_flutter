#ifndef VTK_FLUTTER_SESSION_H_
#define VTK_FLUTTER_SESSION_H_

#include "render_target.h"

#include <memory>
#include <stdexcept>

namespace vtk_flutter {
class RenderTargetUnavailable final : public std::runtime_error {
public:
  RenderTargetUnavailable();
};

class Session final {
public:
  explicit Session(std::unique_ptr<RenderTarget> render_target = nullptr);
  ~Session();

  Session(const Session &) = delete;
  Session &operator=(const Session &) = delete;

  void SetVolume(const VtkFlutterVolume &volume);
  void Render(const VtkFlutterRenderRequest &request,
              VtkFlutterMetrics &metrics);
  void SetRenderTarget(std::unique_ptr<RenderTarget> render_target);

  const VolumePipeline &Pipeline() const;

private:
  VolumePipeline pipeline_;
  std::unique_ptr<RenderTarget> render_target_;
};
} // namespace vtk_flutter

// Platform adapters may include this internal header and construct the opaque C
// handle with their RenderTarget. Core-created handles intentionally have no
// target and cannot render.
struct VtkFlutterSession {
  explicit VtkFlutterSession(
      std::unique_ptr<vtk_flutter::RenderTarget> render_target = nullptr);

  vtk_flutter::Session value;
};

#endif // VTK_FLUTTER_SESSION_H_
