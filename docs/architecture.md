# Architecture

`vtk_flutter` is a deep, product-focused rendering module. Callers provide a
bounded signed-int16 volume and patient affine, submit one of three typed render
requests, and display the resulting `VtkView`. VTK classes and platform texture
objects remain implementation details.

The Dart layer validates inputs, owns the public session lifecycle, and maps
typed requests and metrics. Native platforms use a small MethodChannel for
Flutter texture registration and disposal. Volume upload and rendering use the
generated C ABI through FFI where the platform provides a native session.

The shared C++ core deep-copies volume data and constructs VTK scenes. A
platform `RenderTarget` owns the render window, graphics context, presentation
surface, and synchronization. The platform adapter registers that surface as a
Flutter texture and announces completed frames. On Apple, volume upload and VTK
rendering cross FFI directly; the follow-up `presentFrame` channel call performs
only the Flutter texture handoff.

Only one active session is supported initially. `close()` is explicit and
idempotent; finalization is leak protection, not normal lifecycle management.
