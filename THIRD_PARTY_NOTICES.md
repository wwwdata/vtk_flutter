# Third-party notices

## VTK

This project builds VTK 9.5.2 from source. VTK is distributed under the BSD
3-Clause license. The source archive and license are available from
<https://vtk.org/download/> and <https://gitlab.kitware.com/vtk/vtk>.

## vtk.js

The web implementation uses vtk.js 36.4.1, distributed under the BSD 3-Clause
license. Source and license are available from
<https://github.com/Kitware/vtk-js>.

The generated web bundle also includes vtk.js dependencies. Their exact
versions and complete license texts are recorded in
`assets/vtk_locator.LICENSE.txt`, which is regenerated from
`web/package-lock.json` by `npm run build` in `web/`.

No third-party binary artifacts are committed to this repository.
