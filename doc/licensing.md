# Licensing and notices

The repository's own source is licensed under the
[BSD 3-Clause License](../LICENSE).

## Native VTK artifacts

Native artifacts are built from checksum-pinned VTK 9.6.2 source. VTK is BSD
3-Clause licensed and includes bundled third-party components under their own
compatible terms. Because selected VTK modules and dependencies are statically
linked into each monolithic library, a native release must carry:

- the project [NOTICE](../NOTICE);
- the complete applicable VTK and bundled dependency license texts as
  `NATIVE-THIRD-PARTY-LICENSES.txt`;
- checksums covering both notice files and every binary archive; and
- build provenance that identifies the VTK source URL and SHA-256 digest.

The release workflow copies the notices into the release payload. Updating the
VTK version or enabled module set requires reviewing and regenerating the full
third-party inventory before any native release. The generator compares its
license map with the bundled third-party targets present in the installed VTK
CMake target closure and fails when either side drifts.

## Web assets

The Web backend uses vtk.js, which is BSD 3-Clause licensed, plus its npm
dependencies. The Web build generates the license inventory for the packages
that esbuild actually includes, with versions resolved by the npm lockfile. A
deterministic rebuild in Quality CI verifies that committed Web assets and
their generated notices are current.

## Redistribution

Redistributors must retain the project license and all notices applicable to
the artifacts they ship. GitHub checksums and attestations establish integrity
and build origin; they do not replace license obligations or a security review.
