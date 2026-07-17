# Repository instructions

## Purpose

This repository develops the open-source `vtk_flutter` package at
<https://github.com/wwwdata/vtk_flutter>. The package is experimental and
unpublished. Keep `publish_to: none`; do not publish it without explicit
maintainer approval and a separate release-readiness change.

## Required workflow

- Use FVM and the Flutter version pinned in `.fvmrc`.
- Run `fvm dart tool/check.dart` after Dart changes.
- Run the affected native CMake and platform build after native changes.
- Add focused unit or integration coverage for every behavior change.
- Keep commits small and coherent; never commit `.dart_tool`, VTK source,
  native libraries, build products, private datasets, or local signing state.
- Native build workflows may upload short-lived workflow artifacts. Only the
  gated native-release workflow may create downloadable native release assets.
- Never add a package-publishing workflow while `publish_to: none` is present.

## Architecture rules

- Dart owns product-independent pipeline construction, validation, public
  state, capabilities, operation serialization, and object/session lifecycle.
- The public native boundary is `native/include/vtk_flutter.h` and remains a
  minimal C ABI containing only opaque handles and fixed-width C-compatible
  types.
- Never expose VTK, STL, Flutter, CoreVideo, JNI, Objective-C, or Win32 types in
  the public C header.
- Generated FFI bindings are committed and regenerated from `ffigen.yaml`; do
  not edit them manually.
- The shared native core owns VTK objects and rendering. Platform adapters own
  only context/surface integration, Flutter texture registration, frame
  presentation, and platform lifecycle.
- Public Dart callers use typed wrappers. Any future dynamic object API must be
  explicitly experimental, capability-gated, and isolated from the stable API.
- Preserve native render-thread affinity and explicit, idempotent session and
  object disposal.
- Do not add dependencies on private repositories, unpublished local paths, or
  organization-specific application code.

## Package conventions

- Functions with more than one parameter use named Dart parameters.
- Prefer immutable public value objects and typed failures.
- Avoid force unwraps and silent native fallbacks.
- Tests use descriptive names without external ticket suffixes.
- Examples use generated or public sample data and only public package APIs.
- Keep native artifact target names synchronized across the build hook,
  bootstrap tool, GitHub Actions matrices, and documentation.
- Keep the VTK version, source URL, SHA-256 digest, CMake package directory,
  enabled modules, and serialization-wrapping flags synchronized.
