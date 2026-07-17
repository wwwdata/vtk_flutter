#import <XCTest/XCTest.h>

#import "../vtk_flutter/Sources/vtk_flutter/VtkFlutterProtocol.h"

namespace {
template <typename Function>
Function NonNullFunction() {
  return reinterpret_cast<Function>(static_cast<uintptr_t>(1));
}

VtkFlutterPresentationApi CompletePresentationApi() {
  VtkFlutterPresentationApi api{};
  api.struct_size = sizeof(api);
  api.version = VTK_FLUTTER_PRESENTATION_API_VERSION;
  api.status_clear = NonNullFunction<decltype(api.status_clear)>();
  api.session_attach_texture_target =
      NonNullFunction<decltype(api.session_attach_texture_target)>();
  api.session_detach_texture_target =
      NonNullFunction<decltype(api.session_detach_texture_target)>();
  api.texture_target_create =
      NonNullFunction<decltype(api.texture_target_create)>();
  api.texture_target_destroy =
      NonNullFunction<decltype(api.texture_target_destroy)>();
  return api;
}
}  // namespace

@interface VtkFlutterProtocolTests : XCTestCase
@end

@implementation VtkFlutterProtocolTests

- (void)testCapabilitiesArePresentationOnly {
  NSDictionary* capabilities = VtkFlutterCapabilitiesMap();
  XCTAssertEqualObjects(capabilities[@"supportsExternalTexture"], @YES);
  XCTAssertNil(capabilities[@"renderModes"]);
  XCTAssertNil(capabilities[@"maxVolumeBytes"]);
}

- (void)testValidatesTheV1PresentationApiAddressAndTable {
  const VtkFlutterPresentationApi* decoded = nullptr;
  NSString* error = nil;
  XCTAssertFalse(VtkFlutterDecodePresentationApi(@{}, &decoded, &error));
  XCTAssertEqualObjects(
      error, @"presentationApiAddress must be a positive integer");

  VtkFlutterPresentationApi api = CompletePresentationApi();
  NSNumber* address =
      @(static_cast<uint64_t>(reinterpret_cast<uintptr_t>(&api)));
  XCTAssertTrue(VtkFlutterDecodePresentationApi(
      @{@"presentationApiAddress" : address}, &decoded, &error));
  XCTAssertEqual(decoded, &api);

  api.version = VTK_FLUTTER_PRESENTATION_API_VERSION + 1;
  XCTAssertFalse(VtkFlutterDecodePresentationApi(
      @{@"presentationApiAddress" : address}, &decoded, &error));
  XCTAssertEqualObjects(error, @"Unsupported VTK presentation API version");

  api.version = VTK_FLUTTER_PRESENTATION_API_VERSION;
  api.struct_size =
      offsetof(VtkFlutterPresentationApi, texture_target_destroy);
  XCTAssertFalse(VtkFlutterDecodePresentationApi(
      @{@"presentationApiAddress" : address}, &decoded, &error));
  XCTAssertEqualObjects(error, @"VTK presentation API table is too small");

  api.struct_size = sizeof(api);
  api.texture_target_destroy = nullptr;
  XCTAssertFalse(VtkFlutterDecodePresentationApi(
      @{@"presentationApiAddress" : address}, &decoded, &error));
  XCTAssertEqualObjects(error, @"VTK presentation API table is incomplete");
}

- (void)testDecodesTheDartOwnedNativeSessionAddress {
  VtkFlutterSession* decoded = nullptr;
  NSString* error = nil;
  XCTAssertFalse(VtkFlutterDecodeNativeSession(@{}, &decoded, &error));
  XCTAssertEqualObjects(error,
                        @"nativeSessionAddress must be a positive integer");
  XCTAssertFalse(VtkFlutterDecodeNativeSession(
      @{@"nativeSessionAddress" : @YES}, &decoded, &error));
  XCTAssertFalse(VtkFlutterDecodeNativeSession(
      @{@"nativeSessionAddress" : @4096.0}, &decoded, &error));

  auto* session = reinterpret_cast<VtkFlutterSession*>(
      static_cast<uintptr_t>(0x1234));
  NSNumber* address =
      @(static_cast<uint64_t>(reinterpret_cast<uintptr_t>(session)));
  XCTAssertTrue(VtkFlutterDecodeNativeSession(
      @{@"nativeSessionAddress" : address}, &decoded, &error));
  XCTAssertEqual(decoded, session);
}

- (void)testDecodesAndValidatesTheViewport {
  VtkFlutterViewport viewport{};
  NSString* error = nil;
  XCTAssertTrue(VtkFlutterDecodeViewport(
      @{@"width" : @640, @"height" : @320}, &viewport, &error));
  XCTAssertEqual(viewport.width, 640);
  XCTAssertEqual(viewport.height, 320);

  XCTAssertFalse(VtkFlutterDecodeViewport(
      @{@"width" : @YES, @"height" : @320}, &viewport, &error));
  XCTAssertEqualObjects(error,
                        @"Viewport width and height must be numbers");
  XCTAssertFalse(VtkFlutterDecodeViewport(
      @{@"width" : @0, @"height" : @320}, &viewport, &error));
  XCTAssertEqualObjects(error,
                        @"Viewport width and height must be positive");
}

@end
