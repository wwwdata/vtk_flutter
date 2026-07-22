import '../api/vtk_api.dart';

abstract interface class VtkFfiTransport {
  int get presentationApiAddress;

  int createSession();

  void destroySession(int sessionAddress);

  VtkBackendObjectHandle createObject({
    required int sessionAddress,
    required VtkObjectType type,
  });

  VtkBackendObjectHandle createDynamicObject({
    required int sessionAddress,
    required String className,
  });

  VtkBackendObjectHandle createImageData({
    required int sessionAddress,
    required VtkScalarImageInput input,
  });

  Object? invoke({
    required int sessionAddress,
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    required List<Object?> arguments,
  });

  Object? invokeDynamic({
    required int sessionAddress,
    required VtkBackendObjectHandle target,
    required String methodName,
    required List<Object?> arguments,
  });

  void destroyObject({
    required int sessionAddress,
    required VtkBackendObjectHandle object,
  });

  VtkRenderResult render({
    required int sessionAddress,
    required VtkBackendObjectHandle renderer,
    required VtkViewport viewport,
  });

  VtkRenderResult renderLayout({
    required int sessionAddress,
    required List<VtkBackendRenderLayer> layers,
    required VtkViewport viewport,
    required int primaryLayer,
  });
}
