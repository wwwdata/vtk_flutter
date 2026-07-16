#include "c_contract_support.h"

#include <stddef.h>

_Static_assert(VTK_FLUTTER_ABI_VERSION == 1U, "unexpected ABI version");
_Static_assert(VTK_FLUTTER_CORE_API_VERSION_2 == 2U,
               "unexpected core API version");
_Static_assert(VTK_FLUTTER_FRAME_CALLBACKS_VERSION_2 == 2U,
               "unexpected frame callback version");
_Static_assert(VTK_FLUTTER_RENDER_OBLIQUE_MPR == 1,
               "unexpected oblique mode value");
_Static_assert(VTK_FLUTTER_RENDER_VOLUME_3D == 2,
               "unexpected volume mode value");
_Static_assert(VTK_FLUTTER_RENDER_VOLUME_LOCATOR == 3,
               "unexpected locator mode value");
_Static_assert(offsetof(VtkFlutterCoreApiV2, version) == sizeof(uint32_t),
               "core API prefix is not stable");
_Static_assert(offsetof(VtkFlutterFrameCallbacksV2, version) ==
                   sizeof(uint32_t),
               "callback table prefix is not stable");

static void set_callback_failure(VtkFlutterStatus *status, int32_t code,
                                 const char *message) {
  uint32_t index = 0;
  if (status == NULL) {
    return;
  }
  status->code = code;
  while (message[index] != '\0' &&
         index + 1U < VTK_FLUTTER_STATUS_MESSAGE_CAPACITY) {
    status->message[index] = message[index];
    ++index;
  }
  status->message[index] = '\0';
}

static int32_t VTK_FLUTTER_CALL begin_frame(
    void *user_data, const VtkFlutterViewport *viewport,
    VtkFlutterStatus *status) {
  VtkFlutterTestFrameRecorder *recorder =
      (VtkFlutterTestFrameRecorder *)user_data;
  ++recorder->begin_count;
  recorder->width = viewport->width;
  recorder->height = viewport->height;
  if (recorder->begin_result != VTK_FLUTTER_STATUS_OK) {
    set_callback_failure(status, recorder->begin_result,
                         "C begin_frame failure");
  }
  return recorder->begin_result;
}

static int32_t VTK_FLUTTER_CALL end_frame(
    void *user_data, const VtkFlutterMetrics *metrics,
    VtkFlutterStatus *status) {
  VtkFlutterTestFrameRecorder *recorder =
      (VtkFlutterTestFrameRecorder *)user_data;
  ++recorder->end_count;
  recorder->frame_bytes = metrics->frame_bytes;
  if (recorder->end_result != VTK_FLUTTER_STATUS_OK) {
    set_callback_failure(status, recorder->end_result, "C end_frame failure");
  }
  return recorder->end_result;
}

static void VTK_FLUTTER_CALL cancel_frame(void *user_data) {
  VtkFlutterTestFrameRecorder *recorder =
      (VtkFlutterTestFrameRecorder *)user_data;
  ++recorder->cancel_count;
}

VtkFlutterFrameCallbacksV2 vtk_flutter_test_frame_callbacks_v2(
    VtkFlutterTestFrameRecorder *recorder) {
  VtkFlutterFrameCallbacksV2 callbacks = {0};
  callbacks.struct_size = sizeof(callbacks);
  callbacks.version = VTK_FLUTTER_FRAME_CALLBACKS_VERSION_2;
  callbacks.user_data = recorder;
  callbacks.begin_frame = begin_frame;
  callbacks.end_frame = end_frame;
  callbacks.cancel_frame = cancel_frame;
  return callbacks;
}

int vtk_flutter_public_header_is_c_compatible(void) {
  VtkFlutterStatus status = {0};
  const VtkFlutterCoreApiV2 *api = vtk_flutter_get_core_api_v2();
  vtk_flutter_status_clear(&status);
  if (api == NULL || api->version != VTK_FLUTTER_CORE_API_VERSION_2 ||
      api->struct_size < sizeof(VtkFlutterCoreApiV2) ||
      api->session_attach_texture_target == NULL ||
      api->session_detach_texture_target == NULL) {
    return 1;
  }
  return status.code;
}
