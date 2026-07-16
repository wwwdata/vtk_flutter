#ifndef VTK_FLUTTER_C_CONTRACT_SUPPORT_H_
#define VTK_FLUTTER_C_CONTRACT_SUPPORT_H_

#include "vtk_flutter.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VtkFlutterTestFrameRecorder {
  uint32_t begin_count;
  uint32_t end_count;
  uint32_t cancel_count;
  int32_t begin_result;
  int32_t end_result;
  int32_t width;
  int32_t height;
  uint8_t *pixels;
  uint64_t capacity_bytes;
  uint64_t row_bytes;
  int32_t pixel_format;
  uint64_t frame_bytes;
  uint64_t surface_allocation_bytes;
} VtkFlutterTestFrameRecorder;

VtkFlutterFrameCallbacksV2 vtk_flutter_test_frame_callbacks_v2(
    VtkFlutterTestFrameRecorder *recorder);

int32_t vtk_flutter_test_create_target_from_c(
    const VtkFlutterCoreApiV2 *api, VtkFlutterTestFrameRecorder *recorder,
    VtkFlutterTextureTarget **out_target, VtkFlutterStatus *status);

int32_t vtk_flutter_test_destroy_target_from_c(
    const VtkFlutterCoreApiV2 *api, VtkFlutterTextureTarget *target,
    VtkFlutterStatus *status);

int vtk_flutter_public_header_is_c_compatible(void);

#ifdef __cplusplus
}
#endif

#endif // VTK_FLUTTER_C_CONTRACT_SUPPORT_H_
