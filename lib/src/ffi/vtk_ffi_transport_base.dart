import '../api/vtk_api.dart';

abstract interface class VtkFfiTransport {
  int get presentationApiAddress;

  Future<int> createSession();

  Future<void> destroySession(int sessionAddress);

  Future<VtkBackendObjectHandle> createObject({
    required int sessionAddress,
    required VtkObjectType type,
  });

  Future<VtkBackendObjectHandle> createDynamicObject({
    required int sessionAddress,
    required String className,
  });

  Future<VtkBackendObjectHandle> createImageData({
    required int sessionAddress,
    required VtkScalarImageInput input,
  });

  Future<Object?> invoke({
    required int sessionAddress,
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    required List<Object?> arguments,
  });

  Future<Object?> invokeDynamic({
    required int sessionAddress,
    required VtkBackendObjectHandle target,
    required String methodName,
    required List<Object?> arguments,
  });

  Future<void> destroyObject({
    required int sessionAddress,
    required VtkBackendObjectHandle object,
  });

  Future<VtkRenderResult> render({
    required int sessionAddress,
    required VtkBackendObjectHandle renderer,
    required VtkViewport viewport,
  });
}
