#import <XCTest/XCTest.h>

#import <Flutter/Flutter.h>

#import "../vtk_flutter/Sources/vtk_flutter/VtkFlutterProtocol.h"
#import "../vtk_flutter/Sources/vtk_flutter/include/vtk_flutter/VtkFlutterPlugin.h"

#include <cstdint>
#include <cstdio>
#include <vector>

@interface VtkFlutterPlugin (Testing)
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;
@end

namespace {
struct FakeTarget {
  VtkFlutterFrameCallbacks callbacks;
  VtkFlutterSession* session;
};

std::vector<FakeTarget*> gTargets;
std::vector<VtkFlutterSession*> gDestroyedTargetSessions;
FakeTarget* gDestroyFailureTarget;
int gDestroyFailuresRemaining;
VtkFlutterSession* gAttachFailureSession;
int gAttachFailuresRemaining;
int gDestroyAnyFailuresRemaining;

void StatusClear(VtkFlutterStatus* status) {
  if (status != nullptr) *status = {};
}

int32_t SessionIsValid(VtkFlutterSession* session, VtkFlutterStatus* status) {
  StatusClear(status);
  return session == nullptr ? VTK_FLUTTER_STATUS_INVALID_ARGUMENT : VTK_FLUTTER_STATUS_OK;
}

int32_t AttachTarget(VtkFlutterSession* session, VtkFlutterTextureTarget* target,
                     VtkFlutterStatus* status) {
  StatusClear(status);
  if (session == gAttachFailureSession && gAttachFailuresRemaining > 0) {
    --gAttachFailuresRemaining;
    status->code = VTK_FLUTTER_STATUS_INTERNAL_ERROR;
    std::snprintf(status->message, sizeof(status->message), "%s",
                  "Injected texture target attachment failure");
    return VTK_FLUTTER_STATUS_INTERNAL_ERROR;
  }
  reinterpret_cast<FakeTarget*>(target)->session = session;
  return VTK_FLUTTER_STATUS_OK;
}

int32_t DetachTarget(VtkFlutterSession* session, VtkFlutterTextureTarget* target,
                     VtkFlutterStatus* status) {
  StatusClear(status);
  auto* fakeTarget = reinterpret_cast<FakeTarget*>(target);
  if (fakeTarget->session != session) return VTK_FLUTTER_STATUS_INVALID_STATE;
  fakeTarget->session = nullptr;
  return VTK_FLUTTER_STATUS_OK;
}

int32_t CreateTarget(const VtkFlutterFrameCallbacks* callbacks, VtkFlutterTextureTarget** target,
                     VtkFlutterStatus* status) {
  StatusClear(status);
  auto* fakeTarget = new FakeTarget{.callbacks = *callbacks, .session = nullptr};
  gTargets.push_back(fakeTarget);
  *target = reinterpret_cast<VtkFlutterTextureTarget*>(fakeTarget);
  return VTK_FLUTTER_STATUS_OK;
}

int32_t DestroyTarget(VtkFlutterTextureTarget* target, VtkFlutterStatus* status) {
  StatusClear(status);
  auto* fakeTarget = reinterpret_cast<FakeTarget*>(target);
  if (gDestroyAnyFailuresRemaining > 0 ||
      (fakeTarget == gDestroyFailureTarget && gDestroyFailuresRemaining > 0)) {
    if (gDestroyAnyFailuresRemaining > 0) {
      --gDestroyAnyFailuresRemaining;
    } else {
      --gDestroyFailuresRemaining;
    }
    status->code = VTK_FLUTTER_STATUS_INTERNAL_ERROR;
    std::snprintf(status->message, sizeof(status->message), "%s",
                  "Injected texture target destruction failure");
    return VTK_FLUTTER_STATUS_INTERNAL_ERROR;
  }
  gDestroyedTargetSessions.push_back(fakeTarget->session);
  delete fakeTarget;
  return VTK_FLUTTER_STATUS_OK;
}

VtkFlutterPresentationApi PresentationApi() {
  return VtkFlutterPresentationApi{
      .struct_size = sizeof(VtkFlutterPresentationApi),
      .version = VTK_FLUTTER_PRESENTATION_API_VERSION,
      .status_clear = StatusClear,
      .session_is_valid = SessionIsValid,
      .session_attach_texture_target = AttachTarget,
      .session_detach_texture_target = DetachTarget,
      .texture_target_create = CreateTarget,
      .texture_target_destroy = DestroyTarget,
  };
}

NSNumber* Address(const void* pointer) {
  return @(static_cast<uint64_t>(reinterpret_cast<uintptr_t>(pointer)));
}
}  // namespace

@interface FakeTextureRegistry : NSObject <FlutterTextureRegistry>
@property(nonatomic, readonly) NSMutableDictionary<NSNumber*, id<FlutterTexture>>* textures;
@property(nonatomic, readonly) NSMutableArray<NSNumber*>* unregisteredTextureIds;
@property(nonatomic) int registrationFailuresRemaining;
@end

@implementation FakeTextureRegistry {
  int64_t _nextTextureId;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _nextTextureId = 0;
    _textures = [[NSMutableDictionary alloc] init];
    _unregisteredTextureIds = [[NSMutableArray alloc] init];
  }
  return self;
}

- (int64_t)registerTexture:(id<FlutterTexture>)texture {
  if (_registrationFailuresRemaining > 0) {
    --_registrationFailuresRemaining;
    return -1;
  }
  int64_t textureId = _nextTextureId++;
  _textures[@(textureId)] = texture;
  return textureId;
}

- (void)textureFrameAvailable:(int64_t)textureId {
  CVPixelBufferRef pixelBuffer = [_textures[@(textureId)] copyPixelBuffer];
  if (pixelBuffer != nullptr) CVPixelBufferRelease(pixelBuffer);
}

- (void)unregisterTexture:(int64_t)textureId {
  [_unregisteredTextureIds addObject:@(textureId)];
  [_textures removeObjectForKey:@(textureId)];
}
@end

@interface FakePluginRegistrar : NSObject <FlutterPluginRegistrar>
@property(nonatomic, readonly) FakeTextureRegistry* fakeTextures;
@end

@implementation FakePluginRegistrar

- (instancetype)init {
  self = [super init];
  if (self != nil) _fakeTextures = [[FakeTextureRegistry alloc] init];
  return self;
}

- (NSObject<FlutterTextureRegistry>*)textures {
  return _fakeTextures;
}
- (NSObject<FlutterBinaryMessenger>*)messenger {
  return nil;
}
- (UIViewController*)viewController {
  return nil;
}
- (void)addMethodCallDelegate:(NSObject<FlutterPlugin>*)delegate channel:(FlutterMethodChannel*)channel {
}
- (void)addApplicationDelegate:(NSObject<FlutterPlugin>*)delegate {
}
- (void)addSceneDelegate:(NSObject<FlutterSceneLifeCycleDelegate>*)delegate {
}
- (void)registerViewFactory:(NSObject<FlutterPlatformViewFactory>*)factory
                     withId:(NSString*)factoryId {
}
- (void)registerViewFactory:(NSObject<FlutterPlatformViewFactory>*)factory
                              withId:(NSString*)factoryId
    gestureRecognizersBlockingPolicy:
        (FlutterPlatformViewGestureRecognizersBlockingPolicy)gestureRecognizersBlockingPolicy {
}
- (void)publish:(NSObject*)value {
}
- (NSString*)lookupKeyForAsset:(NSString*)asset {
  return asset;
}
- (NSString*)lookupKeyForAsset:(NSString*)asset fromPackage:(NSString*)package {
  return asset;
}
- (NSObject*)valuePublishedByPlugin:(NSString*)pluginKey {
  return nil;
}
@end

@interface VtkFlutterPluginTests : XCTestCase
@end

@implementation VtkFlutterPluginTests

- (void)setUp {
  [super setUp];
  gTargets.clear();
  gDestroyedTargetSessions.clear();
  gDestroyFailureTarget = nullptr;
  gDestroyFailuresRemaining = 0;
  gAttachFailureSession = nullptr;
  gAttachFailuresRemaining = 0;
  gDestroyAnyFailuresRemaining = 0;
}

- (id)invokePlugin:(VtkFlutterPlugin*)plugin
            method:(NSString*)method
         arguments:(NSDictionary*)arguments {
  __block BOOL completed = NO;
  __block id response = nil;
  FlutterMethodCall* call = [FlutterMethodCall methodCallWithMethodName:method arguments:arguments];
  [plugin handleMethodCall:call
                    result:^(id value) {
                      completed = YES;
                      response = value;
                    }];
  XCTAssertTrue(completed);
  XCTAssertFalse([response isKindOfClass:FlutterError.class]);
  return response;
}

- (FlutterError*)invokePluginExpectingError:(VtkFlutterPlugin*)plugin
                                     method:(NSString*)method
                                  arguments:(NSDictionary*)arguments {
  __block BOOL completed = NO;
  __block id response = nil;
  FlutterMethodCall* call = [FlutterMethodCall methodCallWithMethodName:method arguments:arguments];
  [plugin handleMethodCall:call
                    result:^(id value) {
                      completed = YES;
                      response = value;
                    }];
  XCTAssertTrue(completed);
  XCTAssertTrue([response isKindOfClass:FlutterError.class]);
  return response;
}

- (void)completeFrameForTarget:(FakeTarget*)target width:(int32_t)width {
  VtkFlutterViewport viewport{.width = width, .height = 8};
  VtkFlutterCpuFrame frame{};
  VtkFlutterStatus status{};
  XCTAssertEqual(
      target->callbacks.begin_frame(target->callbacks.user_data, &viewport, &frame, &status),
      VTK_FLUTTER_STATUS_OK);
  XCTAssertNotEqual(frame.pixels, nullptr);
  frame.pixels[0] = static_cast<uint8_t>(width);
  VtkFlutterFrameMetrics metrics{};
  XCTAssertEqual(target->callbacks.end_frame(target->callbacks.user_data, &metrics, &status),
                 VTK_FLUTTER_STATUS_OK);
}

- (void)testTwoSessionsOwnIndependentViewLifecycles {
  FakePluginRegistrar* registrar = [[FakePluginRegistrar alloc] init];
  VtkFlutterPlugin* plugin = [[VtkFlutterPlugin alloc] initWithRegistrar:registrar];
  VtkFlutterPresentationApi api = PresentationApi();
  auto* firstSession = reinterpret_cast<VtkFlutterSession*>(static_cast<uintptr_t>(0x1000));
  auto* secondSession = reinterpret_cast<VtkFlutterSession*>(static_cast<uintptr_t>(0x2000));
  NSDictionary* firstAddress = @{@"nativeSessionAddress" : Address(firstSession)};
  NSDictionary* secondAddress = @{@"nativeSessionAddress" : Address(secondSession)};

  NSDictionary* firstView = [self invokePlugin:plugin
                                        method:@"createView"
                                     arguments:@{
                                       @"width" : @16,
                                       @"height" : @8,
                                       @"presentationApiAddress" : Address(&api),
                                       @"nativeSessionAddress" : Address(firstSession),
                                     }];
  NSDictionary* secondView = [self invokePlugin:plugin
                                         method:@"createView"
                                      arguments:@{
                                        @"width" : @24,
                                        @"height" : @8,
                                        @"presentationApiAddress" : Address(&api),
                                        @"nativeSessionAddress" : Address(secondSession),
                                      }];
  XCTAssertEqualObjects(firstView[@"textureId"], @0);
  XCTAssertEqualObjects(secondView[@"textureId"], @1);
  XCTAssertEqual(gTargets.size(), 2U);
  XCTAssertNotEqual(gTargets[0]->callbacks.user_data, gTargets[1]->callbacks.user_data);

  NSDictionary* repeatedFirstView = [self invokePlugin:plugin
                                                 method:@"createView"
                                              arguments:@{
                                                @"width" : @32,
                                                @"height" : @8,
                                                @"presentationApiAddress" : Address(&api),
                                                @"nativeSessionAddress" : Address(firstSession),
                                              }];
  XCTAssertEqualObjects(repeatedFirstView[@"textureId"], @0);
  XCTAssertEqual(gTargets.size(), 2U);

  [self completeFrameForTarget:gTargets[0] width:16];
  [self completeFrameForTarget:gTargets[1] width:24];
  [self invokePlugin:plugin method:@"presentFrame" arguments:firstAddress];
  [self invokePlugin:plugin method:@"presentFrame" arguments:firstAddress];
  [self invokePlugin:plugin method:@"presentFrame" arguments:secondAddress];

  NSDictionary* firstStatus = [self invokePlugin:plugin method:@"status" arguments:firstAddress];
  NSDictionary* secondStatus = [self invokePlugin:plugin method:@"status" arguments:secondAddress];
  XCTAssertEqualObjects(firstStatus[@"presentedFrameCount"], @2);
  XCTAssertEqualObjects(firstStatus[@"presentedFrameId"], @2);
  XCTAssertEqualObjects(secondStatus[@"presentedFrameCount"], @1);
  XCTAssertEqualObjects(secondStatus[@"presentedFrameId"], @1);

  [self invokePlugin:plugin
              method:@"resize"
           arguments:@{
             @"nativeSessionAddress" : Address(firstSession),
             @"width" : @32,
             @"height" : @8,
           }];
  NSDictionary* recreation = [self invokePlugin:plugin
                                         method:@"recreateGraphicsContext"
                                      arguments:secondAddress];
  XCTAssertEqualObjects(recreation[@"graphicsContextGeneration"], @2);
  XCTAssertEqual(gTargets.size(), 3U);
  XCTAssertEqual(gTargets[2]->session, secondSession);

  [self invokePlugin:plugin method:@"disposeView" arguments:firstAddress];
  XCTAssertEqualObjects(registrar.fakeTextures.unregisteredTextureIds, (@[ @0 ]));
  secondStatus = [self invokePlugin:plugin method:@"status" arguments:secondAddress];
  XCTAssertEqualObjects(secondStatus[@"ready"], @YES);

  auto* unknownSession = reinterpret_cast<VtkFlutterSession*>(static_cast<uintptr_t>(0x4000));
  [self invokePlugin:plugin
              method:@"disposeView"
           arguments:@{@"nativeSessionAddress" : Address(unknownSession)}];
  XCTAssertEqualObjects(registrar.fakeTextures.unregisteredTextureIds, (@[ @0 ]));

  [self invokePlugin:plugin method:@"disposeView" arguments:secondAddress];
  XCTAssertEqualObjects(registrar.fakeTextures.unregisteredTextureIds, (@[ @0, @1 ]));
  XCTAssertEqual(gDestroyedTargetSessions.size(), 3U);
}

- (void)testFailedViewDisposalRemainsRetryable {
  FakePluginRegistrar* registrar = [[FakePluginRegistrar alloc] init];
  VtkFlutterPlugin* plugin = [[VtkFlutterPlugin alloc] initWithRegistrar:registrar];
  VtkFlutterPresentationApi api = PresentationApi();
  auto* session = reinterpret_cast<VtkFlutterSession*>(static_cast<uintptr_t>(0x5000));
  NSDictionary* address = @{@"nativeSessionAddress" : Address(session)};

  [self invokePlugin:plugin
              method:@"createView"
           arguments:@{
             @"width" : @16,
             @"height" : @8,
             @"presentationApiAddress" : Address(&api),
             @"nativeSessionAddress" : Address(session),
           }];
  gDestroyFailureTarget = gTargets[0];
  gDestroyFailuresRemaining = 1;

  FlutterError* firstError =
      [self invokePluginExpectingError:plugin method:@"disposeView" arguments:address];
  XCTAssertEqualObjects(firstError.code, @"vtk_internal_error");
  XCTAssertTrue(registrar.fakeTextures.unregisteredTextureIds.count == 0);
  XCTAssertEqual(gTargets[0]->session, nullptr);

  FlutterError* incompleteError = [self invokePluginExpectingError:plugin
                                                            method:@"createView"
                                                         arguments:@{
                                                           @"width" : @16,
                                                           @"height" : @8,
                                                           @"presentationApiAddress" : Address(&api),
                                                           @"nativeSessionAddress" : Address(session),
                                                         }];
  XCTAssertEqualObjects(incompleteError.code, @"invalid_state");

  [self invokePlugin:plugin method:@"disposeView" arguments:address];
  XCTAssertEqualObjects(registrar.fakeTextures.unregisteredTextureIds, (@[ @0 ]));
  XCTAssertEqual(gDestroyedTargetSessions.size(), 1U);
}

- (void)testIncompleteCreateCleanupRemainsAddressableAndRetryable {
  FakePluginRegistrar* registrar = [[FakePluginRegistrar alloc] init];
  VtkFlutterPlugin* plugin = [[VtkFlutterPlugin alloc] initWithRegistrar:registrar];
  VtkFlutterPresentationApi api = PresentationApi();
  auto* session = reinterpret_cast<VtkFlutterSession*>(static_cast<uintptr_t>(0x2900));
  NSDictionary* address = @{@"nativeSessionAddress" : Address(session)};
  gAttachFailureSession = session;
  gAttachFailuresRemaining = 1;
  gDestroyAnyFailuresRemaining = 2;

  FlutterError* createError = [self invokePluginExpectingError:plugin
                                                       method:@"createView"
                                                    arguments:@{
                                                      @"width" : @16,
                                                      @"height" : @8,
                                                      @"presentationApiAddress" : Address(&api),
                                                      @"nativeSessionAddress" : Address(session),
                                                    }];
  XCTAssertEqualObjects(createError.code, @"vtk_internal_error");
  XCTAssertEqual(gTargets.size(), 1U);
  XCTAssertEqual(registrar.fakeTextures.textures.count, 0U);

  FlutterError* firstDispose =
      [self invokePluginExpectingError:plugin method:@"disposeView" arguments:address];
  XCTAssertEqualObjects(firstDispose.code, @"vtk_internal_error");
  [self invokePlugin:plugin method:@"disposeView" arguments:address];
  [self invokePlugin:plugin method:@"disposeView" arguments:address];
  XCTAssertEqual(gDestroyedTargetSessions.size(), 1U);
  XCTAssertEqual(gDestroyedTargetSessions.front(), nullptr);
}

- (void)testRejectedTextureRegistrationRollsBackWithoutRetainingAView {
  FakePluginRegistrar* registrar = [[FakePluginRegistrar alloc] init];
  registrar.fakeTextures.registrationFailuresRemaining = 1;
  VtkFlutterPlugin* plugin = [[VtkFlutterPlugin alloc] initWithRegistrar:registrar];
  VtkFlutterPresentationApi api = PresentationApi();
  auto* session = reinterpret_cast<VtkFlutterSession*>(static_cast<uintptr_t>(0x2A00));
  NSDictionary* arguments = @{
    @"width" : @16,
    @"height" : @8,
    @"presentationApiAddress" : Address(&api),
    @"nativeSessionAddress" : Address(session),
  };

  FlutterError* error =
      [self invokePluginExpectingError:plugin method:@"createView" arguments:arguments];
  XCTAssertEqualObjects(error.code, @"vtk_create_failed");
  XCTAssertEqual(registrar.fakeTextures.textures.count, 0U);
  XCTAssertEqual(gDestroyedTargetSessions.size(), 1U);

  NSDictionary* replacement =
      [self invokePlugin:plugin method:@"createView" arguments:arguments];
  XCTAssertEqualObjects(replacement[@"textureId"], @0);
  [self invokePlugin:plugin
              method:@"disposeView"
           arguments:@{@"nativeSessionAddress" : Address(session)}];
}

- (void)testFailedReplacedTargetDestructionIsTrackedAndRetried {
  FakePluginRegistrar* registrar = [[FakePluginRegistrar alloc] init];
  VtkFlutterPlugin* plugin = [[VtkFlutterPlugin alloc] initWithRegistrar:registrar];
  VtkFlutterPresentationApi api = PresentationApi();
  auto* session = reinterpret_cast<VtkFlutterSession*>(static_cast<uintptr_t>(0x3000));
  NSDictionary* address = @{@"nativeSessionAddress" : Address(session)};

  [self invokePlugin:plugin
              method:@"createView"
           arguments:@{
             @"width" : @16,
             @"height" : @8,
             @"presentationApiAddress" : Address(&api),
             @"nativeSessionAddress" : Address(session),
           }];
  XCTAssertEqual(gTargets.size(), 1U);
  gDestroyFailureTarget = gTargets[0];
  gDestroyFailuresRemaining = 2;

  NSDictionary* firstRecreation = [self invokePlugin:plugin
                                              method:@"recreateGraphicsContext"
                                           arguments:address];
  XCTAssertEqualObjects(firstRecreation[@"graphicsContextGeneration"], @2);
  XCTAssertEqualObjects(firstRecreation[@"cleanupPending"], @YES);
  XCTAssertEqual(gTargets.size(), 2U);
  NSDictionary* status = [self invokePlugin:plugin method:@"status" arguments:address];
  XCTAssertEqualObjects(status[@"ready"], @YES);
  XCTAssertEqualObjects(status[@"graphicsContextGeneration"], @2);

  [self completeFrameForTarget:gTargets[1] width:16];
  [self invokePlugin:plugin method:@"presentFrame" arguments:address];

  [self invokePluginExpectingError:plugin method:@"recreateGraphicsContext" arguments:address];
  XCTAssertEqual(gTargets.size(), 2U);
  status = [self invokePlugin:plugin method:@"status" arguments:address];
  XCTAssertEqualObjects(status[@"graphicsContextGeneration"], @2);

  NSDictionary* recreation = [self invokePlugin:plugin
                                         method:@"recreateGraphicsContext"
                                      arguments:address];
  XCTAssertEqualObjects(recreation[@"graphicsContextGeneration"], @3);
  XCTAssertEqualObjects(recreation[@"cleanupPending"], @NO);
  XCTAssertEqual(gTargets.size(), 3U);

  [self invokePlugin:plugin method:@"disposeView" arguments:address];
  XCTAssertEqualObjects(registrar.fakeTextures.unregisteredTextureIds, (@[ @0 ]));
  XCTAssertEqual(gDestroyedTargetSessions.size(), 3U);
}

@end
