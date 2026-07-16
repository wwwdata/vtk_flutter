import 'package:flutter/foundation.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'src/exceptions.dart';
import 'src/models.dart';
import 'src/web/vtk_locator_bridge.dart';
import 'vtk_flutter_platform_interface.dart';

final class VtkFlutterWeb extends VtkFlutterPlatform {
  static final _images = <int, ValueNotifier<Uint8List?>>{};
  static int _nextSessionId = 1;

  static void registerWith(Registrar registrar) {
    VtkFlutterPlatform.instance = VtkFlutterWeb();
  }

  static ValueListenable<Uint8List?> imageFor(int sessionId) {
    final image = _images[sessionId];
    if (image == null) throw const VtkSessionClosedException();
    return image;
  }

  final _bridge = VtkLocatorBridge();
  int? _sessionId;
  VtkVolume? _volume;
  VtkViewport? _viewport;
  bool _volumeChanged = false;
  int _frameId = 0;
  int _presentedFrames = 0;
  VtkFrameMetrics? _lastMetrics;

  @override
  Future<VtkCapabilities> capabilities() async => VtkCapabilities(
    renderModes: const {.volumeLocator},
    maxVolumeBytes: 2 * 1024 * 1024,
    supportsExternalTexture: false,
  );

  @override
  Future<int> createSession(VtkViewport viewport) async {
    if (_sessionId != null) throw const VtkSessionAlreadyOpenException();
    final sessionId = _nextSessionId++;
    _sessionId = sessionId;
    _viewport = viewport;
    _images[sessionId] = ValueNotifier(null);
    return sessionId;
  }

  @override
  Future<void> setVolume(VtkVolume volume) async {
    _ensureSession();
    if (volume.byteCount > 2 * 1024 * 1024) {
      throw const VtkValidationException(
        field: 'data',
        message: 'The vtk.js locator is limited to a 2 MiB working volume',
      );
    }
    _volume = volume;
    _volumeChanged = true;
  }

  @override
  Future<VtkFrameMetrics> render(VtkRenderRequest request) async {
    final sessionId = _ensureSession();
    final volume = _volume;
    final viewport = _viewport;
    if (volume == null || viewport == null) {
      throw const VtkPlatformException(
        code: 'invalid_state',
        message: 'Upload a volume before rendering',
      );
    }
    if (request is! VtkVolumeLocatorRequest) {
      throw const VtkPlatformException(
        code: 'unsupported_mode',
        message: 'Web currently supports only the volume locator',
      );
    }

    final locator = request;
    final result = _volumeChanged
        ? await _bridge.initialize(
            bytes: volume.data,
            width: volume.dimensions[0],
            height: volume.dimensions[1],
            depth: volume.dimensions[2],
            indexToPatient: volume.affine,
            outputWidth: viewport.width,
            outputHeight: viewport.height,
            azimuth: locator.azimuth,
            elevation: locator.elevation,
            zoom: locator.zoom,
          )
        : await _bridge.renderCamera(
            outputWidth: viewport.width,
            outputHeight: viewport.height,
            azimuth: locator.azimuth,
            elevation: locator.elevation,
            zoom: locator.zoom,
          );
    _volumeChanged = false;

    final pngBytes = _decodePng(result.pngDataUrl);
    _images[sessionId]?.value = pngBytes;
    _frameId++;
    _presentedFrames++;
    return _lastMetrics = VtkFrameMetrics(
      textureId: sessionId,
      width: result.width,
      height: result.height,
      volumeBytes: volume.byteCount,
      frameBytes: pngBytes.lengthInBytes,
      residentBytes: volume.byteCount + pngBytes.lengthInBytes,
      renderMicroseconds: result.renderMicroseconds,
      blitSubmitMicroseconds: result.captureMicroseconds,
      gpuSyncWaitMicroseconds: 0,
      readbackMicroseconds: result.captureMicroseconds,
      frameId: _frameId,
      presentedFrameCount: _presentedFrames,
      presentedFrameId: _frameId,
      graphicsContextGeneration: 1,
      handoffMode: 'vtkjs_png',
      contentEvidence: VtkFrameContentEvidence(
        fingerprint: _fnvFingerprint(pngBytes),
        changedPixelCount: result.width * result.height,
        uniqueByteValueCount: pngBytes.toSet().length,
      ),
      patientToClip: result.patientToClip,
    );
  }

  @override
  Future<VtkSessionStatus> status() async {
    final sessionId = _sessionId;
    return VtkSessionStatus(
      textureId: sessionId ?? -1,
      ready: sessionId != null,
      initializing: false,
      disposing: false,
      pendingTextureUnregistrations: 0,
      queuedInitializationCount: 0,
      presentedFrameCount: _presentedFrames,
      presentedFrameId: _lastMetrics?.presentedFrameId ?? 0,
      graphicsContextGeneration: sessionId == null ? 0 : 1,
      graphicsSupport: 'vtk.js WebGL',
    );
  }

  @override
  Future<void> resize(VtkViewport viewport) async {
    _ensureSession();
    _viewport = viewport;
  }

  @override
  Future<int> recreateGraphicsContext() => Future.error(
    const VtkPlatformException(
      code: 'unsupported_diagnostic',
      message: 'Explicit WebGL context recreation is unavailable',
    ),
  );

  @override
  Future<void> disposeSession() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    await _bridge.dispose();
    _images.remove(sessionId)?.dispose();
    _sessionId = null;
    _volume = null;
    _viewport = null;
    _lastMetrics = null;
    _volumeChanged = false;
  }

  int _ensureSession() {
    final sessionId = _sessionId;
    if (sessionId == null) throw const VtkSessionClosedException();
    return sessionId;
  }
}

Uint8List _decodePng(String dataUrl) {
  final data = Uri.tryParse(dataUrl)?.data;
  if (data == null || data.mimeType != 'image/png') {
    throw const VtkProtocolException('vtk.js returned no PNG frame');
  }
  return Uint8List.fromList(data.contentAsBytes());
}

String _fnvFingerprint(Uint8List bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return 'fnv1a32-png-v1:${hash.toRadixString(16).padLeft(8, '0')}';
}
