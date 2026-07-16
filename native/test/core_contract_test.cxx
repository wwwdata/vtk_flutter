#include "c_contract_support.h"
#include "session.h"
#include "volume_pipeline.h"
#include "vtk_flutter.h"

#include <vtkCamera.h>
#include <vtkImageData.h>
#include <vtkRenderer.h>

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

namespace {
void Require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error(message);
  }
}

VtkFlutterVolume MakeVolume(std::vector<std::int16_t> &voxels) {
  VtkFlutterVolume volume{};
  volume.voxels = voxels.data();
  volume.voxel_count = voxels.size();
  volume.width = 2;
  volume.height = 3;
  volume.depth = 4;
  const double affine[16] = {0.5, 0.0, 0.0, -4.0, 0.0, 0.6, 0.0, 8.0,
                             0.0, 0.0, 1.2, 12.0, 0.0, 0.0, 0.0, 1.0};
  for (int index = 0; index < 16; ++index) {
    volume.index_to_patient[index] = affine[index];
  }
  return volume;
}

VtkFlutterRenderRequest MakeRequest(int32_t mode) {
  VtkFlutterRenderRequest request{};
  request.mode = mode;
  request.viewport = {640, 320};
  request.window_center = 350.0;
  request.window_width = 1800.0;
  request.plane_normal[2] = 1.0;
  request.camera_azimuth_degrees = 61.0;
  request.camera_elevation_degrees = -11.0;
  request.camera_zoom = 1.75;
  return request;
}

class RecordingRenderTarget final : public vtk_flutter::RenderTarget {
public:
  void Render(vtk_flutter::PreparedView view,
              const VtkFlutterViewport &viewport,
              VtkFlutterMetrics &metrics) override {
    ++render_count;
    captured_view = std::move(view);
    captured_viewport = viewport;
    metrics.surface_allocation_bytes = metrics.frame_bytes + 128;
    metrics.patient_to_clip_valid =
        captured_view.capture_patient_to_clip ? 1 : 0;
  }

  int render_count = 0;
  vtk_flutter::PreparedView captured_view;
  VtkFlutterViewport captured_viewport{};
};

class ThrowingRenderTarget final : public vtk_flutter::RenderTarget {
public:
  void Render(vtk_flutter::PreparedView, const VtkFlutterViewport &,
              VtkFlutterMetrics &) override {
    throw std::runtime_error("render target failure");
  }
};

struct ReentrantCallbackContext {
  const VtkFlutterCoreApiV2 *api = nullptr;
  VtkFlutterSession *session = nullptr;
  VtkFlutterTextureTarget *target = nullptr;
  int32_t reentrant_result = VTK_FLUTTER_STATUS_OK;
};

int32_t VTK_FLUTTER_CALL ReentrantBeginFrame(
    void *user_data, const VtkFlutterViewport *, VtkFlutterStatus *) {
  auto &context = *static_cast<ReentrantCallbackContext *>(user_data);
  VtkFlutterStatus nested_status{};
  context.reentrant_result = context.api->session_detach_texture_target(
      context.session, context.target, &nested_status);
  return VTK_FLUTTER_STATUS_OK;
}

int32_t VTK_FLUTTER_CALL ReentrantEndFrame(
    void *, const VtkFlutterMetrics *, VtkFlutterStatus *) {
  return VTK_FLUTTER_STATUS_OK;
}

void VTK_FLUTTER_CALL ReentrantCancelFrame(void *) {}
} // namespace

int main() {
  static_assert(std::is_standard_layout_v<VtkFlutterViewport>);
  static_assert(std::is_standard_layout_v<VtkFlutterVolume>);
  static_assert(std::is_standard_layout_v<VtkFlutterRenderRequest>);
  static_assert(std::is_standard_layout_v<VtkFlutterMetrics>);
  static_assert(std::is_standard_layout_v<VtkFlutterStatus>);

  try {
    Require(vtk_flutter_abi_version() == 1U,
            "C interface reported the wrong ABI version");
    Require(vtk_flutter_public_header_is_c_compatible() == 0,
            "ABI v2 public header contract failed");
    const auto *core_api = vtk_flutter_get_core_api_v2();
    Require(core_api != nullptr &&
                core_api->version == VTK_FLUTTER_CORE_API_VERSION_2 &&
                core_api->struct_size >= sizeof(VtkFlutterCoreApiV2),
            "ABI v2 core table is unavailable");
    VtkFlutterStatus status{};
    VtkFlutterSession *c_session = nullptr;
    Require(vtk_flutter_session_create(&c_session, &status) ==
                    VTK_FLUTTER_STATUS_OK &&
                c_session != nullptr && status.message[0] == '\0',
            "C interface could not create a core session");

    std::vector<std::int16_t> voxels(24);
    for (std::size_t index = 0; index < voxels.size(); ++index) {
      voxels[index] = static_cast<std::int16_t>(index) - 12;
    }
    auto volume = MakeVolume(voxels);
    Require(vtk_flutter_validate_volume(&volume, &status) ==
                VTK_FLUTTER_STATUS_OK,
            "C interface rejected a valid volume");
    Require(vtk_flutter_session_set_volume(c_session, &volume, &status) ==
                VTK_FLUTTER_STATUS_OK,
            "C interface failed to deep-copy a valid volume");
    --volume.voxel_count;
    Require(vtk_flutter_validate_volume(&volume, &status) ==
                    VTK_FLUTTER_STATUS_INVALID_ARGUMENT &&
                status.message[0] != '\0',
            "C interface accepted an inconsistent voxel count");
    ++volume.voxel_count;
    volume.index_to_patient[0] = INFINITY;
    Require(vtk_flutter_validate_volume(&volume, &status) ==
                VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
            "C interface accepted a non-finite affine");
    volume.index_to_patient[0] = 0.5;

    vtk_flutter::VolumePipeline pipeline;
    pipeline.SetVolume(volume);
    const auto first_voxel = voxels.front();
    voxels.front() = 12345;
    Require(*static_cast<std::int16_t *>(pipeline.Image()->GetScalarPointer(
                0, 0, 0)) == first_voxel,
            "pipeline retained caller-owned voxel memory");
    voxels.front() = first_voxel;
    Require(pipeline.VolumeBytes() == voxels.size() * sizeof(std::int16_t),
            "pipeline reported the wrong volume byte count");
    int dimensions[3]{};
    pipeline.Image()->GetDimensions(dimensions);
    Require(dimensions[0] == 2 && dimensions[1] == 3 && dimensions[2] == 4,
            "pipeline did not preserve volume dimensions");
    double spacing[3]{};
    pipeline.Image()->GetSpacing(spacing);
    Require(std::abs(spacing[0] - 0.5) < 1e-12 &&
                std::abs(spacing[1] - 0.6) < 1e-12 &&
                std::abs(spacing[2] - 1.2) < 1e-12,
            "pipeline did not derive affine spacing");
    double origin[3]{};
    pipeline.Image()->GetOrigin(origin);
    Require(origin[0] == -4.0 && origin[1] == 8.0 && origin[2] == 12.0,
            "pipeline did not preserve affine origin");

    auto request = MakeRequest(VTK_FLUTTER_RENDER_OBLIQUE_MPR);
    Require(vtk_flutter_validate_render_request(&request, &status) ==
                VTK_FLUTTER_STATUS_OK,
            "C interface rejected a valid oblique request");
    request.plane_normal[2] = 0.0;
    Require(vtk_flutter_validate_render_request(&request, &status) ==
                VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
            "C interface accepted a zero oblique normal");
    request.plane_normal[2] = 1.0;
    request.viewport.width = 8193;
    Require(vtk_flutter_validate_render_request(&request, &status) ==
                VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
            "C interface accepted an oversized viewport");
    request.viewport.width = 640;
    request.camera_zoom = 5.01;
    Require(vtk_flutter_validate_render_request(&request, &status) ==
                VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
            "C interface accepted an out-of-range zoom");
    request.camera_zoom = 1.75;
    request.plane_origin[0] = NAN;
    Require(vtk_flutter_validate_render_request(&request, &status) ==
                VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
            "C interface accepted a non-finite plane");
    request.plane_origin[0] = 0.0;
    auto oblique_view = pipeline.PrepareView(request);
    Require(oblique_view.renderer != nullptr &&
                !oblique_view.capture_patient_to_clip,
            "oblique mode did not prepare its renderer");

    request.mode = VTK_FLUTTER_RENDER_VOLUME_3D;
    auto volume_view = pipeline.PrepareView(request);
    Require(volume_view.renderer != nullptr &&
                !volume_view.capture_patient_to_clip,
            "volume mode did not prepare its renderer");

    request.mode = VTK_FLUTTER_RENDER_VOLUME_LOCATOR;
    auto first_locator_view = pipeline.PrepareView(request);
    Require(first_locator_view.renderer != nullptr &&
                first_locator_view.capture_patient_to_clip,
            "locator mode did not request projection capture");
    double view_up[3]{};
    first_locator_view.renderer->GetActiveCamera()->GetViewUp(view_up);
    Require(std::abs(view_up[0]) < 1e-12 &&
                std::abs(view_up[1] - 1.0) < 1e-12 &&
                std::abs(view_up[2]) < 1e-12,
            "locator camera did not keep patient dorsal pointing up");
    const double first_scale =
        first_locator_view.renderer->GetActiveCamera()->GetParallelScale();
    request.camera_zoom = 2.5;
    auto second_locator_view = pipeline.PrepareView(request);
    const double second_scale =
        second_locator_view.renderer->GetActiveCamera()->GetParallelScale();
    Require(std::abs(first_scale / second_scale - 2.5 / 1.75) < 1e-12,
            "locator camera did not apply absolute camera_zoom");
    Require(pipeline.LocatorSurfaceBuildCount() == 1,
            "locator surface was rebuilt for a camera-only request");

    request.mode = 999;
    Require(vtk_flutter_validate_render_request(&request, &status) ==
                VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
            "C interface accepted an unknown render mode");

    request = MakeRequest(VTK_FLUTTER_RENDER_VOLUME_LOCATOR);
    VtkFlutterMetrics metrics{};
    Require(
        vtk_flutter_session_render(c_session, &request, &metrics, &status) ==
            VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE,
        "core-created C session did not report its missing platform target");

    VtkFlutterTestFrameRecorder recorder{};
    auto callbacks = vtk_flutter_test_frame_callbacks_v2(&recorder);
    auto v2_render_target = std::make_unique<RecordingRenderTarget>();
    auto *v2_render_observer = v2_render_target.get();
    VtkFlutterTextureTarget texture_target(std::move(v2_render_target),
                                           &callbacks);
    Require(core_api->session_attach_texture_target(c_session, &texture_target,
                                                    &status) ==
                VTK_FLUTTER_STATUS_OK,
            "ABI v2 could not attach a texture target");
    Require(core_api->session_render(c_session, &request, &metrics, &status) ==
                    VTK_FLUTTER_STATUS_OK &&
                recorder.begin_count == 1 && recorder.end_count == 1 &&
                recorder.cancel_count == 0 &&
                recorder.width == request.viewport.width &&
                recorder.height == request.viewport.height &&
                recorder.frame_bytes == metrics.frame_bytes &&
                v2_render_observer->render_count == 1,
            "ABI v2 did not synchronously bracket target rendering");

    recorder.end_result = VTK_FLUTTER_STATUS_INTERNAL_ERROR;
    Require(core_api->session_render(c_session, &request, &metrics, &status) ==
                    VTK_FLUTTER_STATUS_INTERNAL_ERROR &&
                recorder.cancel_count == 1 && metrics.frame_bytes == 0 &&
                std::string(status.message) == "C end_frame failure",
            "ABI v2 did not contain an end_frame failure");
    recorder.end_result = VTK_FLUTTER_STATUS_OK;

    ReentrantCallbackContext reentrant_context{core_api, c_session};
    VtkFlutterFrameCallbacksV2 reentrant_callbacks{
        sizeof(VtkFlutterFrameCallbacksV2),
        VTK_FLUTTER_FRAME_CALLBACKS_VERSION_2,
        &reentrant_context,
        ReentrantBeginFrame,
        ReentrantEndFrame,
        ReentrantCancelFrame,
    };
    auto reentrant_render_target = std::make_unique<RecordingRenderTarget>();
    VtkFlutterTextureTarget reentrant_target(
        std::move(reentrant_render_target), &reentrant_callbacks);
    reentrant_context.target = &reentrant_target;
    Require(core_api->session_detach_texture_target(c_session, &texture_target,
                                                    &status) ==
                VTK_FLUTTER_STATUS_OK,
            "ABI v2 could not detach a texture target");
    Require(core_api->session_attach_texture_target(c_session,
                                                    &reentrant_target,
                                                    &status) ==
                VTK_FLUTTER_STATUS_OK,
            "ABI v2 could not attach the reentrancy test target");
    Require(core_api->session_render(c_session, &request, &metrics, &status) ==
                    VTK_FLUTTER_STATUS_OK &&
                reentrant_context.reentrant_result ==
                    VTK_FLUTTER_STATUS_INVALID_STATE,
            "ABI v2 did not reject same-session callback re-entry");
    Require(core_api->session_detach_texture_target(c_session,
                                                    &reentrant_target,
                                                    &status) ==
                VTK_FLUTTER_STATUS_OK,
            "ABI v2 could not detach the reentrancy test target");

    recorder = {};
    callbacks = vtk_flutter_test_frame_callbacks_v2(&recorder);
    VtkFlutterTextureTarget throwing_target(
        std::make_unique<ThrowingRenderTarget>(), &callbacks);
    Require(core_api->session_attach_texture_target(c_session, &throwing_target,
                                                    &status) ==
                VTK_FLUTTER_STATUS_OK,
            "ABI v2 could not attach the throwing target");
    Require(core_api->session_render(c_session, &request, &metrics, &status) ==
                    VTK_FLUTTER_STATUS_INTERNAL_ERROR &&
                recorder.begin_count == 1 && recorder.end_count == 0 &&
                recorder.cancel_count == 1 && metrics.frame_bytes == 0,
            "ABI v2 did not cancel and contain a render exception");
    Require(core_api->session_detach_texture_target(c_session, &throwing_target,
                                                    &status) ==
                VTK_FLUTTER_STATUS_OK,
            "ABI v2 could not detach the throwing target");

    vtk_flutter_session_destroy(c_session);

    auto target = std::make_unique<RecordingRenderTarget>();
    auto *target_observer = target.get();
    vtk_flutter::Session session(std::move(target));
    session.SetVolume(volume);
    session.Render(request, metrics);
    Require(target_observer->render_count == 1 &&
                target_observer->captured_view.renderer != nullptr,
            "session did not hand the prepared scene to its target adapter");
    Require(target_observer->captured_viewport.width == 640 &&
                target_observer->captured_viewport.height == 320,
            "session did not preserve the requested viewport");
    Require(metrics.volume_bytes == voxels.size() * sizeof(std::int16_t) &&
                metrics.frame_bytes == 640ULL * 320ULL * 4ULL &&
                metrics.frame_width == 640 && metrics.frame_height == 320 &&
                metrics.patient_to_clip_valid == 1,
            "session did not populate shared render metrics");

    std::cout << "vtk_flutter native core contract: ok\n";
    return EXIT_SUCCESS;
  } catch (const std::exception &exception) {
    std::cerr << "vtk_flutter native core contract: " << exception.what()
              << '\n';
    return EXIT_FAILURE;
  }
}
