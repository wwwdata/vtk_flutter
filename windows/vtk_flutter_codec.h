#ifndef FLUTTER_PLUGIN_VTK_FLUTTER_CODEC_H_
#define FLUTTER_PLUGIN_VTK_FLUTTER_CODEC_H_

#include <flutter/encodable_value.h>

#include <vtk_flutter.h>

#include <cstdint>

namespace vtk_flutter::windows {

flutter::EncodableMap CapabilitiesMap();
VtkFlutterViewport DecodeViewport(const flutter::EncodableValue *arguments);
std::uintptr_t
DecodePresentationApiAddress(const flutter::EncodableValue *arguments);
std::uintptr_t
DecodeNativeSessionAddress(const flutter::EncodableValue *arguments);

} // namespace vtk_flutter::windows

#endif // FLUTTER_PLUGIN_VTK_FLUTTER_CODEC_H_
