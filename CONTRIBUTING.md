# Contributing

Thanks for helping improve `vtk_flutter`.

## Development setup

Install the Flutter version declared in `.fvmrc`, then run:

```sh
fvm flutter pub get
cd example && fvm flutter pub get && cd ..
fvm dart tool/check.dart
```

Native rendering changes must also pass the full checks on an affected host:

```sh
fvm dart tool/bootstrap_vtk.dart --platform <target>
fvm dart tool/check.dart --full
```

The bootstrap is a maintainer workflow, not a consumer installation step. To
exercise an unreleased local library, configure the example workspace with:

```yaml
hooks:
  user_defines:
    vtk_flutter:
      native_artifact: ../.dart_tool/native-shared-test/libvtk_flutter_core.dylib
```

For a multi-architecture build, `native_artifact` can point to a directory with
one library per target:

```text
native-artifacts/
├── ios-simulator-arm64/libvtk_flutter_core.dylib
└── ios-simulator-x64/libvtk_flutter_core.dylib
```

Do not commit that local override. Pull requests build real consumer examples
with workflow-produced target libraries on macOS, iOS Simulator, Android x64,
and Windows x64.

Run `npm ci && npm run build` in `web/` after changing the vtk.js bridge. Commit
the regenerated bundle and license notice with its source change.

## Pull requests

Keep changes focused, add tests for observable behavior, and update platform
support documentation only when the corresponding build or render evidence is
available. Do not commit downloaded VTK sources, native build outputs, signing
identities, private data, or application-specific code.
