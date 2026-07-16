#import "VtkFlutterProtocol.h"

#import <FlutterMacOS/FlutterMacOS.h>

#include <cstring>

namespace {
BOOL Fail(NSString* message, NSString** errorMessage) {
  if (errorMessage != nullptr) {
    *errorMessage = message;
  }
  return NO;
}

BOOL IsNumber(id value) { return [value isKindOfClass:NSNumber.class]; }

double NumberOr(NSDictionary* values, NSString* key, double fallback) {
  id value = values[key];
  return IsNumber(value) ? [value doubleValue] : fallback;
}
}  // namespace

NSDictionary<NSString*, id>* VtkFlutterCapabilitiesMap(void) {
  return @{
    @"renderModes" : @[ @1, @2, @3 ],
    @"maxVolumeBytes" : @(256ULL * 1024ULL * 1024ULL),
    @"supportsExternalTexture" : @YES,
  };
}

BOOL VtkFlutterDecodeViewport(id arguments, VtkFlutterViewport* viewport,
                              NSString** errorMessage) {
  if (viewport == nullptr || ![arguments isKindOfClass:NSDictionary.class]) {
    return Fail(@"Viewport arguments are required", errorMessage);
  }
  NSDictionary* values = arguments;
  id width = values[@"width"];
  id height = values[@"height"];
  if (!IsNumber(width) || !IsNumber(height)) {
    return Fail(@"Viewport width and height must be numbers", errorMessage);
  }
  *viewport = {.width = [width intValue], .height = [height intValue]};
  if (viewport->width <= 0 || viewport->height <= 0) {
    return Fail(@"Viewport width and height must be positive", errorMessage);
  }
  return YES;
}

BOOL VtkFlutterDecodeVolume(id arguments, VtkFlutterVolume* volume,
                            NSString** errorMessage) {
  if (volume == nullptr || ![arguments isKindOfClass:NSDictionary.class]) {
    return Fail(@"Volume arguments are required", errorMessage);
  }
  NSDictionary* values = arguments;
  FlutterStandardTypedData* voxels = values[@"voxels"];
  FlutterStandardTypedData* affine = values[@"indexToPatient"];
  id width = values[@"width"];
  id height = values[@"height"];
  id depth = values[@"depth"];
  if (![voxels isKindOfClass:FlutterStandardTypedData.class] ||
      voxels.type != FlutterStandardDataTypeUInt8 || voxels.data.length % sizeof(int16_t) != 0 ||
      ![affine isKindOfClass:FlutterStandardTypedData.class] ||
      affine.type != FlutterStandardDataTypeFloat64 || affine.elementCount != 16 ||
      !IsNumber(width) || !IsNumber(height) || !IsNumber(depth)) {
    return Fail(@"Expected signed-int16 voxel bytes, dimensions, and a Float64 4x4 affine",
                errorMessage);
  }
  *volume = {};
  volume->voxels = static_cast<const int16_t*>(voxels.data.bytes);
  volume->voxel_count = voxels.data.length / sizeof(int16_t);
  volume->width = [width intValue];
  volume->height = [height intValue];
  volume->depth = [depth intValue];
  std::memcpy(volume->index_to_patient, affine.data.bytes, sizeof(volume->index_to_patient));
  return YES;
}

BOOL VtkFlutterDecodeRenderRequest(id arguments, VtkFlutterViewport viewport,
                                   VtkFlutterRenderRequest* request,
                                   NSString** errorMessage) {
  if (request == nullptr || ![arguments isKindOfClass:NSDictionary.class]) {
    return Fail(@"Render arguments are required", errorMessage);
  }
  NSDictionary* values = arguments;
  id mode = values[@"mode"];
  if (!IsNumber(mode)) {
    return Fail(@"Render mode is required", errorMessage);
  }

  *request = {};
  request->mode = [mode intValue];
  request->viewport = viewport;
  request->window_center = NumberOr(values, @"windowCenter", 40.0);
  request->window_width = NumberOr(values, @"windowWidth", 400.0);
  request->camera_azimuth_degrees = NumberOr(values, @"cameraAzimuthDegrees", 0.0);
  request->camera_elevation_degrees = NumberOr(values, @"cameraElevationDegrees", 0.0);
  request->camera_zoom = NumberOr(values, @"cameraZoom", 1.0);

  if (request->mode == VTK_FLUTTER_RENDER_OBLIQUE_MPR) {
    FlutterStandardTypedData* origin = values[@"planeOrigin"];
    FlutterStandardTypedData* normal = values[@"planeNormal"];
    if (![origin isKindOfClass:FlutterStandardTypedData.class] ||
        origin.type != FlutterStandardDataTypeFloat64 || origin.elementCount != 3 ||
        ![normal isKindOfClass:FlutterStandardTypedData.class] ||
        normal.type != FlutterStandardDataTypeFloat64 || normal.elementCount != 3) {
      return Fail(@"Plane origin and normal must contain three doubles", errorMessage);
    }
    std::memcpy(request->plane_origin, origin.data.bytes, sizeof(request->plane_origin));
    std::memcpy(request->plane_normal, normal.data.bytes, sizeof(request->plane_normal));
  } else if (request->mode != VTK_FLUTTER_RENDER_VOLUME_3D &&
             request->mode != VTK_FLUTTER_RENDER_VOLUME_LOCATOR) {
    return Fail(@"Unsupported VTK render mode", errorMessage);
  }
  return YES;
}
