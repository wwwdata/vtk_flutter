#include "vtk_flutter.h"

_Static_assert(VTK_FLUTTER_ABI_VERSION == 1U, "unexpected ABI version");
_Static_assert(VTK_FLUTTER_RENDER_OBLIQUE_MPR == 1,
               "unexpected oblique mode value");
_Static_assert(VTK_FLUTTER_RENDER_VOLUME_3D == 2,
               "unexpected volume mode value");
_Static_assert(VTK_FLUTTER_RENDER_VOLUME_LOCATOR == 3,
               "unexpected locator mode value");

int vtk_flutter_public_header_is_c_compatible(void) {
  VtkFlutterStatus status = {0};
  vtk_flutter_status_clear(&status);
  return status.code;
}
