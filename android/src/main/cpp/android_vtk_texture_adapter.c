#include <jni.h>

#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <vtk_flutter.h>

#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct AndroidFrameTarget {
  ANativeWindow *window;
  uint8_t *pixels;
  uint64_t capacity_bytes;
  uint64_t row_bytes;
  int32_t width;
  int32_t height;
  bool frame_in_progress;
} AndroidFrameTarget;

typedef struct AndroidAdapterView {
  const VtkFlutterPresentationApi *api;
  VtkFlutterSession *session;
  VtkFlutterTextureTarget *target;
  AndroidFrameTarget frame_target;
  bool attached;
} AndroidAdapterView;

#define REQUIRED_PRESENTATION_API_SIZE                                         \
  (offsetof(VtkFlutterPresentationApi, texture_target_destroy) +               \
   sizeof(((VtkFlutterPresentationApi *)0)->texture_target_destroy))

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

static void ClearStatus(const VtkFlutterPresentationApi *api,
                        VtkFlutterStatus *status) {
  if (api != NULL && api->status_clear != NULL) {
    api->status_clear(status);
  } else {
    SetStatus(status, VTK_FLUTTER_STATUS_OK, NULL);
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
                           : "native presentation operation failed";
  (void)snprintf(message, sizeof(message), "%s failed (%d): %.511s", operation,
                 code, detail);
  ThrowJava(environment, message);
}

static bool ValidatePresentationApi(const VtkFlutterPresentationApi *api,
                                    const char **message) {
  if (api == NULL) {
    *message = "A positive VTK presentation API address is required";
    return false;
  }
  if (api->version != VTK_FLUTTER_PRESENTATION_API_VERSION) {
    *message = "Unsupported VTK presentation API version";
    return false;
  }
  if (api->struct_size < REQUIRED_PRESENTATION_API_SIZE) {
    *message = "VTK presentation API table is too small";
    return false;
  }
  if (api->status_clear == NULL || api->session_is_valid == NULL ||
      api->session_attach_texture_target == NULL ||
      api->session_detach_texture_target == NULL ||
      api->texture_target_create == NULL ||
      api->texture_target_destroy == NULL) {
    *message = "VTK presentation API table has missing functions";
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
                          VtkFlutterCpuFrame *frame, VtkFlutterStatus *status) {
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
    uint8_t *replacement =
        (uint8_t *)realloc(target->pixels, (size_t)capacity_bytes);
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

  frame->struct_size = sizeof(VtkFlutterCpuFrame);
  frame->version = VTK_FLUTTER_CPU_FRAME_VERSION;
  frame->pixels = target->pixels;
  frame->capacity_bytes = target->capacity_bytes;
  frame->row_bytes = row_bytes;
  frame->pixel_format = VTK_FLUTTER_PIXEL_FORMAT_RGBA8888;
  SetStatus(status, VTK_FLUTTER_STATUS_OK, NULL);
  return VTK_FLUTTER_STATUS_OK;
}

static int32_t EndFrame(void *user_data, const VtkFlutterFrameMetrics *metrics,
                        VtkFlutterStatus *status) {
  (void)metrics;
  AndroidFrameTarget *target = (AndroidFrameTarget *)user_data;
  if (target == NULL || target->window == NULL || !target->frame_in_progress ||
      target->pixels == NULL) {
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
  const bool valid =
      buffer.bits != NULL && buffer.format == WINDOW_FORMAT_RGBA_8888 &&
      buffer.stride >= target->width && buffer.height >= target->height;
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

static AndroidAdapterView *ViewFromHandle(jlong handle) {
  if (handle <= 0) {
    return NULL;
  }
  return (AndroidAdapterView *)(uintptr_t)handle;
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

static void ReleaseFrameTarget(AndroidFrameTarget *target) {
  CancelFrame(target);
  if (target->window != NULL) {
    ANativeWindow_release(target->window);
    target->window = NULL;
  }
  free(target->pixels);
  target->pixels = NULL;
  target->capacity_bytes = 0U;
  target->row_bytes = 0U;
  target->width = 0;
  target->height = 0;
}

static int32_t ReleaseView(AndroidAdapterView *view, VtkFlutterStatus *status) {
  if (view->attached) {
    ClearStatus(view->api, status);
    const int32_t detach_code = view->api->session_detach_texture_target(
        view->session, view->target, status);
    if (detach_code != VTK_FLUTTER_STATUS_OK) {
      return detach_code;
    }
    view->attached = false;
  }
  if (view->target != NULL) {
    ClearStatus(view->api, status);
    const int32_t destroy_code =
        view->api->texture_target_destroy(view->target, status);
    if (destroy_code != VTK_FLUTTER_STATUS_OK) {
      return destroy_code;
    }
    view->target = NULL;
  }
  ReleaseFrameTarget(&view->frame_target);
  free(view);
  return VTK_FLUTTER_STATUS_OK;
}

JNIEXPORT jlong JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeCreate(
    JNIEnv *environment, jobject instance, jlong presentation_api_address,
    jlong native_session_address, jobject surface, jint width, jint height) {
  (void)instance;
  if (presentation_api_address <= 0 || native_session_address <= 0 ||
      surface == NULL || width <= 0 || height <= 0) {
    ThrowJava(environment,
              "Positive presentation API address, native session address, "
              "surface, width, and height are required");
    return 0;
  }
  if ((uint64_t)presentation_api_address > (uint64_t)UINTPTR_MAX ||
      (uint64_t)native_session_address > (uint64_t)UINTPTR_MAX) {
    ThrowJava(environment, "A VTK native address does not fit this ABI");
    return 0;
  }

  const VtkFlutterPresentationApi *api =
      (const VtkFlutterPresentationApi *)(uintptr_t)presentation_api_address;
  const char *validation_message = NULL;
  if (!ValidatePresentationApi(api, &validation_message)) {
    ThrowJava(environment, validation_message);
    return 0;
  }

  AndroidAdapterView *view =
      (AndroidAdapterView *)calloc(1U, sizeof(AndroidAdapterView));
  if (view == NULL) {
    ThrowJava(environment, "Could not allocate the Android adapter view");
    return 0;
  }
  view->api = api;
  view->session = (VtkFlutterSession *)(uintptr_t)native_session_address;

  VtkFlutterStatus status = {0};
  if (!ReplaceWindow(environment, &view->frame_target, surface, width, height,
                     &status)) {
    ThrowStatus(environment, "create Android window", status.code, &status);
    ReleaseFrameTarget(&view->frame_target);
    free(view);
    return 0;
  }

  const VtkFlutterFrameCallbacks callbacks = {
      .struct_size = sizeof(VtkFlutterFrameCallbacks),
      .version = VTK_FLUTTER_FRAME_CALLBACKS_VERSION,
      .user_data = &view->frame_target,
      .begin_frame = BeginFrame,
      .end_frame = EndFrame,
      .cancel_frame = CancelFrame,
  };
  ClearStatus(api, &status);
  int32_t code = api->texture_target_create(&callbacks, &view->target, &status);
  if (code != VTK_FLUTTER_STATUS_OK || view->target == NULL) {
    ThrowStatus(environment, "create texture target", code, &status);
    ReleaseFrameTarget(&view->frame_target);
    free(view);
    return 0;
  }

  ClearStatus(api, &status);
  code =
      api->session_attach_texture_target(view->session, view->target, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    ThrowStatus(environment, "attach texture target", code, &status);
    VtkFlutterStatus destroy_status = {0};
    (void)api->texture_target_destroy(view->target, &destroy_status);
    view->target = NULL;
    ReleaseFrameTarget(&view->frame_target);
    free(view);
    return 0;
  }
  view->attached = true;
  return (jlong)(uintptr_t)view;
}

JNIEXPORT void JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeResize(
    JNIEnv *environment, jobject instance, jlong handle, jint width,
    jint height) {
  (void)instance;
  AndroidAdapterView *view = ViewFromHandle(handle);
  VtkFlutterStatus status = {0};
  if (view == NULL) {
    ThrowJava(environment, "Android VTK view is not initialized");
  } else if (!SetWindowGeometry(&view->frame_target, width, height, &status)) {
    ThrowStatus(environment, "resize", status.code, &status);
  }
}

JNIEXPORT void JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeRecreateGraphicsContext(
    JNIEnv *environment, jobject instance, jlong handle, jobject surface,
    jint width, jint height) {
  (void)instance;
  AndroidAdapterView *view = ViewFromHandle(handle);
  VtkFlutterStatus status = {0};
  if (view == NULL || surface == NULL) {
    ThrowJava(environment, "Android VTK view and surface are required");
  } else if (!ReplaceWindow(environment, &view->frame_target, surface, width,
                            height, &status)) {
    ThrowStatus(environment, "recreate presentation window", status.code,
                &status);
  }
}

JNIEXPORT void JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeDestroy(
    JNIEnv *environment, jobject instance, jlong handle) {
  (void)instance;
  AndroidAdapterView *view = ViewFromHandle(handle);
  if (view == NULL) {
    ThrowJava(environment, "Android VTK view is not initialized");
    return;
  }
  VtkFlutterStatus status = {0};
  const int32_t code = ReleaseView(view, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    ThrowStatus(environment, "dispose view", code, &status);
  }
}
