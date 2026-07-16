# Repository instructions

## Purpose

This repository is the open-source `vtk_flutter` package published by
`bieker.ninja` from <https://github.com/wwwdata/vtk_flutter>.

## Required workflow

- Use FVM and the Flutter version pinned in `.fvmrc`.
- Run `fvm dart run tool/check.dart` after Dart changes.
- Run the affected native CMake and platform build after native changes.
- Add focused unit or integration coverage for every behavior change.
- Keep commits small and coherent; never commit `.dart_tool`, VTK source,
  native libraries, build products, patient data, or local signing state.

## Architecture rules

- Product behavior, validation, and public state belong in Dart.
- The public native boundary is `native/include/vtk_flutter.h` and must remain a
  C ABI containing only fixed-width C-compatible types.
- Never expose VTK, STL, Flutter, CoreVideo, JNI, Objective-C, or Win32 types in
  the public C header.
- Generated FFI bindings are committed and regenerated from `ffigen.yaml`; do
  not edit them manually.
- VTK scene construction belongs in the shared native core. Platform adapters
  only own context, surface, texture registration, presentation, and lifecycle.
- Preserve native render-thread affinity and explicit, idempotent session close.
- Do not add dependencies on private repositories, unpublished local paths, or
  organization-specific application code.

## Package conventions

- Functions with more than one parameter use named Dart parameters.
- Prefer immutable public value objects and typed failures.
- Avoid force unwraps and silent native fallbacks.
- Tests use descriptive names without external ticket suffixes.
- The example uses synthetic data and only the public `vtk_flutter` API.
- Keep `publish_to: none` until the first public release is explicitly
  approved.
