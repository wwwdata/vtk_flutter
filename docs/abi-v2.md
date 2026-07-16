# Native ABI v2 migration

ABI v2 introduces an immutable C function table, opaque session and texture
target handles, versioned frame callbacks, serialized session operations, and
exception containment. ABI v1 remains available while platform adapters are
migrated independently.

This is an intermediate compatibility seam. Today each platform module still
constructs a private C++ `RenderTarget`, and a VTK-backed `PreparedView` crosses
that private virtual interface. Therefore a standalone code asset must not be
used alongside a separately linked legacy core in the same process.

The final seam has these invariants:

- The code asset owns VTK, the session, render-window creation, and rendering.
- A platform plugin owns only Flutter texture registration and presentation
  storage.
- Only fixed-width C data, opaque handles, function pointers, and caller-owned
  pixel or framebuffer descriptors cross the boundary.
- A callback target is detached before either the session or plugin-owned
  presentation storage is destroyed.
- Rendering is synchronous and serialized; callbacks do not re-enter their
  session; no exception crosses C.

Migration order:

1. Keep the proven ABI-v1 adapters while qualifying the v2 lifecycle contract.
2. Add a core-owned render target that accepts a C frame descriptor.
3. Migrate Apple, Android, and Windows presentation callbacks independently.
4. Switch Dart bindings to `@Native` resolution from the bundled code asset.
5. Remove VTK compilation and linking from every platform plugin.
6. Add Swift Package Manager manifests for the now-thin Apple plugins, while
   retaining CocoaPods compatibility.
