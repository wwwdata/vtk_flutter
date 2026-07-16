# Platform support

| Platform | Initial target | Modes | Presentation | Current evidence |
|---|---|---|---|---|
| macOS | arm64, x64 | MPR, 3D, locator | BGRA CVPixelBuffer texture | Qualified on arm64: SwiftPM consumer build plus render, resize, replacement, recreation, and disposal integration test; x64 build-covered in CI |
| iOS | arm64 device; arm64/x64 simulator | MPR, 3D, locator | BGRA CVPixelBuffer texture | Adapter and SwiftPM/CocoaPods build-qualified; device render qualification pending |
| Android | arm64-v8a, armeabi-v7a, x86_64 | MPR, 3D, locator | RGBA staging to ANativeWindow SurfaceTexture | Adapter and consumer APK build-qualified; device render qualification pending |
| Windows | x64 | MPR, 3D, locator | Flutter pixel-buffer texture | Native CPU/ABI/lifecycle contracts, adapter, and consumer build-qualified; Windows render qualification pending |
| Web | Chrome | locator | vtk.js image presentation | Release build-qualified; browser render qualification pending |
| Linux | deferred | none | unsupported | Not implemented |

A platform is supported only after its example build, deterministic synthetic
render, presentation acknowledgement, resize, repeated-session, and lifecycle
checks pass. Dart capability reporting must describe unavailable modes; callers
must not infer support from the operating-system name.

`fvm dart run tool/check.dart --full` runs all portable checks plus the native
core, desktop example build, and renderer integration test available on the
current macOS or Windows host. GitHub Actions also builds all nine native code
assets and consumes them from macOS, iOS Simulator, Android, and Windows
example builds. The remaining device-render rows must be qualified on actual
hardware before production use.
