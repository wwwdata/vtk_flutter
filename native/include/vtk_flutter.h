#ifndef VTK_FLUTTER_H_
#define VTK_FLUTTER_H_

#include <stdint.h>

// Additive exports retain ABI 4 so existing clients remain compatible. New
// descriptors carry independent versions and existing declarations never move.
#define VTK_FLUTTER_ABI_VERSION 4U
#define VTK_FLUTTER_PRESENTATION_API_VERSION 2U
#define VTK_FLUTTER_FRAME_CALLBACKS_VERSION 1U
#define VTK_FLUTTER_CPU_FRAME_VERSION 1U
#define VTK_FLUTTER_RENDER_LAYER_VERSION 1U
#define VTK_FLUTTER_MAX_RENDER_LAYERS 64U
#define VTK_FLUTTER_STATUS_MESSAGE_CAPACITY 512U

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
typedef uint32_t VtkFlutterObjectHandle;

typedef enum VtkFlutterStatusCode {
  VTK_FLUTTER_STATUS_OK = 0,
  VTK_FLUTTER_STATUS_INVALID_ARGUMENT = 1,
  VTK_FLUTTER_STATUS_INVALID_STATE = 2,
  VTK_FLUTTER_STATUS_NOT_SUPPORTED = 3,
  VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE = 4,
  VTK_FLUTTER_STATUS_INTERNAL_ERROR = 5,
} VtkFlutterStatusCode;

typedef enum VtkFlutterScalarType {
  VTK_FLUTTER_SCALAR_UINT8 = 1,
  VTK_FLUTTER_SCALAR_INT8 = 2,
  VTK_FLUTTER_SCALAR_UINT16 = 3,
  VTK_FLUTTER_SCALAR_INT16 = 4,
  VTK_FLUTTER_SCALAR_UINT32 = 5,
  VTK_FLUTTER_SCALAR_INT32 = 6,
  VTK_FLUTTER_SCALAR_FLOAT32 = 7,
  VTK_FLUTTER_SCALAR_FLOAT64 = 8,
} VtkFlutterScalarType;

typedef enum VtkFlutterPixelFormat {
  VTK_FLUTTER_PIXEL_FORMAT_RGBA8888 = 1,
  VTK_FLUTTER_PIXEL_FORMAT_BGRA8888 = 2,
} VtkFlutterPixelFormat;

typedef struct VtkFlutterStatus {
  int32_t code;
  char message[VTK_FLUTTER_STATUS_MESSAGE_CAPACITY];
} VtkFlutterStatus;

typedef struct VtkFlutterViewport {
  int32_t width;
  int32_t height;
} VtkFlutterViewport;

typedef struct VtkFlutterRenderLayer {
  uint32_t struct_size;
  uint32_t version;
  VtkFlutterObjectHandle renderer;
  double left;
  double bottom;
  double right;
  double top;
} VtkFlutterRenderLayer;

// The core deep-copies values before this call returns. Values are x-fastest.
// direction is a row-major 3x3 world transform for the image axes.
typedef struct VtkFlutterImageData {
  const void *values;
  uint64_t value_count;
  uint64_t byte_count;
  int32_t scalar_type;
  int32_t component_count;
  int32_t dimensions[3];
  double origin[3];
  double spacing[3];
  double direction[9];
} VtkFlutterImageData;

typedef struct VtkFlutterFrameMetrics {
  uint64_t frame_bytes;
  uint64_t surface_allocation_bytes;
  double render_ms;
  double surface_submit_ms;
  double gpu_sync_wait_ms;
  double cpu_readback_ms;
  int32_t frame_width;
  int32_t frame_height;
  int32_t world_to_clip_valid;
  double world_to_clip[16];
} VtkFlutterFrameMetrics;

// Writable CPU storage supplied by begin_frame. The core writes exactly
// width * 4 bytes to every top-down row and retains no pointer after the
// matching end_frame or cancel_frame call.
typedef struct VtkFlutterCpuFrame {
  uint32_t struct_size;
  uint32_t version;
  uint8_t *pixels;
  uint64_t capacity_bytes;
  uint64_t row_bytes;
  int32_t pixel_format;
} VtkFlutterCpuFrame;

typedef int32_t(VTK_FLUTTER_CALL *VtkFlutterBeginFrameCallback)(
    void *user_data, const VtkFlutterViewport *viewport,
    VtkFlutterCpuFrame *frame, VtkFlutterStatus *status);

typedef int32_t(VTK_FLUTTER_CALL *VtkFlutterEndFrameCallback)(
    void *user_data, const VtkFlutterFrameMetrics *metrics,
    VtkFlutterStatus *status);

typedef void(VTK_FLUTTER_CALL *VtkFlutterCancelFrameCallback)(void *user_data);

typedef struct VtkFlutterFrameCallbacks {
  uint32_t struct_size;
  uint32_t version;
  void *user_data;
  VtkFlutterBeginFrameCallback begin_frame;
  VtkFlutterEndFrameCallback end_frame;
  VtkFlutterCancelFrameCallback cancel_frame;
} VtkFlutterFrameCallbacks;

// Platform plugins use only this table. Pipeline construction and rendering
// are direct Dart FFI calls to the exports below.
typedef struct VtkFlutterPresentationApi {
  uint32_t struct_size;
  uint32_t version;
  void(VTK_FLUTTER_CALL *status_clear)(VtkFlutterStatus *status);
  int32_t(VTK_FLUTTER_CALL *session_is_valid)(
      VtkFlutterSession *session, VtkFlutterStatus *status);
  int32_t(VTK_FLUTTER_CALL *session_attach_texture_target)(
      VtkFlutterSession *session, VtkFlutterTextureTarget *target,
      VtkFlutterStatus *status);
  int32_t(VTK_FLUTTER_CALL *session_detach_texture_target)(
      VtkFlutterSession *session, VtkFlutterTextureTarget *target,
      VtkFlutterStatus *status);
  int32_t(VTK_FLUTTER_CALL *texture_target_create)(
      const VtkFlutterFrameCallbacks *callbacks,
      VtkFlutterTextureTarget **out_target, VtkFlutterStatus *status);
  int32_t(VTK_FLUTTER_CALL *texture_target_destroy)(
      VtkFlutterTextureTarget *target, VtkFlutterStatus *status);
} VtkFlutterPresentationApi;

VTK_FLUTTER_EXPORT uint32_t VTK_FLUTTER_CALL vtk_flutter_abi_version(void);

VTK_FLUTTER_EXPORT const VtkFlutterPresentationApi *VTK_FLUTTER_CALL
vtk_flutter_get_presentation_api(void);

VTK_FLUTTER_EXPORT void VTK_FLUTTER_CALL
vtk_flutter_status_clear(VtkFlutterStatus *status);

VTK_FLUTTER_EXPORT int32_t VTK_FLUTTER_CALL vtk_flutter_session_create(
    VtkFlutterSession **out_session, VtkFlutterStatus *status);

VTK_FLUTTER_EXPORT void VTK_FLUTTER_CALL
vtk_flutter_session_destroy(VtkFlutterSession *session);

VTK_FLUTTER_EXPORT int32_t VTK_FLUTTER_CALL vtk_flutter_object_create(
    VtkFlutterSession *session, const char *class_name,
    VtkFlutterObjectHandle *out_object, VtkFlutterStatus *status);

VTK_FLUTTER_EXPORT int32_t VTK_FLUTTER_CALL vtk_flutter_object_destroy(
    VtkFlutterSession *session, VtkFlutterObjectHandle object,
    VtkFlutterStatus *status);

// result_json is allocated by the core. Always release it with
// vtk_flutter_string_free. Arguments must be a JSON array.
VTK_FLUTTER_EXPORT int32_t VTK_FLUTTER_CALL vtk_flutter_object_invoke(
    VtkFlutterSession *session, VtkFlutterObjectHandle object,
    const char *method_name, const char *arguments_json,
    char **result_json, VtkFlutterStatus *status);

VTK_FLUTTER_EXPORT void VTK_FLUTTER_CALL
vtk_flutter_string_free(char *value);

VTK_FLUTTER_EXPORT int32_t VTK_FLUTTER_CALL vtk_flutter_image_data_create(
    VtkFlutterSession *session, const VtkFlutterImageData *image,
    VtkFlutterObjectHandle *out_object, VtkFlutterStatus *status);

VTK_FLUTTER_EXPORT int32_t VTK_FLUTTER_CALL vtk_flutter_session_render(
    VtkFlutterSession *session, VtkFlutterObjectHandle renderer,
    const VtkFlutterViewport *viewport, VtkFlutterFrameMetrics *metrics,
    VtkFlutterStatus *status);

VTK_FLUTTER_EXPORT int32_t VTK_FLUTTER_CALL vtk_flutter_session_render_layout(
    VtkFlutterSession *session, const VtkFlutterRenderLayer *layers,
    uint32_t layer_count, const VtkFlutterViewport *viewport,
    uint32_t primary_layer, VtkFlutterFrameMetrics *metrics,
    VtkFlutterStatus *status);

#ifdef __cplusplus
}
#endif

#endif // VTK_FLUTTER_H_
