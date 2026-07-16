#ifndef VTK_FLUTTER_H_
#define VTK_FLUTTER_H_

#include <stdint.h>

#define VTK_FLUTTER_ABI_VERSION 1U
#define VTK_FLUTTER_STATUS_MESSAGE_CAPACITY 256U

#if defined(VTK_FLUTTER_STATIC)
#define VTK_FLUTTER_EXPORT
#define VTK_FLUTTER_CALL
#elif defined(_WIN32)
#if defined(VTK_FLUTTER_BUILDING_LIBRARY)
#define VTK_FLUTTER_EXPORT __declspec(dllexport)
#else
#define VTK_FLUTTER_EXPORT __declspec(dllimport)
#endif
#define VTK_FLUTTER_CALL __cdecl
#elif defined(__GNUC__) || defined(__clang__)
#define VTK_FLUTTER_EXPORT __attribute__((visibility("default")))
#define VTK_FLUTTER_CALL
#else
#define VTK_FLUTTER_EXPORT
#define VTK_FLUTTER_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VtkFlutterSession VtkFlutterSession;

typedef enum VtkFlutterStatusCode {
  VTK_FLUTTER_STATUS_OK = 0,
  VTK_FLUTTER_STATUS_INVALID_ARGUMENT = 1,
  VTK_FLUTTER_STATUS_INVALID_STATE = 2,
  VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE = 3,
  VTK_FLUTTER_STATUS_INTERNAL_ERROR = 4,
} VtkFlutterStatusCode;

typedef enum VtkFlutterRenderMode {
  VTK_FLUTTER_RENDER_OBLIQUE_MPR = 1,
  VTK_FLUTTER_RENDER_VOLUME_3D = 2,
  VTK_FLUTTER_RENDER_VOLUME_LOCATOR = 3,
} VtkFlutterRenderMode;

typedef struct VtkFlutterStatus {
  int32_t code;
  char message[VTK_FLUTTER_STATUS_MESSAGE_CAPACITY];
} VtkFlutterStatus;

typedef struct VtkFlutterViewport {
  int32_t width;
  int32_t height;
} VtkFlutterViewport;

// voxels are signed 16-bit, x-fastest, and deep-copied by set_volume.
// index_to_patient is a row-major 4x4 affine from voxel indices to patient
// millimeters.
typedef struct VtkFlutterVolume {
  const int16_t *voxels;
  uint64_t voxel_count;
  int32_t width;
  int32_t height;
  int32_t depth;
  double index_to_patient[16];
} VtkFlutterVolume;

typedef struct VtkFlutterRenderRequest {
  int32_t mode;
  VtkFlutterViewport viewport;
  double window_center;
  double window_width;
  double plane_origin[3];
  double plane_normal[3];
  double camera_azimuth_degrees;
  double camera_elevation_degrees;
  double camera_zoom;
} VtkFlutterRenderRequest;

typedef struct VtkFlutterMetrics {
  uint64_t volume_bytes;
  uint64_t frame_bytes;
  uint64_t surface_allocation_bytes;
  uint64_t surface_checksum;
  uint64_t surface_changed_pixels;
  uint64_t surface_unique_byte_values;
  uint64_t cpu_checksum;
  uint64_t cpu_changed_pixels;
  uint64_t cpu_unique_byte_values;
  double render_ms;
  double surface_submit_ms;
  double gpu_sync_wait_ms;
  double cpu_readback_ms;
  int32_t frame_width;
  int32_t frame_height;
  int32_t patient_to_clip_valid;
  double patient_to_clip[16];
} VtkFlutterMetrics;

VTK_FLUTTER_EXPORT uint32_t VTK_FLUTTER_CALL vtk_flutter_abi_version(void);

VTK_FLUTTER_EXPORT void VTK_FLUTTER_CALL
vtk_flutter_status_clear(VtkFlutterStatus *status);

// Core-created sessions support volume upload and request validation. Rendering
// additionally requires a platform adapter to attach an appropriate VTK render
// window and presentation target.
VTK_FLUTTER_EXPORT int32_t VTK_FLUTTER_CALL vtk_flutter_session_create(
    VtkFlutterSession **out_session, VtkFlutterStatus *status);

VTK_FLUTTER_EXPORT void VTK_FLUTTER_CALL
vtk_flutter_session_destroy(VtkFlutterSession *session);

VTK_FLUTTER_EXPORT int32_t VTK_FLUTTER_CALL vtk_flutter_validate_volume(
    const VtkFlutterVolume *volume, VtkFlutterStatus *status);

VTK_FLUTTER_EXPORT int32_t VTK_FLUTTER_CALL vtk_flutter_session_set_volume(
    VtkFlutterSession *session, const VtkFlutterVolume *volume,
    VtkFlutterStatus *status);

VTK_FLUTTER_EXPORT int32_t VTK_FLUTTER_CALL vtk_flutter_validate_render_request(
    const VtkFlutterRenderRequest *request, VtkFlutterStatus *status);

// The platform adapter owns presentation. This call only orchestrates scene
// configuration and target rendering; no platform image, Flutter, or graphics
// types cross this interface.
VTK_FLUTTER_EXPORT int32_t VTK_FLUTTER_CALL vtk_flutter_session_render(
    VtkFlutterSession *session, const VtkFlutterRenderRequest *request,
    VtkFlutterMetrics *metrics, VtkFlutterStatus *status);

#ifdef __cplusplus
}
#endif

#endif // VTK_FLUTTER_H_
