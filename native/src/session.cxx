#include "session.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>

namespace {
constexpr std::size_t kFrameCallbacksV2Size =
    sizeof(VtkFlutterFrameCallbacksV2);

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
  throw vtk_flutter::FrameCallbackFailure(
      contained_code, CallbackMessage(status, fallback));
}
} // namespace

namespace vtk_flutter {
RenderTargetUnavailable::RenderTargetUnavailable()
    : std::runtime_error(
          "no platform render target is attached to this session") {}

InvalidState::InvalidState(const char *message) : std::runtime_error(message) {}

FrameCallbackFailure::FrameCallbackFailure(int32_t code, std::string message)
    : std::runtime_error(std::move(message)), code_(code) {}

int32_t FrameCallbackFailure::Code() const { return code_; }

Session::Session(std::unique_ptr<RenderTarget> render_target)
    : legacy_target_(render_target == nullptr
                         ? nullptr
                         : std::make_unique<VtkFlutterTextureTarget>(
                               std::move(render_target))) {}

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
  auto *target =
      attached_target_ != nullptr ? attached_target_ : legacy_target_.get();
  if (target == nullptr) {
    throw RenderTargetUnavailable();
  }

  metrics = {};
  metrics.volume_bytes = static_cast<std::uint64_t>(pipeline_.VolumeBytes());
  metrics.frame_bytes = static_cast<std::uint64_t>(request.viewport.width) *
                        static_cast<std::uint64_t>(request.viewport.height) *
                        4ULL;
  metrics.frame_width = request.viewport.width;
  metrics.frame_height = request.viewport.height;
  target->Render(pipeline_.PrepareView(request), request.viewport, metrics);
}

void Session::SetRenderTarget(std::unique_ptr<RenderTarget> render_target) {
  Operation operation(*this);
  legacy_target_ = render_target == nullptr
                       ? nullptr
                       : std::make_unique<VtkFlutterTextureTarget>(
                             std::move(render_target));
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
    std::unique_ptr<vtk_flutter::RenderTarget> render_target,
    const VtkFlutterFrameCallbacksV2 *callbacks)
    : render_target_(std::move(render_target)) {
  if (render_target_ == nullptr) {
    throw std::invalid_argument("render_target is required");
  }
  if (callbacks == nullptr) {
    return;
  }
  if (callbacks->version != VTK_FLUTTER_FRAME_CALLBACKS_VERSION_2 ||
      callbacks->struct_size < kFrameCallbacksV2Size) {
    throw std::invalid_argument("unsupported frame callback table");
  }
  if (callbacks->begin_frame == nullptr || callbacks->end_frame == nullptr ||
      callbacks->cancel_frame == nullptr) {
    throw std::invalid_argument("all frame callbacks are required");
  }
  callbacks_ = *callbacks;
  has_callbacks_ = true;
}

VtkFlutterTextureTarget::~VtkFlutterTextureTarget() = default;

void VtkFlutterTextureTarget::Attach(vtk_flutter::Session *session) {
  std::lock_guard lock(attachment_mutex_);
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

void VtkFlutterTextureTarget::Render(vtk_flutter::PreparedView view,
                                     const VtkFlutterViewport &viewport,
                                     VtkFlutterMetrics &metrics) {
  if (!has_callbacks_) {
    render_target_->Render(std::move(view), viewport, metrics);
    return;
  }

  VtkFlutterStatus callback_status{};
  const auto begin_code =
      callbacks_.begin_frame(callbacks_.user_data, &viewport, &callback_status);
  CheckCallbackResult(begin_code, callback_status, "begin_frame failed");

  try {
    render_target_->Render(std::move(view), viewport, metrics);
    callback_status = {};
    const auto end_code = callbacks_.end_frame(callbacks_.user_data, &metrics,
                                                &callback_status);
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

VtkFlutterSession::VtkFlutterSession(
    std::unique_ptr<vtk_flutter::RenderTarget> render_target)
    : value(std::move(render_target)) {}
