# Native ABI

The canonical native contract is `native/include/vtk_flutter.h`.

- ABI version changes whenever an exported signature or struct layout changes.
- The header must compile as C11 without VTK or Flutter headers.
- Native functions return `VtkFlutterStatusCode` and fill a bounded status
  message. C++ exceptions never cross the boundary.
- Voxel data is x-fastest signed-int16 and is deep-copied by `set_volume`.
- The affine is a finite row-major 4x4 index-to-patient transform.
- Volumes are limited to 256 MiB and each dimension to 4096.
- Render requests carry their viewport and all mode-specific values.
- Opaque sessions are created or attached by the platform adapter and destroyed
  exactly once.

Regenerate bindings with:

```sh
fvm dart run ffigen --config ffigen.yaml
```
