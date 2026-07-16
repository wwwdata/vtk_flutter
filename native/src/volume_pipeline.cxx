#include "volume_pipeline.h"

#include <vtkActor.h>
#include <vtkCamera.h>
#include <vtkColorTransferFunction.h>
#include <vtkFlyingEdges3D.h>
#include <vtkGPUVolumeRayCastMapper.h>
#include <vtkImageActor.h>
#include <vtkImageData.h>
#include <vtkImageMapper3D.h>
#include <vtkImageProperty.h>
#include <vtkImageReslice.h>
#include <vtkImageShiftScale.h>
#include <vtkMatrix3x3.h>
#include <vtkNew.h>
#include <vtkPiecewiseFunction.h>
#include <vtkPolyData.h>
#include <vtkPolyDataConnectivityFilter.h>
#include <vtkPolyDataMapper.h>
#include <vtkProperty.h>
#include <vtkRenderer.h>
#include <vtkVolume.h>
#include <vtkVolumeProperty.h>
#include <vtkWindowedSincPolyDataFilter.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <stdexcept>

namespace {
constexpr int SyntheticVolumeWidth = 96;
constexpr int SyntheticVolumeHeight = 80;
constexpr int SyntheticVolumeDepth = 64;
constexpr int MaximumVolumeDimension = 4096;
constexpr int MaximumViewportDimension = 8192;
constexpr std::uint64_t MaximumVolumeBytes = 256ULL * 1024ULL * 1024ULL;
constexpr std::uint64_t MaximumFrameBytes = 256ULL * 1024ULL * 1024ULL;

vtkSmartPointer<vtkImageData> CreateSyntheticVolume() {
  vtkNew<vtkImageData> image;
  image->SetDimensions(SyntheticVolumeWidth, SyntheticVolumeHeight,
                       SyntheticVolumeDepth);
  image->SetSpacing(0.8, 0.8, 1.2);
  image->SetOrigin(-SyntheticVolumeWidth * 0.4, -SyntheticVolumeHeight * 0.4,
                   -SyntheticVolumeDepth * 0.6);
  image->AllocateScalars(VTK_SHORT, 1);

  for (int z = 0; z < SyntheticVolumeDepth; ++z) {
    for (int y = 0; y < SyntheticVolumeHeight; ++y) {
      for (int x = 0; x < SyntheticVolumeWidth; ++x) {
        const double dx = (x - 47.5) / 40.0;
        const double dy = (y - 39.5) / 31.0;
        const double dz = (z - 31.5) / 25.0;
        const double radius = dx * dx + dy * dy + dz * dz;
        std::int16_t value = -1000;
        if (radius < 1.0) {
          value = 45;
        }
        if (radius < 0.52) {
          value = 320;
        }
        if (radius < 0.13) {
          value = 1050;
        }
        const double marker = std::pow((x - 68.0) / 6.0, 2.0) +
                              std::pow((y - 29.0) / 5.0, 2.0) +
                              std::pow((z - 39.0) / 8.0, 2.0);
        if (marker < 1.0) {
          value = 1750;
        }
        *static_cast<std::int16_t *>(image->GetScalarPointer(x, y, z)) = value;
      }
    }
  }
  return image;
}

vtkSmartPointer<vtkRenderer>
PrepareObliqueScene(vtkImageData *image,
                    const VtkFlutterRenderRequest &request) {
  const double normal_length =
      std::sqrt(request.plane_normal[0] * request.plane_normal[0] +
                request.plane_normal[1] * request.plane_normal[1] +
                request.plane_normal[2] * request.plane_normal[2]);
  const double n[3] = {request.plane_normal[0] / normal_length,
                       request.plane_normal[1] / normal_length,
                       request.plane_normal[2] / normal_length};
  const bool use_superior_reference = std::abs(n[2]) < 0.9;
  const double reference[3] = {0.0, use_superior_reference ? 0.0 : 1.0,
                               use_superior_reference ? 1.0 : 0.0};
  double x[3] = {reference[1] * n[2] - reference[2] * n[1],
                 reference[2] * n[0] - reference[0] * n[2],
                 reference[0] * n[1] - reference[1] * n[0]};
  const double x_length = std::sqrt(x[0] * x[0] + x[1] * x[1] + x[2] * x[2]);
  for (double &value : x) {
    value /= x_length;
  }
  const double y[3] = {n[1] * x[2] - n[2] * x[1], n[2] * x[0] - n[0] * x[2],
                       n[0] * x[1] - n[1] * x[0]};

  int extent[6]{};
  image->GetExtent(extent);
  double half_width = 0.0;
  double half_height = 0.0;
  for (int corner = 0; corner < 8; ++corner) {
    double point[3]{};
    image->TransformIndexToPhysicalPoint(
        extent[(corner & 1) != 0 ? 1 : 0], extent[(corner & 2) != 0 ? 3 : 2],
        extent[(corner & 4) != 0 ? 5 : 4], point);
    const double offset[3] = {point[0] - request.plane_origin[0],
                              point[1] - request.plane_origin[1],
                              point[2] - request.plane_origin[2]};
    half_width =
        std::max(half_width, std::abs(offset[0] * x[0] + offset[1] * x[1] +
                                      offset[2] * x[2]));
    half_height =
        std::max(half_height, std::abs(offset[0] * y[0] + offset[1] * y[1] +
                                       offset[2] * y[2]));
  }
  const double output_spacing =
      std::max({0.1, half_width * 2.1 / request.viewport.width,
                half_height * 2.1 / request.viewport.height});
  vtkNew<vtkImageReslice> reslice;
  reslice->SetInputData(image);
  reslice->SetOutputDimensionality(2);
  reslice->SetOutputDirection(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0);
  reslice->SetInterpolationModeToLinear();
  reslice->SetResliceAxesDirectionCosines(x[0], x[1], x[2], y[0], y[1], y[2],
                                          n[0], n[1], n[2]);
  reslice->SetResliceAxesOrigin(request.plane_origin);
  reslice->SetOutputSpacing(output_spacing, output_spacing, 1.0);
  reslice->SetOutputOrigin(-request.viewport.width * output_spacing * 0.5,
                           -request.viewport.height * output_spacing * 0.5,
                           0.0);
  reslice->SetOutputExtent(0, request.viewport.width - 1, 0,
                           request.viewport.height - 1, 0, 0);
  vtkNew<vtkImageShiftScale> display_values;
  display_values->SetInputConnection(reslice->GetOutputPort());
  display_values->SetShift(
      -(request.window_center - request.window_width * 0.5));
  display_values->SetScale(255.0 / request.window_width);
  display_values->SetOutputScalarTypeToUnsignedChar();
  display_values->ClampOverflowOn();
  vtkNew<vtkImageActor> actor;
  actor->GetMapper()->SetInputConnection(display_values->GetOutputPort());
  actor->GetProperty()->SetColorWindow(255.0);
  actor->GetProperty()->SetColorLevel(127.5);
  auto renderer = vtkSmartPointer<vtkRenderer>::New();
  renderer->SetBackground(0.025, 0.035, 0.055);
  renderer->AddActor(actor);
  auto *camera = renderer->GetActiveCamera();
  const double center_x = -output_spacing * 0.5;
  const double center_y = -output_spacing * 0.5;
  camera->ParallelProjectionOn();
  camera->SetFocalPoint(center_x, center_y, 0.0);
  camera->SetPosition(center_x, center_y, 1.0);
  camera->SetViewUp(0.0, 1.0, 0.0);
  camera->SetParallelScale(request.viewport.height * output_spacing * 0.5);
  renderer->ResetCameraClippingRange();
  return renderer;
}

vtkSmartPointer<vtkRenderer>
PrepareVolumeScene(vtkImageData *image, const VtkFlutterRenderRequest &request,
                   vtkPolyData *locator_surface) {
  if (locator_surface != nullptr) {
    vtkNew<vtkPolyDataMapper> surface_mapper;
    surface_mapper->SetInputData(locator_surface);
    surface_mapper->ScalarVisibilityOff();
    vtkNew<vtkActor> surface_actor;
    surface_actor->SetMapper(surface_mapper);
    surface_actor->GetProperty()->SetColor(0.78, 0.80, 0.80);
    surface_actor->GetProperty()->SetAmbient(0.42);
    surface_actor->GetProperty()->SetDiffuse(0.82);
    surface_actor->GetProperty()->SetSpecular(0.18);
    surface_actor->GetProperty()->SetSpecularPower(18.0);
    surface_actor->GetProperty()->SetInterpolationToPhong();
    auto renderer = vtkSmartPointer<vtkRenderer>::New();
    renderer->SetBackground(0.0, 0.0, 0.0);
    renderer->SetBackgroundAlpha(0.0);
    renderer->AddActor(surface_actor);
    double bounds[6]{};
    image->GetBounds(bounds);
    const double center[3] = {(bounds[0] + bounds[1]) * 0.5,
                              (bounds[2] + bounds[3]) * 0.5,
                              (bounds[4] + bounds[5]) * 0.5};
    auto *camera = renderer->GetActiveCamera();
    camera->SetFocalPoint(center);
    constexpr double pi = 3.14159265358979323846;
    const double azimuth = request.camera_azimuth_degrees * pi / 180.0;
    const double elevation = request.camera_elevation_degrees * pi / 180.0;
    const double horizontal = std::cos(elevation);
    camera->SetPosition(center[0] + std::sin(azimuth) * horizontal,
                        center[1] + std::sin(elevation),
                        center[2] + std::cos(azimuth) * horizontal);
    camera->SetViewUp(0.0, 1.0, 0.0);
    camera->ParallelProjectionOn();
    renderer->ResetCamera(bounds);
    camera->Zoom(request.camera_zoom);
    renderer->ResetCameraClippingRange();
    return renderer;
  }

  vtkNew<vtkGPUVolumeRayCastMapper> mapper;
  vtkNew<vtkImageShiftScale> display_values;
  const double low = request.window_center - request.window_width * 0.5;
  display_values->SetInputData(image);
  display_values->SetShift(-low);
  display_values->SetScale(255.0 / request.window_width);
  display_values->SetOutputScalarTypeToUnsignedChar();
  display_values->ClampOverflowOn();
  mapper->SetInputConnection(display_values->GetOutputPort());
  mapper->SetBlendModeToComposite();
  mapper->SetAutoAdjustSampleDistances(true);
  vtkNew<vtkColorTransferFunction> colors;
  vtkNew<vtkPiecewiseFunction> opacity;
  colors->AddRGBPoint(0.0, 0.0, 0.0, 0.0);
  colors->AddRGBPoint(127.5, 0.72, 0.50, 0.36);
  colors->AddRGBPoint(255.0, 1.0, 0.98, 0.92);
  opacity->AddPoint(0.0, 0.0);
  opacity->AddPoint(127.5, 0.08);
  opacity->AddPoint(255.0, 0.75);
  vtkNew<vtkVolumeProperty> property;
  property->SetColor(colors);
  property->SetScalarOpacity(opacity);
  property->SetInterpolationTypeToLinear();
  property->ShadeOn();
  vtkNew<vtkVolume> volume;
  volume->SetMapper(mapper);
  volume->SetProperty(property);
  auto renderer = vtkSmartPointer<vtkRenderer>::New();
  renderer->SetBackground(0.025, 0.035, 0.055);
  renderer->AddVolume(volume);
  renderer->ResetCamera();
  renderer->GetActiveCamera()->Azimuth(request.camera_azimuth_degrees);
  renderer->GetActiveCamera()->Elevation(request.camera_elevation_degrees);
  renderer->GetActiveCamera()->Zoom(request.camera_zoom);
  renderer->ResetCameraClippingRange();
  return renderer;
}
} // namespace

namespace vtk_flutter {
VolumePipeline::VolumePipeline() : image_data_(CreateSyntheticVolume()) {}

VolumePipeline::~VolumePipeline() = default;

void VolumePipeline::ValidateVolume(const VtkFlutterVolume &volume) {
  if (volume.voxels == nullptr || volume.width <= 0 || volume.height <= 0 ||
      volume.depth <= 0) {
    throw std::invalid_argument(
        "volume data and positive dimensions are required");
  }
  if (volume.width > MaximumVolumeDimension ||
      volume.height > MaximumVolumeDimension ||
      volume.depth > MaximumVolumeDimension) {
    throw std::invalid_argument(
        "volume dimensions exceed the bounded VTK working-set limit");
  }
  const auto expected = static_cast<std::uint64_t>(volume.width) *
                        static_cast<std::uint64_t>(volume.height) *
                        static_cast<std::uint64_t>(volume.depth);
  if (expected != volume.voxel_count ||
      expected > MaximumVolumeBytes / sizeof(std::int16_t)) {
    throw std::invalid_argument(
        "volume voxel count is inconsistent or exceeds the 256 MiB limit");
  }
  for (double value : volume.index_to_patient) {
    if (!std::isfinite(value)) {
      throw std::invalid_argument(
          "index-to-patient matrix must contain finite values");
    }
  }
  for (int axis = 0; axis < 3; ++axis) {
    const double x = volume.index_to_patient[axis];
    const double y = volume.index_to_patient[4 + axis];
    const double z = volume.index_to_patient[8 + axis];
    const double spacing = std::sqrt(x * x + y * y + z * z);
    if (!std::isfinite(spacing) || spacing < 1e-9) {
      throw std::invalid_argument(
          "index-to-patient matrix contains a degenerate voxel axis");
    }
  }
}

void VolumePipeline::ValidateRenderRequest(
    const VtkFlutterRenderRequest &request) {
  if (request.viewport.width <= 0 || request.viewport.height <= 0 ||
      request.viewport.width > MaximumViewportDimension ||
      request.viewport.height > MaximumViewportDimension) {
    throw std::invalid_argument(
        "viewport dimensions must be between 1 and 8192 pixels");
  }
  const auto frame_bytes = static_cast<std::uint64_t>(request.viewport.width) *
                           static_cast<std::uint64_t>(request.viewport.height) *
                           4ULL;
  if (frame_bytes > MaximumFrameBytes) {
    throw std::invalid_argument("viewport exceeds the 256 MiB frame limit");
  }
  if (!std::isfinite(request.window_center) ||
      !std::isfinite(request.window_width) || request.window_width <= 0.0 ||
      !std::isfinite(request.camera_azimuth_degrees) ||
      !std::isfinite(request.camera_elevation_degrees)) {
    throw std::invalid_argument(
        "window center and positive width must be finite");
  }
  if (!std::isfinite(request.camera_zoom) || request.camera_zoom < 0.5 ||
      request.camera_zoom > 5.0 || request.camera_elevation_degrees < -89.0 ||
      request.camera_elevation_degrees > 89.0) {
    throw std::invalid_argument(
        "volume camera values are outside the supported range");
  }
  switch (request.mode) {
  case VTK_FLUTTER_RENDER_OBLIQUE_MPR: {
    double normal_length_squared = 0.0;
    for (int axis = 0; axis < 3; ++axis) {
      if (!std::isfinite(request.plane_origin[axis]) ||
          !std::isfinite(request.plane_normal[axis])) {
        throw std::invalid_argument("oblique plane values must be finite");
      }
      normal_length_squared +=
          request.plane_normal[axis] * request.plane_normal[axis];
    }
    if (!std::isfinite(normal_length_squared) ||
        normal_length_squared < 1e-18) {
      throw std::invalid_argument(
          "oblique plane normal must be finite and non-zero");
    }
    return;
  }
  case VTK_FLUTTER_RENDER_VOLUME_3D:
  case VTK_FLUTTER_RENDER_VOLUME_LOCATOR:
    return;
  default:
    throw std::invalid_argument("unsupported VTK render mode");
  }
}

void VolumePipeline::SetVolume(const VtkFlutterVolume &volume) {
  ValidateVolume(volume);

  vtkNew<vtkImageData> image;
  image->SetDimensions(volume.width, volume.height, volume.depth);
  double spacing[3]{};
  vtkNew<vtkMatrix3x3> direction;
  for (int axis = 0; axis < 3; ++axis) {
    const double x = volume.index_to_patient[axis];
    const double y = volume.index_to_patient[4 + axis];
    const double z = volume.index_to_patient[8 + axis];
    spacing[axis] = std::sqrt(x * x + y * y + z * z);
    direction->SetElement(0, axis, x / spacing[axis]);
    direction->SetElement(1, axis, y / spacing[axis]);
    direction->SetElement(2, axis, z / spacing[axis]);
  }
  image->SetSpacing(spacing);
  image->SetOrigin(volume.index_to_patient[3], volume.index_to_patient[7],
                   volume.index_to_patient[11]);
  image->SetDirectionMatrix(direction);
  image->AllocateScalars(VTK_SHORT, 1);
  std::memcpy(image->GetScalarPointer(), volume.voxels,
              static_cast<std::size_t>(volume.voxel_count) *
                  sizeof(std::int16_t));
  image_data_ = image;
  locator_surface_data_ = nullptr;
  locator_surface_builds_ = 0;
}

vtkPolyData *VolumePipeline::GetOrCreateLocatorSurface() const {
  if (locator_surface_data_ != nullptr) {
    return locator_surface_data_;
  }
  vtkNew<vtkFlyingEdges3D> surface;
  surface->SetInputData(image_data_);
  surface->SetValue(0, -300.0);
  surface->ComputeNormalsOn();
  surface->ComputeGradientsOff();
  surface->ComputeScalarsOff();
  vtkNew<vtkPolyDataConnectivityFilter> patient_region;
  patient_region->SetInputConnection(surface->GetOutputPort());
  patient_region->SetExtractionModeToLargestRegion();
  vtkNew<vtkWindowedSincPolyDataFilter> smoothed_surface;
  smoothed_surface->SetInputConnection(patient_region->GetOutputPort());
  smoothed_surface->SetNumberOfIterations(10);
  smoothed_surface->SetPassBand(0.08);
  smoothed_surface->BoundarySmoothingOff();
  smoothed_surface->FeatureEdgeSmoothingOff();
  smoothed_surface->NonManifoldSmoothingOn();
  smoothed_surface->NormalizeCoordinatesOn();
  smoothed_surface->Update();
  vtkNew<vtkPolyData> retained_surface;
  retained_surface->DeepCopy(smoothed_surface->GetOutput());
  locator_surface_data_ = retained_surface;
  ++locator_surface_builds_;
  return locator_surface_data_;
}

PreparedView
VolumePipeline::PrepareView(const VtkFlutterRenderRequest &request) const {
  ValidateRenderRequest(request);
  switch (request.mode) {
  case VTK_FLUTTER_RENDER_OBLIQUE_MPR:
    return {PrepareObliqueScene(image_data_, request), false};
  case VTK_FLUTTER_RENDER_VOLUME_3D:
    return {PrepareVolumeScene(image_data_, request, nullptr), false};
  case VTK_FLUTTER_RENDER_VOLUME_LOCATOR:
    return {
        PrepareVolumeScene(image_data_, request, GetOrCreateLocatorSurface()),
        true};
  default:
    throw std::invalid_argument("unsupported VTK render mode");
  }
}

std::size_t VolumePipeline::VolumeBytes() const {
  int dimensions[3]{};
  image_data_->GetDimensions(dimensions);
  return static_cast<std::size_t>(dimensions[0]) *
         static_cast<std::size_t>(dimensions[1]) *
         static_cast<std::size_t>(dimensions[2]) * sizeof(std::int16_t);
}

vtkImageData *VolumePipeline::Image() const { return image_data_; }

std::size_t VolumePipeline::LocatorSurfaceBuildCount() const {
  return locator_surface_builds_;
}
} // namespace vtk_flutter
