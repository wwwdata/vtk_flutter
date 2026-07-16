#import "VtkFlutterPlugin.h"
#import "VtkFlutterProtocol.h"

#import <CoreVideo/CoreVideo.h>

#include <cmath>
#include <cstdio>
#include <cstdint>

namespace {
constexpr const char* kHandoffMode = "cpu_bgra_pixel_buffer";

void SetStatus(VtkFlutterStatus* status, int32_t code, const char* message) {
  if (status == nullptr) return;
  status->code = code;
  std::snprintf(status->message, sizeof(status->message), "%s", message);
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
  if (message == nil) message = [NSString stringWithFormat:@"%@ failed", operation];
  return [FlutterError errorWithCode:errorCode message:message details:nil];
}
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
- (int32_t)beginFrame:(const VtkFlutterViewport*)viewport
                frame:(VtkFlutterCpuFrameV2*)frame
               status:(VtkFlutterStatus*)status;
- (int32_t)endFrame:(const VtkFlutterMetrics*)metrics
              status:(VtkFlutterStatus*)status;
- (void)cancelFrame;
@end

static int32_t VtkFlutterBeginFrame(void* userData,
                                    const VtkFlutterViewport* viewport,
                                    VtkFlutterCpuFrameV2* frame,
                                    VtkFlutterStatus* status) {
  @autoreleasepool {
    VtkFlutterPlugin* plugin = (__bridge VtkFlutterPlugin*)userData;
    if (plugin == nil) {
      SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE,
                "macOS frame callback state is unavailable");
      return VTK_FLUTTER_STATUS_INVALID_STATE;
    }
    return [plugin beginFrame:viewport frame:frame status:status];
  }
}

static int32_t VtkFlutterEndFrame(void* userData,
                                  const VtkFlutterMetrics* metrics,
                                  VtkFlutterStatus* status) {
  @autoreleasepool {
    VtkFlutterPlugin* plugin = (__bridge VtkFlutterPlugin*)userData;
    if (plugin == nil) {
      SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE,
                "macOS frame callback state is unavailable");
      return VTK_FLUTTER_STATUS_INVALID_STATE;
    }
    return [plugin endFrame:metrics status:status];
  }
}

static void VtkFlutterCancelFrame(void* userData) {
  @autoreleasepool {
    VtkFlutterPlugin* plugin = (__bridge VtkFlutterPlugin*)userData;
    [plugin cancelFrame];
  }
}

@implementation VtkFlutterPlugin {
  id<FlutterPluginRegistrar> _registrar;
  VtkFlutterExternalTexture* _texture;
  int64_t _textureId;
  const VtkFlutterCoreApiV2* _coreApi;
  VtkFlutterSession* _session;
  VtkFlutterTextureTarget* _textureTarget;
  VtkFlutterViewport _viewport;
  int64_t _frameId;
  int64_t _graphicsContextGeneration;

  CVPixelBufferPoolRef _pixelBufferPool;
  CVPixelBufferRef _inProgressPixelBuffer;
  CVPixelBufferRef _completedPixelBuffer;
  int32_t _poolWidth;
  int32_t _poolHeight;
  BOOL _frameLocked;
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
  const VtkFlutterCoreApiV2* coreApi = nullptr;
  if (!VtkFlutterDecodeCoreApi(arguments, &coreApi, &message)) {
    result([FlutterError errorWithCode:@"invalid_core_api" message:message details:nil]);
    return;
  }
  if (_session != nullptr) {
    if (_coreApi != coreApi) {
      result([FlutterError errorWithCode:@"invalid_state"
                                 message:@"The active session uses a different core API table"
                                 details:nil]);
      return;
    }
    _viewport = viewport;
    result(@{
      @"textureId" : @(_textureId),
      @"nativeSessionAddress" : @(
          static_cast<uint64_t>(reinterpret_cast<uintptr_t>(_session)))
    });
    return;
  }

  VtkFlutterExternalTexture* texture = [[VtkFlutterExternalTexture alloc] init];
  int64_t textureId = [_registrar.textures registerTexture:texture];
  if (textureId <= 0) {
    result([FlutterError errorWithCode:@"vtk_create_failed"
                               message:@"Flutter rejected the macOS external texture"
                               details:nil]);
    return;
  }

  VtkFlutterFrameCallbacksV2 callbacks{
      .struct_size = sizeof(VtkFlutterFrameCallbacksV2),
      .version = VTK_FLUTTER_FRAME_CALLBACKS_VERSION_2,
      .user_data = (__bridge void*)self,
      .begin_frame = VtkFlutterBeginFrame,
      .end_frame = VtkFlutterEndFrame,
      .cancel_frame = VtkFlutterCancelFrame,
  };
  VtkFlutterStatus status{};
  VtkFlutterTextureTarget* textureTarget = nullptr;
  int32_t code = coreApi->texture_target_create(&callbacks, &textureTarget, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    [_registrar.textures unregisterTexture:textureId];
    result(StatusError(@"create texture target", code, status));
    return;
  }

  VtkFlutterSession* session = nullptr;
  status = {};
  code = coreApi->session_create(&session, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    VtkFlutterStatus destroyStatus{};
    coreApi->texture_target_destroy(textureTarget, &destroyStatus);
    [_registrar.textures unregisterTexture:textureId];
    result(StatusError(@"create session", code, status));
    return;
  }

  status = {};
  code = coreApi->session_attach_texture_target(session, textureTarget, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    coreApi->session_destroy(session);
    VtkFlutterStatus destroyStatus{};
    coreApi->texture_target_destroy(textureTarget, &destroyStatus);
    [_registrar.textures unregisterTexture:textureId];
    result(StatusError(@"attach texture target", code, status));
    return;
  }

  _coreApi = coreApi;
  _session = session;
  _textureTarget = textureTarget;
  _texture = texture;
  _textureId = textureId;
  _viewport = viewport;
  _frameId = 0;
  _graphicsContextGeneration = 1;
  result(@{
    @"textureId" : @(_textureId),
    @"nativeSessionAddress" : @(
        static_cast<uint64_t>(reinterpret_cast<uintptr_t>(_session)))
  });
}

- (void)setVolume:(id)arguments result:(FlutterResult)result {
  if (_session == nullptr || _coreApi == nullptr) {
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
  int32_t code = _coreApi->session_set_volume(_session, &volume, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    result(StatusError(@"setVolume", code, status));
    return;
  }
  result(nil);
}

- (void)render:(id)arguments result:(FlutterResult)result {
  if (_session == nullptr || _coreApi == nullptr || _texture == nil ||
      _textureTarget == nullptr) {
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
  int32_t code = _coreApi->session_render(_session, &request, &metrics, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    result(StatusError(@"render", code, status));
    return;
  }
  if (![self publishCompletedFrame]) {
    result([FlutterError errorWithCode:@"vtk_render_failed"
                               message:@"VTK produced no macOS pixel buffer"
                               details:nil]);
    return;
  }
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
    @"handoffMode" : [NSString stringWithUTF8String:kHandoffMode],
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

- (BOOL)publishCompletedFrame {
  CVPixelBufferRef pixelBuffer = nullptr;
  @synchronized(self) {
    if (_completedPixelBuffer != nullptr) {
      pixelBuffer = CVPixelBufferRetain(_completedPixelBuffer);
    }
  }
  if (pixelBuffer == nullptr) return NO;
  ++_frameId;
  [_texture replacePixelBuffer:pixelBuffer frameId:_frameId];
  [_registrar.textures textureFrameAvailable:_textureId];
  return YES;
}

- (void)presentFrame:(FlutterResult)result {
  if (_session == nullptr || _texture == nil || _textureTarget == nullptr) {
    result([FlutterError errorWithCode:@"vtk_not_initialized"
                               message:@"Create a VTK session before presenting"
                               details:nil]);
    return;
  }
  if (![self publishCompletedFrame]) {
    result([FlutterError errorWithCode:@"vtk_render_failed"
                               message:@"VTK produced no macOS pixel buffer"
                               details:nil]);
    return;
  }
  result(@{
    @"frameId" : @(_frameId),
    @"presentedFrameCount" : @(_texture.presentedFrameCount),
    @"presentedFrameId" : @(_texture.presentedFrameId),
    @"graphicsContextGeneration" : @(_graphicsContextGeneration),
    @"handoffMode" : [NSString stringWithUTF8String:kHandoffMode],
  });
}

- (NSDictionary*)status {
  BOOL ready = _session != nullptr && _textureTarget != nullptr &&
               _texture != nil && _textureId > 0;
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
    @"graphicsSupport" : @"Core-owned VTK with BGRA CVPixelBuffer (macOS)",
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

- (VtkFlutterFrameCallbacksV2)frameCallbacks {
  return VtkFlutterFrameCallbacksV2{
      .struct_size = sizeof(VtkFlutterFrameCallbacksV2),
      .version = VTK_FLUTTER_FRAME_CALLBACKS_VERSION_2,
      .user_data = (__bridge void*)self,
      .begin_frame = VtkFlutterBeginFrame,
      .end_frame = VtkFlutterEndFrame,
      .cancel_frame = VtkFlutterCancelFrame,
  };
}

- (void)recreateGraphicsContext:(FlutterResult)result {
  if (_session == nullptr || _coreApi == nullptr || _textureTarget == nullptr) {
    result([FlutterError errorWithCode:@"vtk_not_initialized"
                               message:@"Create a VTK session before recreating graphics"
                               details:nil]);
    return;
  }
  VtkFlutterFrameCallbacksV2 callbacks = [self frameCallbacks];
  VtkFlutterStatus status{};
  VtkFlutterTextureTarget* newTarget = nullptr;
  int32_t code = _coreApi->texture_target_create(&callbacks, &newTarget, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    result(StatusError(@"recreate texture target", code, status));
    return;
  }
  status = {};
  code = _coreApi->session_detach_texture_target(_session, _textureTarget, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    VtkFlutterStatus destroyStatus{};
    _coreApi->texture_target_destroy(newTarget, &destroyStatus);
    result(StatusError(@"detach texture target", code, status));
    return;
  }
  status = {};
  code = _coreApi->session_attach_texture_target(_session, newTarget, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    VtkFlutterStatus restoreStatus{};
    _coreApi->session_attach_texture_target(_session, _textureTarget, &restoreStatus);
    VtkFlutterStatus destroyStatus{};
    _coreApi->texture_target_destroy(newTarget, &destroyStatus);
    result(StatusError(@"attach recreated texture target", code, status));
    return;
  }
  VtkFlutterTextureTarget* oldTarget = _textureTarget;
  _textureTarget = newTarget;
  VtkFlutterStatus destroyStatus{};
  code = _coreApi->texture_target_destroy(oldTarget, &destroyStatus);
  if (code != VTK_FLUTTER_STATUS_OK) {
    result(StatusError(@"destroy replaced texture target", code, destroyStatus));
    return;
  }
  ++_graphicsContextGeneration;
  result(@{ @"graphicsContextGeneration" : @(_graphicsContextGeneration) });
}

- (int32_t)beginFrame:(const VtkFlutterViewport*)viewport
                frame:(VtkFlutterCpuFrameV2*)frame
               status:(VtkFlutterStatus*)status {
  @synchronized(self) {
    if (viewport == nullptr || frame == nullptr || viewport->width <= 0 ||
        viewport->height <= 0) {
      SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
                "macOS begin_frame received an invalid viewport or frame");
      return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
    }
    if (_frameLocked || _inProgressPixelBuffer != nullptr) {
      SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE,
                "macOS frame storage is already locked");
      return VTK_FLUTTER_STATUS_INVALID_STATE;
    }
    if (_pixelBufferPool == nullptr || _poolWidth != viewport->width ||
        _poolHeight != viewport->height) {
      if (_pixelBufferPool != nullptr) CVPixelBufferPoolRelease(_pixelBufferPool);
      _pixelBufferPool = nullptr;
      NSDictionary* poolAttributes = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey : @2,
      };
      NSDictionary* pixelAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey : @(viewport->width),
        (id)kCVPixelBufferHeightKey : @(viewport->height),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
      };
      CVReturn poolResult = CVPixelBufferPoolCreate(
          kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes,
          (__bridge CFDictionaryRef)pixelAttributes, &_pixelBufferPool);
      if (poolResult != kCVReturnSuccess) {
        SetStatus(status, VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE,
                  "Could not create the macOS pixel buffer pool");
        return VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE;
      }
      _poolWidth = viewport->width;
      _poolHeight = viewport->height;
    }

    CVPixelBufferRef pixelBuffer = nullptr;
    CVReturn createResult =
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool,
                                           &pixelBuffer);
    if (createResult != kCVReturnSuccess || pixelBuffer == nullptr) {
      SetStatus(status, VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE,
                "Could not acquire an macOS pixel buffer");
      return VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE;
    }
    CVReturn lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    if (lockResult != kCVReturnSuccess) {
      CVPixelBufferRelease(pixelBuffer);
      SetStatus(status, VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE,
                "Could not lock the macOS pixel buffer");
      return VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE;
    }

    _inProgressPixelBuffer = pixelBuffer;
    _frameLocked = YES;
    *frame = VtkFlutterCpuFrameV2{
        .struct_size = sizeof(VtkFlutterCpuFrameV2),
        .version = VTK_FLUTTER_CPU_FRAME_VERSION_2,
        .pixels = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixelBuffer)),
        .capacity_bytes = CVPixelBufferGetDataSize(pixelBuffer),
        .row_bytes = CVPixelBufferGetBytesPerRow(pixelBuffer),
        .pixel_format = VTK_FLUTTER_PIXEL_FORMAT_BGRA8888,
    };
    return VTK_FLUTTER_STATUS_OK;
  }
}

- (int32_t)endFrame:(const VtkFlutterMetrics*)metrics
              status:(VtkFlutterStatus*)status {
  static_cast<void>(metrics);
  @synchronized(self) {
    if (!_frameLocked || _inProgressPixelBuffer == nullptr) {
      SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE,
                "macOS end_frame has no locked pixel buffer");
      return VTK_FLUTTER_STATUS_INVALID_STATE;
    }
    CVReturn unlockResult = CVPixelBufferUnlockBaseAddress(_inProgressPixelBuffer, 0);
    _frameLocked = NO;
    if (unlockResult != kCVReturnSuccess) {
      CVPixelBufferRelease(_inProgressPixelBuffer);
      _inProgressPixelBuffer = nullptr;
      SetStatus(status, VTK_FLUTTER_STATUS_INTERNAL_ERROR,
                "Could not unlock the completed macOS pixel buffer");
      return VTK_FLUTTER_STATUS_INTERNAL_ERROR;
    }
    if (_completedPixelBuffer != nullptr) {
      CVPixelBufferRelease(_completedPixelBuffer);
    }
    _completedPixelBuffer = _inProgressPixelBuffer;
    _inProgressPixelBuffer = nullptr;
    return VTK_FLUTTER_STATUS_OK;
  }
}

- (void)cancelFrame {
  @synchronized(self) {
    if (_inProgressPixelBuffer == nullptr) return;
    if (_frameLocked) CVPixelBufferUnlockBaseAddress(_inProgressPixelBuffer, 0);
    _frameLocked = NO;
    CVPixelBufferRelease(_inProgressPixelBuffer);
    _inProgressPixelBuffer = nullptr;
  }
}

- (void)clearFrameStorage {
  [self cancelFrame];
  @synchronized(self) {
    if (_completedPixelBuffer != nullptr) {
      CVPixelBufferRelease(_completedPixelBuffer);
      _completedPixelBuffer = nullptr;
    }
    if (_pixelBufferPool != nullptr) {
      CVPixelBufferPoolRelease(_pixelBufferPool);
      _pixelBufferPool = nullptr;
    }
    _poolWidth = 0;
    _poolHeight = 0;
  }
}

- (void)disposeSession {
  if (_coreApi != nullptr && _session != nullptr && _textureTarget != nullptr) {
    VtkFlutterStatus status{};
    int32_t code =
        _coreApi->session_detach_texture_target(_session, _textureTarget, &status);
    if (code != VTK_FLUTTER_STATUS_OK) {
      _coreApi->session_destroy(_session);
      _session = nullptr;
    }
  }
  if (_coreApi != nullptr && _textureTarget != nullptr) {
    VtkFlutterStatus destroyStatus{};
    _coreApi->texture_target_destroy(_textureTarget, &destroyStatus);
  }
  if (_coreApi != nullptr && _session != nullptr) {
    _coreApi->session_destroy(_session);
  }
  _session = nullptr;
  _textureTarget = nullptr;
  _coreApi = nullptr;
  [self clearFrameStorage];
  if (_textureId > 0) [_registrar.textures unregisterTexture:_textureId];
  _textureId = -1;
  [_texture clear];
  _texture = nil;
  _viewport = {};
  _frameId = 0;
  _graphicsContextGeneration = 0;
}

- (void)dealloc { [self disposeSession]; }
@end
