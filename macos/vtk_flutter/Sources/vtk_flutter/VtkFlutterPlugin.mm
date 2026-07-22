#import "VtkFlutterPlugin.h"
#import "VtkFlutterProtocol.h"

#import <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <cstdio>

namespace {
constexpr const char* kHandoffMode = "cpu_bgra_pixel_buffer";

void SetStatus(VtkFlutterStatus* status, int32_t code, const char* message) {
  if (status == nullptr) return;
  status->code = code;
  std::snprintf(status->message, sizeof(status->message), "%s", message);
}

FlutterError* StatusError(NSString* operation, int32_t code, const VtkFlutterStatus& status) {
  NSString* errorCode = @"vtk_internal_error";
  if (code == VTK_FLUTTER_STATUS_INVALID_ARGUMENT) {
    errorCode = @"invalid_argument";
  } else if (code == VTK_FLUTTER_STATUS_INVALID_STATE) {
    errorCode = @"invalid_state";
  } else if (code == VTK_FLUTTER_STATUS_NOT_SUPPORTED) {
    errorCode = @"not_supported";
  } else if (code == VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE) {
    errorCode = @"render_target_unavailable";
  }
  NSString* message = status.message[0] == '\0'
                          ? [NSString stringWithFormat:@"%@ failed", operation]
                          : [NSString stringWithUTF8String:status.message];
  if (message == nil) {
    message = [NSString stringWithFormat:@"%@ failed", operation];
  }
  return [FlutterError errorWithCode:errorCode message:message details:nil];
}

NSNumber* SessionKey(VtkFlutterSession* session) {
  return @(static_cast<uint64_t>(reinterpret_cast<uintptr_t>(session)));
}

void ReleaseCallbackUserData(void* userData) {
  if (userData != nullptr) {
    CFRelease(static_cast<CFTypeRef>(userData));
  }
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
  @synchronized(self) {
    return _presentedFrameCount;
  }
}

- (int64_t)presentedFrameId {
  @synchronized(self) {
    return _presentedFrameId;
  }
}

- (void)dealloc {
  [self clear];
}
@end

@interface VtkFlutterViewState : NSObject
- (instancetype)initWithRegistrar:(id<FlutterPluginRegistrar>)registrar
                  presentationApi:(const VtkFlutterPresentationApi*)presentationApi
                          session:(VtkFlutterSession*)session
                         viewport:(VtkFlutterViewport)viewport;
- (VtkFlutterFrameCallbacks)retainedFrameCallbacks;
- (int32_t)beginFrame:(const VtkFlutterViewport*)viewport
                frame:(VtkFlutterCpuFrame*)frame
               status:(VtkFlutterStatus*)status;
- (int32_t)endFrame:(const VtkFlutterFrameMetrics*)metrics status:(VtkFlutterStatus*)status;
- (void)cancelFrame;
- (BOOL)publishCompletedFrame;
- (NSDictionary*)status;
- (void)deferTargetDestruction:(VtkFlutterTextureTarget*)target
              callbackUserData:(void*)callbackUserData;
- (FlutterError*)destroyPendingTarget;
- (FlutterError*)dispose;

@property(nonatomic, readonly) const VtkFlutterPresentationApi* presentationApi;
@property(nonatomic, readonly) VtkFlutterSession* session;
@property(nonatomic) VtkFlutterTextureTarget* textureTarget;
@property(nonatomic) void* callbackUserData;
@property(nonatomic) BOOL targetAttached;
@property(nonatomic, strong) VtkFlutterExternalTexture* texture;
@property(nonatomic) int64_t textureId;
@property(nonatomic) VtkFlutterViewport viewport;
@property(nonatomic) int64_t graphicsContextGeneration;
@property(nonatomic, readonly) int64_t frameId;
@property(nonatomic, readonly) BOOL isComplete;
@end

static int32_t VtkFlutterBeginFrame(void* userData, const VtkFlutterViewport* viewport,
                                    VtkFlutterCpuFrame* frame, VtkFlutterStatus* status) {
  @autoreleasepool {
    VtkFlutterViewState* view = (__bridge VtkFlutterViewState*)userData;
    if (view == nil) {
      SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE,
                "macOS frame callback state is unavailable");
      return VTK_FLUTTER_STATUS_INVALID_STATE;
    }
    return [view beginFrame:viewport frame:frame status:status];
  }
}

static int32_t VtkFlutterEndFrame(void* userData, const VtkFlutterFrameMetrics* metrics,
                                  VtkFlutterStatus* status) {
  @autoreleasepool {
    VtkFlutterViewState* view = (__bridge VtkFlutterViewState*)userData;
    if (view == nil) {
      SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE,
                "macOS frame callback state is unavailable");
      return VTK_FLUTTER_STATUS_INVALID_STATE;
    }
    return [view endFrame:metrics status:status];
  }
}

static void VtkFlutterCancelFrame(void* userData) {
  @autoreleasepool {
    VtkFlutterViewState* view = (__bridge VtkFlutterViewState*)userData;
    [view cancelFrame];
  }
}

@implementation VtkFlutterViewState {
  id<FlutterPluginRegistrar> _registrar;
  const VtkFlutterPresentationApi* _presentationApi;
  VtkFlutterSession* _session;
  int64_t _frameId;

  CVPixelBufferPoolRef _pixelBufferPool;
  CVPixelBufferRef _inProgressPixelBuffer;
  CVPixelBufferRef _completedPixelBuffer;
  int32_t _poolWidth;
  int32_t _poolHeight;
  BOOL _frameLocked;

  VtkFlutterTextureTarget* _pendingDestroyTarget;
  void* _pendingDestroyUserData;
}

- (instancetype)initWithRegistrar:(id<FlutterPluginRegistrar>)registrar
                  presentationApi:(const VtkFlutterPresentationApi*)presentationApi
                          session:(VtkFlutterSession*)session
                         viewport:(VtkFlutterViewport)viewport {
  self = [super init];
  if (self != nil) {
    _registrar = registrar;
    _presentationApi = presentationApi;
    _session = session;
    _viewport = viewport;
    _textureId = -1;
  }
  return self;
}

- (const VtkFlutterPresentationApi*)presentationApi {
  return _presentationApi;
}

- (VtkFlutterSession*)session {
  return _session;
}

- (int64_t)frameId {
  return _frameId;
}

- (BOOL)isComplete {
  return _session != nullptr && _textureTarget != nullptr && _targetAttached && _texture != nil &&
         _textureId > 0;
}

- (VtkFlutterFrameCallbacks)retainedFrameCallbacks {
  void* userData = (__bridge_retained void*)self;
  return VtkFlutterFrameCallbacks{
      .struct_size = sizeof(VtkFlutterFrameCallbacks),
      .version = VTK_FLUTTER_FRAME_CALLBACKS_VERSION,
      .user_data = userData,
      .begin_frame = VtkFlutterBeginFrame,
      .end_frame = VtkFlutterEndFrame,
      .cancel_frame = VtkFlutterCancelFrame,
  };
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

- (NSDictionary*)status {
  return @{
    @"textureId" : @(_textureId),
    @"ready" : @(self.isComplete),
    @"initializing" : @NO,
    @"disposing" : @NO,
    @"pendingTextureUnregistrations" : @0,
    @"queuedInitializationCount" : @0,
    @"presentedFrameCount" : @(_texture.presentedFrameCount),
    @"presentedFrameId" : @(_texture.presentedFrameId),
    @"graphicsContextGeneration" : @(_graphicsContextGeneration),
    @"graphicsSupport" : @"BGRA CVPixelBuffer external texture (macOS)",
  };
}

- (int32_t)beginFrame:(const VtkFlutterViewport*)viewport
                frame:(VtkFlutterCpuFrame*)frame
               status:(VtkFlutterStatus*)status {
  @synchronized(self) {
    if (viewport == nullptr || frame == nullptr || viewport->width <= 0 || viewport->height <= 0) {
      SetStatus(status, VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
                "macOS begin_frame received an invalid viewport or frame");
      return VTK_FLUTTER_STATUS_INVALID_ARGUMENT;
    }
    if (_frameLocked || _inProgressPixelBuffer != nullptr) {
      SetStatus(status, VTK_FLUTTER_STATUS_INVALID_STATE, "macOS frame storage is already locked");
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
      CVReturn poolResult =
          CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes,
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
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool, &pixelBuffer);
    if (createResult != kCVReturnSuccess || pixelBuffer == nullptr) {
      SetStatus(status, VTK_FLUTTER_STATUS_RENDER_TARGET_UNAVAILABLE,
                "Could not acquire a macOS pixel buffer");
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
    *frame = VtkFlutterCpuFrame{
        .struct_size = sizeof(VtkFlutterCpuFrame),
        .version = VTK_FLUTTER_CPU_FRAME_VERSION,
        .pixels = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixelBuffer)),
        .capacity_bytes = CVPixelBufferGetDataSize(pixelBuffer),
        .row_bytes = CVPixelBufferGetBytesPerRow(pixelBuffer),
        .pixel_format = VTK_FLUTTER_PIXEL_FORMAT_BGRA8888,
    };
    return VTK_FLUTTER_STATUS_OK;
  }
}

- (int32_t)endFrame:(const VtkFlutterFrameMetrics*)metrics status:(VtkFlutterStatus*)status {
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

- (void)deferTargetDestruction:(VtkFlutterTextureTarget*)target
              callbackUserData:(void*)callbackUserData {
  _pendingDestroyTarget = target;
  _pendingDestroyUserData = callbackUserData;
}

- (FlutterError*)destroyPendingTarget {
  if (_pendingDestroyTarget == nullptr) return nil;
  VtkFlutterStatus status{};
  int32_t code = _presentationApi->texture_target_destroy(_pendingDestroyTarget, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    return StatusError(@"destroy deferred texture target", code, status);
  }
  _pendingDestroyTarget = nullptr;
  ReleaseCallbackUserData(_pendingDestroyUserData);
  _pendingDestroyUserData = nullptr;
  return nil;
}

- (FlutterError*)dispose {
  FlutterError* pendingError = [self destroyPendingTarget];
  if (pendingError != nil) return pendingError;

  if (_presentationApi != nullptr && _session != nullptr && _textureTarget != nullptr &&
      _targetAttached) {
    VtkFlutterStatus status{};
    int32_t code =
        _presentationApi->session_detach_texture_target(_session, _textureTarget, &status);
    if (code != VTK_FLUTTER_STATUS_OK) {
      return StatusError(@"detach texture target", code, status);
    }
    _targetAttached = NO;
  }

  if (_presentationApi != nullptr && _textureTarget != nullptr) {
    VtkFlutterStatus status{};
    int32_t code = _presentationApi->texture_target_destroy(_textureTarget, &status);
    if (code != VTK_FLUTTER_STATUS_OK) {
      return StatusError(@"destroy texture target", code, status);
    }
    _textureTarget = nullptr;
    ReleaseCallbackUserData(_callbackUserData);
    _callbackUserData = nullptr;
  }

  [self clearFrameStorage];
  if (_textureId > 0) [_registrar.textures unregisterTexture:_textureId];
  _textureId = -1;
  [_texture clear];
  _texture = nil;
  _viewport = {};
  _frameId = 0;
  _graphicsContextGeneration = 0;
  _session = nullptr;
  _presentationApi = nullptr;
  return nil;
}
@end

@interface VtkFlutterPlugin ()
- (instancetype)initWithRegistrar:(id<FlutterPluginRegistrar>)registrar;
@end

@implementation VtkFlutterPlugin {
  id<FlutterPluginRegistrar> _registrar;
  NSMutableDictionary<NSNumber*, VtkFlutterViewState*>* _views;
}

+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:@"vtk_flutter/session"
                                                              binaryMessenger:registrar.messenger];
  VtkFlutterPlugin* instance = [[VtkFlutterPlugin alloc] initWithRegistrar:registrar];
  [registrar addMethodCallDelegate:instance channel:channel];
  [registrar publish:instance];
}

- (instancetype)initWithRegistrar:(id<FlutterPluginRegistrar>)registrar {
  self = [super init];
  if (self != nil) {
    _registrar = registrar;
    _views = [[NSMutableDictionary alloc] init];
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"capabilities"]) {
    result(VtkFlutterCapabilitiesMap());
  } else if ([call.method isEqualToString:@"createView"]) {
    [self createView:call.arguments result:result];
  } else if ([call.method isEqualToString:@"presentFrame"]) {
    [self presentFrame:call.arguments result:result];
  } else if ([call.method isEqualToString:@"status"]) {
    [self status:call.arguments result:result];
  } else if ([call.method isEqualToString:@"resize"]) {
    [self resize:call.arguments result:result];
  } else if ([call.method isEqualToString:@"recreateGraphicsContext"]) {
    [self recreateGraphicsContext:call.arguments result:result];
  } else if ([call.method isEqualToString:@"disposeView"]) {
    [self disposeView:call.arguments result:result];
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (VtkFlutterViewState*)viewForArguments:(id)arguments result:(FlutterResult)result {
  NSString* message = nil;
  VtkFlutterSession* session = nullptr;
  if (!VtkFlutterDecodeNativeSession(arguments, &session, &message)) {
    result([FlutterError errorWithCode:@"invalid_native_session" message:message details:nil]);
    return nil;
  }
  VtkFlutterViewState* view = _views[SessionKey(session)];
  if (view == nil) {
    result([FlutterError errorWithCode:@"vtk_not_initialized"
                               message:@"Create a VTK view for this session first"
                               details:nil]);
  }
  return view;
}

- (void)createView:(id)arguments result:(FlutterResult)result {
  NSString* message = nil;
  VtkFlutterViewport viewport{};
  if (!VtkFlutterDecodeViewport(arguments, &viewport, &message)) {
    result([FlutterError errorWithCode:@"invalid_viewport" message:message details:nil]);
    return;
  }
  const VtkFlutterPresentationApi* presentationApi = nullptr;
  if (!VtkFlutterDecodePresentationApi(arguments, &presentationApi, &message)) {
    result([FlutterError errorWithCode:@"invalid_presentation_api" message:message details:nil]);
    return;
  }
  VtkFlutterSession* session = nullptr;
  if (!VtkFlutterDecodeNativeSession(arguments, &session, &message)) {
    result([FlutterError errorWithCode:@"invalid_native_session" message:message details:nil]);
    return;
  }

  NSNumber* key = SessionKey(session);
  VtkFlutterViewState* existing = _views[key];
  if (existing != nil) {
    if (existing.presentationApi != presentationApi) {
      result([FlutterError errorWithCode:@"invalid_state"
                                 message:@"The session view uses a different presentation API"
                                 details:nil]);
      return;
    }
    if (!existing.isComplete) {
      result([FlutterError errorWithCode:@"invalid_state"
                                 message:@"Dispose the incomplete macOS VTK view before retrying"
                                 details:nil]);
      return;
    }
    existing.viewport = viewport;
    result(@{@"textureId" : @(existing.textureId)});
    return;
  }

  VtkFlutterViewState* view = [[VtkFlutterViewState alloc] initWithRegistrar:_registrar
                                                             presentationApi:presentationApi
                                                                     session:session
                                                                    viewport:viewport];
  view.texture = [[VtkFlutterExternalTexture alloc] init];
  VtkFlutterFrameCallbacks callbacks = [view retainedFrameCallbacks];
  VtkFlutterStatus status{};
  VtkFlutterTextureTarget* textureTarget = nullptr;
  int32_t code = presentationApi->texture_target_create(&callbacks, &textureTarget, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    ReleaseCallbackUserData(callbacks.user_data);
    result(StatusError(@"create texture target", code, status));
    return;
  }
  if (textureTarget == nullptr) {
    ReleaseCallbackUserData(callbacks.user_data);
    result([FlutterError errorWithCode:@"invalid_state"
                               message:@"Native VTK created no macOS texture target"
                               details:nil]);
    return;
  }
  view.textureTarget = textureTarget;
  view.callbackUserData = callbacks.user_data;

  status = {};
  code = presentationApi->session_attach_texture_target(session, textureTarget, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    VtkFlutterStatus destroyStatus{};
    int32_t destroyCode = presentationApi->texture_target_destroy(textureTarget, &destroyStatus);
    if (destroyCode == VTK_FLUTTER_STATUS_OK) {
      view.textureTarget = nullptr;
      ReleaseCallbackUserData(view.callbackUserData);
      view.callbackUserData = nullptr;
    } else {
      _views[key] = view;
    }
    result(StatusError(@"attach texture target", code, status));
    return;
  }
  view.targetAttached = YES;

  int64_t textureId = [_registrar.textures registerTexture:view.texture];
  // Flutter's macOS registrar returns zero when engine registration fails.
  if (textureId <= 0) {
    VtkFlutterStatus detachStatus{};
    code = presentationApi->session_detach_texture_target(session, textureTarget, &detachStatus);
    if (code != VTK_FLUTTER_STATUS_OK) {
      _views[key] = view;
      result(StatusError(@"roll back texture target attachment", code, detachStatus));
      return;
    }
    view.targetAttached = NO;
    VtkFlutterStatus destroyStatus{};
    code = presentationApi->texture_target_destroy(textureTarget, &destroyStatus);
    if (code != VTK_FLUTTER_STATUS_OK) {
      _views[key] = view;
      result(StatusError(@"destroy unregistered texture target", code, destroyStatus));
      return;
    }
    view.textureTarget = nullptr;
    ReleaseCallbackUserData(view.callbackUserData);
    view.callbackUserData = nullptr;
    result([FlutterError errorWithCode:@"vtk_create_failed"
                               message:@"Flutter rejected the macOS external texture"
                               details:nil]);
    return;
  }

  view.textureId = textureId;
  view.graphicsContextGeneration = 1;
  _views[key] = view;
  result(@{@"textureId" : @(textureId)});
}

- (void)presentFrame:(id)arguments result:(FlutterResult)result {
  VtkFlutterViewState* view = [self viewForArguments:arguments result:result];
  if (view == nil) return;
  if (!view.isComplete) {
    result([FlutterError errorWithCode:@"vtk_not_initialized"
                               message:@"Complete the VTK view before presenting"
                               details:nil]);
    return;
  }
  if (![view publishCompletedFrame]) {
    result([FlutterError errorWithCode:@"vtk_render_failed"
                               message:@"VTK produced no macOS pixel buffer"
                               details:nil]);
    return;
  }
  NSDictionary* status = [view status];
  result(@{
    @"frameId" : @(view.frameId),
    @"presentedFrameCount" : status[@"presentedFrameCount"],
    @"presentedFrameId" : status[@"presentedFrameId"],
    @"graphicsContextGeneration" : status[@"graphicsContextGeneration"],
    @"handoffMode" : [NSString stringWithUTF8String:kHandoffMode],
  });
}

- (void)status:(id)arguments result:(FlutterResult)result {
  VtkFlutterViewState* view = [self viewForArguments:arguments result:result];
  if (view != nil) result([view status]);
}

- (void)resize:(id)arguments result:(FlutterResult)result {
  VtkFlutterViewState* view = [self viewForArguments:arguments result:result];
  if (view == nil) return;
  NSString* message = nil;
  VtkFlutterViewport viewport{};
  if (!VtkFlutterDecodeViewport(arguments, &viewport, &message)) {
    result([FlutterError errorWithCode:@"invalid_viewport" message:message details:nil]);
    return;
  }
  view.viewport = viewport;
  result(nil);
}

- (void)recreateGraphicsContext:(id)arguments result:(FlutterResult)result {
  VtkFlutterViewState* view = [self viewForArguments:arguments result:result];
  if (view == nil) return;
  if (!view.isComplete) {
    result([FlutterError errorWithCode:@"vtk_not_initialized"
                               message:@"Complete the VTK view before recreating graphics"
                               details:nil]);
    return;
  }

  FlutterError* pendingError = [view destroyPendingTarget];
  if (pendingError != nil) {
    result(pendingError);
    return;
  }

  VtkFlutterFrameCallbacks callbacks = [view retainedFrameCallbacks];
  VtkFlutterStatus status{};
  VtkFlutterTextureTarget* newTarget = nullptr;
  int32_t code = view.presentationApi->texture_target_create(&callbacks, &newTarget, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    ReleaseCallbackUserData(callbacks.user_data);
    result(StatusError(@"recreate texture target", code, status));
    return;
  }
  if (newTarget == nullptr) {
    ReleaseCallbackUserData(callbacks.user_data);
    result([FlutterError errorWithCode:@"invalid_state"
                               message:@"Native VTK recreated no macOS texture target"
                               details:nil]);
    return;
  }

  status = {};
  code = view.presentationApi->session_detach_texture_target(view.session, view.textureTarget,
                                                             &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    VtkFlutterStatus destroyStatus{};
    int32_t destroyCode = view.presentationApi->texture_target_destroy(newTarget, &destroyStatus);
    if (destroyCode == VTK_FLUTTER_STATUS_OK) {
      ReleaseCallbackUserData(callbacks.user_data);
    } else {
      [view deferTargetDestruction:newTarget callbackUserData:callbacks.user_data];
    }
    result(StatusError(@"detach texture target", code, status));
    return;
  }
  view.targetAttached = NO;

  status = {};
  code = view.presentationApi->session_attach_texture_target(view.session, newTarget, &status);
  if (code != VTK_FLUTTER_STATUS_OK) {
    VtkFlutterStatus restoreStatus{};
    int32_t restoreCode = view.presentationApi->session_attach_texture_target(
        view.session, view.textureTarget, &restoreStatus);
    view.targetAttached = restoreCode == VTK_FLUTTER_STATUS_OK;
    VtkFlutterStatus destroyStatus{};
    int32_t destroyCode = view.presentationApi->texture_target_destroy(newTarget, &destroyStatus);
    if (destroyCode == VTK_FLUTTER_STATUS_OK) {
      ReleaseCallbackUserData(callbacks.user_data);
    } else {
      [view deferTargetDestruction:newTarget callbackUserData:callbacks.user_data];
    }
    result(StatusError(@"attach recreated texture target", code, status));
    return;
  }

  VtkFlutterTextureTarget* oldTarget = view.textureTarget;
  void* oldUserData = view.callbackUserData;
  VtkFlutterStatus destroyStatus{};
  code = view.presentationApi->texture_target_destroy(oldTarget, &destroyStatus);
  if (code != VTK_FLUTTER_STATUS_OK) {
    view.textureTarget = newTarget;
    view.callbackUserData = callbacks.user_data;
    view.targetAttached = YES;
    view.graphicsContextGeneration = view.graphicsContextGeneration + 1;
    [view deferTargetDestruction:oldTarget callbackUserData:oldUserData];
    result(@{
      @"graphicsContextGeneration" : @(view.graphicsContextGeneration),
      @"cleanupPending" : @YES,
    });
    return;
  }
  ReleaseCallbackUserData(oldUserData);
  view.textureTarget = newTarget;
  view.callbackUserData = callbacks.user_data;
  view.targetAttached = YES;
  view.graphicsContextGeneration = view.graphicsContextGeneration + 1;
  result(@{
    @"graphicsContextGeneration" : @(view.graphicsContextGeneration),
    @"cleanupPending" : @NO,
  });
}

- (void)disposeView:(id)arguments result:(FlutterResult)result {
  NSString* message = nil;
  VtkFlutterSession* session = nullptr;
  if (!VtkFlutterDecodeNativeSession(arguments, &session, &message)) {
    result([FlutterError errorWithCode:@"invalid_native_session" message:message details:nil]);
    return;
  }
  NSNumber* key = SessionKey(session);
  VtkFlutterViewState* view = _views[key];
  if (view == nil) {
    result(nil);
    return;
  }
  FlutterError* error = [view dispose];
  if (error == nil) [_views removeObjectForKey:key];
  result(error);
}

- (void)dealloc {
  for (VtkFlutterViewState* view in _views.allValues) {
    FlutterError* error = [view dispose];
    if (error != nil) {
      NSLog(@"[vtk_flutter] dispose during plugin dealloc failed: %@ (%@)",
            error.code, error.message);
    }
  }
}
@end
