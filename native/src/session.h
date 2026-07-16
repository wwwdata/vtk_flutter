#ifndef VTK_FLUTTER_SESSION_H_
#define VTK_FLUTTER_SESSION_H_

#include "callback_render_target.h"

#include <cstdint>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>

namespace vtk_flutter {
class Session;

class RenderTargetUnavailable final : public std::runtime_error {
public:
  RenderTargetUnavailable();
};

class InvalidState final : public std::runtime_error {
public:
  explicit InvalidState(const char *message);
};

} // namespace vtk_flutter

// The public header exposes only this tag. ABI-v2 construction and destruction
// happen inside vtk_flutter.cxx, so no definition or C++ type crosses the C
// boundary.
struct VtkFlutterTextureTarget {
  explicit VtkFlutterTextureTarget(
      const VtkFlutterFrameCallbacksV2 &callbacks);
  ~VtkFlutterTextureTarget();

  VtkFlutterTextureTarget(const VtkFlutterTextureTarget &) = delete;
  VtkFlutterTextureTarget &operator=(const VtkFlutterTextureTarget &) = delete;

  void MarkDestroying();

private:
  friend class vtk_flutter::Session;

  void Attach(vtk_flutter::Session *session);
  void Detach(vtk_flutter::Session *session);
  void Render(vtk_flutter::PreparedView view,
              const VtkFlutterViewport &viewport,
              VtkFlutterMetrics &metrics);

  std::unique_ptr<vtk_flutter::CallbackRenderTarget> render_target_;
  std::mutex attachment_mutex_;
  vtk_flutter::Session *attached_session_ = nullptr;
  bool destroying_ = false;
};

namespace vtk_flutter {
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
  void AttachTextureTarget(VtkFlutterTextureTarget &target);
  void DetachTextureTarget(VtkFlutterTextureTarget &target);

  const VolumePipeline &Pipeline() const;

private:
  class Operation final {
  public:
    explicit Operation(Session &session);
    ~Operation();

    Operation(const Operation &) = delete;
    Operation &operator=(const Operation &) = delete;

  private:
    Session &session_;
    std::unique_lock<std::recursive_mutex> lock_;
  };

  VolumePipeline pipeline_;
  std::unique_ptr<RenderTarget> legacy_target_;
  VtkFlutterTextureTarget *attached_target_ = nullptr;
  std::recursive_mutex operation_mutex_;
  bool operation_active_ = false;
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
