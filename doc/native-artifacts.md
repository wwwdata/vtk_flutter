# Native artifacts and release separation

The package source and the VTK-powered native libraries have separate
verification paths. The Flutter package is unpublished and has no pub.dev
publishing workflow. Native libraries may eventually be distributed through a
maintainer-gated GitHub native release because normal application builds
should not compile VTK.

## Delivery contract

The Dart build hook maps the active target to exactly one ZIP:

| Target | Asset | Library at ZIP root |
| --- | --- | --- |
| `macos-arm64` | `vtk_flutter-native-macos-arm64.zip` | `libvtk_flutter_core.dylib` |
| `macos-x64` | `vtk_flutter-native-macos-x64.zip` | `libvtk_flutter_core.dylib` |
| `ios-arm64` | `vtk_flutter-native-ios-arm64.zip` | `libvtk_flutter_core.dylib` |
| `ios-simulator-arm64` | `vtk_flutter-native-ios-simulator-arm64.zip` | `libvtk_flutter_core.dylib` |
| `ios-simulator-x64` | `vtk_flutter-native-ios-simulator-x64.zip` | `libvtk_flutter_core.dylib` |
| `android-arm64` | `vtk_flutter-native-android-arm64.zip` | `libvtk_flutter_core.so` |
| `android-armeabi-v7a` | `vtk_flutter-native-android-armeabi-v7a.zip` | `libvtk_flutter_core.so` |
| `android-x86_64` | `vtk_flutter-native-android-x86_64.zip` | `libvtk_flutter_core.so` |
| `windows-x64` | `vtk_flutter-native-windows-x64.zip` | `vtk_flutter_core.dll` |

Each ZIP contains only the dynamic library at its root. It does not contain a
VTK SDK, headers, static libraries, platform packages, or nested directories.
Web uses vtk.js assets and is not part of this native matrix.

The hook downloads the release checksum manifest, verifies the selected ZIP,
safely extracts the expected single file, and exposes it as a Dart code asset.
A local override may point to one library or to a directory containing
`<target>/<library>` entries for multi-architecture builds.

## Pinned VTK input

All native rows build the same source:

```text
VTK version: 9.6.2
URL: https://vtk.org/files/release/9.6/VTK-9.6.2.tar.gz
SHA-256: aed12cec12a9609179bf66329070266627ca64244a10856a452b2a17ffb04a1d
```

The bootstrap enables only the selected modules and keeps
`VTK_ENABLE_WRAPPING=ON` with `VTK_WRAP_SERIALIZATION=ON`. Serialization
wrapping provides the generic object invocation support; language wrappers are
not a public package API.

## Three independent workflows

1. **Quality** runs formatting, analysis, Dart, example, and vtk.js tests,
   reproducible Web asset generation, and a release Web build. It also verifies
   that the package remains unpublished.
2. **Native build** builds all nine native targets for every default-branch
   commit, for relevant pull-request changes, or when a maintainer dispatches
   it. Running every default-branch commit guarantees that a later native tag
   has qualification evidence for its exact source revision. The workflow may
   cache the checksum-pinned VTK source/install and upload short-lived workflow
   artifacts for consumer smoke builds. It never creates a tag or release.
3. **Release native libraries** is triggered only by a reviewed `native-v*`
   tag and a protected environment. It requires successful Quality and Native
   build runs for the exact commit, rebuilds every target without compiled VTK
   caches, creates manifests/checksums/attestations, refuses to replace an
   existing release, and qualifies the published checksum-and-download path
   with a macOS FFI smoke and real recipe renders.

The release workflow does not publish the Dart/Flutter package. The repository
contains no pub.dev OIDC or package-publish job while `publish_to: none` is
present.

## Native release contents

A complete native release contains the nine ZIPs plus:

- `BUILD-MANIFESTS.json` with source, target, toolchain, runner, commit, size,
  and digest metadata;
- `SHA256SUMS` covering every released file;
- `VTK-NOTICE.txt`;
- `NATIVE-THIRD-PARTY-LICENSES.txt`; and
- GitHub artifact attestations for the release assets.

Consumers should use the build hook. Manual downloads are intended for release
inspection and debugging.

## Maintainer safeguards

- Never move or reuse a native tag.
- Keep the native tag and asset map in source synchronized.
- Require review on the `native-release` GitHub environment.
- Enable immutable GitHub releases before allowing the release workflow.
- Rebuild release artifacts from the checksum-pinned source; do not restore a
  compiled VTK cache in the release workflow.
- Confirm all nine manifests and archives exist before creating a release.
- Update the complete third-party license inventory for the exact VTK source
  and enabled module set before a native release.
