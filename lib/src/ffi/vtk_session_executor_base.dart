import '../api/vtk_api.dart';

abstract interface class VtkSessionExecutorFactory {
  Future<VtkSessionExecutor> create();
}

/// Asynchronous root-isolate proxy for one native VTK session.
///
/// Implementations own the native session and preserve request order for that
/// session. Platform presentation remains on the root isolate and uses
/// [nativeSessionAddress] only as an opaque routing key.
abstract interface class VtkSessionExecutor {
  int get presentationApiAddress;

  int get nativeSessionAddress;

  Future<VtkBackendObjectHandle> createObject({required VtkObjectType type});

  Future<VtkBackendObjectHandle> createDynamicObject({
    required String className,
  });

  Future<VtkBackendObjectHandle> createImageData({
    required VtkScalarImageInput input,
  });

  Future<Object?> invoke({
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    required List<Object?> arguments,
  });

  Future<Object?> invokeDynamic({
    required VtkBackendObjectHandle target,
    required String methodName,
    required List<Object?> arguments,
  });

  Future<void> destroyObject({required VtkBackendObjectHandle object});

  Future<VtkRenderResult> renderLayout({
    required List<VtkBackendRenderLayer> layers,
    required VtkViewport viewport,
    required int primaryLayer,
  });

  Future<void> close();
}
