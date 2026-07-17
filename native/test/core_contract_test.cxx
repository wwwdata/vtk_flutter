#include "callback_render_target.h"
#include "vtk_flutter.h"

// clang-format off
#include <vtk_nlohmannjson.h>
#include VTK_NLOHMANN_JSON(json.hpp)
// clang-format on

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

extern "C" int vtk_flutter_public_header_contract(void);

namespace {
void Require(bool condition, std::string_view message) {
  if (!condition) {
    throw std::runtime_error(std::string(message));
  }
}

void RequireOk(int32_t result, const VtkFlutterStatus &status,
               std::string_view operation) {
  if (result != VTK_FLUTTER_STATUS_OK) {
    throw std::runtime_error(std::string(operation) + ": " + status.message);
  }
}

struct SessionGuard {
  SessionGuard() = default;
  SessionGuard(const SessionGuard &) = delete;
  SessionGuard &operator=(const SessionGuard &) = delete;
  SessionGuard(SessionGuard &&other) noexcept : value(other.value) {
    other.value = nullptr;
  }
  SessionGuard &operator=(SessionGuard &&) = delete;
  ~SessionGuard() { vtk_flutter_session_destroy(value); }
  VtkFlutterSession *value = nullptr;
};

VtkFlutterObjectHandle CreateObject(VtkFlutterSession *session,
                                    const char *class_name) {
  VtkFlutterObjectHandle object = 0;
  VtkFlutterStatus status{};
  RequireOk(vtk_flutter_object_create(session, class_name, &object, &status),
            status, class_name);
  Require(object != 0, "VTK returned an invalid object handle");
  return object;
}

nlohmann::json Invoke(VtkFlutterSession *session,
                      VtkFlutterObjectHandle object, const char *method,
                      const nlohmann::json &arguments = nlohmann::json::array()) {
  char *result = nullptr;
  VtkFlutterStatus status{};
  const auto arguments_text = arguments.dump();
  RequireOk(vtk_flutter_object_invoke(session, object, method,
                                      arguments_text.c_str(), &result, &status),
            status, method);
  Require(result != nullptr, "VTK returned no invocation result");
  const auto parsed = nlohmann::json::parse(result);
  vtk_flutter_string_free(result);
  return parsed;
}

VtkFlutterObjectHandle ResultHandle(const nlohmann::json &value) {
  Require(value.is_object() && value.contains("Id"),
          "VTK result contains no object handle");
  return value["Id"].get<VtkFlutterObjectHandle>();
}

SessionGuard CreateSession() {
  SessionGuard session;
  VtkFlutterStatus status{};
  RequireOk(vtk_flutter_session_create(&session.value, &status), status,
            "session_create");
  Require(session.value != nullptr, "VTK returned no session");
  return session;
}

struct FrameHarness {
  std::vector<std::uint8_t> pixels;
  int begin_count = 0;
  int end_count = 0;
  int cancel_count = 0;
};

int32_t VTK_FLUTTER_CALL BeginFrame(void *user_data,
                                    const VtkFlutterViewport *viewport,
                                    VtkFlutterCpuFrame *frame,
                                    VtkFlutterStatus *) {
  auto &harness = *static_cast<FrameHarness *>(user_data);
  ++harness.begin_count;
  harness.pixels.assign(
      static_cast<std::size_t>(viewport->width) * viewport->height * 4U, 0U);
  frame->struct_size = sizeof(VtkFlutterCpuFrame);
  frame->version = VTK_FLUTTER_CPU_FRAME_VERSION;
  frame->pixels = harness.pixels.data();
  frame->capacity_bytes = harness.pixels.size();
  frame->row_bytes = static_cast<std::uint64_t>(viewport->width) * 4U;
  frame->pixel_format = VTK_FLUTTER_PIXEL_FORMAT_RGBA8888;
  return VTK_FLUTTER_STATUS_OK;
}

int32_t VTK_FLUTTER_CALL EndFrame(void *user_data,
                                  const VtkFlutterFrameMetrics *,
                                  VtkFlutterStatus *) {
  ++static_cast<FrameHarness *>(user_data)->end_count;
  return VTK_FLUTTER_STATUS_OK;
}

void VTK_FLUTTER_CALL CancelFrame(void *user_data) {
  ++static_cast<FrameHarness *>(user_data)->cancel_count;
}

void TestPublicHeader() {
  Require(vtk_flutter_public_header_contract() == 1,
          "public C header contract failed");
  Require(vtk_flutter_abi_version() == VTK_FLUTTER_ABI_VERSION,
          "ABI version mismatch");
  const auto *api = vtk_flutter_get_presentation_api();
  Require(api != nullptr, "presentation API is missing");
  Require(api->version == VTK_FLUTTER_PRESENTATION_API_VERSION,
          "presentation API version mismatch");
  Require(api->struct_size >= sizeof(VtkFlutterPresentationApi),
          "presentation API is truncated");
  Require(api->session_is_valid != nullptr,
          "presentation API session validation is missing");

  VtkFlutterStatus status{};
  VtkFlutterSession *session = nullptr;
  RequireOk(vtk_flutter_session_create(&session, &status), status,
            "session_create");
  RequireOk(api->session_is_valid(session, &status), status,
            "session_is_valid");
  vtk_flutter_session_destroy(session);
  Require(api->session_is_valid(session, &status) ==
              VTK_FLUTTER_STATUS_INVALID_STATE,
          "a destroyed session remained valid");
  vtk_flutter_session_destroy(session);
}

void TestCpuFrameCopy() {
  const VtkFlutterViewport viewport{2, 2};
  const std::array<std::uint8_t, 16> bottom_up{
      1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 13, 14, 15, 16, 17, 18,
  };
  std::array<std::uint8_t, 16> top_down{};
  const VtkFlutterCpuFrame frame{
      sizeof(VtkFlutterCpuFrame),
      VTK_FLUTTER_CPU_FRAME_VERSION,
      top_down.data(),
      top_down.size(),
      8,
      VTK_FLUTTER_PIXEL_FORMAT_RGBA8888,
  };
  vtk_flutter::CopyRgbaBottomUpToFrame(bottom_up.data(), viewport, frame);
  const std::array<std::uint8_t, 16> expected{
      11, 12, 13, 14, 15, 16, 17, 18, 1, 2, 3, 4, 5, 6, 7, 8,
  };
  Require(top_down == expected, "CPU frame was not vertically flipped");
}

void TestGenericSession() {
  auto session = CreateSession();
  const std::array<const char *, 19> classes{
      "vtkImageReslice",
      "vtkImageMapToWindowLevelColors",
      "vtkImageActor",
      "vtkImageProperty",
      "vtkSmartVolumeMapper",
      "vtkColorTransferFunction",
      "vtkPiecewiseFunction",
      "vtkVolumeProperty",
      "vtkVolume",
      "vtkFlyingEdges3D",
      "vtkPolyDataConnectivityFilter",
      "vtkWindowedSincPolyDataFilter",
      "vtkPolyDataMapper",
      "vtkActor",
      "vtkProperty",
      "vtkRenderer",
      "vtkCamera",
      "vtkImageSliceMapper",
      "vtkContourFilter",
  };
  for (const auto *class_name : classes) {
    CreateObject(session.value, class_name);
  }

  VtkFlutterObjectHandle unsupported = 0;
  VtkFlutterStatus status{};
  const auto result = vtk_flutter_object_create(
      session.value, "vtkDefinitelyNotAClass", &unsupported, &status);
  Require(result == VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
          "unsupported class was accepted");

  const auto renderer = CreateObject(session.value, "vtkRenderer");
  char *invocation_result = nullptr;
  status = {};
  const auto invalid_invocation = vtk_flutter_object_invoke(
      session.value, renderer, "DefinitelyNotAMethod", "[]",
      &invocation_result, &status);
  Require(invalid_invocation == VTK_FLUTTER_STATUS_INVALID_ARGUMENT,
          "failed invocation was reported as successful");
  Require(invocation_result == nullptr,
          "failed invocation returned a result");

  status = {};
  RequireOk(vtk_flutter_object_destroy(session.value, renderer, &status),
            status, "first object destroy");
  status = {};
  RequireOk(vtk_flutter_object_destroy(session.value, renderer, &status),
            status, "idempotent object destroy");
}

void TestSurfaceRender() {
  auto session = CreateSession();
  constexpr int dimension = 24;
  std::vector<std::int16_t> values(dimension * dimension * dimension);
  for (int z = 0; z < dimension; ++z) {
    for (int y = 0; y < dimension; ++y) {
      for (int x = 0; x < dimension; ++x) {
        const auto dx = x - dimension / 2;
        const auto dy = y - dimension / 2;
        const auto dz = z - dimension / 2;
        values[static_cast<std::size_t>(
            z * dimension * dimension + y * dimension + x)] =
            dx * dx + dy * dy + dz * dz < 64 ? 1000 : -1000;
      }
    }
  }

  VtkFlutterImageData image{};
  image.values = values.data();
  image.value_count = values.size();
  image.byte_count = values.size() * sizeof(std::int16_t);
  image.scalar_type = VTK_FLUTTER_SCALAR_INT16;
  image.component_count = 1;
  image.dimensions[0] = dimension;
  image.dimensions[1] = dimension;
  image.dimensions[2] = dimension;
  image.spacing[0] = 1.0;
  image.spacing[1] = 1.0;
  image.spacing[2] = 1.0;
  image.direction[0] = 1.0;
  image.direction[4] = 1.0;
  image.direction[8] = 1.0;
  VtkFlutterObjectHandle image_handle = 0;
  VtkFlutterStatus status{};
  RequireOk(vtk_flutter_image_data_create(session.value, &image,
                                          &image_handle, &status),
            status, "image_data_create");

  const auto surface = CreateObject(session.value, "vtkFlyingEdges3D");
  Invoke(session.value, surface, "SetInputData",
         nlohmann::json::array({{{"Id", image_handle}}}));
  Invoke(session.value, surface, "SetValue",
         nlohmann::json::array({0, 0.0}));
  const auto output =
      ResultHandle(Invoke(session.value, surface, "GetOutputPort",
                          nlohmann::json::array({0})));

  const auto mapper = CreateObject(session.value, "vtkPolyDataMapper");
  Invoke(session.value, mapper, "SetInputConnection",
         nlohmann::json::array({0, {{"Id", output}}}));
  Invoke(session.value, mapper, "ScalarVisibilityOff");

  const auto actor = CreateObject(session.value, "vtkActor");
  Invoke(session.value, actor, "SetMapper",
         nlohmann::json::array({{{"Id", mapper}}}));
  const auto renderer = CreateObject(session.value, "vtkRenderer");
  Invoke(session.value, renderer, "AddActor",
         nlohmann::json::array({{{"Id", actor}}}));
  Invoke(session.value, renderer, "SetBackground",
         nlohmann::json::array({0.05, 0.08, 0.12}));
  Invoke(session.value, renderer, "ResetCamera");

  FrameHarness harness;
  const VtkFlutterFrameCallbacks callbacks{
      sizeof(VtkFlutterFrameCallbacks),
      VTK_FLUTTER_FRAME_CALLBACKS_VERSION,
      &harness,
      BeginFrame,
      EndFrame,
      CancelFrame,
  };
  const auto *api = vtk_flutter_get_presentation_api();
  VtkFlutterTextureTarget *target = nullptr;
  RequireOk(api->texture_target_create(&callbacks, &target, &status), status,
            "texture_target_create");
  RequireOk(api->session_attach_texture_target(session.value, target, &status),
            status, "session_attach_texture_target");

  const VtkFlutterViewport viewport{96, 96};
  VtkFlutterFrameMetrics metrics{};
  RequireOk(vtk_flutter_session_render(session.value, renderer, &viewport,
                                       &metrics, &status),
            status, "session_render");
  Require(harness.begin_count == 1 && harness.end_count == 1 &&
              harness.cancel_count == 0,
          "frame callback transaction failed");
  Require(std::any_of(harness.pixels.begin(), harness.pixels.end(),
                      [](std::uint8_t value) { return value != 0; }),
          "rendered frame is blank");
  Require(metrics.world_to_clip_valid == 1,
          "render omitted world-to-clip matrix");

  RequireOk(api->session_detach_texture_target(session.value, target, &status),
            status, "session_detach_texture_target");
  RequireOk(api->texture_target_destroy(target, &status), status,
            "texture_target_destroy");
}
} // namespace

int main(int argc, char **argv) {
  try {
    Require(argc == 2, "one test case name is required");
    const std::string_view test_case = argv[1];
    if (test_case == "public_header") {
      TestPublicHeader();
    } else if (test_case == "cpu_frame_copy") {
      TestCpuFrameCopy();
    } else if (test_case == "generic_session") {
      TestGenericSession();
    } else if (test_case == "surface_render") {
      TestSurfaceRender();
    } else {
      throw std::runtime_error("unknown test case");
    }
    return EXIT_SUCCESS;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return EXIT_FAILURE;
  }
}
