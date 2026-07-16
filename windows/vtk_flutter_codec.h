#ifndef FLUTTER_PLUGIN_VTK_FLUTTER_CODEC_H_
#define FLUTTER_PLUGIN_VTK_FLUTTER_CODEC_H_

#include <flutter/encodable_value.h>

#include <vtk_flutter.h>

#include <array>
#include <cstdint>
#include <vector>

namespace vtk_flutter::windows {

constexpr std::uint64_t kMaximumVolumeBytes = 256ULL * 1024ULL * 1024ULL;

struct OwnedVolume {
  std::vector<std::int16_t> voxels;
  std::array<double, 16> index_to_patient{};
  std::int32_t width = 0;
  std::int32_t height = 0;
  std::int32_t depth = 0;

  VtkFlutterVolume NativeView() const;
};

flutter::EncodableMap CapabilitiesMap();
VtkFlutterViewport DecodeViewport(const flutter::EncodableValue *arguments);
std::uintptr_t DecodeCoreApiAddress(const flutter::EncodableValue *arguments);
OwnedVolume DecodeVolume(const flutter::EncodableValue *arguments);
VtkFlutterRenderRequest
DecodeRenderRequest(const flutter::EncodableValue *arguments,
                    const VtkFlutterViewport &viewport);

} // namespace vtk_flutter::windows

#endif // FLUTTER_PLUGIN_VTK_FLUTTER_CODEC_H_
