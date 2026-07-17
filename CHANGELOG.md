## 0.2.0-dev.1 (unpublished)

- Replace product-specific rendering requests with Dart-owned, typed VTK
  pipeline objects and capability-aware sessions.
- Reduce the native boundary to a generic VTK 9.6.2 C ABI with opaque object
  handles, image upload, invocation, rendering, presentation callbacks, and
  explicit lifecycle management.
- Keep Android, iOS, macOS, and Windows plugins focused on Flutter texture
  presentation and platform lifecycle.
- Define nine checksum-pinned native artifact targets and a capability-limited
  vtk.js Web backend.
- Separate package/Web quality checks, native build qualification, and gated
  native artifact releases. The package remains unpublished.

## 0.1.0-dev.1 (unpublished)

- Add the initial typed Dart session and rendering experiment.
- Add checksum-verified native code-asset delivery.
- Add initial Android, iOS, macOS, Windows, and Web adapters.
- Add Swift Package Manager and CocoaPods support for Apple platforms.
- Add synthetic examples and native contract coverage.
