# Platform support

| Platform | Initial target | Modes | Presentation | Current evidence |
|---|---|---|---|---|
| macOS | arm64 | MPR, 3D, locator | IOSurface/OpenGL external texture | Qualified: package-local VTK build, consumer build, and render/lifecycle integration test |
| iOS | arm64 simulator and device | MPR, 3D, locator | FlutterTexture/CoreVideo | Implemented; Apple-host build and device/simulator render qualification pending |
| Android | arm64-v8a | MPR, 3D, locator | SurfaceTexture/EGL | Build-qualified with Kotlin, Gradle, NDK link, ABI, and channel checks; device render pending |
| Windows | x64 | MPR, 3D, locator | Pixel-buffer texture fallback | Implemented and contract-checked; Windows-host build and render pending |
| Web | Chrome | locator | vtk.js image presentation | Release build-qualified; browser render qualification pending |
| Linux | deferred | none | unsupported | Not implemented |

A platform is supported only after its example build, deterministic synthetic
render, presentation acknowledgement, resize, repeated-session, and lifecycle
checks pass. Dart capability reporting must describe unavailable modes; callers
must not infer support from the operating-system name.

`fvm dart run tool/check.dart --full` runs all portable checks plus the native
core, desktop example build, and renderer integration test available on the
current macOS or Windows host. The remaining target-specific rows must be
qualified on their actual hosts before production use.
