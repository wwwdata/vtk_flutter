#ifndef VTK_FLUTTER_H_
#define VTK_FLUTTER_H_

#include <stdint.h>

// The legacy direct-export ABI remains version 1 during the v2 migration.
#define VTK_FLUTTER_ABI_VERSION 1U
#define VTK_FLUTTER_CORE_API_VERSION_2 2U
#define VTK_FLUTTER_FRAME_CALLBACKS_VERSION_2 2U
#define VTK_FLUTTER_CPU_FRAME_VERSION_2 2U
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
typedef struct VtkFlutterTextureTarget VtkFlutterTextureTarget;

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

typedef enum VtkFlutterPixelFormatV2 {
  VTK_FLUTTER_PIXEL_FORMAT_RGBA8888 = 1,
  VTK_FLUTTER_PIXEL_FORMAT_BGRA8888 = 2,
} VtkFlutterPixelFormatV2;

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

// Writable CPU storage supplied by begin_frame. The descriptor and pixels stay
// caller-owned. The core writes exactly width * 4 bytes to each top-down row,
// using the viewport passed to begin_frame. capacity_bytes must cover the last
// byte written, including row padding. The core does not retain the descriptor
// or pixels after end_frame/cancel_frame returns.
typedef struct VtkFlutterCpuFrameV2 {
  uint32_t struct_size;
  uint32_t version;
  uint8_t *pixels;
  uint64_t capacity_bytes;
  uint64_t row_bytes;
  int32_t pixel_format;
} VtkFlutterCpuFrameV2;

// A platform supplies these callbacks to texture_target_create. The core
// copies the table; the table itself need not outlive target creation.
// user_data and everything it references must remain valid until the target is
// detached and successfully destroyed.
//
// begin_frame locks/allocates presentation storage and fills frame. end_frame
// publishes the completed frame. If rendering or copying fails after a
// successful begin_frame, cancel_frame releases that storage. An end_frame
// failure is also followed by best-effort cancel_frame. Callbacks may fill
// status with a bounded diagnostic and must not re-enter the same session.
typedef int32_t(VTK_FLUTTER_CALL *VtkFlutterBeginFrameCallbackV2)(
    void *user_data, const VtkFlutterViewport *viewport,
    VtkFlutterCpuFrameV2 *frame, VtkFlutterStatus *status);

typedef int32_t(VTK_FLUTTER_CALL *VtkFlutterEndFrameCallbackV2)(
    void *user_data, const VtkFlutterMetrics *metrics,
    VtkFlutterStatus *status);

typedef void(VTK_FLUTTER_CALL *VtkFlutterCancelFrameCallbackV2)(
    void *user_data);

typedef struct VtkFlutterFrameCallbacksV2 {
  uint32_t struct_size;
  uint32_t version;
  void *user_data;
  VtkFlutterBeginFrameCallbackV2 begin_frame;
  VtkFlutterEndFrameCallbackV2 end_frame;
  VtkFlutterCancelFrameCallbackV2 cancel_frame;
} VtkFlutterFrameCallbacksV2;

// ABI v2 is exposed as one immutable, process-lifetime function table. A
// caller must check version and struct_size before reading function pointers.
// Texture target handles are created and destroyed only by this table. Their
// VTK render window and all C++ state remain inside the core. The caller must
// detach a target before destroying it. A target can be attached to at most one
// session at a time.
//
// All operations on one live session are synchronous and serialized. Calls
// from different threads wait for the active operation. Re-entering that same
// session from a frame callback fails with VTK_FLUTTER_STATUS_INVALID_STATE.
// Session destruction must not race another operation or occur in a callback.
typedef struct VtkFlutterCoreApiV2 {
  uint32_t struct_size;
  uint32_t version;
  void(VTK_FLUTTER_CALL *status_clear)(VtkFlutterStatus *status);
  int32_t(VTK_FLUTTER_CALL *session_create)(
      VtkFlutterSession **out_session, VtkFlutterStatus *status);
  void(VTK_FLUTTER_CALL *session_destroy)(VtkFlutterSession *session);
  int32_t(VTK_FLUTTER_CALL *validate_volume)(
      const VtkFlutterVolume *volume, VtkFlutterStatus *status);
  int32_t(VTK_FLUTTER_CALL *session_set_volume)(
      VtkFlutterSession *session, const VtkFlutterVolume *volume,
      VtkFlutterStatus *status);
  int32_t(VTK_FLUTTER_CALL *validate_render_request)(
      const VtkFlutterRenderRequest *request, VtkFlutterStatus *status);
  int32_t(VTK_FLUTTER_CALL *session_render)(
      VtkFlutterSession *session, const VtkFlutterRenderRequest *request,
      VtkFlutterMetrics *metrics, VtkFlutterStatus *status);
  int32_t(VTK_FLUTTER_CALL *session_attach_texture_target)(
      VtkFlutterSession *session, VtkFlutterTextureTarget *target,
      VtkFlutterStatus *status);
  int32_t(VTK_FLUTTER_CALL *session_detach_texture_target)(
      VtkFlutterSession *session, VtkFlutterTextureTarget *target,
      VtkFlutterStatus *status);
  int32_t(VTK_FLUTTER_CALL *texture_target_create)(
      const VtkFlutterFrameCallbacksV2 *callbacks,
      VtkFlutterTextureTarget **out_target, VtkFlutterStatus *status);
  int32_t(VTK_FLUTTER_CALL *texture_target_destroy)(
      VtkFlutterTextureTarget *target, VtkFlutterStatus *status);
} VtkFlutterCoreApiV2;

VTK_FLUTTER_EXPORT uint32_t VTK_FLUTTER_CALL vtk_flutter_abi_version(void);

VTK_FLUTTER_EXPORT const VtkFlutterCoreApiV2 *VTK_FLUTTER_CALL
vtk_flutter_get_core_api_v2(void);

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
