#ifndef VTK_FLUTTER_VOLUME_PIPELINE_H_
#define VTK_FLUTTER_VOLUME_PIPELINE_H_

#include "vtk_flutter.h"

#include <vtkSmartPointer.h>

#include <cstddef>

class vtkImageData;
class vtkPolyData;
class vtkRenderer;

namespace vtk_flutter {
struct PreparedView {
  vtkSmartPointer<vtkRenderer> renderer;
  bool capture_patient_to_clip = false;
};

class VolumePipeline final {
public:
  VolumePipeline();
  ~VolumePipeline();

  VolumePipeline(const VolumePipeline &) = delete;
  VolumePipeline &operator=(const VolumePipeline &) = delete;

  static void ValidateVolume(const VtkFlutterVolume &volume);
  static void ValidateRenderRequest(const VtkFlutterRenderRequest &request);

  void SetVolume(const VtkFlutterVolume &volume);
  PreparedView PrepareView(const VtkFlutterRenderRequest &request) const;

  std::size_t VolumeBytes() const;
  vtkImageData *Image() const;
  std::size_t LocatorSurfaceBuildCount() const;

private:
  vtkPolyData *GetOrCreateLocatorSurface() const;

  vtkSmartPointer<vtkImageData> image_data_;
  mutable vtkSmartPointer<vtkPolyData> locator_surface_data_;
  mutable std::size_t locator_surface_builds_ = 0;
};
} // namespace vtk_flutter

#endif // VTK_FLUTTER_VOLUME_PIPELINE_H_
