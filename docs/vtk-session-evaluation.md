# VTK 9.6 session API evaluation

Decision for the initial package: retain the focused VTK 9.5.2 C++ pipeline
behind `vtk_flutter.h`.

VTK 9.6 introduces the experimental `vtkSession` C API, including opaque
objects, JSON state, blobs, invocation, observers, and rendering. It is useful
directionally, but it does not replace this package's native core yet:

- The available JSON implementation is currently centered on the
  JavaScript/WebAssembly session path rather than a qualified native mobile and
  desktop implementation for the required rendering graph.
- Coverage of the exact reslice, volume mapper, surface extraction, smoothing,
  camera, and render-window methods used here is not guaranteed.
- Flutter texture registration, graphics-context ownership, synchronization,
  and presentation remain platform responsibilities in either design.
- Using generic JSON invocation would move type errors from compile time to
  runtime without eliminating the platform adapters.

The package-owned C ABI therefore remains the stable boundary. Re-evaluate
`vtkSession` when VTK provides a native implementation covering all three
render modes without custom handlers or serializers. Adoption still requires
the deterministic native contract tests and no more than a 10% regression in
render time or resident memory.

References:

- <https://vtk.org/doc/nightly/html/vtkSession_8h.html>
- <https://docs.vtk.org/en/latest/advanced/WrappingTools.html>
