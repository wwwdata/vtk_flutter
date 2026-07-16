#include "session.h"

#include <cstddef>
#include <utility>

namespace {
constexpr std::size_t kFrameCallbacksV2Size =
    sizeof(VtkFlutterFrameCallbacksV2);
} // namespace

namespace vtk_flutter {
RenderTargetUnavailable::RenderTargetUnavailable()
    : std::runtime_error(
          "no platform render target is attached to this session") {}

InvalidState::InvalidState(const char *message) : std::runtime_error(message) {}

Session::Session(std::unique_ptr<RenderTarget> render_target)
    : legacy_target_(std::move(render_target)) {}

Session::~Session() {
  if (attached_target_ != nullptr) {
    attached_target_->Detach(this);
  }
}

Session::Operation::Operation(Session &session)
    : session_(session), lock_(session.operation_mutex_) {
  if (session_.operation_active_) {
    throw InvalidState("reentrant access to a session is not allowed");
  }
  session_.operation_active_ = true;
}

Session::Operation::~Operation() { session_.operation_active_ = false; }

void Session::SetVolume(const VtkFlutterVolume &volume) {
  Operation operation(*this);
  pipeline_.SetVolume(volume);
}

void Session::Render(const VtkFlutterRenderRequest &request,
                     VtkFlutterMetrics &metrics) {
  Operation operation(*this);
  VolumePipeline::ValidateRenderRequest(request);
  if (attached_target_ == nullptr && legacy_target_ == nullptr) {
    throw RenderTargetUnavailable();
  }

  metrics = {};
  metrics.volume_bytes = static_cast<std::uint64_t>(pipeline_.VolumeBytes());
  metrics.frame_bytes = static_cast<std::uint64_t>(request.viewport.width) *
                        static_cast<std::uint64_t>(request.viewport.height) *
                        4ULL;
  metrics.frame_width = request.viewport.width;
  metrics.frame_height = request.viewport.height;
  auto view = pipeline_.PrepareView(request);
  if (attached_target_ != nullptr) {
    attached_target_->Render(std::move(view), request.viewport, metrics);
  } else {
    legacy_target_->Render(std::move(view), request.viewport, metrics);
  }
}

void Session::SetRenderTarget(std::unique_ptr<RenderTarget> render_target) {
  Operation operation(*this);
  legacy_target_ = std::move(render_target);
}

void Session::AttachTextureTarget(VtkFlutterTextureTarget &target) {
  Operation operation(*this);
  if (attached_target_ == &target) {
    return;
  }
  if (attached_target_ != nullptr) {
    throw InvalidState("a texture target is already attached to the session");
  }
  target.Attach(this);
  attached_target_ = &target;
}

void Session::DetachTextureTarget(VtkFlutterTextureTarget &target) {
  Operation operation(*this);
  if (attached_target_ == nullptr) {
    return;
  }
  if (attached_target_ != &target) {
    throw InvalidState("the requested texture target is not attached");
  }
  target.Detach(this);
  attached_target_ = nullptr;
}

const VolumePipeline &Session::Pipeline() const { return pipeline_; }
} // namespace vtk_flutter

VtkFlutterTextureTarget::VtkFlutterTextureTarget(
    const VtkFlutterFrameCallbacksV2 &callbacks) {
  if (callbacks.version != VTK_FLUTTER_FRAME_CALLBACKS_VERSION_2 ||
      callbacks.struct_size < kFrameCallbacksV2Size) {
    throw std::invalid_argument("unsupported frame callback table");
  }
  if (callbacks.begin_frame == nullptr || callbacks.end_frame == nullptr ||
      callbacks.cancel_frame == nullptr) {
    throw std::invalid_argument("all frame callbacks are required");
  }
  render_target_ =
      std::make_unique<vtk_flutter::CallbackRenderTarget>(callbacks);
}

VtkFlutterTextureTarget::~VtkFlutterTextureTarget() = default;

void VtkFlutterTextureTarget::Attach(vtk_flutter::Session *session) {
  std::lock_guard lock(attachment_mutex_);
  if (destroying_) {
    throw vtk_flutter::InvalidState("the texture target is being destroyed");
  }
  if (attached_session_ != nullptr && attached_session_ != session) {
    throw vtk_flutter::InvalidState(
        "the texture target is already attached to another session");
  }
  attached_session_ = session;
}

void VtkFlutterTextureTarget::Detach(vtk_flutter::Session *session) {
  std::lock_guard lock(attachment_mutex_);
  if (attached_session_ == nullptr) {
    return;
  }
  if (attached_session_ != session) {
    throw vtk_flutter::InvalidState(
        "the texture target is attached to another session");
  }
  attached_session_ = nullptr;
}

void VtkFlutterTextureTarget::MarkDestroying() {
  std::lock_guard lock(attachment_mutex_);
  if (attached_session_ != nullptr) {
    throw vtk_flutter::InvalidState(
        "the texture target must be detached before destruction");
  }
  if (destroying_) {
    throw vtk_flutter::InvalidState(
        "the texture target is already being destroyed");
  }
  destroying_ = true;
}

void VtkFlutterTextureTarget::Render(vtk_flutter::PreparedView view,
                                     const VtkFlutterViewport &viewport,
                                     VtkFlutterMetrics &metrics) {
  render_target_->Render(std::move(view), viewport, metrics);
}

VtkFlutterSession::VtkFlutterSession(
    std::unique_ptr<vtk_flutter::RenderTarget> render_target)
    : value(std::move(render_target)) {}
