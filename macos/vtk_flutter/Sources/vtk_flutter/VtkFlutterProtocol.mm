#import "VtkFlutterProtocol.h"

#include <cstddef>
#include <cstdint>
#include <limits>

namespace {
BOOL Fail(NSString* message, NSString** errorMessage) {
  if (errorMessage != nullptr) {
    *errorMessage = message;
  }
  return NO;
}

BOOL IsNonBooleanNumber(id value) {
  return [value isKindOfClass:NSNumber.class] &&
         CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}

BOOL IsNonBooleanInteger(id value) {
  return IsNonBooleanNumber(value) &&
         !CFNumberIsFloatType((__bridge CFNumberRef)value);
}

BOOL DecodeAddress(NSDictionary* arguments,
                   NSString* key,
                   uintptr_t* address,
                   NSString** errorMessage) {
  id value = arguments[key];
  NSString* field = [key stringByAppendingString:@" must be a positive integer"];
  if (!IsNonBooleanInteger(value) || [value longLongValue] <= 0) {
    return Fail(field, errorMessage);
  }
  unsigned long long decoded = [value unsignedLongLongValue];
  if (decoded > std::numeric_limits<uintptr_t>::max()) {
    return Fail([key stringByAppendingString:@" is outside the native address range"],
                errorMessage);
  }
  *address = static_cast<uintptr_t>(decoded);
  return YES;
}

constexpr std::size_t kRequiredPresentationApiSize =
    offsetof(VtkFlutterPresentationApi, texture_target_destroy) +
    sizeof(VtkFlutterPresentationApi::texture_target_destroy);

BOOL HasRequiredPresentationFunctions(const VtkFlutterPresentationApi* api) {
  return api->status_clear != nullptr &&
         api->session_attach_texture_target != nullptr &&
         api->session_detach_texture_target != nullptr &&
         api->texture_target_create != nullptr &&
         api->texture_target_destroy != nullptr;
}
}  // namespace

NSDictionary<NSString*, id>* VtkFlutterCapabilitiesMap(void) {
  return @{@"supportsExternalTexture" : @YES};
}

BOOL VtkFlutterDecodePresentationApi(
    id arguments,
    const VtkFlutterPresentationApi** presentationApi,
    NSString** errorMessage) {
  if (presentationApi == nullptr ||
      ![arguments isKindOfClass:NSDictionary.class]) {
    return Fail(@"Presentation API arguments are required", errorMessage);
  }
  uintptr_t address = 0;
  if (!DecodeAddress(arguments, @"presentationApiAddress", &address,
                     errorMessage)) {
    return NO;
  }
  const auto* api =
      reinterpret_cast<const VtkFlutterPresentationApi*>(address);
  if (api->version != VTK_FLUTTER_PRESENTATION_API_VERSION) {
    return Fail(@"Unsupported VTK presentation API version", errorMessage);
  }
  if (api->struct_size < kRequiredPresentationApiSize) {
    return Fail(@"VTK presentation API table is too small", errorMessage);
  }
  if (!HasRequiredPresentationFunctions(api)) {
    return Fail(@"VTK presentation API table is incomplete", errorMessage);
  }
  *presentationApi = api;
  return YES;
}

BOOL VtkFlutterDecodeNativeSession(id arguments,
                                   VtkFlutterSession** nativeSession,
                                   NSString** errorMessage) {
  if (nativeSession == nullptr ||
      ![arguments isKindOfClass:NSDictionary.class]) {
    return Fail(@"Native session arguments are required", errorMessage);
  }
  uintptr_t address = 0;
  if (!DecodeAddress(arguments, @"nativeSessionAddress", &address,
                     errorMessage)) {
    return NO;
  }
  *nativeSession = reinterpret_cast<VtkFlutterSession*>(address);
  return YES;
}

BOOL VtkFlutterDecodeViewport(id arguments, VtkFlutterViewport* viewport,
                              NSString** errorMessage) {
  if (viewport == nullptr ||
      ![arguments isKindOfClass:NSDictionary.class]) {
    return Fail(@"Viewport arguments are required", errorMessage);
  }
  NSDictionary* values = arguments;
  id width = values[@"width"];
  id height = values[@"height"];
  if (!IsNonBooleanNumber(width) || !IsNonBooleanNumber(height)) {
    return Fail(@"Viewport width and height must be numbers", errorMessage);
  }
  *viewport = {.width = [width intValue], .height = [height intValue]};
  if (viewport->width <= 0 || viewport->height <= 0) {
    return Fail(@"Viewport width and height must be positive", errorMessage);
  }
  return YES;
}
