# vtk_flutter showcase

This example demonstrates three reusable visualization recipes built with the
typed public API exported by `package:vtk_flutter/vtk_flutter.dart`.

- **Oblique reslice** builds a two-dimensional angled slice with window/level
  mapping, an image mapper, and a parallel-projection camera.
- **Volume ray cast** uses the public `VtkSmartVolumeMapper` to build a
  composite volume pipeline with color and opacity transfer functions,
  optional shading, and perspective camera controls. The mapper is GPU-capable,
  but the current public API cannot force or report a GPU execution mode.
- **Extracted surface** builds an isosurface with largest-region connectivity,
  optional windowed-sinc smoothing, surface styling, and perspective camera
  controls.

The input is a deterministic unsigned 16-bit scalar field generated entirely in
memory by `createSyntheticScalarField`. The example downloads no datasets and
imports no package internals, experimental API, backend-specific API, or native
VTK symbols. The recipe builders in `lib/recipes.dart` return a renderer and
camera so applications can render the scene through a `VtkSession`.

The app presents each selected recipe beside a companion renderer using one
atomic `VtkSession.renderLayout` call. This keeps both regions in one session
and one Flutter texture while visibly exercising the multi-renderer contract.

## Run the showcase

From this directory:

```sh
fvm flutter pub get
fvm flutter run -d macos
```

Replace `macos` with another configured device supported by your local
`vtk_flutter` runtime.

## Run the tests

The focused tests use an in-memory backend recorder, so they validate scalar
data and typed pipeline orchestration without requiring native rendering:

```sh
fvm flutter test test/scalar_field_test.dart test/recipes_test.dart
```

The modest widget smoke test makes no assumption about renderer support:

```sh
fvm flutter test test/showcase_app_test.dart
```

The macOS consumer integration test launches the real app, switches through
every supported recipe, and requires a rendered frame from each:

```sh
fvm flutter test integration_test/renderer_lab_test.dart -d macos
```

When developing against an unreleased native library, configure the temporary
`hooks.user_defines.vtk_flutter.native_artifact` override described in the
repository contributing guide. Do not commit that local override.
