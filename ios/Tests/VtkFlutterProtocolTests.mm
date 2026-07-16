#import <Flutter/Flutter.h>
#import <XCTest/XCTest.h>

#import "../vtk_flutter/Sources/vtk_flutter/VtkFlutterProtocol.h"

#include <vector>

namespace {
template <typename Function>
Function NonNullFunction() {
  return reinterpret_cast<Function>(static_cast<uintptr_t>(1));
}

VtkFlutterCoreApiV2 CompleteCoreApi() {
  VtkFlutterCoreApiV2 api{};
  api.struct_size = sizeof(api);
  api.version = VTK_FLUTTER_CORE_API_VERSION_2;
  api.status_clear = NonNullFunction<decltype(api.status_clear)>();
  api.session_create = NonNullFunction<decltype(api.session_create)>();
  api.session_destroy = NonNullFunction<decltype(api.session_destroy)>();
  api.validate_volume = NonNullFunction<decltype(api.validate_volume)>();
  api.session_set_volume = NonNullFunction<decltype(api.session_set_volume)>();
  api.validate_render_request =
      NonNullFunction<decltype(api.validate_render_request)>();
  api.session_render = NonNullFunction<decltype(api.session_render)>();
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

- (FlutterStandardTypedData*)doubles:(NSArray<NSNumber*>*)values {
  std::vector<double> doubles;
  doubles.reserve(values.count);
  for (NSNumber* value in values) doubles.push_back(value.doubleValue);
  NSData* data = [NSData dataWithBytes:doubles.data()
                                length:doubles.size() * sizeof(double)];
  return [FlutterStandardTypedData typedDataWithFloat64:data];
}

- (void)testCapabilitiesExposeAllThreeModes {
  NSDictionary* capabilities = VtkFlutterCapabilitiesMap();
  XCTAssertEqualObjects(capabilities[@"renderModes"], (@[ @1, @2, @3 ]));
  XCTAssertEqualObjects(capabilities[@"maxVolumeBytes"], @(256 * 1024 * 1024));
  XCTAssertEqualObjects(capabilities[@"supportsExternalTexture"], @YES);
}

- (void)testValidatesTheV2CoreApiAddressAndTable {
  const VtkFlutterCoreApiV2* decoded = nullptr;
  NSString* error = nil;
  XCTAssertFalse(VtkFlutterDecodeCoreApi(@{}, &decoded, &error));
  XCTAssertEqualObjects(error, @"coreApiAddress must be a positive integer");

  VtkFlutterCoreApiV2 api = CompleteCoreApi();
  NSNumber* address = @(
      static_cast<uint64_t>(reinterpret_cast<uintptr_t>(&api)));
  XCTAssertTrue(VtkFlutterDecodeCoreApi(@{ @"coreApiAddress" : address },
                                        &decoded, &error));
  XCTAssertEqual(decoded, &api);

  api.version = VTK_FLUTTER_CORE_API_VERSION_2 + 1;
  XCTAssertFalse(VtkFlutterDecodeCoreApi(@{ @"coreApiAddress" : address },
                                         &decoded, &error));
  XCTAssertEqualObjects(error, @"Unsupported VTK core API version");

  api.version = VTK_FLUTTER_CORE_API_VERSION_2;
  api.struct_size = offsetof(VtkFlutterCoreApiV2, texture_target_destroy);
  XCTAssertFalse(VtkFlutterDecodeCoreApi(@{ @"coreApiAddress" : address },
                                         &decoded, &error));
  XCTAssertEqualObjects(error, @"VTK core API table is too small");
}

- (void)testDecodesDartViewportAndEveryRenderMap {
  VtkFlutterViewport viewport{};
  NSString* error = nil;
  XCTAssertTrue(VtkFlutterDecodeViewport(@{ @"width" : @640, @"height" : @320 },
                                         &viewport, &error));
  XCTAssertEqual(viewport.width, 640);
  XCTAssertEqual(viewport.height, 320);

  VtkFlutterRenderRequest request{};
  XCTAssertTrue(VtkFlutterDecodeRenderRequest(
      @{
        @"mode" : @1,
        @"windowCenter" : @350.0,
        @"windowWidth" : @1800.0,
        @"planeOrigin" : [self doubles:@[ @10.0, @20.0, @30.0 ]],
        @"planeNormal" : [self doubles:@[ @0.0, @0.34, @0.94 ]],
      },
      viewport, &request, &error));
  XCTAssertEqual(request.mode, VTK_FLUTTER_RENDER_OBLIQUE_MPR);
  XCTAssertEqualWithAccuracy(request.plane_origin[2], 30.0, 0.0001);

  XCTAssertTrue(VtkFlutterDecodeRenderRequest(
      @{
        @"mode" : @2,
        @"windowCenter" : @350.0,
        @"windowWidth" : @1800.0,
        @"cameraAzimuthDegrees" : @25.0,
        @"cameraElevationDegrees" : @18.0,
        @"cameraZoom" : @1.5,
      },
      viewport, &request, &error));
  XCTAssertEqual(request.mode, VTK_FLUTTER_RENDER_VOLUME_3D);
  XCTAssertEqualWithAccuracy(request.camera_zoom, 1.5, 0.0001);

  XCTAssertTrue(VtkFlutterDecodeRenderRequest(
      @{
        @"mode" : @3,
        @"cameraAzimuthDegrees" : @61.0,
        @"cameraElevationDegrees" : @-11.0,
        @"cameraZoom" : @2.5,
      },
      viewport, &request, &error));
  XCTAssertEqual(request.mode, VTK_FLUTTER_RENDER_VOLUME_LOCATOR);
  XCTAssertGreaterThan(request.window_width, 0.0);
  XCTAssertEqualWithAccuracy(request.camera_zoom, 2.5, 0.0001);
}

- (void)testRejectsUnsupportedRenderMode {
  VtkFlutterRenderRequest request{};
  NSString* error = nil;
  XCTAssertFalse(VtkFlutterDecodeRenderRequest(
      @{ @"mode" : @99 }, VtkFlutterViewport{.width = 1, .height = 1},
      &request, &error));
  XCTAssertEqualObjects(error, @"Unsupported VTK render mode");
}

- (void)testDecodesDartVolumeMap {
  const int16_t voxels[] = {0, 1, -1, 2};
  const double affine[] = {
      1, 0, 0, 0,
      0, 1, 0, 0,
      0, 0, 1, 0,
      0, 0, 0, 1,
  };
  VtkFlutterVolume volume{};
  NSString* error = nil;
  XCTAssertTrue(VtkFlutterDecodeVolume(
      @{
        @"voxels" : [FlutterStandardTypedData
            typedDataWithBytes:[NSData dataWithBytes:voxels length:sizeof(voxels)]],
        @"width" : @2,
        @"height" : @2,
        @"depth" : @1,
        @"indexToPatient" : [FlutterStandardTypedData
            typedDataWithFloat64:[NSData dataWithBytes:affine length:sizeof(affine)]],
      },
      &volume, &error));
  XCTAssertEqual(volume.voxel_count, 4u);
  XCTAssertEqual(volume.depth, 1);
  XCTAssertEqualWithAccuracy(volume.index_to_patient[10], 1.0, 0.0001);
}

@end
