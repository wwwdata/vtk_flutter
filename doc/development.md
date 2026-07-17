# Local verification

Use FVM so local checks match `.fvmrc`.

## Package and Web

Install dependencies and run the repository check driver:

```sh
fvm flutter pub get
fvm flutter pub get --directory example
fvm dart tool/check.dart
```

That checks Dart formatting, Flutter analysis, package tests, and example
tests. To reproduce the Web-specific CI steps:

```sh
cd web
npm ci
npm run build
cd ..
git diff --exit-code -- assets/
cd example
fvm flutter build web --release
```

The asset diff must be empty after a clean rebuild.

## Native host

Bootstrap the checksum-pinned VTK source for the host:

```sh
fvm dart tool/bootstrap_vtk.dart --platform macos-arm64
```

Use `macos-x64` on an Intel Mac or `windows-x64` on Windows. Then run:

```sh
fvm dart tool/check.dart --full
```

The full check adds the Web build, native CMake configure/build/contracts, and
the host desktop example build. Native release artifacts are built in
`Release` mode by `.github/scripts/build-native-artifact.ps1`; local outputs
stay under `.dart_tool/`.

Cross-compiled iOS and Android rows require their platform toolchains and are
normally covered by the Native build workflow.

Regenerate the native license inventory whenever the VTK version or enabled
module closure changes:

```sh
fvm dart tool/generate_native_licenses.dart \
  --source .dart_tool/vtk/9.6.2/macos-arm64/source \
  --targets .dart_tool/vtk/9.6.2/macos-arm64/install/lib/cmake/vtk-9.6/VTK-targets.cmake
```

Use the source directory for the bootstrapped target on other hosts. Native CI
runs the same generator in `--check` mode against the pinned source archive.

## Documentation and workflow checks

These read-only checks are useful after documentation or automation changes:

```sh
git diff --check
rg --hidden -n '9\.5\.2' .github README.md CHANGELOG.md doc AGENTS.md NOTICE
```

The version search and a separate search for stale domain-specific terminology
should return no matches in the maintained open-source repository.

Validate the PowerShell build script without running it:

```powershell
[scriptblock]::Create(
  (Get-Content '.github/scripts/build-native-artifact.ps1' -Raw)
) | Out-Null
```

If `actionlint` is installed, run `actionlint`. A YAML parser can provide a
secondary syntax check, but it does not validate GitHub expression semantics.
