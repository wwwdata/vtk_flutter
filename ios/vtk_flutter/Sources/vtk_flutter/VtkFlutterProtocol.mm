#import "VtkFlutterProtocol.h"

#import <Flutter/Flutter.h>

#include <cstddef>
#include <cstring>
#include <cstdint>
#include <limits>

namespace {
BOOL Fail(NSString* message, NSString** errorMessage) {
  if (errorMessage != nullptr) {
    *errorMessage = message;
  }
  return NO;
}

BOOL IsNumber(id value) { return [value isKindOfClass:NSNumber.class]; }

BOOL IsNonBooleanNumber(id value) {
  return IsNumber(value) &&
         CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}

constexpr std::size_t kRequiredCoreApiSize =
    offsetof(VtkFlutterCoreApiV2, texture_target_destroy) +
    sizeof(VtkFlutterCoreApiV2::texture_target_destroy);

BOOL HasRequiredCoreFunctions(const VtkFlutterCoreApiV2* api) {
  return api->status_clear != nullptr && api->session_create != nullptr &&
         api->session_destroy != nullptr && api->validate_volume != nullptr &&
         api->session_set_volume != nullptr &&
         api->validate_render_request != nullptr &&
         api->session_render != nullptr &&
         api->session_attach_texture_target != nullptr &&
         api->session_detach_texture_target != nullptr &&
         api->texture_target_create != nullptr &&
         api->texture_target_destroy != nullptr;
}

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

BOOL VtkFlutterDecodeCoreApi(id arguments,
                             const VtkFlutterCoreApiV2** coreApi,
                             NSString** errorMessage) {
  if (coreApi == nullptr || ![arguments isKindOfClass:NSDictionary.class]) {
    return Fail(@"Core API arguments are required", errorMessage);
  }
  id value = ((NSDictionary*)arguments)[@"coreApiAddress"];
  if (!IsNonBooleanNumber(value) || [value longLongValue] <= 0) {
    return Fail(@"coreApiAddress must be a positive integer", errorMessage);
  }
  unsigned long long address = [value unsignedLongLongValue];
  if (address > std::numeric_limits<uintptr_t>::max()) {
    return Fail(@"coreApiAddress is outside the native address range", errorMessage);
  }
  const auto* api = reinterpret_cast<const VtkFlutterCoreApiV2*>(
      static_cast<uintptr_t>(address));
  if (api->version != VTK_FLUTTER_CORE_API_VERSION_2) {
    return Fail(@"Unsupported VTK core API version", errorMessage);
  }
  if (api->struct_size < kRequiredCoreApiSize) {
    return Fail(@"VTK core API table is too small", errorMessage);
  }
  if (!HasRequiredCoreFunctions(api)) {
    return Fail(@"VTK core API table is incomplete", errorMessage);
  }
  *coreApi = api;
  return YES;
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
