import 'vtk_web_module.dart';

final class VtkJsModule implements VtkWebModule {
  Never _unsupported() {
    throw UnsupportedError('The vtk.js module is available on web only');
  }

  @override
  Future<VtkWebModuleCapabilities> capabilities() => _unsupported();

  @override
  Future<int> openSession() => _unsupported();

  @override
  Future<int> createObject({required int sessionId, required String type}) =>
      _unsupported();

  @override
  Future<int> createImageData({
    required int sessionId,
    required VtkWebImageInput input,
  }) => _unsupported();

  @override
  Future<int?> invoke({
    required int sessionId,
    required int target,
    required String operation,
    required List<Object?> arguments,
  }) => _unsupported();

  @override
  Future<void> destroyObject({required int sessionId, required int object}) =>
      _unsupported();

  @override
  Future<VtkWebRenderFrame> render({
    required int sessionId,
    required int renderer,
    required int width,
    required int height,
  }) => _unsupported();

  @override
  Future<void> closeSession(int sessionId) => _unsupported();
}
