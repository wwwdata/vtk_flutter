# Releasing vtk_flutter

This repository has two release streams:

- `native-v0.1.0-dev.1` publishes the monolithic dynamic libraries consumed by
  the Dart native-assets build hook.
- `v<package-version>` publishes the Flutter package to pub.dev.

Neither workflow creates a tag. A maintainer must create and push a reviewed
tag after every required `Quality` job passes for the tagged commit.

## CI coverage

The pull-request workflow uses Flutter 3.44.6 from `.fvmrc`. Its Dart and web
job checks formatting, analysis, package and example tests, deterministic
vtk.js bundle regeneration, and a release web build.

The native matrix bootstraps checksum-pinned VTK 9.5.2 and builds
`native/CMakeLists.txt` with `VTK_FLUTTER_BUILD_SHARED_CORE=ON` for every hook
target:

| Target | Runner | ZIP library |
| --- | --- | --- |
| `macos-arm64` | macOS arm64 | `libvtk_flutter_core.dylib` |
| `macos-x64` | macOS Intel | `libvtk_flutter_core.dylib` |
| `ios-arm64` | macOS arm64 | `libvtk_flutter_core.dylib` |
| `ios-simulator-arm64` | macOS arm64 | `libvtk_flutter_core.dylib` |
| `ios-simulator-x64` | macOS Intel | `libvtk_flutter_core.dylib` |
| `android-arm64` | Linux x64, Android NDK | `libvtk_flutter_core.so` |
| `android-armeabi-v7a` | Linux x64, Android NDK | `libvtk_flutter_core.so` |
| `android-x86_64` | Linux x64, Android NDK | `libvtk_flutter_core.so` |
| `windows-x64` | Windows x64 | `vtk_flutter_core.dll` |

Host native contract tests run for both macOS architectures and Windows x64.
GitHub's headless Windows runner executes the CPU, ABI, lifecycle, and
serialization contracts with real-render contracts disabled because VTK's
Win32 backend requires a usable WGL context. The iOS and Android rows are
cross-compile checks; device and simulator render qualification remains a
separate platform-support concern.

Every quality native job uploads its built library as a short-lived workflow
artifact. Downstream jobs inject that exact library through the build hook's
local override and build real macOS, iOS Simulator, Android x64, and Windows
consumer examples. The macOS job also runs the full renderer lifecycle
integration test. This proves the adapters and code-asset bundling in addition
to compiling the core in isolation.

CI may restore a checksum-keyed VTK install cache. Native releases never
restore compiled VTK or vtk_flutter output caches: every library is rebuilt
from the checksum-pinned VTK source on its designated runner.

## Native library release

The `Release native libraries` workflow accepts only the exact
`native-v0.1.0-dev.1` tag. It verifies that `tool/native_artifacts.dart` maps
that tag and all target asset names before any release is published. A
preflight job also requires a completed successful `Quality` run for the exact
tagged commit before allocating the release build matrix.

The release assets are:

```text
vtk_flutter-native-macos-arm64.zip
vtk_flutter-native-macos-x64.zip
vtk_flutter-native-ios-arm64.zip
vtk_flutter-native-ios-simulator-arm64.zip
vtk_flutter-native-ios-simulator-x64.zip
vtk_flutter-native-android-arm64.zip
vtk_flutter-native-android-armeabi-v7a.zip
vtk_flutter-native-android-x86_64.zip
vtk_flutter-native-windows-x64.zip
BUILD-MANIFESTS.json
NATIVE-THIRD-PARTY-LICENSES.txt
SHA256SUMS
```

Every ZIP contains exactly one file at its root: the target's monolithic
dynamic library shown in the matrix above. It does not contain VTK install
directories, headers, static libraries, platform packages, or nested folders.
The hook downloads `SHA256SUMS`, verifies the selected ZIP, safely extracts its
single library, and exposes that library as a bundled code asset.

`BUILD-MANIFESTS.json` records each artifact digest, size, target library,
source checksum, toolchain, runner, workflow run, and source commit.
`SHA256SUMS` covers every ZIP, `BUILD-MANIFESTS.json`, and the native license
file. GitHub build provenance attestations cover all release assets.

`NATIVE-THIRD-PARTY-LICENSES.txt` reproduces the VTK and bundled dependency
license texts that accompany the statically linked components in every
monolithic library. It is also covered by `SHA256SUMS` and the release
attestation.

### One-time repository setup

Before pushing the native tag:

1. In **Settings → General → Releases**, enable immutable releases. This must
   happen before the release is published.
2. Create a repository variable named `IMMUTABLE_RELEASES_ENABLED` with the
   exact value `true`. Set it only after step 1; it is the workflow's explicit
   acknowledgement gate.
3. Create the `native-release` GitHub environment and require maintainer review.
4. Protect tags matching `native-v*` so only release maintainers can create them.
5. Make every `Quality` job required on the default branch.

The workflow creates a draft, uploads all assets, and publishes only after all
nine builds succeed. Publishing locks the assets and tag when release
immutability is enabled. The workflow then verifies GitHub's immutable release
attestation before reporting success.

### Publishing

Create an annotated, preferably signed tag on the reviewed package commit:

```sh
git tag -s native-v0.1.0-dev.1 -m "vtk_flutter native libraries 0.1.0-dev.1"
git push origin native-v0.1.0-dev.1
```

If a run fails before publication, inspect and delete any draft release before
rerunning the workflow. The workflow refuses to replace an existing draft or
published release. Never move or reuse a native release tag; update the hook's
tag and asset contract for the next native version.

### Verifying a release

With a recent GitHub CLI:

```sh
gh release verify native-v0.1.0-dev.1 --repo wwwdata/vtk_flutter
gh release download native-v0.1.0-dev.1 \
  --repo wwwdata/vtk_flutter --dir native-release
cd native-release
sha256sum --check SHA256SUMS
gh attestation verify vtk_flutter-native-macos-arm64.zip \
  --repo wwwdata/vtk_flutter
gh release verify-asset native-v0.1.0-dev.1 \
  vtk_flutter-native-macos-arm64.zip --repo wwwdata/vtk_flutter
```

Normal consumers should let the build hook select, verify, and install the
correct library. Manual extraction is intended only for release inspection and
debugging.

## Publishing the package to pub.dev

Automated publishing uses pub.dev OIDC and Dart's maintained reusable GitHub
workflow. There is no long-lived publishing credential.

### First publication (manual and mandatory)

Pub.dev cannot automate creation of a new package. Before enabling automation:

1. Obtain explicit approval for the first public package release.
2. Remove `publish_to: none`, set the final package version in `pubspec.yaml`,
   update `CHANGELOG.md`, podspec versions, web package metadata, generated
   assets, notices, and documentation, then run the complete quality matrix.
3. Run `dart pub publish --dry-run`, inspect the package contents, and publish
   the first version manually with `dart pub publish` from a trusted workstation.
4. On pub.dev, configure automated publishing for
   `github.com/wwwdata/vtk_flutter` with tag pattern `v{{version}}`.

### One-time GitHub setup after the manual publication

1. Create a protected `pub.dev` environment with required maintainer approval.
2. Protect tags matching `v*` so only release maintainers can create them.
3. Create the repository variable `PUB_DEV_AUTOMATION_ENABLED=true`.

The variable is an intentional kill switch. Until it exists with the exact
value `true`, `v` tags cannot run the publishing job. The protected environment
adds a second approval gate.

### Subsequent package releases

Confirm that the package version exactly matches the tag, the changelog is
complete, `publish_to: none` is absent, the native hook references an existing
immutable release, and all quality jobs pass. Then create and push a signed tag:

```sh
git tag -s v1.2.3 -m "vtk_flutter 1.2.3"
git push origin v1.2.3
```

The workflow accepts stable and prerelease semantic-version tags such as
`v1.2.3` and `v1.2.3-beta.1`. Pub.dev validates that the pushed tag and package
version match before accepting the OIDC publication.

## Security release notes

For a vulnerability, use a private GitHub security advisory and coordinate the
disclosure date before tagging. Release notes should describe affected
versions, impact, fixed versions, and mitigations without exposing sensitive
reporter information. Follow `.github/SECURITY.md` for reporting and support.
