#include <jni.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include "session.h"

#include <vtkCamera.h>
#include <vtkGenericOpenGLRenderWindow.h>
#include <vtkMatrix4x4.h>
#include <vtkObjectFactory.h>
#include <vtkRenderer.h>
#include <vtkSmartPointer.h>

#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
constexpr std::size_t MetricCount = 26;
constexpr std::size_t PatientToClipOffset = 10;

template <typename Duration> double Milliseconds(Duration duration) {
  return std::chrono::duration<double, std::milli>(duration).count();
}

void ThrowJava(JNIEnv *environment, const char *message) {
  jclass exception_class =
      environment->FindClass("java/lang/RuntimeException");
  if (exception_class != nullptr) {
    environment->ThrowNew(exception_class, message);
  }
}

void CheckEgl(EGLBoolean succeeded, const char *operation) {
  if (succeeded != EGL_TRUE) {
    throw std::runtime_error(std::string(operation) +
                             " failed with EGL error " +
                             std::to_string(eglGetError()));
  }
}

class AndroidExternalRenderWindow final
    : public vtkGenericOpenGLRenderWindow {
public:
  static AndroidExternalRenderWindow *New();
  vtkTypeMacro(AndroidExternalRenderWindow, vtkGenericOpenGLRenderWindow)

  void MakeCurrent() override {}
  bool IsCurrent() override { return true; }

protected:
  AndroidExternalRenderWindow() = default;
  ~AndroidExternalRenderWindow() override = default;
};

vtkStandardNewMacro(AndroidExternalRenderWindow);

class AndroidEglRenderTarget final : public vtk_flutter::RenderTarget {
public:
  AndroidEglRenderTarget(JNIEnv *environment, jobject surface, int width,
                         int height)
      : width_(width), height_(height) {
    window_ = ANativeWindow_fromSurface(environment, surface);
    if (window_ == nullptr) {
      throw std::runtime_error(
          "Flutter SurfaceTexture did not provide an ANativeWindow");
    }
    try {
      Initialize();
    } catch (...) {
      Release();
      throw;
    }
  }

  ~AndroidEglRenderTarget() override { Release(); }

  AndroidEglRenderTarget(const AndroidEglRenderTarget &) = delete;
  AndroidEglRenderTarget &operator=(const AndroidEglRenderTarget &) = delete;

  void Resize(int width, int height) {
    if (width <= 0 || height <= 0) {
      throw std::invalid_argument("positive render target size is required");
    }
    MakeCurrent();
    if (ANativeWindow_setBuffersGeometry(window_, width, height,
                                         native_format_) != 0) {
      throw std::runtime_error(
          "Could not resize the Flutter texture's ANativeWindow");
    }
    width_ = width;
    height_ = height;
    render_window_->SetSize(width, height);
  }

  void Render(vtk_flutter::PreparedView view,
              const VtkFlutterViewport &viewport,
              VtkFlutterMetrics &metrics) override {
    if (viewport.width != width_ || viewport.height != height_) {
      Resize(viewport.width, viewport.height);
    } else {
      MakeCurrent();
    }

    render_window_->AddRenderer(view.renderer);
    try {
      const auto render_started = Clock::now();
      render_window_->Render();
      const auto render_finished = Clock::now();
      if (view.capture_patient_to_clip) {
        CapturePatientToClip(*view.renderer, viewport, metrics);
      }
      CheckEgl(eglSwapBuffers(display_, surface_), "eglSwapBuffers");
      const auto submit_finished = Clock::now();

      metrics.surface_allocation_bytes = metrics.frame_bytes * 3ULL;
      metrics.render_ms = Milliseconds(render_finished - render_started);
      metrics.surface_submit_ms =
          Milliseconds(submit_finished - render_finished);
      metrics.gpu_sync_wait_ms = 0.0;
      metrics.cpu_readback_ms = 0.0;
    } catch (...) {
      render_window_->RemoveRenderer(view.renderer);
      throw;
    }
    render_window_->RemoveRenderer(view.renderer);
  }

private:
  void Initialize() {
    CheckEgl(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI");
    display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display_ == EGL_NO_DISPLAY) {
      throw std::runtime_error("eglGetDisplay failed");
    }
    CheckEgl(eglInitialize(display_, nullptr, nullptr), "eglInitialize");

    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE,
        EGL_OPENGL_ES3_BIT_KHR, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 24, EGL_NONE};
    EGLint config_count = 0;
    CheckEgl(eglChooseConfig(display_, config_attributes, &config_, 1,
                             &config_count),
             "eglChooseConfig");
    if (config_count != 1) {
      throw std::runtime_error("No EGL3 window configuration is available");
    }
    CheckEgl(eglGetConfigAttrib(display_, config_, EGL_NATIVE_VISUAL_ID,
                                &native_format_),
             "eglGetConfigAttrib");
    if (ANativeWindow_setBuffersGeometry(window_, width_, height_,
                                         native_format_) != 0) {
      throw std::runtime_error(
          "Could not size the Flutter texture's ANativeWindow");
    }

    const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3,
                                         EGL_NONE};
    context_ =
        eglCreateContext(display_, config_, EGL_NO_CONTEXT, context_attributes);
    if (context_ == EGL_NO_CONTEXT) {
      throw std::runtime_error(
          "eglCreateContext could not create an OpenGL ES 3 context");
    }
    surface_ = eglCreateWindowSurface(display_, config_, window_, nullptr);
    if (surface_ == EGL_NO_SURFACE) {
      throw std::runtime_error("eglCreateWindowSurface failed");
    }
    MakeCurrent();
    render_window_->SetSize(width_, height_);
    render_window_->SetReadyForRendering(true);
  }

  void MakeCurrent() {
    CheckEgl(eglMakeCurrent(display_, surface_, surface_, context_),
             "eglMakeCurrent");
  }

  static void CapturePatientToClip(vtkRenderer &renderer,
                                   const VtkFlutterViewport &viewport,
                                   VtkFlutterMetrics &metrics) {
    const double aspect =
        static_cast<double>(viewport.width) / viewport.height;
    vtkMatrix4x4 *matrix = renderer.GetActiveCamera()
                               ->GetCompositeProjectionTransformMatrix(
                                   aspect, -1.0, 1.0);
    if (matrix == nullptr) {
      return;
    }
    for (int row = 0; row < 4; ++row) {
      for (int column = 0; column < 4; ++column) {
        metrics.patient_to_clip[row * 4 + column] =
            matrix->GetElement(row, column);
      }
    }
    metrics.patient_to_clip_valid = 1;
  }

  void Release() {
    if (display_ != EGL_NO_DISPLAY) {
      if (context_ != EGL_NO_CONTEXT && surface_ != EGL_NO_SURFACE) {
        eglMakeCurrent(display_, surface_, surface_, context_);
        render_window_->Finalize();
      }
      render_window_ = nullptr;
      eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      if (surface_ != EGL_NO_SURFACE) {
        eglDestroySurface(display_, surface_);
        surface_ = EGL_NO_SURFACE;
      }
      if (context_ != EGL_NO_CONTEXT) {
        eglDestroyContext(display_, context_);
        context_ = EGL_NO_CONTEXT;
      }
      eglTerminate(display_);
      display_ = EGL_NO_DISPLAY;
    }
    if (window_ != nullptr) {
      ANativeWindow_release(window_);
      window_ = nullptr;
    }
  }

  int width_;
  int height_;
  int native_format_ = 0;
  ANativeWindow *window_ = nullptr;
  EGLDisplay display_ = EGL_NO_DISPLAY;
  EGLConfig config_ = nullptr;
  EGLContext context_ = EGL_NO_CONTEXT;
  EGLSurface surface_ = EGL_NO_SURFACE;
  vtkSmartPointer<AndroidExternalRenderWindow> render_window_ =
      vtkSmartPointer<AndroidExternalRenderWindow>::New();
};

class AndroidVtkSession final {
public:
  AndroidVtkSession(JNIEnv *environment, jobject surface, int width,
                    int height) {
    auto target = std::make_unique<AndroidEglRenderTarget>(
        environment, surface, width, height);
    render_target_ = target.get();
    session_ =
        std::make_unique<VtkFlutterSession>(std::move(target));
  }

  void SetVolume(const VtkFlutterVolume &volume) {
    session_->value.SetVolume(volume);
  }

  void Render(const VtkFlutterRenderRequest &request,
              VtkFlutterMetrics &metrics) {
    session_->value.Render(request, metrics);
  }

  void Resize(int width, int height) { render_target_->Resize(width, height); }

  void RecreateGraphicsContext(JNIEnv *environment, jobject surface, int width,
                               int height) {
    auto replacement = std::make_unique<AndroidEglRenderTarget>(
        environment, surface, width, height);
    AndroidEglRenderTarget *replacement_pointer = replacement.get();
    session_->value.SetRenderTarget(std::move(replacement));
    render_target_ = replacement_pointer;
  }

private:
  std::unique_ptr<VtkFlutterSession> session_;
  AndroidEglRenderTarget *render_target_ = nullptr;
};

AndroidVtkSession *SessionFromHandle(jlong handle) {
  if (handle == 0) {
    throw std::runtime_error("Android VTK session is not initialized");
  }
  return reinterpret_cast<AndroidVtkSession *>(handle);
}

template <typename Action>
void TranslateJavaErrors(JNIEnv *environment, Action action) {
  try {
    action();
  } catch (const std::exception &exception) {
    ThrowJava(environment, exception.what());
  } catch (...) {
    ThrowJava(environment, "Unknown Android VTK error");
  }
}
} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeCreate(
    JNIEnv *environment, jobject, jobject surface, jint width, jint height) {
  try {
    return reinterpret_cast<jlong>(
        new AndroidVtkSession(environment, surface, width, height));
  } catch (const std::exception &exception) {
    ThrowJava(environment, exception.what());
    return 0;
  } catch (...) {
    ThrowJava(environment, "Unknown Android VTK creation error");
    return 0;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeSetVolume(
    JNIEnv *environment, jobject, jlong handle, jbyteArray voxel_array,
    jint width, jint height, jint depth, jdoubleArray matrix_array) {
  TranslateJavaErrors(environment, [&] {
    const jsize voxel_byte_count = environment->GetArrayLength(voxel_array);
    if (voxel_byte_count % static_cast<jsize>(sizeof(std::int16_t)) != 0 ||
        environment->GetArrayLength(matrix_array) != 16) {
      throw std::invalid_argument("Invalid voxel bytes or affine matrix");
    }

    std::vector<std::int16_t> voxels(
        static_cast<std::size_t>(voxel_byte_count) / sizeof(std::int16_t));
    environment->GetByteArrayRegion(
        voxel_array, 0, voxel_byte_count,
        reinterpret_cast<jbyte *>(voxels.data()));
    if (environment->ExceptionCheck()) {
      throw std::runtime_error("Could not copy Android VTK voxel bytes");
    }

    VtkFlutterVolume volume{};
    volume.voxels = voxels.data();
    volume.voxel_count = voxels.size();
    volume.width = width;
    volume.height = height;
    volume.depth = depth;
    environment->GetDoubleArrayRegion(matrix_array, 0, 16,
                                      volume.index_to_patient);
    if (environment->ExceptionCheck()) {
      throw std::runtime_error("Could not copy Android VTK affine matrix");
    }
    SessionFromHandle(handle)->SetVolume(volume);
  });
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeRender(
    JNIEnv *environment, jobject, jlong handle, jint mode, jint width,
    jint height, jdouble window_center, jdouble window_width,
    jdoubleArray origin_array, jdoubleArray normal_array, jdouble azimuth,
    jdouble elevation, jdouble zoom) {
  try {
    if (environment->GetArrayLength(origin_array) != 3 ||
        environment->GetArrayLength(normal_array) != 3) {
      throw std::invalid_argument(
          "Plane origin and normal need three values");
    }

    VtkFlutterRenderRequest request{};
    request.mode = mode;
    request.viewport = {width, height};
    request.window_center = window_center;
    request.window_width = window_width;
    request.camera_azimuth_degrees = azimuth;
    request.camera_elevation_degrees = elevation;
    request.camera_zoom = zoom;
    environment->GetDoubleArrayRegion(origin_array, 0, 3,
                                      request.plane_origin);
    environment->GetDoubleArrayRegion(normal_array, 0, 3,
                                      request.plane_normal);
    if (environment->ExceptionCheck()) {
      throw std::runtime_error("Could not copy Android VTK render vectors");
    }

    VtkFlutterMetrics metrics{};
    SessionFromHandle(handle)->Render(request, metrics);
    std::array<double, MetricCount> values{
        static_cast<double>(metrics.volume_bytes),
        static_cast<double>(metrics.frame_bytes),
        static_cast<double>(metrics.surface_allocation_bytes),
        metrics.render_ms,
        metrics.surface_submit_ms,
        metrics.gpu_sync_wait_ms,
        metrics.cpu_readback_ms,
        static_cast<double>(metrics.frame_width),
        static_cast<double>(metrics.frame_height),
        static_cast<double>(metrics.patient_to_clip_valid),
    };
    std::memcpy(values.data() + PatientToClipOffset, metrics.patient_to_clip,
                sizeof(metrics.patient_to_clip));

    jdoubleArray result = environment->NewDoubleArray(values.size());
    if (result == nullptr) {
      throw std::runtime_error("Could not allocate Android VTK metrics");
    }
    environment->SetDoubleArrayRegion(result, 0, values.size(), values.data());
    return result;
  } catch (const std::exception &exception) {
    ThrowJava(environment, exception.what());
    return nullptr;
  } catch (...) {
    ThrowJava(environment, "Unknown Android VTK render error");
    return nullptr;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeResize(
    JNIEnv *environment, jobject, jlong handle, jint width, jint height) {
  TranslateJavaErrors(environment,
                      [&] { SessionFromHandle(handle)->Resize(width, height); });
}

extern "C" JNIEXPORT void JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeRecreateGraphicsContext(
    JNIEnv *environment, jobject, jlong handle, jobject surface, jint width,
    jint height) {
  TranslateJavaErrors(environment, [&] {
    SessionFromHandle(handle)->RecreateGraphicsContext(
        environment, surface, width, height);
  });
}

extern "C" JNIEXPORT void JNICALL
Java_ninja_bieker_vtk_1flutter_AndroidVtkTextureAdapter_nativeDestroy(
    JNIEnv *environment, jobject, jlong handle) {
  TranslateJavaErrors(environment,
                      [&] { delete SessionFromHandle(handle); });
}
