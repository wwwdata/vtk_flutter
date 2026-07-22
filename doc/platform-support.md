# Platform support

The build and runtime matrices are related but different. A native artifact
row proves that VTK 9.6.2 and the generic core cross-compile for that target.
A consumer build additionally checks the Flutter presentation adapter and code
asset packaging. Runtime qualification requires a real render and lifecycle
test on suitable hardware.

| Runtime | Artifact target | Presentation | CI evidence |
| --- | --- | --- | --- |
| macOS Apple silicon | `macos-arm64` | Flutter texture backed by platform pixel storage | Native build, host contracts, Dart FFI smoke, consumer build, real recipe renders |
| macOS Intel | `macos-x64` | Flutter texture backed by platform pixel storage | Native build and host contracts |
| iOS device | `ios-arm64` | Flutter texture backed by platform pixel storage | Cross-compile |
| iOS Simulator Apple silicon | `ios-simulator-arm64` | Flutter texture backed by platform pixel storage | Cross-compile and consumer build |
| iOS Simulator Intel | `ios-simulator-x64` | Flutter texture backed by platform pixel storage | Cross-compile and consumer build |
| Android 64-bit ARM | `android-arm64` | Flutter texture backed by Android surface storage | Cross-compile |
| Android 32-bit ARM | `android-armeabi-v7a` | Flutter texture backed by Android surface storage | Cross-compile |
| Android x86-64 | `android-x86_64` | Flutter texture backed by Android surface storage | Cross-compile and consumer build |
| Windows x86-64 | `windows-x64` | Flutter pixel-buffer texture | Native build, headless contracts, consumer build |
| Web | none | vtk.js/WebGL rendered output | Dart/vtk.js tests, deterministic asset rebuild, release Web build |

These are the complete nine native artifact targets plus Web. Linux is not
implemented.

Android, iOS, macOS, and Windows presentation adapters support multiple live
native sessions. Each session has independently addressed texture, frame,
viewport, and lifecycle state. Web sessions are managed by the vtk.js backend
and do not use the native presentation-adapter contract.

## Capability rules

Callers must query `VtkCapabilities` and treat it as the source of truth.
Platform names alone do not guarantee that an object type, scalar type,
operation, or rendering path is available.

Native builds target the curated typed wrapper set backed by VTK 9.6.2. Exact
runtime support can still depend on graphics drivers and usable platform
surfaces.

Web has deliberate limits:

- it does not load a native artifact or use Dart FFI;
- only the object and operation subset implemented by the vtk.js backend is
  available;
- polydata connectivity supports all-region and largest-region extraction, but
  not closest-point extraction or region coloring;
- supported scalar types and maximum image bytes may be lower than native;
- browser WebGL and memory limits can disable rendering at runtime;
- synchronous native timing and presentation behavior do not map exactly to
  JavaScript; and
- the experimental dynamic API is limited to backend allow-listed mappings and
  may not match native coverage.

Unsupported operations fail as typed capability or state errors. They must not
silently switch to an unrelated pipeline.

## Qualification policy

Cross-compilation is necessary but does not establish production runtime
support. A platform is runtime-qualified only after deterministic rendering,
frame publication, resize, repeated session creation, cancellation/error
handling, and disposal pass on the target environment.

GitHub-hosted Windows runners do not provide the graphics environment needed
for all real-render contracts. That row runs public-ABI, CPU-frame, generic
session, and lifecycle contracts with real rendering disabled. Device runtime
qualification remains a separate hardware task for iOS and Android.
