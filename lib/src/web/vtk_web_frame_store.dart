import 'package:flutter/foundation.dart';

import '../api/vtk_api.dart';

final class VtkWebFrame {
  VtkWebFrame({required this.viewport, required Uint8List pngBytes})
    : pngBytes = Uint8List.fromList(pngBytes);

  final VtkViewport viewport;
  final Uint8List pngBytes;
}

/// Session-scoped PNG presentation for Flutter's web `Image.memory` adapter.
final class VtkWebFrameStore {
  VtkWebFrameStore._();

  static final _frames = <int, ValueNotifier<VtkWebFrame?>>{};
  static final _images = <int, ValueNotifier<Uint8List?>>{};

  static ValueListenable<VtkWebFrame?> frameFor(int viewId) {
    final frame = _frames[viewId];
    if (frame == null) {
      throw VtkApiStateException('Unknown vtk.js view $viewId');
    }
    return frame;
  }

  static ValueListenable<Uint8List?> imageFor(int viewId) {
    final image = _images[viewId];
    if (image == null) {
      throw VtkApiStateException('Unknown vtk.js view $viewId');
    }
    return image;
  }

  static void register(int viewId) {
    if (_frames.containsKey(viewId)) {
      throw VtkApiStateException('vtk.js view $viewId is already registered');
    }
    _frames[viewId] = ValueNotifier(null);
    _images[viewId] = ValueNotifier(null);
  }

  static void present({
    required int viewId,
    required VtkViewport viewport,
    required Uint8List pngBytes,
  }) {
    final frame = _frames[viewId];
    if (frame == null) {
      throw VtkApiStateException('Unknown vtk.js view $viewId');
    }
    frame.value = VtkWebFrame(viewport: viewport, pngBytes: pngBytes);
    _images[viewId]!.value = Uint8List.fromList(pngBytes);
  }

  static void unregister(int viewId) {
    _frames.remove(viewId)?.dispose();
    _images.remove(viewId)?.dispose();
  }
}
