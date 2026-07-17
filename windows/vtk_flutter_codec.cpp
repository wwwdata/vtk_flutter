#include "vtk_flutter_codec.h"

#include <limits>
#include <optional>
#include <stdexcept>

namespace vtk_flutter::windows {
namespace {

constexpr std::uint64_t kMaximumFrameBytes = 256ULL * 1024ULL * 1024ULL;

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

std::uintptr_t DecodeAddress(const flutter::EncodableMap &values,
                             const char *key, const char *message) {
  const auto address = ReadInteger(Find(values, key));
  if (!address || *address <= 0 ||
      static_cast<std::uint64_t>(*address) >
          std::numeric_limits<std::uintptr_t>::max()) {
    throw std::invalid_argument(message);
  }
  return static_cast<std::uintptr_t>(*address);
}

} // namespace

flutter::EncodableMap CapabilitiesMap() {
  return {
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
  if (frame_bytes > kMaximumFrameBytes) {
    throw std::invalid_argument("Viewport exceeds the 256 MiB frame limit");
  }
  return {static_cast<std::int32_t>(*width),
          static_cast<std::int32_t>(*height)};
}

std::uintptr_t
DecodePresentationApiAddress(const flutter::EncodableValue *arguments) {
  const auto &values = RequireMap(arguments, "View arguments are required");
  return DecodeAddress(values, "presentationApiAddress",
                       "presentationApiAddress must be a positive pointer");
}

std::uintptr_t
DecodeNativeSessionAddress(const flutter::EncodableValue *arguments) {
  const auto &values = RequireMap(arguments, "View arguments are required");
  return DecodeAddress(values, "nativeSessionAddress",
                       "nativeSessionAddress must be a positive pointer");
}

} // namespace vtk_flutter::windows
