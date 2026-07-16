# Native ABI

The canonical native contract is `native/include/vtk_flutter.h`.

- The direct-export ABI remains version 1 during migration. ABI-v2 is discovered
  through its versioned, size-checked function table and descriptors.
- The header must compile as C11 without VTK or Flutter headers.
- Native functions return `VtkFlutterStatusCode` and fill a bounded status
  message. C++ exceptions never cross the boundary.
- Voxel data is x-fastest signed-int16 and is deep-copied by `set_volume`.
- The affine is a finite row-major 4x4 index-to-patient transform.
- Volumes are limited to 256 MiB and each dimension to 4096.
- Render requests carry their viewport and all mode-specific values.
- ABI-v2 sessions and texture targets are opaque core allocations and are
  destroyed exactly once. See [abi-v2.md](abi-v2.md) for callback storage,
  attachment, serialization, and re-entry rules.

Regenerate bindings with:

```sh
fvm dart run ffigen --config ffigen.yaml
```
