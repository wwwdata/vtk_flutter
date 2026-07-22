#ifndef VTK_FLUTTER_SESSION_H_
#define VTK_FLUTTER_SESSION_H_

#include "callback_render_target.h"
#include "vtk_flutter.h"

#include <vtkSmartPointer.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

VTK_ABI_NAMESPACE_BEGIN
class vtkObjectManager;
class vtkRenderer;
VTK_ABI_NAMESPACE_END

struct vtkSessionImpl;
typedef struct vtkSessionImpl *vtkSession;

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

struct VtkFlutterTextureTarget {
  explicit VtkFlutterTextureTarget(const VtkFlutterFrameCallbacks &callbacks);
  ~VtkFlutterTextureTarget();

  VtkFlutterTextureTarget(const VtkFlutterTextureTarget &) = delete;
  VtkFlutterTextureTarget &operator=(const VtkFlutterTextureTarget &) = delete;

  void MarkDestroying();

private:
  friend class vtk_flutter::Session;

  void Attach(vtk_flutter::Session *session);
  void Detach(vtk_flutter::Session *session);
  void Render(const std::vector<vtk_flutter::RenderLayer> &layers,
              const VtkFlutterViewport &viewport, std::uint32_t primary_layer,
              VtkFlutterFrameMetrics &metrics);

  std::unique_ptr<vtk_flutter::CallbackRenderTarget> render_target_;
  std::mutex attachment_mutex_;
  vtk_flutter::Session *attached_session_ = nullptr;
  bool destroying_ = false;
};

namespace vtk_flutter {
class Session final {
public:
  Session();
  ~Session();

  Session(const Session &) = delete;
  Session &operator=(const Session &) = delete;

  VtkFlutterObjectHandle CreateObject(const char *class_name);
  void DestroyObject(VtkFlutterObjectHandle object);
  std::string Invoke(VtkFlutterObjectHandle object, const char *method_name,
                     const char *arguments_json);
  VtkFlutterObjectHandle CreateImageData(const VtkFlutterImageData &image);
  void RenderLayout(const VtkFlutterRenderLayer *layers,
                    std::uint32_t layer_count,
                    const VtkFlutterViewport &viewport,
                    std::uint32_t primary_layer,
                    VtkFlutterFrameMetrics &metrics);
  void AttachTextureTarget(VtkFlutterTextureTarget &target);
  void DetachTextureTarget(VtkFlutterTextureTarget &target);

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

  vtkSession session_ = nullptr;
  vtkObjectManager *manager_ = nullptr;
  VtkFlutterTextureTarget *attached_target_ = nullptr;
  std::recursive_mutex operation_mutex_;
  bool operation_active_ = false;
};
} // namespace vtk_flutter

struct VtkFlutterSession {
  vtk_flutter::Session value;
};

#endif // VTK_FLUTTER_SESSION_H_
