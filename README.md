# vtk_flutter

An open-source Flutter plugin for focused VTK-backed volume rendering. The
package owns its Dart API, native VTK integration, Flutter texture adapters,
and a self-contained example.

## Current status

The public Dart contract and portable VTK 9.5.2 core are implemented. Platform
adapters are qualified independently; see [platform support](docs/platform-support.md)
for the current evidence and limitations.

## Use the package

Once a package version is published, add it to a Flutter application and run
the application normally:

```sh
flutter pub add vtk_flutter
flutter run
```

No VTK SDK, CMake setup, CocoaPods customization, or application-owned C++ is
required. A Dart build hook selects the current target, downloads the pinned
native library from an immutable GitHub Release, verifies its SHA-256 digest,
and bundles it as a Dart code asset. Flutter's normal platform build compiles
only the small texture adapter.

Apple applications can consume that adapter through Swift Package Manager or
CocoaPods. Flutter 3.44 and later prefer Swift Package Manager.

## Develop the repository

The repository uses Flutter 3.44.6 through FVM.

```sh
fvm flutter pub get
fvm dart run tool/check.dart
```

Maintainers building native release artifacts can bootstrap the checksum-pinned
VTK source and run host integration checks:

```sh
fvm dart run tool/bootstrap_vtk.dart --platform macos-arm64
fvm dart run tool/check.dart --full
```

The example becomes a normal zero-setup consumer after the corresponding
native GitHub Release exists. Before that release, maintainers can set
`hooks.user_defines.vtk_flutter.native_artifact` in the example application's
`pubspec.yaml` to a locally built library; the build-hook tests cover this
override explicitly.

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
- Platform directories contain only Flutter texture and presentation glue.
- `example/` is a synthetic renderer lab with no patient or backend data.

The package intentionally exposes three product-level rendering modes rather
than generic bindings for arbitrary VTK C++ objects: oblique MPR, 3D volume,
and high-visibility volume locator.

See [architecture](docs/architecture.md) and the [ABI contract](docs/abi.md)
before changing native code. The bounded VTK 9.6 session evaluation is recorded
in [docs/vtk-session-evaluation.md](docs/vtk-session-evaluation.md).
