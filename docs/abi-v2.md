# Native ABI v2 code-asset contract

ABI v2 is the final C-only boundary between the monolithic VTK code asset and
thin Flutter platform plugins. The code asset owns every VTK object, including
the offscreen render window and framebuffer readback. A plugin owns Flutter
texture registration and writable CPU presentation storage. No C++ class, VTK
object, graphics-context handle, or Flutter type crosses this boundary.

The direct ABI-v1 exports remain available to Dart FFI. Every Flutter platform
adapter uses ABI v2; no adapter compiles or links the private C++ render-target
seam or any VTK library.

## Discovery and ownership

`vtk_flutter_get_core_api_v2()` returns an immutable, process-lifetime
`VtkFlutterCoreApiV2`. A caller must verify `version` and that `struct_size`
reaches every function pointer it reads. The table retains its transitional v2
prefix; `texture_target_create` and `texture_target_destroy` are appended.

Sessions and texture targets are opaque core allocations:

1. Create a session with `session_create`.
2. Create a target with `texture_target_create`, passing a complete callback
   table. The core copies the table.
3. Attach the target to one session with `session_attach_texture_target`.
4. Render synchronously with `session_render`.
5. Detach the target before destroying either its callback state or the target.
6. Destroy the target with `texture_target_destroy`, then destroy the session.

A target can be attached to at most one session. Destroying an attached target
returns `VTK_FLUTTER_STATUS_INVALID_STATE` and leaves it alive. Target creation
and destruction happen entirely inside the core; platform code must never
allocate, define, cast, or delete an opaque handle.

The legacy `session_destroy` signature has no status channel. It must not race
another operation and must not be called from a callback. This restriction is
retained until ABI v1 is removed.

## CPU frame descriptor

After the core validates a render request, `begin_frame` receives its viewport
and a zero-initialized `VtkFlutterCpuFrameV2`. On success the callback fills:

- `struct_size = sizeof(VtkFlutterCpuFrameV2)`
- `version = VTK_FLUTTER_CPU_FRAME_VERSION_2`
- `pixels` with a writable first byte
- `row_bytes` with the distance between top-down rows
- `capacity_bytes` with the accessible allocation size
- `pixel_format` with `VTK_FLUTTER_PIXEL_FORMAT_RGBA8888` or
  `VTK_FLUTTER_PIXEL_FORMAT_BGRA8888`

For viewport width `w` and height `h`, `row_bytes` must be at least `w * 4` and
capacity must be at least `(h - 1) * row_bytes + w * 4`. The core writes only
the first `w * 4` bytes of each row; row padding is untouched. Rows are
top-down, so `pixels[0]` is the top-left pixel. Channels are straight
(unpremultiplied) 8-bit RGBA or BGRA in memory, as selected by the descriptor.
The VTK framebuffer is read as RGBA, vertically flipped, and channel-converted
by the core. A platform texture API that requires premultiplied alpha must do
that in its presentation path.

The descriptor and storage remain caller-owned. They must stay writable until
`end_frame` or `cancel_frame` returns and are not retained by the core.

## Callback transaction

Callbacks execute synchronously on the thread that called `session_render`:

- If `begin_frame` returns an error, no frame storage is used and neither
  `end_frame` nor `cancel_frame` is called.
- After a successful `begin_frame`, render/readback/copy success is followed by
  one `end_frame` call.
- A render, descriptor-validation, readback, or copy failure is followed by one
  best-effort `cancel_frame` call.
- If `end_frame` returns an error or throws in a C++ test host, it is followed
  by best-effort `cancel_frame`; the end failure remains the reported error.
- A `cancel_frame` failure never replaces the original failure.

Callbacks return `VtkFlutterStatusCode` and may write a bounded diagnostic to
`VtkFlutterStatus`. Unknown callback status values are contained as
`VTK_FLUTTER_STATUS_INTERNAL_ERROR`. Production callbacks are C ABI functions
and must not throw. The core nevertheless catches all C++ exceptions at every
exported C entry point.

`end_frame` is the publication point. It receives completed render/readback
metrics and should make the frame visible to Flutter before returning. A
successful `session_render` means publication succeeded; its returned metrics
also include the measured `end_frame` duration. On any failure the public
metrics output is zeroed.

## Serialization and re-entry

All operations on one session are synchronous and serialized. Concurrent calls
from different threads wait for the active operation. A callback runs while
that operation is active; re-entering the same session from `begin_frame`,
`end_frame`, or `cancel_frame` returns
`VTK_FLUTTER_STATUS_INVALID_STATE` instead of deadlocking. Callbacks may signal
their platform registrar, but must not attach, detach, render, mutate, or
destroy that same session.

Different sessions have independent serialization. Callback-owned storage must
therefore provide any synchronization needed across different targets.

## Metrics

`frame_bytes` is the tightly packed visible size (`width * height * 4`).
`surface_allocation_bytes` is the callback-reported `capacity_bytes`.
`render_ms` covers VTK rendering, `cpu_readback_ms` covers framebuffer readback
plus flip/conversion/copy, and `surface_submit_ms` covers `end_frame` execution.
The surface and CPU evidence fields are computed over visible destination
pixels only, excluding row padding. Locator renders capture the final
patient-to-clip matrix after the renderer is attached to the core-owned window.

## Platform callback contract

The common plugin pattern is:

- `begin_frame`: acquire or allocate a viewport-sized texture backing store,
  lock it for CPU writes, and return its base address, capacity, stride, and
  channel order.
- `end_frame`: unlock/commit the backing store, atomically publish it as the
  latest frame, and notify Flutter that a frame is available.
- `cancel_frame`: unlock/release the in-progress store without publishing it.

Apple adapters normally expose a top-down BGRA `CVPixelBuffer`; Windows can
return the channel order expected by its `FlutterDesktopPixelBuffer`; Android
must return CPU storage that remains valid through publication and perform any
required texture upload in `end_frame`. The core never receives platform image,
texture, surface, device, context, or registrar handles.

## Platform status

Android, iOS, macOS, and Windows all create opaque core sessions and texture
targets from this table. Their build definitions compile only Flutter-facing
presentation code. The shared code asset is the sole native binary that links
VTK.
