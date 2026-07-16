# Third-party notices

## VTK

This project builds VTK 9.5.2 from source. VTK is distributed under the BSD
3-Clause license. The source archive and license are available from
<https://vtk.org/download/> and <https://gitlab.kitware.com/vtk/vtk>.

The monolithic native library also statically links VTK's bundled third-party
dependencies. The complete license texts for VTK and every linked bundled
component are reproduced in `native/THIRD_PARTY_LICENSES.txt`. The same file is
published and attested alongside every native GitHub Release.

## vtk.js

The web implementation uses vtk.js 36.4.1, distributed under the BSD 3-Clause
license. Source and license are available from
<https://github.com/Kitware/vtk-js>.

The generated web bundle also includes vtk.js dependencies. Their exact
versions and complete license texts are recorded in
`assets/vtk_locator.LICENSE.txt`, which is regenerated from
`web/package-lock.json` by `npm run build` in `web/`.

No third-party binary artifacts are committed to this repository.
