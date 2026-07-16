#ifndef VTK_FLUTTER_SESSION_H_
#define VTK_FLUTTER_SESSION_H_

#include "render_target.h"

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

class FrameCallbackFailure final : public std::runtime_error {
public:
  FrameCallbackFailure(int32_t code, std::string message);

  int32_t Code() const;

private:
  int32_t code_;
};
} // namespace vtk_flutter

// The public header exposes only this tag. Platform adapters construct the
// concrete handle in their private native implementation, where RenderTarget
// and VTK types are allowed. The C v2 table only ever receives the opaque
// pointer.
struct VtkFlutterTextureTarget {
  explicit VtkFlutterTextureTarget(
      std::unique_ptr<vtk_flutter::RenderTarget> render_target,
      const VtkFlutterFrameCallbacksV2 *callbacks = nullptr);
  ~VtkFlutterTextureTarget();

  VtkFlutterTextureTarget(const VtkFlutterTextureTarget &) = delete;
  VtkFlutterTextureTarget &operator=(const VtkFlutterTextureTarget &) = delete;

private:
  friend class vtk_flutter::Session;

  void Attach(vtk_flutter::Session *session);
  void Detach(vtk_flutter::Session *session);
  void Render(vtk_flutter::PreparedView view,
              const VtkFlutterViewport &viewport,
              VtkFlutterMetrics &metrics);

  std::unique_ptr<vtk_flutter::RenderTarget> render_target_;
  VtkFlutterFrameCallbacksV2 callbacks_{};
  bool has_callbacks_ = false;
  std::mutex attachment_mutex_;
  vtk_flutter::Session *attached_session_ = nullptr;
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
  std::unique_ptr<VtkFlutterTextureTarget> legacy_target_;
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
