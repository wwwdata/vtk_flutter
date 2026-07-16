# vtk_flutter

An open-source Flutter plugin for focused VTK-backed volume rendering. The
package owns its Dart API, native VTK integration, Flutter texture adapters,
and a self-contained example.

## Current status

The public Dart contract and portable VTK 9.5.2 core are implemented. Platform
adapters are qualified independently; see [platform support](docs/platform-support.md)
for the current evidence and limitations.

## Setup

The repository uses Flutter 3.44.6 through FVM.

```sh
fvm flutter pub get
fvm dart run tool/bootstrap_vtk.dart --platform macos-arm64
fvm dart run tool/check.dart --full
cd example && fvm flutter run -d macos
```

The bootstrap command downloads the pinned VTK source archive, verifies its
SHA-256, and installs the selected static native build beneath `.dart_tool/vtk/`.
Use `--help` to list all targets and `--source-dir` to reuse an existing VTK
9.5.2 checkout.

## Public API

```dart
final renderer = VtkRenderer();
final session = await renderer.open(VtkViewport(width: 640, height: 360));
await session.setVolume(volume);
await session.render(
  VtkVolume3dRequest(
    windowCenter: 350,
    windowWidth: 1800,
    azimuth: 35,
    elevation: 20,
    zoom: 1.35,
  ),
);

// Place this in the widget tree and close the session when its owner disposes.
VtkView(session: session);
```

`VtkVolume` accepts x-fastest signed-int16 bytes, three dimensions, and a
row-major 4x4 index-to-patient affine. The example creates deterministic data
and exercises every available mode, resize, volume replacement, graphics
context recreation, and session disposal/recreation.

## Package shape

- `lib/` contains the stable Dart API and generated FFI bindings.
- `native/` contains the C ABI and shared VTK pipeline.
- Platform directories contain only Flutter texture and graphics-context glue.
- `example/` is a synthetic renderer lab with no patient or backend data.

The package intentionally exposes three product-level rendering modes rather
than generic bindings for arbitrary VTK C++ objects: oblique MPR, 3D volume,
and high-visibility volume locator.

See [architecture](docs/architecture.md) and the [ABI contract](docs/abi.md)
before changing native code. The bounded VTK 9.6 session evaluation is recorded
in [docs/vtk-session-evaluation.md](docs/vtk-session-evaluation.md).
