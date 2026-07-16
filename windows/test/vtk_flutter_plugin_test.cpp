#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>

#include <vtk_flutter.h>

#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <variant>
#include <vector>

#include "vtk_flutter_codec.h"
#include "vtk_flutter_plugin.h"

namespace vtk_flutter::test {
namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

EncodableValue Key(const char *value) { return EncodableValue(value); }

const EncodableValue &ValueAt(const EncodableMap &values, const char *key) {
  return values.at(Key(key));
}

EncodableValue Viewport(int width, int height) {
  return EncodableValue(EncodableMap{
      {Key("width"), EncodableValue(width)},
      {Key("height"), EncodableValue(height)},
  });
}

EncodableValue CameraRequest(int mode, double zoom) {
  return EncodableValue(EncodableMap{
      {Key("mode"), EncodableValue(mode)},
      {Key("windowCenter"), EncodableValue(350.0)},
      {Key("windowWidth"), EncodableValue(1800.0)},
      {Key("cameraAzimuthDegrees"), EncodableValue(25.0)},
      {Key("cameraElevationDegrees"), EncodableValue(18.0)},
      {Key("cameraZoom"), EncodableValue(zoom)},
  });
}

} // namespace

TEST(VtkFlutterCodec, ReportsAllCapabilities) {
  const auto capabilities = windows::CapabilitiesMap();
  const auto &modes =
      std::get<EncodableList>(ValueAt(capabilities, "renderModes"));

  ASSERT_EQ(modes.size(), 3U);
  EXPECT_EQ(std::get<std::int32_t>(modes[0]), 1);
  EXPECT_EQ(std::get<std::int32_t>(modes[1]), 2);
  EXPECT_EQ(std::get<std::int32_t>(modes[2]), 3);
  EXPECT_EQ(std::get<std::int64_t>(ValueAt(capabilities, "maxVolumeBytes")),
            256LL * 1024LL * 1024LL);
  EXPECT_TRUE(std::get<bool>(ValueAt(capabilities, "supportsExternalTexture")));
}

TEST(VtkFlutterCodec, DecodesBoundedViewport) {
  const auto arguments = Viewport(640, 320);
  const auto viewport = windows::DecodeViewport(&arguments);

  EXPECT_EQ(viewport.width, 640);
  EXPECT_EQ(viewport.height, 320);

  const auto invalid = Viewport(0, 320);
  EXPECT_THROW(windows::DecodeViewport(&invalid), std::invalid_argument);
}

TEST(VtkFlutterCodec, PreservesCameraZoomForBothVolumeModes) {
  const VtkFlutterViewport viewport{640, 320};
  const auto volume_arguments = CameraRequest(2, 1.5);
  const auto locator_arguments = CameraRequest(3, 2.5);

  const auto volume = windows::DecodeRenderRequest(&volume_arguments, viewport);
  const auto locator =
      windows::DecodeRenderRequest(&locator_arguments, viewport);

  EXPECT_EQ(volume.mode, VTK_FLUTTER_RENDER_VOLUME_3D);
  EXPECT_DOUBLE_EQ(volume.camera_zoom, 1.5);
  EXPECT_EQ(locator.mode, VTK_FLUTTER_RENDER_VOLUME_LOCATOR);
  EXPECT_DOUBLE_EQ(locator.camera_zoom, 2.5);
}

TEST(VtkFlutterCodec, DecodesObliqueTypedVectors) {
  const VtkFlutterViewport viewport{800, 600};
  const EncodableValue arguments(EncodableMap{
      {Key("mode"), EncodableValue(1)},
      {Key("windowCenter"), EncodableValue(350.0)},
      {Key("windowWidth"), EncodableValue(1800.0)},
      {Key("planeOrigin"),
       EncodableValue(std::vector<double>{10.0, 20.0, 30.0})},
      {Key("planeNormal"),
       EncodableValue(std::vector<double>{0.0, 0.34, 0.94})},
  });

  const auto request = windows::DecodeRenderRequest(&arguments, viewport);

  EXPECT_EQ(request.mode, VTK_FLUTTER_RENDER_OBLIQUE_MPR);
  EXPECT_DOUBLE_EQ(request.plane_origin[0], 10.0);
  EXPECT_DOUBLE_EQ(request.plane_normal[1], 0.34);
  EXPECT_DOUBLE_EQ(request.camera_zoom, 1.0);
}

TEST(VtkFlutterCodec, OwnsDecodedVolumeBytes) {
  const EncodableValue arguments(EncodableMap{
      {Key("voxels"),
       EncodableValue(std::vector<std::uint8_t>{0, 0, 1, 0, 255, 255, 2, 0})},
      {Key("width"), EncodableValue(2)},
      {Key("height"), EncodableValue(2)},
      {Key("depth"), EncodableValue(1)},
      {Key("indexToPatient"), EncodableValue(std::vector<double>{
                                  1,
                                  0,
                                  0,
                                  0,
                                  0,
                                  1,
                                  0,
                                  0,
                                  0,
                                  0,
                                  1,
                                  0,
                                  0,
                                  0,
                                  0,
                                  1,
                              })},
  });

  const auto owned = windows::DecodeVolume(&arguments);
  const auto native = owned.NativeView();

  EXPECT_EQ(native.voxel_count, 4U);
  EXPECT_EQ(native.width, 2);
  EXPECT_EQ(native.height, 2);
  EXPECT_EQ(native.depth, 1);
  EXPECT_EQ(native.voxels[1], 1);
  EXPECT_EQ(native.voxels[2], -1);
  EXPECT_DOUBLE_EQ(native.index_to_patient[15], 1.0);
}

TEST(VtkFlutterPlugin, UsesSessionChannelContractWithoutRegistrar) {
  VtkFlutterPlugin plugin;
  EncodableMap capabilities;
  plugin.HandleMethodCall(
      MethodCall("capabilities", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&capabilities](const EncodableValue *result) {
            capabilities = std::get<EncodableMap>(*result);
          },
          nullptr, nullptr));

  EXPECT_EQ(std::get<std::int64_t>(ValueAt(capabilities, "maxVolumeBytes")),
            256LL * 1024LL * 1024LL);
  EXPECT_EQ(vtk_flutter_abi_version(), VTK_FLUTTER_ABI_VERSION);
}

TEST(VtkFlutterPlugin, ReportsCompleteDisposedStatus) {
  VtkFlutterPlugin plugin;
  EncodableMap status;
  plugin.HandleMethodCall(
      MethodCall("status", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&status](const EncodableValue *result) {
            status = std::get<EncodableMap>(*result);
          },
          nullptr, nullptr));

  EXPECT_EQ(std::get<std::int64_t>(ValueAt(status, "textureId")), -1);
  EXPECT_FALSE(std::get<bool>(ValueAt(status, "ready")));
  EXPECT_FALSE(std::get<bool>(ValueAt(status, "initializing")));
  EXPECT_FALSE(std::get<bool>(ValueAt(status, "disposing")));
  EXPECT_EQ(std::get<int>(ValueAt(status, "pendingTextureUnregistrations")), 0);
  EXPECT_EQ(std::get<std::int64_t>(ValueAt(status, "presentedFrameCount")), 0);
  EXPECT_EQ(std::get<std::int64_t>(ValueAt(status, "presentedFrameId")), 0);
  EXPECT_EQ(
      std::get<std::int64_t>(ValueAt(status, "graphicsContextGeneration")), 0);
}

} // namespace vtk_flutter::test
