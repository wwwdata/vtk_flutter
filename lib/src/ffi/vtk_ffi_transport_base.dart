import '../models.dart';

abstract interface class VtkFfiTransport {
  Future<void> setVolume({
    required int sessionAddress,
    required VtkVolume volume,
  });

  Future<VtkFrameMetrics> render({
    required int sessionAddress,
    required int textureId,
    required VtkViewport viewport,
    required VtkRenderRequest request,
  });
}
