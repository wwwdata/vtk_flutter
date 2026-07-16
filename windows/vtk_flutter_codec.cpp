#include "vtk_flutter_codec.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <optional>
#include <stdexcept>

namespace vtk_flutter::windows {
namespace {

flutter::EncodableValue Key(const char *value) {
  return flutter::EncodableValue(value);
}

const flutter::EncodableValue *Find(const flutter::EncodableMap &values,
                                    const char *key) {
  const auto iterator = values.find(Key(key));
  return iterator == values.end() ? nullptr : &iterator->second;
}

std::optional<std::int64_t> ReadInteger(const flutter::EncodableValue *value) {
  if (const auto *integer =
          value == nullptr ? nullptr : std::get_if<std::int32_t>(value)) {
    return *integer;
  }
  if (const auto *integer =
          value == nullptr ? nullptr : std::get_if<std::int64_t>(value)) {
    return *integer;
  }
  return std::nullopt;
}

std::optional<double> ReadDouble(const flutter::EncodableValue *value) {
  if (const auto *number =
          value == nullptr ? nullptr : std::get_if<double>(value)) {
    return *number;
  }
  if (const auto integer = ReadInteger(value)) {
    return static_cast<double>(*integer);
  }
  return std::nullopt;
}

const flutter::EncodableMap &
RequireMap(const flutter::EncodableValue *arguments, const char *message) {
  const auto *values = arguments == nullptr
                           ? nullptr
                           : std::get_if<flutter::EncodableMap>(arguments);
  if (values == nullptr) {
    throw std::invalid_argument(message);
  }
  return *values;
}

double ReadDoubleOr(const flutter::EncodableMap &values, const char *key,
                    double fallback) {
  return ReadDouble(Find(values, key)).value_or(fallback);
}

void CopyVector(const flutter::EncodableMap &values, const char *key,
                double (&destination)[3]) {
  const auto *value = Find(values, key);
  const auto *vector =
      value == nullptr ? nullptr : std::get_if<std::vector<double>>(value);
  if (vector == nullptr || vector->size() != 3) {
    throw std::invalid_argument(
        "Plane origin and normal must contain three doubles");
  }
  std::copy(vector->begin(), vector->end(), destination);
}

} // namespace

VtkFlutterVolume OwnedVolume::NativeView() const {
  VtkFlutterVolume volume{};
  volume.voxels = voxels.data();
  volume.voxel_count = voxels.size();
  volume.width = width;
  volume.height = height;
  volume.depth = depth;
  std::copy(index_to_patient.begin(), index_to_patient.end(),
            volume.index_to_patient);
  return volume;
}

flutter::EncodableMap CapabilitiesMap() {
  return {
      {Key("renderModes"), flutter::EncodableValue(flutter::EncodableList{
                               flutter::EncodableValue(std::int32_t{1}),
                               flutter::EncodableValue(std::int32_t{2}),
                               flutter::EncodableValue(std::int32_t{3}),
                           })},
      {Key("maxVolumeBytes"),
       flutter::EncodableValue(static_cast<std::int64_t>(kMaximumVolumeBytes))},
      {Key("supportsExternalTexture"), flutter::EncodableValue(true)},
  };
}

VtkFlutterViewport DecodeViewport(const flutter::EncodableValue *arguments) {
  const auto &values = RequireMap(arguments, "Viewport arguments are required");
  const auto width = ReadInteger(Find(values, "width"));
  const auto height = ReadInteger(Find(values, "height"));
  if (!width || !height || *width <= 0 || *height <= 0 || *width > 8192 ||
      *height > 8192) {
    throw std::invalid_argument(
        "Viewport dimensions must be between 1 and 8192 pixels");
  }
  const auto frame_bytes = static_cast<std::uint64_t>(*width) *
                           static_cast<std::uint64_t>(*height) * 4ULL;
  if (frame_bytes > kMaximumVolumeBytes) {
    throw std::invalid_argument("Viewport exceeds the 256 MiB frame limit");
  }
  return {static_cast<std::int32_t>(*width),
          static_cast<std::int32_t>(*height)};
}

std::uintptr_t DecodeCoreApiAddress(const flutter::EncodableValue *arguments) {
  const auto &values = RequireMap(arguments, "Session arguments are required");
  const auto address = ReadInteger(Find(values, "coreApiAddress"));
  if (!address || *address <= 0 ||
      static_cast<std::uint64_t>(*address) >
          std::numeric_limits<std::uintptr_t>::max()) {
    throw std::invalid_argument("coreApiAddress must be a positive pointer");
  }
  return static_cast<std::uintptr_t>(*address);
}

OwnedVolume DecodeVolume(const flutter::EncodableValue *arguments) {
  const auto &values = RequireMap(arguments, "Volume arguments are required");
  const auto width = ReadInteger(Find(values, "width"));
  const auto height = ReadInteger(Find(values, "height"));
  const auto depth = ReadInteger(Find(values, "depth"));
  const auto *voxel_value = Find(values, "voxels");
  const auto *affine_value = Find(values, "indexToPatient");
  const auto *voxel_bytes =
      voxel_value == nullptr
          ? nullptr
          : std::get_if<std::vector<std::uint8_t>>(voxel_value);
  const auto *affine = affine_value == nullptr
                           ? nullptr
                           : std::get_if<std::vector<double>>(affine_value);
  if (!width || !height || !depth || *width <= 0 || *height <= 0 ||
      *depth <= 0 || *width > 4096 || *height > 4096 || *depth > 4096 ||
      voxel_bytes == nullptr || affine == nullptr || affine->size() != 16) {
    throw std::invalid_argument(
        "Expected bounded signed-int16 voxel bytes, dimensions, and a "
        "Float64 affine");
  }

  const auto voxel_count = static_cast<std::uint64_t>(*width) *
                           static_cast<std::uint64_t>(*height) *
                           static_cast<std::uint64_t>(*depth);
  if (voxel_count > kMaximumVolumeBytes / sizeof(std::int16_t) ||
      voxel_count >
          std::numeric_limits<std::size_t>::max() / sizeof(std::int16_t) ||
      voxel_bytes->size() != voxel_count * sizeof(std::int16_t)) {
    throw std::invalid_argument(
        "Volume dimensions do not match the signed-int16 bytes");
  }

  OwnedVolume volume;
  volume.voxels.resize(static_cast<std::size_t>(voxel_count));
  std::memcpy(volume.voxels.data(), voxel_bytes->data(), voxel_bytes->size());
  std::copy(affine->begin(), affine->end(), volume.index_to_patient.begin());
  volume.width = static_cast<std::int32_t>(*width);
  volume.height = static_cast<std::int32_t>(*height);
  volume.depth = static_cast<std::int32_t>(*depth);
  return volume;
}

VtkFlutterRenderRequest
DecodeRenderRequest(const flutter::EncodableValue *arguments,
                    const VtkFlutterViewport &viewport) {
  const auto &values = RequireMap(arguments, "Render arguments are required");
  const auto mode = ReadInteger(Find(values, "mode"));
  if (!mode) {
    throw std::invalid_argument("Render mode is required");
  }

  VtkFlutterRenderRequest request{};
  request.mode = static_cast<std::int32_t>(*mode);
  request.viewport = viewport;
  request.window_center = ReadDoubleOr(values, "windowCenter", 40.0);
  request.window_width = ReadDoubleOr(values, "windowWidth", 400.0);
  request.camera_azimuth_degrees =
      ReadDoubleOr(values, "cameraAzimuthDegrees", 0.0);
  request.camera_elevation_degrees =
      ReadDoubleOr(values, "cameraElevationDegrees", 0.0);
  request.camera_zoom = ReadDoubleOr(values, "cameraZoom", 1.0);
  request.plane_normal[2] = 1.0;

  if (request.mode == VTK_FLUTTER_RENDER_OBLIQUE_MPR) {
    CopyVector(values, "planeOrigin", request.plane_origin);
    CopyVector(values, "planeNormal", request.plane_normal);
  } else if (request.mode != VTK_FLUTTER_RENDER_VOLUME_3D &&
             request.mode != VTK_FLUTTER_RENDER_VOLUME_LOCATOR) {
    throw std::invalid_argument("Unsupported VTK render mode");
  }
  return request;
}

} // namespace vtk_flutter::windows
