#include "vtk_flutter.h"

#include <stddef.h>
#include <stdint.h>

_Static_assert(offsetof(VtkFlutterPresentationApi, version) ==
                   sizeof(uint32_t),
               "presentation API prefix changed");
_Static_assert(offsetof(VtkFlutterFrameCallbacks, version) ==
                   sizeof(uint32_t),
               "frame callback prefix changed");
_Static_assert(offsetof(VtkFlutterCpuFrame, version) == sizeof(uint32_t),
               "CPU frame prefix changed");
_Static_assert(offsetof(VtkFlutterRenderLayer, version) == sizeof(uint32_t),
               "render layer prefix changed");
_Static_assert(sizeof(VtkFlutterObjectHandle) == sizeof(uint32_t),
               "object handles must remain 32-bit");

int vtk_flutter_public_header_contract(void) {
  return VTK_FLUTTER_ABI_VERSION == 4U &&
         VTK_FLUTTER_RENDER_LAYER_VERSION == 1U &&
         VTK_FLUTTER_MAX_RENDER_LAYERS == 64U &&
         VTK_FLUTTER_PRESENTATION_API_VERSION == 2U;
}
