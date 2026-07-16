#import "VtkFlutterPlugin.h"
#import "VtkFlutterProtocol.h"

#import <CoreVideo/CoreVideo.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <TargetConditionals.h>

#include "../../../../native/src/session.h"

#include <vtkCamera.h>
#include <vtkIOSRenderWindow.h>
#include <vtkMatrix4x4.h>
#include <vtkOpenGLFramebufferObject.h>
#include <vtkOpenGLRenderWindow.h>
#include <vtkOpenGLState.h>
#include <vtkRenderer.h>
#include <vtkRendererCollection.h>
#include <vtkSmartPointer.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

void vtkRenderingOpenGL2_AutoInit_Construct();
void vtkRenderingVolumeOpenGL2_AutoInit_Construct();

namespace {
using Clock = std::chrono::steady_clock;

template <typename Duration>
double Milliseconds(Duration duration) {
  return std::chrono::duration<double, std::milli>(duration).count();
}

NSString* ExceptionMessage(const std::exception& exception) {
  return [NSString stringWithUTF8String:exception.what()];
}

FlutterError* StatusError(NSString* operation,
                          int32_t code,
                          const VtkFlutterStatus& status) {
  NSString* errorCode = @"vtk_internal_error";
  if (code == VTK_FLUTTER_STATUS_INVALID_ARGUMENT) {
    errorCode = @"invalid_argument";
  } else if (code == VTK_FLUTTER_STATUS_INVALID_STATE) {
    errorCode = @"invalid_state";
  } else if (code == VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE) {
    errorCode = @"render_target_unavailable";
  }
  NSString* message = status.message[0] == '\0'
                          ? [NSString stringWithFormat:@"%@ failed", operation]
                          : [NSString stringWithUTF8String:status.message];
  return [FlutterError errorWithCode:errorCode message:message details:nil];
}

class IosPixelBufferTarget final {
 public:
  IosPixelBufferTarget(EAGLContext* context, int width, int height)
      : width_(width), height_(height) {
    NSDictionary* attributes = @{
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferOpenGLESCompatibilityKey : @YES,
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    try {
      Check(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)attributes,
                                &pixelBuffer_),
            "CVPixelBufferCreate");
      if (CVPixelBufferGetIOSurface(pixelBuffer_) == nullptr) {
        throw std::runtime_error("iOS pixel buffer has no IOSurface");
      }
#if !TARGET_OS_SIMULATOR
      Check(CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nullptr, context,
                                         nullptr, &textureCache_),
            "CVOpenGLESTextureCacheCreate");
      Check(CVOpenGLESTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache_, pixelBuffer_, nullptr,
                GL_TEXTURE_2D, GL_RGBA, width, height, GL_BGRA,
                GL_UNSIGNED_BYTE, 0, &texture_),
            "CVOpenGLESTextureCacheCreateTextureFromImage");
      glGenFramebuffers(1, &framebuffer_);
      glBindFramebuffer(GL_FRAMEBUFFER, framebuffer_);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                             CVOpenGLESTextureGetTarget(texture_),
                             CVOpenGLESTextureGetName(texture_), 0);
      glDrawBuffers(1, &kColorAttachment);
      if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        throw std::runtime_error("iOS IOSurface framebuffer is incomplete");
      }
      glBindFramebuffer(GL_FRAMEBUFFER, 0);
#endif
    } catch (...) {
      ReleaseResources();
      throw;
    }
  }

  ~IosPixelBufferTarget() { ReleaseResources(); }

  IosPixelBufferTarget(const IosPixelBufferTarget&) = delete;
  IosPixelBufferTarget& operator=(const IosPixelBufferTarget&) = delete;

  bool Matches(int width, int height) const {
    return width_ == width && height_ == height;
  }

  void BindDraw(vtkOpenGLState* state) const {
#if TARGET_OS_SIMULATOR
    static_cast<void>(state);
#else
    state->vtkglBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer_);
    state->vtkglDrawBuffer(GL_COLOR_ATTACHMENT0);
#endif
  }

  void ReadPixelsFromBoundFramebuffer() const {
#if TARGET_OS_SIMULATOR
    Check(CVPixelBufferLockBaseAddress(pixelBuffer_, 0),
          "CVPixelBufferLockBaseAddress");
    auto* destinationBase =
        static_cast<std::uint8_t*>(CVPixelBufferGetBaseAddress(pixelBuffer_));
    const std::size_t destinationRowBytes =
        CVPixelBufferGetBytesPerRow(pixelBuffer_);
    std::vector<std::uint8_t> rgba(
        static_cast<std::size_t>(width_) * height_ * 4);
    while (glGetError() != GL_NO_ERROR) {
    }
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, width_, height_, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
    if (glGetError() != GL_NO_ERROR) {
      CVPixelBufferUnlockBaseAddress(pixelBuffer_, 0);
      throw std::runtime_error("iOS Simulator OpenGL readback failed");
    }
    for (int y = 0; y < height_; ++y) {
      const auto* source = rgba.data() +
                           static_cast<std::size_t>(height_ - 1 - y) * width_ * 4;
      auto* destination = destinationBase +
                          static_cast<std::size_t>(y) * destinationRowBytes;
      for (int x = 0; x < width_; ++x) {
        destination[x * 4] = source[x * 4 + 2];
        destination[x * 4 + 1] = source[x * 4 + 1];
        destination[x * 4 + 2] = source[x * 4];
        destination[x * 4 + 3] = source[x * 4 + 3];
      }
    }
    Check(CVPixelBufferUnlockBaseAddress(pixelBuffer_, 0),
          "CVPixelBufferUnlockBaseAddress");
#endif
  }

  CVPixelBufferRef RetainPixelBuffer() const {
    return CVPixelBufferRetain(pixelBuffer_);
  }

  std::size_t AllocationBytes() const {
    return CVPixelBufferGetDataSize(pixelBuffer_);
  }

  const char* HandoffMode() const {
#if TARGET_OS_SIMULATOR
    return "simulator_cpu_readback";
#else
    return "iosurface_opengles_blit";
#endif
  }

 private:
  static void Check(CVReturn result, const char* operation) {
    if (result != kCVReturnSuccess) {
      throw std::runtime_error(std::string(operation) +
                               " failed with CoreVideo status " +
                               std::to_string(result));
    }
  }

  void ReleaseResources() {
    if (framebuffer_ != 0) glDeleteFramebuffers(1, &framebuffer_);
    if (texture_ != nullptr) CFRelease(texture_);
    if (textureCache_ != nullptr) {
      CVOpenGLESTextureCacheFlush(textureCache_, 0);
      CFRelease(textureCache_);
    }
    if (pixelBuffer_ != nullptr) {
      CVPixelBufferRelease(pixelBuffer_);
      pixelBuffer_ = nullptr;
    }
  }

  static constexpr GLenum kColorAttachment = GL_COLOR_ATTACHMENT0;
  int width_;
  int height_;
  CVPixelBufferRef pixelBuffer_ = nullptr;
  CVOpenGLESTextureCacheRef textureCache_ = nullptr;
  CVOpenGLESTextureRef texture_ = nullptr;
  GLuint framebuffer_ = 0;
};

class IosRenderTarget final : public vtk_flutter::RenderTarget {
 public:
  IosRenderTarget() {
    context_ = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (context_ == nil || ![EAGLContext setCurrentContext:context_]) {
      throw std::runtime_error("could not create the iOS OpenGL ES 3 context");
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      vtkRenderingOpenGL2_AutoInit_Construct();
      vtkRenderingVolumeOpenGL2_AutoInit_Construct();
    });
    window_ = vtkSmartPointer<vtkIOSRenderWindow>::New();
    window_->SetShowWindow(false);
    window_->SetMultiSamples(0);
    window_->SetSwapBuffers(0);
    window_->Initialize();
    openGlWindow_ = vtkOpenGLRenderWindow::SafeDownCast(window_);
    if (openGlWindow_ == nullptr) {
      throw std::runtime_error("iOS VTK render window is not OpenGL-backed");
    }
  }

  ~IosRenderTarget() override {
    [EAGLContext setCurrentContext:context_];
    target_.reset();
    window_ = nullptr;
    if ([EAGLContext currentContext] == context_) {
      [EAGLContext setCurrentContext:nil];
    }
  }

  void Render(vtk_flutter::PreparedView view,
              const VtkFlutterViewport& viewport,
              VtkFlutterMetrics& metrics) override {
    if (![EAGLContext setCurrentContext:context_]) {
      throw std::runtime_error("could not activate the iOS OpenGL ES context");
    }
    EnsureTarget(viewport.width, viewport.height);
    window_->GetRenderers()->RemoveAllItems();
    window_->AddRenderer(view.renderer);

    const auto renderStart = Clock::now();
    window_->Render();
    const auto renderEnd = Clock::now();
    openGlWindow_->GetRenderFramebuffer()->Bind(GL_READ_FRAMEBUFFER);
    openGlWindow_->GetRenderFramebuffer()->ActivateReadBuffer(0);

    const auto handoffStart = Clock::now();
#if TARGET_OS_SIMULATOR
    target_->ReadPixelsFromBoundFramebuffer();
#else
    target_->BindDraw(openGlWindow_->GetState());
    openGlWindow_->GetState()->vtkglBlitFramebuffer(
        0, 0, viewport.width, viewport.height, 0, 0, viewport.width,
        viewport.height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
#endif
    const auto handoffEnd = Clock::now();

#if TARGET_OS_SIMULATOR
    const auto syncStart = handoffEnd;
    const auto syncEnd = handoffEnd;
#else
    GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    if (fence == nullptr) {
      throw std::runtime_error("iOS OpenGL ES fence creation failed");
    }
    glFlush();
    const auto syncStart = Clock::now();
    GLenum waitResult = GL_TIMEOUT_EXPIRED;
    for (int attempt = 0;
         attempt < 5 && waitResult == GL_TIMEOUT_EXPIRED; ++attempt) {
      waitResult =
          glClientWaitSync(fence, GL_SYNC_FLUSH_COMMANDS_BIT, 1000000000ULL);
    }
    const auto syncEnd = Clock::now();
    glDeleteSync(fence);
    if (waitResult == GL_WAIT_FAILED || waitResult == GL_TIMEOUT_EXPIRED) {
      throw std::runtime_error("iOS OpenGL ES fence wait failed");
    }
#endif

    metrics.surface_allocation_bytes = target_->AllocationBytes();
    metrics.render_ms = Milliseconds(renderEnd - renderStart);
    metrics.surface_submit_ms = Milliseconds(handoffEnd - handoffStart);
    metrics.gpu_sync_wait_ms = Milliseconds(syncEnd - syncStart);
#if TARGET_OS_SIMULATOR
    metrics.cpu_readback_ms = Milliseconds(handoffEnd - handoffStart);
#else
    metrics.cpu_readback_ms = 0.0;
#endif
    if (view.capture_patient_to_clip) {
      vtkRenderer* renderer = window_->GetRenderers()->GetFirstRenderer();
      if (renderer == nullptr) {
        throw std::runtime_error("locator render produced no renderer");
      }
      vtkMatrix4x4* matrix =
          renderer->GetActiveCamera()->GetCompositeProjectionTransformMatrix(
              renderer->GetTiledAspectRatio(), -1.0, 1.0);
      for (int row = 0; row < 4; ++row) {
        for (int column = 0; column < 4; ++column) {
          metrics.patient_to_clip[row * 4 + column] =
              matrix->GetElement(row, column);
        }
      }
      metrics.patient_to_clip_valid = 1;
    }
  }

  CVPixelBufferRef RetainPixelBuffer() const {
    return target_ == nullptr ? nullptr : target_->RetainPixelBuffer();
  }

  const char* HandoffMode() const {
    return target_ == nullptr ? "unavailable" : target_->HandoffMode();
  }

 private:
  void EnsureTarget(int width, int height) {
    if (target_ != nullptr && target_->Matches(width, height)) return;
    target_.reset();
    window_->SetSize(width, height);
    target_ = std::make_unique<IosPixelBufferTarget>(context_, width, height);
  }

  __strong EAGLContext* context_;
  vtkSmartPointer<vtkIOSRenderWindow> window_;
  vtkOpenGLRenderWindow* openGlWindow_ = nullptr;
  std::unique_ptr<IosPixelBufferTarget> target_;
};
}  // namespace

@interface VtkFlutterExternalTexture : NSObject <FlutterTexture>
- (void)replacePixelBuffer:(CVPixelBufferRef)pixelBuffer frameId:(int64_t)frameId;
- (void)clear;
@property(nonatomic, readonly) uint64_t presentedFrameCount;
@property(nonatomic, readonly) int64_t presentedFrameId;
@end

@implementation VtkFlutterExternalTexture {
  CVPixelBufferRef _pixelBuffer;
  uint64_t _presentedFrameCount;
  int64_t _currentFrameId;
  int64_t _presentedFrameId;
}

- (CVPixelBufferRef)copyPixelBuffer {
  @synchronized(self) {
    if (_pixelBuffer == nullptr) return nullptr;
    ++_presentedFrameCount;
    _presentedFrameId = _currentFrameId;
    return CVPixelBufferRetain(_pixelBuffer);
  }
}

- (void)replacePixelBuffer:(CVPixelBufferRef)pixelBuffer frameId:(int64_t)frameId {
  @synchronized(self) {
    if (_pixelBuffer != nullptr) CVPixelBufferRelease(_pixelBuffer);
    _pixelBuffer = pixelBuffer;
    _currentFrameId = frameId;
  }
}

- (void)clear {
  @synchronized(self) {
    if (_pixelBuffer != nullptr) {
      CVPixelBufferRelease(_pixelBuffer);
      _pixelBuffer = nullptr;
    }
  }
}

- (uint64_t)presentedFrameCount {
  @synchronized(self) { return _presentedFrameCount; }
}

- (int64_t)presentedFrameId {
  @synchronized(self) { return _presentedFrameId; }
}

- (void)dealloc { [self clear]; }
@end

@interface VtkFlutterPlugin ()
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;
@end

@implementation VtkFlutterPlugin {
  NSObject<FlutterPluginRegistrar>* _registrar;
  VtkFlutterExternalTexture* _texture;
  int64_t _textureId;
  std::unique_ptr<VtkFlutterSession> _session;
  IosRenderTarget* _renderTarget;
  VtkFlutterViewport _viewport;
  int64_t _frameId;
  int64_t _graphicsContextGeneration;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:@"vtk_flutter/session"
                                  binaryMessenger:registrar.messenger];
  VtkFlutterPlugin* instance =
      [[VtkFlutterPlugin alloc] initWithRegistrar:registrar];
  [registrar addMethodCallDelegate:instance channel:channel];
  [registrar publish:instance];
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  self = [super init];
  if (self != nil) {
    _registrar = registrar;
    _textureId = -1;
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"capabilities"]) {
    result(VtkFlutterCapabilitiesMap());
  } else if ([call.method isEqualToString:@"createSession"]) {
    [self createSession:call.arguments result:result];
  } else if ([call.method isEqualToString:@"setVolume"]) {
    [self setVolume:call.arguments result:result];
  } else if ([call.method isEqualToString:@"render"]) {
    [self render:call.arguments result:result];
  } else if ([call.method isEqualToString:@"presentFrame"]) {
    [self presentFrame:result];
  } else if ([call.method isEqualToString:@"status"]) {
    result([self status]);
  } else if ([call.method isEqualToString:@"resize"]) {
    [self resize:call.arguments result:result];
  } else if ([call.method isEqualToString:@"recreateGraphicsContext"]) {
    [self recreateGraphicsContext:result];
  } else if ([call.method isEqualToString:@"disposeSession"]) {
    [self disposeSession];
    result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)createSession:(id)arguments result:(FlutterResult)result {
  NSString* message = nil;
  VtkFlutterViewport viewport{};
  if (!VtkFlutterDecodeViewport(arguments, &viewport, &message)) {
    result([FlutterError errorWithCode:@"invalid_viewport" message:message details:nil]);
    return;
  }
  if (_session != nullptr) {
    _viewport = viewport;
    result(@{
      @"textureId" : @(_textureId),
      @"nativeSessionAddress" : @(
          static_cast<uint64_t>(reinterpret_cast<uintptr_t>(_session.get())))
    });
    return;
  }
  try {
    auto renderTarget = std::make_unique<IosRenderTarget>();
    IosRenderTarget* renderTargetPointer = renderTarget.get();
    auto session = std::make_unique<VtkFlutterSession>(std::move(renderTarget));
    VtkFlutterExternalTexture* texture = [[VtkFlutterExternalTexture alloc] init];
    int64_t textureId = [_registrar.textures registerTexture:texture];
    _session = std::move(session);
    _renderTarget = renderTargetPointer;
    _texture = texture;
    _textureId = textureId;
    _viewport = viewport;
    _frameId = 0;
    _graphicsContextGeneration = 1;
    result(@{
      @"textureId" : @(_textureId),
      @"nativeSessionAddress" : @(
          static_cast<uint64_t>(reinterpret_cast<uintptr_t>(_session.get())))
    });
  } catch (const std::exception& exception) {
    result([FlutterError errorWithCode:@"vtk_create_failed"
                               message:ExceptionMessage(exception)
                               details:nil]);
  }
}

- (void)setVolume:(id)arguments result:(FlutterResult)result {
  if (_session == nullptr) {
    result([FlutterError errorWithCode:@"vtk_not_initialized"
                               message:@"Create a VTK session before uploading a volume"
                               details:nil]);
    return;
  }
  NSString* message = nil;
  VtkFlutterVolume volume{};
  if (!VtkFlutterDecodeVolume(arguments, &volume, &message)) {
    result([FlutterError errorWithCode:@"invalid_volume" message:message details:nil]);
    return;
  }
  VtkFlutterStatus status{};
  int32_t code = vtk_flutter_session_set_volume(_session.get(), &volume, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    result(StatusError(@"setVolume", code, status));
    return;
  }
  result(nil);
}

- (void)render:(id)arguments result:(FlutterResult)result {
  if (_session == nullptr || _texture == nil || _renderTarget == nullptr) {
    result([FlutterError errorWithCode:@"vtk_not_initialized"
                               message:@"Create a VTK session before rendering"
                               details:nil]);
    return;
  }
  NSString* message = nil;
  VtkFlutterRenderRequest request{};
  if (!VtkFlutterDecodeRenderRequest(arguments, _viewport, &request, &message)) {
    result([FlutterError errorWithCode:@"invalid_render_request"
                               message:message
                               details:nil]);
    return;
  }
  VtkFlutterMetrics metrics{};
  VtkFlutterStatus status{};
  int32_t code = vtk_flutter_session_render(_session.get(), &request, &metrics, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    result(StatusError(@"render", code, status));
    return;
  }
  CVPixelBufferRef pixelBuffer = _renderTarget->RetainPixelBuffer();
  if (pixelBuffer == nullptr) {
    result([FlutterError errorWithCode:@"vtk_render_failed"
                               message:@"VTK produced no iOS pixel buffer"
                               details:nil]);
    return;
  }
  ++_frameId;
  [_texture replacePixelBuffer:pixelBuffer frameId:_frameId];
  [_registrar.textures textureFrameAvailable:_textureId];
  NSMutableDictionary* response = [@{
    @"textureId" : @(_textureId),
    @"width" : @(metrics.frame_width),
    @"height" : @(metrics.frame_height),
    @"volumeBytes" : @(metrics.volume_bytes),
    @"frameBytes" : @(metrics.frame_bytes),
    @"residentBytes" : @(metrics.surface_allocation_bytes),
    @"renderUs" : @(llround(metrics.render_ms * 1000.0)),
    @"blitSubmitUs" : @(llround(metrics.surface_submit_ms * 1000.0)),
    @"gpuSyncWaitUs" : @(llround(metrics.gpu_sync_wait_ms * 1000.0)),
    @"readbackUs" : @(llround(metrics.cpu_readback_ms * 1000.0)),
    @"frameId" : @(_frameId),
    @"presentedFrameCount" : @(_texture.presentedFrameCount),
    @"presentedFrameId" : @(_texture.presentedFrameId),
    @"graphicsContextGeneration" : @(_graphicsContextGeneration),
    @"handoffMode" : [NSString stringWithUTF8String:_renderTarget->HandoffMode()],
  } mutableCopy];
  if (metrics.patient_to_clip_valid != 0) {
    NSMutableArray<NSNumber*>* matrix = [NSMutableArray arrayWithCapacity:16];
    for (int index = 0; index < 16; ++index) {
      [matrix addObject:@(metrics.patient_to_clip[index])];
    }
    response[@"patientToClip"] = matrix;
  }
  result(response);
}

- (void)presentFrame:(FlutterResult)result {
  if (_session == nullptr || _texture == nil || _renderTarget == nullptr) {
    result([FlutterError errorWithCode:@"vtk_not_initialized"
                               message:@"Create a VTK session before presenting"
                               details:nil]);
    return;
  }
  CVPixelBufferRef pixelBuffer = _renderTarget->RetainPixelBuffer();
  if (pixelBuffer == nullptr) {
    result([FlutterError errorWithCode:@"vtk_render_failed"
                               message:@"VTK produced no iOS pixel buffer"
                               details:nil]);
    return;
  }
  ++_frameId;
  [_texture replacePixelBuffer:pixelBuffer frameId:_frameId];
  [_registrar.textures textureFrameAvailable:_textureId];
  result(@{
    @"frameId" : @(_frameId),
    @"presentedFrameCount" : @(_texture.presentedFrameCount),
    @"presentedFrameId" : @(_texture.presentedFrameId),
    @"graphicsContextGeneration" : @(_graphicsContextGeneration),
    @"handoffMode" : [NSString stringWithUTF8String:_renderTarget->HandoffMode()],
  });
}

- (NSDictionary*)status {
  BOOL ready = _session != nullptr && _texture != nil && _textureId >= 0;
#if TARGET_OS_SIMULATOR
  NSString* graphicsSupport = @"OpenGL ES simulator CPU readback";
#else
  NSString* graphicsSupport = @"OpenGL ES IOSurface (iOS)";
#endif
  return @{
    @"textureId" : @(_textureId),
    @"ready" : @(ready),
    @"initializing" : @NO,
    @"disposing" : @NO,
    @"pendingTextureUnregistrations" : @0,
    @"queuedInitializationCount" : @0,
    @"presentedFrameCount" : @(_texture.presentedFrameCount),
    @"presentedFrameId" : @(_texture.presentedFrameId),
    @"graphicsContextGeneration" : @(_graphicsContextGeneration),
    @"graphicsSupport" : graphicsSupport,
  };
}

- (void)resize:(id)arguments result:(FlutterResult)result {
  if (_session == nullptr) {
    result([FlutterError errorWithCode:@"vtk_not_initialized"
                               message:@"Create a VTK session before resizing"
                               details:nil]);
    return;
  }
  NSString* message = nil;
  VtkFlutterViewport viewport{};
  if (!VtkFlutterDecodeViewport(arguments, &viewport, &message)) {
    result([FlutterError errorWithCode:@"invalid_viewport" message:message details:nil]);
    return;
  }
  _viewport = viewport;
  result(nil);
}

- (void)recreateGraphicsContext:(FlutterResult)result {
  if (_session == nullptr) {
    result([FlutterError errorWithCode:@"vtk_not_initialized"
                               message:@"Create a VTK session before recreating graphics"
                               details:nil]);
    return;
  }
  try {
    auto renderTarget = std::make_unique<IosRenderTarget>();
    IosRenderTarget* renderTargetPointer = renderTarget.get();
    _session->value.SetRenderTarget(std::move(renderTarget));
    _renderTarget = renderTargetPointer;
    ++_graphicsContextGeneration;
    result(@{ @"graphicsContextGeneration" : @(_graphicsContextGeneration) });
  } catch (const std::exception& exception) {
    result([FlutterError errorWithCode:@"vtk_context_failed"
                               message:ExceptionMessage(exception)
                               details:nil]);
  }
}

- (void)disposeSession {
  if (_textureId >= 0) [_registrar.textures unregisterTexture:_textureId];
  _textureId = -1;
  [_texture clear];
  _texture = nil;
  _renderTarget = nullptr;
  _session.reset();
  _viewport = {};
  _frameId = 0;
  _graphicsContextGeneration = 0;
}

- (void)dealloc { [self disposeSession]; }
@end
