#include "session.h"

#include <cstdint>
#include <utility>

namespace vtk_flutter {
RenderTargetUnavailable::RenderTargetUnavailable()
    : std::runtime_error(
          "no platform render target is attached to this session") {}

Session::Session(std::unique_ptr<RenderTarget> render_target)
    : render_target_(std::move(render_target)) {}

Session::~Session() = default;

void Session::SetVolume(const VtkFlutterVolume &volume) {
  pipeline_.SetVolume(volume);
}

void Session::Render(const VtkFlutterRenderRequest &request,
                     VtkFlutterMetrics &metrics) {
  VolumePipeline::ValidateRenderRequest(request);
  if (render_target_ == nullptr) {
    throw RenderTargetUnavailable();
  }

  metrics = {};
  metrics.volume_bytes = static_cast<std::uint64_t>(pipeline_.VolumeBytes());
  metrics.frame_bytes = static_cast<std::uint64_t>(request.viewport.width) *
                        static_cast<std::uint64_t>(request.viewport.height) *
                        4ULL;
  metrics.frame_width = request.viewport.width;
  metrics.frame_height = request.viewport.height;
  render_target_->Render(pipeline_.PrepareView(request), request.viewport,
                         metrics);
}

void Session::SetRenderTarget(std::unique_ptr<RenderTarget> render_target) {
  render_target_ = std::move(render_target);
}

const VolumePipeline &Session::Pipeline() const { return pipeline_; }
} // namespace vtk_flutter

VtkFlutterSession::VtkFlutterSession(
    std::unique_ptr<vtk_flutter::RenderTarget> render_target)
    : value(std::move(render_target)) {}
