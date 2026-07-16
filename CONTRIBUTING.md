# Contributing

Thanks for helping improve `vtk_flutter`.

## Development setup

Install the Flutter version declared in `.fvmrc`, then run:

```sh
fvm flutter pub get
cd example && fvm flutter pub get && cd ..
fvm dart run tool/check.dart
```

Native rendering changes must also pass the full checks on an affected host:

```sh
fvm dart run tool/bootstrap_vtk.dart --platform <target>
fvm dart run tool/check.dart --full
```

Run `npm ci && npm run build` in `web/` after changing the vtk.js bridge. Commit
the regenerated bundle and license notice with its source change.

## Pull requests

Keep changes focused, add tests for observable behavior, and update platform
support documentation only when the corresponding build or render evidence is
available. Do not commit downloaded VTK sources, native build outputs, signing
identities, patient data, or application-specific code.
