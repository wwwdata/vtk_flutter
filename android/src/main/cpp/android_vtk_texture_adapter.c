#include <jni.h>

#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <vtk_flutter.h>

#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define METRIC_COUNT 26
#define PATIENT_TO_CLIP_OFFSET 10

typedef struct AndroidFrameTarget {
  ANativeWindow *window;
  uint8_t *pixels;
  uint64_t capacity_bytes;
  uint64_t row_bytes;
  int32_t width;
  int32_t height;
  bool frame_in_progress;
} AndroidFrameTarget;

typedef struct AndroidAdapterSession {
  const VtkFlutterCoreApiV2 *api;
  VtkFlutterSession *session;
  VtkFlutterTextureTarget *target;
  AndroidFrameTarget frame_target;
} AndroidAdapterSession;

static void SetStatus(VtkFlutterStatus *status, int32_t code,
                      const char *message) {
  if (status == NULL) {
    return;
  }
  status->code = code;
  status->message[0] = '\0';
  if (message != NULL) {
    strncpy(status->message, message, VTK_FLUTTER_STATUS_MESSAGE_CAPACITY - 1U);
    status->message[VTK_FLUTTER_STATUS_MESSAGE_CAPACITY - 1U] = '\0';
  }
}

static void ThrowJava(JNIEnv *environment, const char *message) {
  jclass exception_class =
      (*environment)->FindClass(environment, "java/lang/RuntimeException");
  if (exception_class != NULL) {
    (*environment)
        ->ThrowNew(environment, exception_class,
                   message == NULL ? "Android VTK adapter failed" : message);
  }
}

static void ThrowStatus(JNIEnv *environment, const char *operation,
                        int32_t code, const VtkFlutterStatus *status) {
  char message[VTK_FLUTTER_STATUS_MESSAGE_CAPACITY + 64U];
  const char *detail = status != NULL && status->message[0] != '\0'
                           ? status->message
                           : "native core operation failed";
  (void)snprintf(message, sizeof(message), "%s failed (%d): %.255s", operation,
                 code, detail);
  ThrowJava(environment, message);
}

static bool ValidateCoreApi(const VtkFlutterCoreApiV2 *api,
                            const char **message) {
  if (api == NULL) {
    *message = "A positive VTK core API address is required";
    return false;
  }
  if (api->version != VTK_FLUTTER_CORE_API_VERSION_2) {
    *message = "Unsupported VTK core API version";
    return false;
  }
  if (api->struct_size < sizeof(VtkFlutterCoreApiV2)) {
    *message = "VTK core API table is too small";
    return false;
  }
  if (api->status_clear == NULL || api->session_create == NULL ||
      api->session_destroy == NULL || api->validate_volume == NULL ||
      api->session_set_volume == NULL || api->validate_render_request == NULL ||
      api->session_render == NULL ||
      api->session_attach_texture_target == NULL ||
      api->session_detach_texture_target == NULL ||
      api->texture_target_create == NULL ||
      api->texture_target_destroy == NULL) {
    *message = "VTK core API table has missing functions";
    return false;
  }
  return true;
}

static bool SetWindowGeometry(AndroidFrameTarget *target, int32_t width,
                              int32_t height, VtkFlutterStatus *status) {
  if (target == NULL || target->window == NULL) {
    SetStatus(status, VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE,
              "Android presentation window is unavailable");
    return false;
  }
  if (width <= 0 || height <= 0) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "Positive Android frame dimensions are required");
    return false;
  }
  if (target->frame_in_progress) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE,
              "Cannot resize an Android frame in progress");
    return false;
  }
  if (ANativeWindow_setBuffersGeometry(target->window, width, height,
                                       WINDOW_FORMAT_RGBA_8888) != 0) {
    SetStatus(status, VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE,
              "Could not size the Android presentation window");
    return false;
  }
  target->width = width;
  target->height = height;
  SetStatus(status, VTK_FLUTTER_STATUS_OK, NULL);
  return true;
}

static int32_t BeginFrame(void *user_data, const VtkFlutterViewport *viewport,
                          VtkFlutterCpuFrameV2 *frame,
                          VtkFlutterStatus *status) {
  AndroidFrameTarget *target = (AndroidFrameTarget *)user_data;
  if (target == NULL || viewport == NULL || frame == NULL) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "Android begin_frame arguments are required");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  if (target->frame_in_progress) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE,
              "An Android frame is already in progress");
    return VTK_FLUTTER_STATUS_INVALID_STATE;
  }
  if ((target->width != viewport->width ||
       target->height != viewport->height) &&
      !SetWindowGeometry(target, viewport->width, viewport->height, status)) {
    return status == NULL ? VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE
                          : status->code;
  }

  const uint64_t row_bytes = (uint64_t)viewport->width * 4ULL;
  const uint64_t height = (uint64_t)viewport->height;
  if (height != 0U && row_bytes > UINT64_MAX / height) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "Android frame dimensions overflow");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  const uint64_t capacity_bytes = row_bytes * height;
  if (capacity_bytes > (uint64_t)SIZE_MAX) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
              "Android frame does not fit addressable memory");
    return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
  }
  if (capacity_bytes > target->capacity_bytes) {
    uint8_t *replacement = (uint8_t *)realloc(
        target->pixels, (size_t)capacity_bytes);
    if (replacement == NULL) {
      SetStatus(status, VTK_FLUTTER_STATUS_INTERNAL_ERROR,
                "Could not allocate Android frame staging memory");
      return VTK_FLUTTER_STATUS_INTERNAL_ERROR;
    }
    target->pixels = replacement;
    target->capacity_bytes = capacity_bytes;
  }
  target->row_bytes = row_bytes;
  target->frame_in_progress = true;

  frame->struct_size = sizeof(VtkFlutterCpuFrameV2);
  frame->version = VTK_FLUTTER_CPU_FRAME_VERSION_2;
  frame->pixels = target->pixels;
  frame->capacity_bytes = target->capacity_bytes;
  frame->row_bytes = row_bytes;
  frame->pixel_format = VTK_FLUTTER_PIXEL_FORMAT_RGBA8888;
  SetStatus(status, VTK_FLUTTER_STATUS_OK, NULL);
  return VTK_FLUTTER_STATUS_OK;
}

static int32_t EndFrame(void *user_data, const VtkFlutterMetrics *metrics,
                        VtkFlutterStatus *status) {
  (void)metrics;
  AndroidFrameTarget *target = (AndroidFrameTarget *)user_data;
  if (target == NULL || target->window == NULL ||
      !target->frame_in_progress || target->pixels == NULL) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE,
              "No Android frame is ready for publication");
    return VTK_FLUTTER_STATUS_INVALID_STATE;
  }

  ANativeWindow_Buffer buffer = {0};
  if (ANativeWindow_lock(target->window, &buffer, NULL) != 0) {
    target->frame_in_progress = false;
    SetStatus(status, VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE,
              "Could not lock the Android presentation window");
    return VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE;
  }
  const uint64_t destination_row_bytes = (uint64_t)buffer.stride * 4ULL;
  const bool valid = buffer.bits != NULL &&
                     buffer.format == WINDOW_FORMAT_RGBA_8888 &&
                     buffer.stride >= target->width &&
                     buffer.height >= target->height;
  if (valid) {
    for (int32_t row = 0; row < target->height; ++row) {
      memcpy((uint8_t *)buffer.bits + (size_t)row * destination_row_bytes,
             target->pixels + (size_t)row * target->row_bytes,
             (size_t)target->row_bytes);
    }
  }
  const int result = ANativeWindow_unlockAndPost(target->window);
  target->frame_in_progress = false;
  if (!valid || result != 0) {
    SetStatus(status, VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE,
              valid ? "Could not publish the Android frame"
                    : "Android returned an invalid presentation buffer");
    return VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE;
  }
  SetStatus(status, VTK_FLUTTER_STATUS_OK, NULL);
  return VTK_FLUTTER_STATUS_OK;
}

static void CancelFrame(void *user_data) {
  AndroidFrameTarget *target = (AndroidFrameTarget *)user_data;
  if (target != NULL) {
    target->frame_in_progress = false;
  }
}

static AndroidAdapterSession *AdapterFromHandle(jlong handle) {
  if (handle <= 0) {
    return NULL;
  }
  return (AndroidAdapterSession *)(uintptr_t)handle;
}

static bool ReplaceWindow(JNIEnv *environment, AndroidFrameTarget *target,
                          jobject surface, int32_t width, int32_t height,
                          VtkFlutterStatus *status) {
  if (target->frame_in_progress) {
    SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE,
              "Cannot recreate an Android frame in progress");
    return false;
  }
  ANativeWindow *replacement = ANativeWindow_fromSurface(environment, surface);
  if (replacement == NULL) {
    SetStatus(status, VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE,
              "Flutter SurfaceTexture did not provide an Android window");
    return false;
  }
  AndroidFrameTarget candidate = {.window = replacement};
  if (!SetWindowGeometry(&candidate, width, height, status)) {
    ANativeWindow_release(replacement);
    return false;
  }
  ANativeWindow *previous = target->window;
  target->window = candidate.window;
  target->width = candidate.width;
  target->height = candidate.height;
  if (previous != NULL) {
    ANativeWindow_release(previous);
  }
  return true;
}

static void ReleaseAdapter(AndroidAdapterSession *adapter) {
  if (adapter == NULL) {
    return;
  }
  CancelFrame(&adapter->frame_target);
  if (adapter->session != NULL && adapter->target != NULL) {
    VtkFlutterStatus status = {0};
    if (adapter->api->session_detach_texture_target(
            adapter->session, adapter->target, &status) !=
        VTK_FLUTTER_STATUS_OK) {
      adapter->api->session_destroy(adapter->session);
      adapter->session = NULL;
    }
  }
  if (adapter->target != NULL) {
    VtkFlutterStatus status = {0};
    (void)adapter->api->texture_target_destroy(adapter->target, &status);
    adapter->target = NULL;
  }
  if (adapter->session != NULL) {
    adapter->api->session_destroy(adapter->session);
    adapter->session = NULL;
  }
  if (adapter->frame_target.window != NULL) {
    ANativeWindow_release(adapter->frame_target.window);
    adapter->frame_target.window = NULL;
  }
  free(adapter->frame_target.pixels);
  adapter->frame_target.pixels = NULL;
  free(adapter);
}

JNIEXPORT jlongArray JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeCreate(
    JNIEnv *environment, jobject instance, jlong core_api_address,
    jobject surface, jint width, jint height) {
  (void)instance;
  if (core_api_address <= 0 || surface == NULL || width <= 0 || height <= 0) {
    ThrowJava(
        environment,
        "Positive core API address, surface, width, and height are required");
    return NULL;
  }
  if ((uint64_t)core_api_address > (uint64_t)UINTPTR_MAX) {
    ThrowJava(environment, "The VTK core API address does not fit this ABI");
    return NULL;
  }

  const VtkFlutterCoreApiV2 *api =
      (const VtkFlutterCoreApiV2 *)(uintptr_t)core_api_address;
  const char *validation_message = NULL;
  if (!ValidateCoreApi(api, &validation_message)) {
    ThrowJava(environment, validation_message);
    return NULL;
  }

  AndroidAdapterSession *adapter =
      (AndroidAdapterSession *)calloc(1U, sizeof(AndroidAdapterSession));
  if (adapter == NULL) {
    ThrowJava(environment, "Could not allocate the Android adapter session");
    return NULL;
  }
  adapter->api = api;
  VtkFlutterStatus status = {0};
  if (!ReplaceWindow(environment, &adapter->frame_target, surface, width,
                     height, &status)) {
    ThrowStatus(environment, "create Android window", status.code, &status);
    ReleaseAdapter(adapter);
    return NULL;
  }

  int32_t code = api->session_create(&adapter->session, &status);
  if (code != VTK_FLUTTER_STATUS_OK || adapter->session == NULL) {
    ThrowStatus(environment, "create session", code, &status);
    ReleaseAdapter(adapter);
    return NULL;
  }

  const VtkFlutterFrameCallbacksV2 callbacks = {
      .struct_size = sizeof(VtkFlutterFrameCallbacksV2),
      .version = VTK_FLUTTER_FRAME_CALLBACKS_VERSION_2,
      .user_data = &adapter->frame_target,
      .begin_frame = BeginFrame,
      .end_frame = EndFrame,
      .cancel_frame = CancelFrame,
  };
  code = api->texture_target_create(&callbacks, &adapter->target, &status);
  if (code != VTK_FLUTTER_STATUS_OK || adapter->target == NULL) {
    ThrowStatus(environment, "create texture target", code, &status);
    ReleaseAdapter(adapter);
    return NULL;
  }
  code = api->session_attach_texture_target(adapter->session, adapter->target,
                                            &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    ThrowStatus(environment, "attach texture target", code, &status);
    ReleaseAdapter(adapter);
    return NULL;
  }

  jlongArray result = (*environment)->NewLongArray(environment, 2);
  if (result == NULL) {
    ReleaseAdapter(adapter);
    return NULL;
  }
  const jlong handles[2] = {
      (jlong)(uintptr_t)adapter,
      (jlong)(uintptr_t)adapter->session,
  };
  (*environment)->SetLongArrayRegion(environment, result, 0, 2, handles);
  if ((*environment)->ExceptionCheck(environment)) {
    ReleaseAdapter(adapter);
    return NULL;
  }
  return result;
}

JNIEXPORT void JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeSetVolume(
    JNIEnv *environment, jobject instance, jlong handle, jbyteArray voxel_array,
    jint width, jint height, jint depth, jdoubleArray matrix_array) {
  (void)instance;
  AndroidAdapterSession *adapter = AdapterFromHandle(handle);
  if (adapter == NULL || voxel_array == NULL || matrix_array == NULL) {
    ThrowJava(environment,
              "Android VTK session, voxels, and affine are required");
    return;
  }
  const jsize voxel_byte_count =
      (*environment)->GetArrayLength(environment, voxel_array);
  if (voxel_byte_count <= 0 || voxel_byte_count % (jsize)sizeof(int16_t) != 0 ||
      (*environment)->GetArrayLength(environment, matrix_array) != 16) {
    ThrowJava(environment, "Invalid voxel bytes or affine matrix");
    return;
  }

  int16_t *voxels = (int16_t *)malloc((size_t)voxel_byte_count);
  if (voxels == NULL) {
    ThrowJava(environment, "Could not allocate Android voxel staging memory");
    return;
  }
  (*environment)
      ->GetByteArrayRegion(environment, voxel_array, 0, voxel_byte_count,
                           (jbyte *)voxels);
  if ((*environment)->ExceptionCheck(environment)) {
    free(voxels);
    return;
  }

  VtkFlutterVolume volume = {
      .voxels = voxels,
      .voxel_count = (uint64_t)voxel_byte_count / sizeof(int16_t),
      .width = width,
      .height = height,
      .depth = depth,
  };
  (*environment)
      ->GetDoubleArrayRegion(environment, matrix_array, 0, 16,
                             volume.index_to_patient);
  if ((*environment)->ExceptionCheck(environment)) {
    free(voxels);
    return;
  }
  VtkFlutterStatus status = {0};
  const int32_t code =
      adapter->api->session_set_volume(adapter->session, &volume, &status);
  free(voxels);
  if (code != VTK_FLUTTER_STATUS_OK) {
    ThrowStatus(environment, "set volume", code, &status);
  }
}

JNIEXPORT jdoubleArray JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeRender(
    JNIEnv *environment, jobject instance, jlong handle, jint mode, jint width,
    jint height, jdouble window_center, jdouble window_width,
    jdoubleArray origin_array, jdoubleArray normal_array, jdouble azimuth,
    jdouble elevation, jdouble zoom) {
  (void)instance;
  AndroidAdapterSession *adapter = AdapterFromHandle(handle);
  if (adapter == NULL || origin_array == NULL || normal_array == NULL ||
      (*environment)->GetArrayLength(environment, origin_array) != 3 ||
      (*environment)->GetArrayLength(environment, normal_array) != 3) {
    ThrowJava(
        environment,
        "Android VTK session and three-value render vectors are required");
    return NULL;
  }

  VtkFlutterRenderRequest request = {
      .mode = mode,
      .viewport = {.width = width, .height = height},
      .window_center = window_center,
      .window_width = window_width,
      .camera_azimuth_degrees = azimuth,
      .camera_elevation_degrees = elevation,
      .camera_zoom = zoom,
  };
  (*environment)
      ->GetDoubleArrayRegion(environment, origin_array, 0, 3,
                             request.plane_origin);
  (*environment)
      ->GetDoubleArrayRegion(environment, normal_array, 0, 3,
                             request.plane_normal);
  if ((*environment)->ExceptionCheck(environment)) {
    return NULL;
  }

  VtkFlutterMetrics metrics = {0};
  VtkFlutterStatus status = {0};
  const int32_t code = adapter->api->session_render(adapter->session, &request,
                                                    &metrics, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    ThrowStatus(environment, "render", code, &status);
    return NULL;
  }

  const jdouble values[METRIC_COUNT] = {
      (jdouble)metrics.volume_bytes,
      (jdouble)metrics.frame_bytes,
      (jdouble)metrics.surface_allocation_bytes,
      metrics.render_ms,
      metrics.surface_submit_ms,
      metrics.gpu_sync_wait_ms,
      metrics.cpu_readback_ms,
      (jdouble)metrics.frame_width,
      (jdouble)metrics.frame_height,
      (jdouble)metrics.patient_to_clip_valid,
      metrics.patient_to_clip[0],
      metrics.patient_to_clip[1],
      metrics.patient_to_clip[2],
      metrics.patient_to_clip[3],
      metrics.patient_to_clip[4],
      metrics.patient_to_clip[5],
      metrics.patient_to_clip[6],
      metrics.patient_to_clip[7],
      metrics.patient_to_clip[8],
      metrics.patient_to_clip[9],
      metrics.patient_to_clip[10],
      metrics.patient_to_clip[11],
      metrics.patient_to_clip[12],
      metrics.patient_to_clip[13],
      metrics.patient_to_clip[14],
      metrics.patient_to_clip[15],
  };
  jdoubleArray result =
      (*environment)->NewDoubleArray(environment, METRIC_COUNT);
  if (result == NULL) {
    return NULL;
  }
  (*environment)
      ->SetDoubleArrayRegion(environment, result, 0, METRIC_COUNT, values);
  return result;
}

JNIEXPORT void JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeResize(
    JNIEnv *environment, jobject instance, jlong handle, jint width,
    jint height) {
  (void)instance;
  AndroidAdapterSession *adapter = AdapterFromHandle(handle);
  VtkFlutterStatus status = {0};
  if (adapter == NULL) {
    ThrowJava(environment, "Android VTK session is not initialized");
  } else if (!SetWindowGeometry(&adapter->frame_target, width, height,
                                &status)) {
    ThrowStatus(environment, "resize", status.code, &status);
  }
}

JNIEXPORT void JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeRecreateGraphicsContext(
    JNIEnv *environment, jobject instance, jlong handle, jobject surface,
    jint width, jint height) {
  (void)instance;
  AndroidAdapterSession *adapter = AdapterFromHandle(handle);
  VtkFlutterStatus status = {0};
  if (adapter == NULL || surface == NULL) {
    ThrowJava(environment, "Android VTK session and surface are required");
  } else if (!ReplaceWindow(environment, &adapter->frame_target, surface, width,
                            height, &status)) {
    ThrowStatus(environment, "recreate presentation window", status.code,
                &status);
  }
}

JNIEXPORT void JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeDestroy(
    JNIEnv *environment, jobject instance, jlong handle) {
  (void)instance;
  AndroidAdapterSession *adapter = AdapterFromHandle(handle);
  if (adapter == NULL) {
    ThrowJava(environment, "Android VTK session is not initialized");
    return;
  }
  ReleaseAdapter(adapter);
}
