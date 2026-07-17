# Architecture

`vtk_flutter` is a generic VTK execution layer with Flutter presentation. Its
main design constraint is that application-visible behavior belongs in Dart,
while native code stays small enough to build, audit, and distribute as one
target-specific artifact.

## Dart owns pipelines

Applications assemble pipelines from typed Dart wrappers for supported VTK
concepts such as image data, algorithms, mappers, properties, actors, volumes,
renderers, and cameras. Dart owns:

- value validation and immutable input objects;
- capability checks before backend calls;
- object ownership and cross-session safety;
- ordered asynchronous operations;
- explicit, idempotent object, session, and runtime disposal; and
- the public failure model.

The wrappers send a closed set of typed operations to a backend. Public callers
do not pass VTK class names, raw method strings, native addresses, JSON, or
platform texture handles.

This keeps pipeline policy testable without VTK and gives native and Web
backends the same Dart-owned contract even when their capabilities differ.

## Minimal generic native session

The native library embeds VTK 9.6.2 and exposes a C-only ABI. Its public values
are fixed-width scalars, plain structs, callbacks, opaque session pointers, and
integer object handles. The ABI supports only the transport primitives needed
by Dart:

1. create and destroy a session;
2. create and destroy a serialization-registered VTK object in that session;
3. deep-copy typed scalar image data;
4. invoke a VTK method through VTK's generated serialization invoker and
   return a bounded JSON result;
5. render a renderer object into the attached presentation target; and
6. report status and frame metrics.

The C++ core owns every VTK object. Handles are session-local, never expose a
VTK pointer, and become invalid when destroyed or when their session closes.
Calls on one session are serialized, and render-thread requirements remain in
the native implementation.

VTK is a C++ library and does not expose a stable C ABI that Dart FFI can call
directly. The small C++ session is therefore the irreducible adapter: it owns
VTK smart pointers and VTK's generated serialization manager, while all
pipeline choices remain in Dart. Class names, method names, and serialized
arguments are backend implementation details, not the stable Dart contract.

## Presentation-only platform adapters

The Android, iOS, macOS, and Windows plugins receive the native presentation
function table and work with an opaque session. Their responsibilities are:

- register and unregister a Flutter texture;
- allocate or acquire writable frame storage;
- attach and detach the frame target;
- publish a completed frame and notify Flutter;
- cancel an incomplete frame safely; and
- coordinate platform lifecycle and thread affinity.

They do not link a second VTK copy, create VTK pipelines, interpret application
data, or choose visualization behavior. The native core writes through a
versioned `begin_frame`/`end_frame`/`cancel_frame` transaction and retains no
platform-owned pixel pointer after the transaction.

## Web backend

Web uses vtk.js rather than the native C ABI. It implements the same Dart
backend protocol where practical and returns a capability object describing
its actual object, scalar, memory, and rendering support.

Web capability reporting is authoritative. Browser memory limits, WebGL
availability, JavaScript numeric constraints, main-thread scheduling, and the
curated vtk.js bundle make Web a smaller target than native platforms. Code
must not infer support from an API type existing in Dart.

See [Platform support](platform-support.md) for current limits.

## Experimental dynamic API intent

The typed wrappers intentionally cover a curated, testable VTK surface. The
separate `vtk_flutter_experimental.dart` library exposes a dynamic API for
prototyping object graphs without adding a typed wrapper first. Its intent is
deliberately narrow. The API is:

- explicitly marked experimental and excluded from compatibility guarantees;
- capability-gated per backend and VTK version;
- restricted to VTK serialization-registered classes and methods rather than
  arbitrary native symbol access;
- based on session-owned handles, never C++ pointers; and
- isolated so typed pipelines do not depend on dynamic strings or results.

It is not intended to reproduce all of VTK's C++ API or replace generated,
typed wrappers for production pipelines. Code using only `vtk_flutter.dart`
does not import the dynamic surface.
