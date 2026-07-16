#ifndef VTK_FLUTTER_RENDER_TARGET_H_
#define VTK_FLUTTER_RENDER_TARGET_H_

#include "volume_pipeline.h"

namespace vtk_flutter {
// Legacy in-process platform seam retained for ABI-v1 migration. New ABI-v2
// callers use only the C callback contract in vtk_flutter.h; this C++ interface
// and PreparedView never cross the code-asset boundary.
class RenderTarget {
public:
  virtual ~RenderTarget() = default;

  virtual void Render(PreparedView view, const VtkFlutterViewport &viewport,
                      VtkFlutterMetrics &metrics) = 0;
};
} // namespace vtk_flutter

#endif // VTK_FLUTTER_RENDER_TARGET_H_
