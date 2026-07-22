import 'dart:typed_data';

abstract interface class VtkWebModule {
  Future<VtkWebModuleCapabilities> capabilities();

  Future<int> openSession();

  Future<int> createObject({required int sessionId, required String type});

  Future<int> createImageData({
    required int sessionId,
    required VtkWebImageInput input,
  });

  Future<int?> invoke({
    required int sessionId,
    required int target,
    required String operation,
    required List<Object?> arguments,
  });

  Future<void> destroyObject({required int sessionId, required int object});

  Future<VtkWebRenderFrame> render({
    required int sessionId,
    required int renderer,
    required int width,
    required int height,
  });

  Future<VtkWebRenderFrame> renderLayout({
    required int sessionId,
    required List<VtkWebRenderLayer> layers,
    required int width,
    required int height,
    required int primaryLayer,
  });

  Future<void> closeSession(int sessionId);
}

final class VtkWebRenderLayer {
  const VtkWebRenderLayer({
    required this.renderer,
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });

  final int renderer;
  final double left;
  final double bottom;
  final double right;
  final double top;
}

final class VtkWebModuleCapabilities {
  VtkWebModuleCapabilities({
    required List<String> supportedObjectTypes,
    required List<String> supportedScalarTypes,
    required this.maxImageBytes,
    required this.supportsRendering,
    required Map<String, String> limitations,
  }) : supportedObjectTypes = List.unmodifiable(supportedObjectTypes),
       supportedScalarTypes = List.unmodifiable(supportedScalarTypes),
       limitations = Map.unmodifiable(limitations);

  final List<String> supportedObjectTypes;
  final List<String> supportedScalarTypes;
  final int maxImageBytes;
  final bool supportsRendering;
  final Map<String, String> limitations;
}

final class VtkWebImageInput {
  VtkWebImageInput({
    required Uint8List bytes,
    required this.scalarType,
    required List<int> dimensions,
    required this.componentCount,
    required List<double> origin,
    required List<double> spacing,
    required List<double> direction,
  }) : bytes = Uint8List.fromList(bytes),
       dimensions = List.unmodifiable(dimensions),
       origin = List.unmodifiable(origin),
       spacing = List.unmodifiable(spacing),
       direction = List.unmodifiable(direction);

  final Uint8List bytes;
  final String scalarType;
  final List<int> dimensions;
  final int componentCount;
  final List<double> origin;
  final List<double> spacing;
  final List<double> direction;
}

final class VtkWebRenderFrame {
  VtkWebRenderFrame({
    required this.pngDataUrl,
    required this.width,
    required this.height,
    required this.renderMicroseconds,
    required this.captureMicroseconds,
    required List<double> worldToClip,
  }) : worldToClip = List.unmodifiable(worldToClip);

  final String pngDataUrl;
  final int width;
  final int height;
  final int renderMicroseconds;
  final int captureMicroseconds;
  final List<double> worldToClip;
}
