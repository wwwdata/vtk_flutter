# vtk_flutter

`vtk_flutter` is an experimental, domain-agnostic Flutter integration for
[VTK](https://vtk.org/). It lets Dart code assemble typed visualization
pipelines while a small native core executes those pipelines with VTK 9.6.2
and platform plugins present completed frames to Flutter.

The package is under active development and is not published to pub.dev.
`publish_to: none` is intentional; use a reviewed source dependency only if
you are prepared for API and artifact-contract changes.

## Architecture at a glance

- Dart owns public types, validation, pipeline construction, object lifetimes,
  capabilities, and serialized session operations.
- Native code exposes a minimal, generic C ABI: opaque sessions and object
  handles, image-data upload, typed-wrapper invocation transport, rendering,
  status reporting, and explicit destruction.
- Android, iOS, macOS, and Windows plugins are presentation adapters. They
  register Flutter textures, provide frame storage, publish completed frames,
  and manage platform lifecycle; they do not construct VTK pipelines.
- Web uses a vtk.js backend and reports a smaller capability set. Native and
  Web callers must query capabilities instead of assuming feature parity.

The supported Dart API is a curated set of typed VTK wrappers. A broader
dynamic object API is available only through `vtk_flutter_experimental.dart`
as an explicitly unstable escape hatch; it is not a stable mirror of the VTK
C++ API.

See [Architecture](doc/architecture.md) for ownership and boundary details.

## Atomic multi-renderer layouts

One `VtkSession` can render several owned `VtkRenderer` objects into disjoint
normalized viewports of one Flutter texture. The operation resizes, renders,
captures, and presents the complete layout once:

```dart
await session.renderLayout(
  layers: [
    VtkRenderLayer(
      renderer: overviewRenderer,
      viewport: VtkNormalizedViewport(
        left: 0,
        bottom: 0,
        right: 0.4,
        top: 1,
      ),
    ),
    VtkRenderLayer(
      renderer: detailRenderer,
      viewport: VtkNormalizedViewport(
        left: 0.4,
        bottom: 0,
        right: 1,
        top: 1,
      ),
    ),
  ],
  viewport: VtkViewport(width: 1200, height: 800),
  primaryLayer: 1,
);
```

Normalized VTK viewport coordinates use a bottom-left origin. Flutter image
coordinates use a top-left origin, so consumers cropping a shared texture must
flip the vertical coordinate. Viewports may touch but cannot overlap. Every
renderer must be live, unique, and owned by the same session. The returned
`worldToClip` matrix belongs to `primaryLayer` and uses that layer's pixel
aspect ratio. `render(renderer:, viewport:)` remains the full-texture,
one-renderer convenience API.

## Platforms

The native artifact matrix contains nine targets:

| Flutter platform | Artifact targets |
| --- | --- |
| macOS | `macos-arm64`, `macos-x64` |
| iOS | `ios-arm64`, `ios-simulator-arm64`, `ios-simulator-x64` |
| Android | `android-arm64`, `android-armeabi-v7a`, `android-x86_64` |
| Windows | `windows-x64` |
| Web | No native artifact; vtk.js backend |

Web is the tenth runtime row, but it is not a native build target. Linux is not
currently implemented. Detailed qualification and capability limits are in
[Platform support](doc/platform-support.md).

## Native artifact delivery

Applications do not build VTK. A Dart build hook selects the target-specific
native library, downloads it from the pinned immutable GitHub native release,
verifies its SHA-256 digest, and bundles it as a code asset. Flutter then
builds only the platform presentation adapter.

Maintainers can override the download with a local library or a directory of
target-specific libraries. Release assets, integrity metadata, and the
separation between package quality and native releases are documented in
[Native artifacts](doc/native-artifacts.md).

## Develop locally

The repository pins Flutter 3.44.6 through FVM.

```sh
fvm flutter pub get
fvm flutter pub get --directory example
fvm dart tool/check.dart
```

For a complete host check, first bootstrap VTK 9.6.2 for the current native
target, then run:

```sh
fvm dart tool/bootstrap_vtk.dart --platform macos-arm64
fvm dart tool/check.dart --full
```

Use `windows-x64` on Windows and `macos-x64` on an Intel Mac. Cross-compiled
iOS and Android targets are built in GitHub Actions. See
[Local verification](doc/development.md) for the full check matrix.

## Project layout

- `lib/` contains public Dart types, typed VTK wrappers, lifecycle management,
  backend protocols, and generated FFI bindings.
- `native/` contains the generic C ABI, VTK-backed object session, render
  target, and native contract tests.
- `android/`, `ios/`, `macos/`, and `windows/` contain presentation-only
  Flutter adapters.
- `web/` builds the vtk.js backend assets.
- `hook/` and `tool/` select, verify, build, and test native artifacts.

## Licensing

`vtk_flutter` is BSD 3-Clause licensed. VTK 9.6.2, vtk.js, and bundled
third-party components retain their own notices and licenses. See
[Licensing](doc/licensing.md), [LICENSE](LICENSE), and [NOTICE](NOTICE).
