#import "VtkFlutterPlugin.h"
#import "VtkFlutterProtocol.h"

#import <CoreVideo/CoreVideo.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>

#include "../../../../native/src/session.h"

#include <vtkCamera.h>
#include <vtkCocoaRenderWindow.h>
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

class CoreVideoTarget final {
 public:
  CoreVideoTarget(vtkCocoaRenderWindow* window, int width, int height)
      : width_(width), height_(height) {
    NSOpenGLContext* context = (__bridge NSOpenGLContext*)window->GetContextId();
    if (context == nil) {
      throw std::runtime_error("VTK did not create an NSOpenGLContext");
    }
    NSDictionary* attributes = @{
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferOpenGLCompatibilityKey : @YES,
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    try {
      Check(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)attributes,
                                &pixelBuffer_),
            "CVPixelBufferCreate");
      if (CVPixelBufferGetIOSurface(pixelBuffer_) == nullptr) {
        throw std::runtime_error("macOS pixel buffer has no IOSurface");
      }
      Check(CVOpenGLTextureCacheCreate(kCFAllocatorDefault, nullptr,
                                       context.CGLContextObj,
                                       context.pixelFormat.CGLPixelFormatObj,
                                       nullptr, &textureCache_),
            "CVOpenGLTextureCacheCreate");
      Check(CVOpenGLTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache_, pixelBuffer_, nullptr,
                &texture_),
            "CVOpenGLTextureCacheCreateTextureFromImage");
      glGenFramebuffers(1, &framebuffer_);
      glBindFramebuffer(GL_FRAMEBUFFER, framebuffer_);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                             CVOpenGLTextureGetTarget(texture_),
                             CVOpenGLTextureGetName(texture_), 0);
      glDrawBuffer(GL_COLOR_ATTACHMENT0);
      if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        throw std::runtime_error("macOS IOSurface framebuffer is incomplete");
      }
      glBindFramebuffer(GL_FRAMEBUFFER, 0);
    } catch (...) {
      ReleaseResources();
      throw;
    }
  }

  ~CoreVideoTarget() { ReleaseResources(); }

  CoreVideoTarget(const CoreVideoTarget&) = delete;
  CoreVideoTarget& operator=(const CoreVideoTarget&) = delete;

  bool Matches(int width, int height) const {
    return width_ == width && height_ == height;
  }

  void BindDraw(vtkOpenGLState* state) const {
    state->vtkglBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer_);
    state->vtkglDrawBuffer(GL_COLOR_ATTACHMENT0);
  }

  CVPixelBufferRef RetainPixelBuffer() const {
    return CVPixelBufferRetain(pixelBuffer_);
  }

  std::size_t AllocationBytes() const {
    return CVPixelBufferGetDataSize(pixelBuffer_);
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
    if (framebuffer_ != 0) {
      glDeleteFramebuffers(1, &framebuffer_);
      framebuffer_ = 0;
    }
    if (texture_ != nullptr) {
      CFRelease(texture_);
      texture_ = nullptr;
    }
    if (textureCache_ != nullptr) {
      CVOpenGLTextureCacheFlush(textureCache_, 0);
      CFRelease(textureCache_);
      textureCache_ = nullptr;
    }
    if (pixelBuffer_ != nullptr) {
      CVPixelBufferRelease(pixelBuffer_);
      pixelBuffer_ = nullptr;
    }
  }

  int width_;
  int height_;
  CVPixelBufferRef pixelBuffer_ = nullptr;
  CVOpenGLTextureCacheRef textureCache_ = nullptr;
  CVOpenGLTextureRef texture_ = nullptr;
  GLuint framebuffer_ = 0;
};

class MacRenderTarget final : public vtk_flutter::RenderTarget {
 public:
  MacRenderTarget() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      vtkRenderingOpenGL2_AutoInit_Construct();
      vtkRenderingVolumeOpenGL2_AutoInit_Construct();
    });
    window_ = vtkSmartPointer<vtkCocoaRenderWindow>::New();
    window_->SetWindowName("vtk_flutter");
    window_->SetShowWindow(false);
    window_->SetUseOffScreenBuffers(false);
    window_->SetAlphaBitPlanes(1);
    window_->SetMultiSamples(0);
    window_->SetSwapBuffers(0);
    window_->Initialize();
    window_->MakeCurrent();
    openGlWindow_ = vtkOpenGLRenderWindow::SafeDownCast(window_);
    if (openGlWindow_ == nullptr) {
      throw std::runtime_error("macOS VTK render window is not OpenGL-backed");
    }
  }

  ~MacRenderTarget() override {
    if (window_ != nullptr) window_->MakeCurrent();
    target_.reset();
    window_ = nullptr;
  }

  void Render(vtk_flutter::PreparedView view,
              const VtkFlutterViewport& viewport,
              VtkFlutterMetrics& metrics) override {
    window_->MakeCurrent();
    EnsureTarget(viewport.width, viewport.height);
    window_->GetRenderers()->RemoveAllItems();
    window_->AddRenderer(view.renderer);

    const auto renderStart = Clock::now();
    window_->Render();
    const auto renderEnd = Clock::now();
    openGlWindow_->GetRenderFramebuffer()->Bind(GL_READ_FRAMEBUFFER);
    openGlWindow_->GetRenderFramebuffer()->ActivateReadBuffer(0);
    target_->BindDraw(openGlWindow_->GetState());
    const auto blitStart = Clock::now();
    openGlWindow_->GetState()->vtkglBlitFramebuffer(
        0, 0, viewport.width, viewport.height, 0, 0, viewport.width,
        viewport.height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    const auto blitEnd = Clock::now();

    GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    if (fence == nullptr) {
      throw std::runtime_error("macOS OpenGL fence creation failed");
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
      throw std::runtime_error("macOS OpenGL fence wait failed");
    }

    metrics.surface_allocation_bytes = target_->AllocationBytes();
    metrics.render_ms = Milliseconds(renderEnd - renderStart);
    metrics.surface_submit_ms = Milliseconds(blitEnd - blitStart);
    metrics.gpu_sync_wait_ms = Milliseconds(syncEnd - syncStart);
    metrics.cpu_readback_ms = 0.0;
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

 private:
  void EnsureTarget(int width, int height) {
    if (target_ != nullptr && target_->Matches(width, height)) return;
    target_.reset();
    window_->SetSize(width, height);
    target_ = std::make_unique<CoreVideoTarget>(window_, width, height);
  }

  vtkSmartPointer<vtkCocoaRenderWindow> window_;
  vtkOpenGLRenderWindow* openGlWindow_ = nullptr;
  std::unique_ptr<CoreVideoTarget> target_;
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
- (instancetype)initWithRegistrar:(id<FlutterPluginRegistrar>)registrar;
@end

@implementation VtkFlutterPlugin {
  id<FlutterPluginRegistrar> _registrar;
  VtkFlutterExternalTexture* _texture;
  int64_t _textureId;
  std::unique_ptr<VtkFlutterSession> _session;
  MacRenderTarget* _renderTarget;
  VtkFlutterViewport _viewport;
  int64_t _frameId;
  int64_t _graphicsContextGeneration;
}

+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:@"vtk_flutter/session"
                                  binaryMessenger:registrar.messenger];
  VtkFlutterPlugin* instance =
      [[VtkFlutterPlugin alloc] initWithRegistrar:registrar];
  [registrar addMethodCallDelegate:instance channel:channel];
  [registrar publish:instance];
}

- (instancetype)initWithRegistrar:(id<FlutterPluginRegistrar>)registrar {
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
    auto renderTarget = std::make_unique<MacRenderTarget>();
    MacRenderTarget* renderTargetPointer = renderTarget.get();
    auto session = std::make_unique<VtkFlutterSession>(std::move(renderTarget));
    VtkFlutterExternalTexture* texture = [[VtkFlutterExternalTexture alloc] init];
    int64_t textureId = [_registrar.textures registerTexture:texture];
    if (textureId == 0) {
      throw std::runtime_error("Flutter rejected the macOS external texture");
    }
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
                               message:@"VTK produced no macOS pixel buffer"
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
    @"readbackUs" : @0,
    @"frameId" : @(_frameId),
    @"presentedFrameCount" : @(_texture.presentedFrameCount),
    @"presentedFrameId" : @(_texture.presentedFrameId),
    @"graphicsContextGeneration" : @(_graphicsContextGeneration),
    @"handoffMode" : @"iosurface_opengl_blit",
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
                               message:@"VTK produced no macOS pixel buffer"
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
    @"handoffMode" : @"iosurface_opengl_blit",
  });
}

- (NSDictionary*)status {
  BOOL ready = _session != nullptr && _texture != nil && _textureId > 0;
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
    @"graphicsSupport" : @"OpenGL IOSurface (macOS)",
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
    auto renderTarget = std::make_unique<MacRenderTarget>();
    MacRenderTarget* renderTargetPointer = renderTarget.get();
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
  if (_textureId > 0) [_registrar.textures unregisterTexture:_textureId];
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
