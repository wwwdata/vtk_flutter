import 'dart:typed_data';

import 'exceptions.dart';

const int vtkMaximumVolumeBytes = 256 * 1024 * 1024;

enum VtkRenderMode { obliqueMpr, volume3d, volumeLocator }

final class VtkCapabilities {
  VtkCapabilities({
    required Set<VtkRenderMode> renderModes,
    required this.maxVolumeBytes,
    required this.supportsExternalTexture,
  }) : renderModes = Set.unmodifiable(renderModes) {
    if (maxVolumeBytes < 0) {
      throw const VtkValidationException(
        field: 'maxVolumeBytes',
        message: 'Maximum volume bytes cannot be negative',
      );
    }
  }

  final Set<VtkRenderMode> renderModes;
  final int maxVolumeBytes;
  final bool supportsExternalTexture;

  bool get isSupported => renderModes.isNotEmpty && maxVolumeBytes > 0;
}

final class VtkViewport {
  VtkViewport({required this.width, required this.height}) {
    if (width <= 0) {
      throw const VtkValidationException(
        field: 'width',
        message: 'Viewport width must be positive',
      );
    }
    if (height <= 0) {
      throw const VtkValidationException(
        field: 'height',
        message: 'Viewport height must be positive',
      );
    }
  }

  final int width;
  final int height;
}

final class VtkVolume {
  VtkVolume({
    required this.data,
    required List<int> dimensions,
    required List<double> affine,
  }) : dimensions = List.unmodifiable(dimensions),
       affine = List.unmodifiable(affine) {
    if (this.dimensions.length != 3 ||
        this.dimensions.any((dimension) => dimension <= 0)) {
      throw const VtkValidationException(
        field: 'dimensions',
        message: 'Volume dimensions must contain three positive values',
      );
    }

    final expectedBytes = voxelCount * 2;
    if (expectedBytes > vtkMaximumVolumeBytes) {
      throw const VtkValidationException(
        field: 'data',
        message: 'Volume data exceeds the 256 MiB limit',
      );
    }
    if (data.lengthInBytes != expectedBytes) {
      throw VtkValidationException(
        field: 'data',
        message:
            'Signed-int16 data has ${data.lengthInBytes} bytes; '
            '$expectedBytes bytes are required by the dimensions',
      );
    }
    if (this.affine.length != 16 ||
        this.affine.any((value) => !value.isFinite)) {
      throw const VtkValidationException(
        field: 'affine',
        message: 'Affine must be a finite row-major 4x4 matrix',
      );
    }
  }

  final Uint8List data;
  final List<int> dimensions;
  final List<double> affine;

  int get voxelCount => dimensions[0] * dimensions[1] * dimensions[2];
  int get byteCount => data.lengthInBytes;
}

sealed class VtkRenderRequest {
  const VtkRenderRequest();

  VtkRenderMode get mode;
}

final class VtkObliqueMprRequest extends VtkRenderRequest {
  VtkObliqueMprRequest({
    required this.windowCenter,
    required this.windowWidth,
    required List<double> origin,
    required List<double> normal,
  }) : origin = List.unmodifiable(origin),
       normal = List.unmodifiable(normal) {
    _validateWindow(center: windowCenter, width: windowWidth);
    _validateVector(name: 'origin', values: this.origin);
    _validateVector(name: 'normal', values: this.normal);
    if (this.normal.every((value) => value == 0)) {
      throw const VtkValidationException(
        field: 'normal',
        message: 'Plane normal must be non-zero',
      );
    }
  }

  final double windowCenter;
  final double windowWidth;
  final List<double> origin;
  final List<double> normal;

  @override
  VtkRenderMode get mode => .obliqueMpr;
}

final class VtkVolume3dRequest extends VtkRenderRequest {
  VtkVolume3dRequest({
    required this.windowCenter,
    required this.windowWidth,
    required this.azimuth,
    required this.elevation,
    required this.zoom,
  }) {
    _validateWindow(center: windowCenter, width: windowWidth);
    _validateCamera(azimuth: azimuth, elevation: elevation, zoom: zoom);
  }

  final double windowCenter;
  final double windowWidth;
  final double azimuth;
  final double elevation;
  final double zoom;

  @override
  VtkRenderMode get mode => .volume3d;
}

final class VtkVolumeLocatorRequest extends VtkRenderRequest {
  VtkVolumeLocatorRequest({
    required this.azimuth,
    required this.elevation,
    required this.zoom,
  }) {
    _validateCamera(azimuth: azimuth, elevation: elevation, zoom: zoom);
  }

  final double azimuth;
  final double elevation;
  final double zoom;

  @override
  VtkRenderMode get mode => .volumeLocator;
}

final class VtkFrameContentEvidence {
  const VtkFrameContentEvidence({
    required this.fingerprint,
    required this.changedPixelCount,
    required this.uniqueByteValueCount,
  });

  final String fingerprint;
  final int changedPixelCount;
  final int uniqueByteValueCount;
}

final class VtkFrameArtifactEvidence {
  const VtkFrameArtifactEvidence({
    required this.path,
    required this.sha256,
    required this.byteCount,
  });

  final String path;
  final String sha256;
  final int byteCount;
}

final class VtkFrameMetrics {
  VtkFrameMetrics({
    required this.textureId,
    required this.width,
    required this.height,
    required this.volumeBytes,
    required this.frameBytes,
    required this.residentBytes,
    required this.renderMicroseconds,
    required this.blitSubmitMicroseconds,
    required this.gpuSyncWaitMicroseconds,
    required this.readbackMicroseconds,
    required this.frameId,
    required this.presentedFrameCount,
    required this.presentedFrameId,
    required this.graphicsContextGeneration,
    required this.handoffMode,
    this.contentEvidence,
    this.artifactEvidence,
    List<double>? patientToClip,
  }) : patientToClip = patientToClip == null
           ? null
           : List.unmodifiable(patientToClip) {
    final projection = this.patientToClip;
    if (projection != null &&
        (projection.length != 16 ||
            projection.any((value) => !value.isFinite))) {
      throw const VtkValidationException(
        field: 'patientToClip',
        message: 'Patient-to-clip must be a finite row-major 4x4 matrix',
      );
    }
  }

  final int textureId;
  final int width;
  final int height;
  final int volumeBytes;
  final int frameBytes;
  final int residentBytes;
  final int renderMicroseconds;
  final int blitSubmitMicroseconds;
  final int gpuSyncWaitMicroseconds;
  final int readbackMicroseconds;
  final int frameId;
  final int presentedFrameCount;
  final int presentedFrameId;
  final int graphicsContextGeneration;
  final String handoffMode;
  final VtkFrameContentEvidence? contentEvidence;
  final VtkFrameArtifactEvidence? artifactEvidence;
  final List<double>? patientToClip;
}

final class VtkSessionStatus {
  const VtkSessionStatus({
    required this.textureId,
    required this.ready,
    required this.initializing,
    required this.disposing,
    required this.pendingTextureUnregistrations,
    required this.queuedInitializationCount,
    required this.presentedFrameCount,
    required this.presentedFrameId,
    required this.graphicsContextGeneration,
    required this.graphicsSupport,
  });

  final int textureId;
  final bool ready;
  final bool initializing;
  final bool disposing;
  final int pendingTextureUnregistrations;
  final int queuedInitializationCount;
  final int presentedFrameCount;
  final int presentedFrameId;
  final int graphicsContextGeneration;
  final String graphicsSupport;

  bool get isReady =>
      textureId >= 0 &&
      ready &&
      !initializing &&
      !disposing &&
      pendingTextureUnregistrations == 0;

  bool get isDisposed =>
      textureId == -1 &&
      !ready &&
      !initializing &&
      !disposing &&
      pendingTextureUnregistrations == 0;
}

void _validateWindow({required double center, required double width}) {
  if (!center.isFinite) {
    throw const VtkValidationException(
      field: 'windowCenter',
      message: 'Window center must be finite',
    );
  }
  if (!width.isFinite || width <= 0) {
    throw const VtkValidationException(
      field: 'windowWidth',
      message: 'Window width must be finite and positive',
    );
  }
}

void _validateVector({required String name, required List<double> values}) {
  if (values.length != 3 || values.any((value) => !value.isFinite)) {
    throw VtkValidationException(
      field: name,
      message: '$name must contain three finite values',
    );
  }
}

void _validateCamera({
  required double azimuth,
  required double elevation,
  required double zoom,
}) {
  if (!azimuth.isFinite) {
    throw const VtkValidationException(
      field: 'azimuth',
      message: 'Azimuth must be finite',
    );
  }
  if (!elevation.isFinite) {
    throw const VtkValidationException(
      field: 'elevation',
      message: 'Elevation must be finite',
    );
  }
  if (!zoom.isFinite || zoom <= 0) {
    throw const VtkValidationException(
      field: 'zoom',
      message: 'Zoom must be finite and positive',
    );
  }
}
