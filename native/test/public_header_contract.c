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
_Static_assert(sizeof(VtkFlutterObjectHandle) == sizeof(uint32_t),
               "object handles must remain 32-bit");

int vtk_flutter_public_header_contract(void) {
  return VTK_FLUTTER_ABI_VERSION == 3U &&
         VTK_FLUTTER_PRESENTATION_API_VERSION == 1U;
}
