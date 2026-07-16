#include <vtk_flutter.h>

#include "vtk_flutter_native_exports.h"
#include "windows_vtk_render_target.h"

#include <mutex>

namespace vtk_flutter::windows {

std::mutex &NativeSessionMutex() {
  static std::mutex mutex;
  return mutex;
}

} // namespace vtk_flutter::windows

extern "C" {

uint32_t VTK_FLUTTER_CALL vtk_flutter_core_abi_version(void);
void VTK_FLUTTER_CALL vtk_flutter_core_status_clear(VtkFlutterStatus *status);
int32_t VTK_FLUTTER_CALL vtk_flutter_core_session_create(
    VtkFlutterSession **out_session, VtkFlutterStatus *status);
void VTK_FLUTTER_CALL
vtk_flutter_core_session_destroy(VtkFlutterSession *session);
int32_t VTK_FLUTTER_CALL vtk_flutter_core_validate_volume(
    const VtkFlutterVolume *volume, VtkFlutterStatus *status);
int32_t VTK_FLUTTER_CALL vtk_flutter_core_session_set_volume(
    VtkFlutterSession *session, const VtkFlutterVolume *volume,
    VtkFlutterStatus *status);
int32_t VTK_FLUTTER_CALL vtk_flutter_core_validate_render_request(
    const VtkFlutterRenderRequest *request, VtkFlutterStatus *status);
int32_t VTK_FLUTTER_CALL vtk_flutter_core_session_render(
    VtkFlutterSession *session, const VtkFlutterRenderRequest *request,
    VtkFlutterMetrics *metrics, VtkFlutterStatus *status);

uint32_t VTK_FLUTTER_CALL vtk_flutter_abi_version(void) {
  return vtk_flutter_core_abi_version();
}

void VTK_FLUTTER_CALL vtk_flutter_status_clear(VtkFlutterStatus *status) {
  vtk_flutter_core_status_clear(status);
}

int32_t VTK_FLUTTER_CALL vtk_flutter_session_create(
    VtkFlutterSession **out_session, VtkFlutterStatus *status) {
  return vtk_flutter_core_session_create(out_session, status);
}

void VTK_FLUTTER_CALL vtk_flutter_session_destroy(VtkFlutterSession *session) {
  std::lock_guard lock(vtk_flutter::windows::NativeSessionMutex());
  vtk_flutter_core_session_destroy(session);
}

int32_t VTK_FLUTTER_CALL vtk_flutter_validate_volume(
    const VtkFlutterVolume *volume, VtkFlutterStatus *status) {
  return vtk_flutter_core_validate_volume(volume, status);
}

int32_t VTK_FLUTTER_CALL vtk_flutter_session_set_volume(
    VtkFlutterSession *session, const VtkFlutterVolume *volume,
    VtkFlutterStatus *status) {
  std::lock_guard lock(vtk_flutter::windows::NativeSessionMutex());
  return vtk_flutter_core_session_set_volume(session, volume, status);
}

int32_t VTK_FLUTTER_CALL vtk_flutter_validate_render_request(
    const VtkFlutterRenderRequest *request, VtkFlutterStatus *status) {
  return vtk_flutter_core_validate_render_request(request, status);
}

int32_t VTK_FLUTTER_CALL vtk_flutter_session_render(
    VtkFlutterSession *session, const VtkFlutterRenderRequest *request,
    VtkFlutterMetrics *metrics, VtkFlutterStatus *status) {
  std::lock_guard lock(vtk_flutter::windows::NativeSessionMutex());
  return vtk_flutter_core_session_render(session, request, metrics, status);
}

} // extern "C"
