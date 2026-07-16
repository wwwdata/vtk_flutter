import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/exceptions.dart';
import 'src/ffi/vtk_ffi_transport.dart';
import 'src/models.dart';
import 'vtk_flutter_platform_interface.dart';

final class MethodChannelVtkFlutter extends VtkFlutterPlatform {
  MethodChannelVtkFlutter({VtkFfiTransport? ffiTransport})
    : _ffiTransport = ffiTransport ?? createDefaultVtkFfiTransport();

  @visibleForTesting
  final methodChannel = const MethodChannel('vtk_flutter/session');

  final VtkFfiTransport? _ffiTransport;
  int? _nativeSessionAddress;
  int? _textureId;
  VtkViewport? _viewport;

  @override
  Future<VtkCapabilities> capabilities() async {
    final values = await _invokeMap(method: 'capabilities');
    final modes = values.readList('renderModes').map(_decodeMode).toSet();
    return VtkCapabilities(
      renderModes: modes,
      maxVolumeBytes: values.readInt('maxVolumeBytes'),
      supportsExternalTexture: values.readBool('supportsExternalTexture'),
    );
  }

  @override
  Future<int> createSession(VtkViewport viewport) async {
    final values = await _invokeMap(
      method: 'createSession',
      arguments: {'width': viewport.width, 'height': viewport.height},
    );
    final textureId = values.readInt('textureId');
    if (textureId < 0) {
      throw const VtkProtocolException(
        'Native VTK returned an invalid texture identifier',
      );
    }
    final address = values['nativeSessionAddress'];
    if (address != null && (address is! num || address <= 0)) {
      throw const VtkProtocolException(
        'Native VTK returned an invalid session address',
      );
    }
    _nativeSessionAddress = (address as num?)?.round();
    _textureId = textureId;
    _viewport = viewport;
    return textureId;
  }

  @override
  Future<void> setVolume(VtkVolume volume) {
    final address = _nativeSessionAddress;
    final transport = _ffiTransport;
    if (address != null && transport != null) {
      return transport.setVolume(sessionAddress: address, volume: volume);
    }
    return _invokeVoid(
      method: 'setVolume',
      arguments: {
        'voxels': volume.data,
        'width': volume.dimensions[0],
        'height': volume.dimensions[1],
        'depth': volume.dimensions[2],
        'indexToPatient': Float64List.fromList(volume.affine),
      },
    );
  }

  @override
  Future<VtkFrameMetrics> render(VtkRenderRequest request) async {
    final address = _nativeSessionAddress;
    final textureId = _textureId;
    final viewport = _viewport;
    final transport = _ffiTransport;
    if (address != null &&
        textureId != null &&
        viewport != null &&
        transport != null) {
      final metrics = await transport.render(
        sessionAddress: address,
        textureId: textureId,
        viewport: viewport,
        request: request,
      );
      final presentation = await _invokeMap(method: 'presentFrame');
      return VtkFrameMetrics(
        textureId: metrics.textureId,
        width: metrics.width,
        height: metrics.height,
        volumeBytes: metrics.volumeBytes,
        frameBytes: metrics.frameBytes,
        residentBytes: metrics.residentBytes,
        renderMicroseconds: metrics.renderMicroseconds,
        blitSubmitMicroseconds: metrics.blitSubmitMicroseconds,
        gpuSyncWaitMicroseconds: metrics.gpuSyncWaitMicroseconds,
        readbackMicroseconds: metrics.readbackMicroseconds,
        frameId: presentation.readInt('frameId'),
        presentedFrameCount: presentation.readInt('presentedFrameCount'),
        presentedFrameId: presentation.readInt('presentedFrameId'),
        graphicsContextGeneration: presentation.readInt(
          'graphicsContextGeneration',
        ),
        handoffMode: presentation.readString('handoffMode'),
        contentEvidence: metrics.contentEvidence,
        artifactEvidence: metrics.artifactEvidence,
        patientToClip: metrics.patientToClip,
      );
    }
    final values = await _invokeMap(
      method: 'render',
      arguments: _encodeRequest(request),
    );
    final contentEvidence = _decodeContentEvidence(values);
    final artifactEvidence = _decodeArtifactEvidence(values);
    if (artifactEvidence != null && contentEvidence == null) {
      throw const VtkProtocolException(
        'Native VTK artifact omitted frame content evidence',
      );
    }
    return VtkFrameMetrics(
      textureId: values.readInt('textureId'),
      width: values.readInt('width'),
      height: values.readInt('height'),
      volumeBytes: values.readInt('volumeBytes'),
      frameBytes: values.readInt('frameBytes'),
      residentBytes: values.readInt('residentBytes'),
      renderMicroseconds: values.readInt('renderUs'),
      blitSubmitMicroseconds: values.readInt('blitSubmitUs'),
      gpuSyncWaitMicroseconds: values.readInt('gpuSyncWaitUs'),
      readbackMicroseconds: values.readInt('readbackUs'),
      frameId: values.readInt('frameId'),
      presentedFrameCount: values.readInt('presentedFrameCount'),
      presentedFrameId: values.readInt('presentedFrameId'),
      graphicsContextGeneration: values.readInt('graphicsContextGeneration'),
      handoffMode: values.readString('handoffMode'),
      contentEvidence: contentEvidence,
      artifactEvidence: artifactEvidence,
      patientToClip: values.decodeOptionalMatrix('patientToClip'),
    );
  }

  @override
  Future<VtkSessionStatus> status() async {
    final values = await _invokeMap(method: 'status');
    return VtkSessionStatus(
      textureId: values.readInt('textureId'),
      ready: values.readBool('ready'),
      initializing: values.readBool('initializing'),
      disposing: values.readBool('disposing'),
      pendingTextureUnregistrations: values.readInt(
        'pendingTextureUnregistrations',
      ),
      queuedInitializationCount: values.readInt('queuedInitializationCount'),
      presentedFrameCount: values.readInt('presentedFrameCount'),
      presentedFrameId: values.readInt('presentedFrameId'),
      graphicsContextGeneration: values.readInt('graphicsContextGeneration'),
      graphicsSupport:
          values['graphicsSupport'] as String? ??
          values['openGlSupport'] as String? ??
          '',
    );
  }

  @override
  Future<void> resize(VtkViewport viewport) async {
    await _invokeVoid(
      method: 'resize',
      arguments: {'width': viewport.width, 'height': viewport.height},
    );
    _viewport = viewport;
  }

  @override
  Future<int> recreateGraphicsContext() async {
    final values = await _invokeMap(method: 'recreateGraphicsContext');
    final generation = values.readInt('graphicsContextGeneration');
    if (generation <= 0) {
      throw const VtkProtocolException(
        'Native VTK returned an invalid graphics context generation',
      );
    }
    return generation;
  }

  @override
  Future<void> disposeSession() async {
    try {
      await _invokeVoid(method: 'disposeSession');
    } finally {
      _nativeSessionAddress = null;
      _textureId = null;
      _viewport = null;
    }
  }

  Future<Map<Object?, Object?>> _invokeMap({
    required String method,
    Object? arguments,
  }) async {
    try {
      final result = await methodChannel.invokeMapMethod<Object?, Object?>(
        method,
        arguments,
      );
      if (result == null) {
        throw VtkProtocolException('Native VTK returned no result for $method');
      }
      return result;
    } on PlatformException catch (error) {
      throw VtkPlatformException(
        code: error.code,
        message: error.message ?? 'Native VTK operation failed',
      );
    } on MissingPluginException {
      throw const VtkPlatformException(
        code: 'unavailable',
        message: 'The native VTK renderer is unavailable',
      );
    }
  }

  Future<void> _invokeVoid({required String method, Object? arguments}) async {
    try {
      await methodChannel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      throw VtkPlatformException(
        code: error.code,
        message: error.message ?? 'Native VTK operation failed',
      );
    } on MissingPluginException {
      throw const VtkPlatformException(
        code: 'unavailable',
        message: 'The native VTK renderer is unavailable',
      );
    }
  }
}

Map<String, Object> _encodeRequest(VtkRenderRequest request) =>
    switch (request) {
      VtkObliqueMprRequest(
        :final windowCenter,
        :final windowWidth,
        :final origin,
        :final normal,
      ) =>
        {
          'mode': 1,
          'windowCenter': windowCenter,
          'windowWidth': windowWidth,
          'planeOrigin': Float64List.fromList(origin),
          'planeNormal': Float64List.fromList(normal),
        },
      VtkVolume3dRequest(
        :final windowCenter,
        :final windowWidth,
        :final azimuth,
        :final elevation,
        :final zoom,
      ) =>
        {
          'mode': 2,
          'windowCenter': windowCenter,
          'windowWidth': windowWidth,
          'cameraAzimuthDegrees': azimuth,
          'cameraElevationDegrees': elevation,
          'cameraZoom': zoom,
        },
      VtkVolumeLocatorRequest(:final azimuth, :final elevation, :final zoom) =>
        {
          'mode': 3,
          'cameraAzimuthDegrees': azimuth,
          'cameraElevationDegrees': elevation,
          'cameraZoom': zoom,
        },
    };

VtkRenderMode _decodeMode(Object? value) => switch (value) {
  1 => .obliqueMpr,
  2 => .volume3d,
  3 => .volumeLocator,
  _ => throw VtkProtocolException('Native VTK returned invalid mode $value'),
};

extension on Map<Object?, Object?> {
  int readInt(String key) {
    final value = this[key];
    if (value is! num || !value.isFinite) {
      throw VtkProtocolException('Native VTK returned invalid $key');
    }
    return value.round();
  }

  bool readBool(String key) {
    final value = this[key];
    if (value is! bool) {
      throw VtkProtocolException('Native VTK returned invalid $key');
    }
    return value;
  }

  String readString(String key) {
    final value = this[key];
    if (value is! String) {
      throw VtkProtocolException('Native VTK returned invalid $key');
    }
    return value;
  }

  List<Object?> readList(String key) {
    final value = this[key];
    if (value is! List<Object?>) {
      throw VtkProtocolException('Native VTK returned invalid $key');
    }
    return value;
  }

  List<double>? decodeOptionalMatrix(String key) {
    final value = this[key];
    if (value == null) return null;
    if (value is! List<Object?> ||
        value.length != 16 ||
        value.any((element) => element is! num || !element.isFinite)) {
      throw VtkProtocolException('Native VTK returned invalid $key');
    }
    return value.cast<num>().map((element) => element.toDouble()).toList();
  }
}

VtkFrameContentEvidence? _decodeContentEvidence(Map<Object?, Object?> values) {
  const keys = {
    'frameFingerprint',
    'frameChangedPixels',
    'frameUniqueByteValues',
  };
  final count = keys.where(values.containsKey).length;
  if (count == 0) return null;
  if (count != keys.length) {
    throw const VtkProtocolException(
      'Native VTK returned partial frame content evidence',
    );
  }
  return VtkFrameContentEvidence(
    fingerprint: values.readString('frameFingerprint'),
    changedPixelCount: values.readInt('frameChangedPixels'),
    uniqueByteValueCount: values.readInt('frameUniqueByteValues'),
  );
}

VtkFrameArtifactEvidence? _decodeArtifactEvidence(
  Map<Object?, Object?> values,
) {
  const keys = {
    'frameArtifactPath',
    'frameArtifactSha256',
    'frameArtifactBytes',
  };
  final count = keys.where(values.containsKey).length;
  if (count == 0) return null;
  if (count != keys.length) {
    throw const VtkProtocolException(
      'Native VTK returned partial frame artifact evidence',
    );
  }
  return VtkFrameArtifactEvidence(
    path: values.readString('frameArtifactPath'),
    sha256: values.readString('frameArtifactSha256'),
    byteCount: values.readInt('frameArtifactBytes'),
  );
}
