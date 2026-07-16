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
  uint64_t frame_bytes;
} VtkFlutterTestFrameRecorder;

VtkFlutterFrameCallbacksV2 vtk_flutter_test_frame_callbacks_v2(
    VtkFlutterTestFrameRecorder *recorder);

int vtk_flutter_public_header_is_c_compatible(void);

#ifdef __cplusplus
}
#endif

#endif // VTK_FLUTTER_C_CONTRACT_SUPPORT_H_
