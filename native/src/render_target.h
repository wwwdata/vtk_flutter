#ifndef VTK_FLUTTER_RENDER_TARGET_H_
#define VTK_FLUTTER_RENDER_TARGET_H_

#include "volume_pipeline.h"

namespace vtk_flutter {
// Transitional private seam implemented by each platform. ABI v2 erases the
// concrete type behind VtkFlutterTextureTarget and brackets rendering with C
// callbacks, but the platform module still constructs this C++ object. The
// final code-asset migration must move this implementation into the core so no
// C++ or VTK type crosses a dynamic-library boundary. An adapter owns its
// concrete VTK render window, graphics context, Flutter/native
// presentation surface, synchronization, and frame lifetime. Render is called
// with a fully configured renderer. The adapter attaches it to its window,
// renders at viewport size, publishes the frame, and fills target-specific
// metrics. When capture_patient_to_clip is true it also captures the final
// camera projection after attachment, because the render target owns the
// effective aspect ratio.
class RenderTarget {
public:
  virtual ~RenderTarget() = default;

  virtual void Render(PreparedView view, const VtkFlutterViewport &viewport,
                      VtkFlutterMetrics &metrics) = 0;
};
} // namespace vtk_flutter

#endif // VTK_FLUTTER_RENDER_TARGET_H_
