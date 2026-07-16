# Architecture

`vtk_flutter` is a deep, product-focused rendering module. Callers provide a
bounded signed-int16 volume and patient affine, submit one of three typed render
requests, and display the resulting `VtkView`. VTK classes and platform texture
objects remain implementation details.

The Dart layer validates inputs, owns the public session lifecycle, and maps
typed requests and metrics. Its generated `@Native` bindings resolve a bundled
code asset rather than opening a platform library by filename. A Dart build
hook selects and checksum-verifies the target-specific library from the pinned
immutable native release.

Native platforms use a small MethodChannel only for Flutter texture
registration, presentation acknowledgement, resize, and disposal. Session
creation passes the already-resolved ABI-v2 table address to the platform
adapter. Volume upload and VTK rendering then cross the C ABI directly through
Dart FFI.

The monolithic C++ code asset deep-copies volume data, constructs VTK scenes,
owns the offscreen VTK render window, and reads its framebuffer. An opaque core
texture target calls a C-only frame transaction supplied by the platform:
`begin_frame`, `end_frame`, and `cancel_frame`. The adapter supplies writable
CPU storage and never sees a VTK or C++ type.

- Apple uses pooled BGRA `CVPixelBuffer` storage and supports both SwiftPM and
  CocoaPods. macOS keeps VTK's offscreen OpenGL context disconnected from an
  AppKit view, so code-asset lifetime cannot leave a stale `vtkCocoaGLView`.
- Android renders into staging RGBA memory, copies only completed frames into
  an `ANativeWindow`, and discards cancelled frames without publication.
- Windows publishes immutable RGBA frame snapshots through Flutter's pixel
  buffer texture API.

The follow-up `presentFrame` channel call performs only the Flutter texture
notification or acknowledgement; it never invokes VTK.

Only one active session is supported initially. `close()` is explicit and
idempotent; finalization is leak protection, not normal lifecycle management.
