import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/vtk_flutter.dart';

void main() {
  group('VtkViewport', () {
    test('accepts positive pixel dimensions', () {
      final viewport = VtkViewport(width: 640, height: 320);

      expect(viewport.width, 640);
      expect(viewport.height, 320);
    });

    test('rejects non-positive dimensions', () {
      expect(
        () => VtkViewport(width: 0, height: 320),
        throwsA(isA<VtkValidationException>()),
      );
      expect(
        () => VtkViewport(width: 640, height: -1),
        throwsA(isA<VtkValidationException>()),
      );
    });
  });

  group('VtkVolume', () {
    test('retains x-fastest signed-int16 bytes and affine', () {
      final bytes = Uint8List.fromList([0, 0, 1, 0, 255, 255, 2, 0]);
      final volume = VtkVolume(
        data: bytes,
        dimensions: const [2, 2, 1],
        affine: _identity,
      );

      expect(volume.data, same(bytes));
      expect(volume.dimensions, [2, 2, 1]);
      expect(volume.affine, _identity);
      expect(volume.voxelCount, 4);
      expect(volume.byteCount, 8);
    });

    test('copies dimensions and affine metadata', () {
      final dimensions = [1, 1, 1];
      final affine = [..._identity];
      final volume = VtkVolume(
        data: Uint8List(2),
        dimensions: dimensions,
        affine: affine,
      );

      dimensions[0] = 2;
      affine[0] = 2;

      expect(volume.dimensions, [1, 1, 1]);
      expect(volume.affine, _identity);
    });

    test('rejects dimensions that do not describe the bytes', () {
      expect(
        () => VtkVolume(
          data: Uint8List(6),
          dimensions: const [2, 2, 1],
          affine: _identity,
        ),
        throwsA(isA<VtkValidationException>()),
      );
      expect(
        () => VtkVolume(
          data: Uint8List(2),
          dimensions: const [1, 0, 1],
          affine: _identity,
        ),
        throwsA(isA<VtkValidationException>()),
      );
    });

    test('rejects volumes above 256 MiB before byte upload', () {
      expect(
        () => VtkVolume(
          data: Uint8List(0),
          dimensions: const [513, 512, 512],
          affine: _identity,
        ),
        throwsA(
          isA<VtkValidationException>().having(
            (error) => error.field,
            'field',
            'data',
          ),
        ),
      );
    });

    test('rejects malformed or non-finite affine matrices', () {
      expect(
        () => VtkVolume(
          data: Uint8List(2),
          dimensions: const [1, 1, 1],
          affine: const [1, 0, 0],
        ),
        throwsA(isA<VtkValidationException>()),
      );
      expect(
        () => VtkVolume(
          data: Uint8List(2),
          dimensions: const [1, 1, 1],
          affine: [..._identity]..[15] = double.nan,
        ),
        throwsA(isA<VtkValidationException>()),
      );
    });
  });

  group('Vtk render requests', () {
    test('exposes a mode for every sealed request', () {
      final requests = <VtkRenderRequest>[
        VtkObliqueMprRequest(
          windowCenter: 350,
          windowWidth: 1800,
          origin: [10, 20, 30],
          normal: [0, 0, 1],
        ),
        VtkVolume3dRequest(
          windowCenter: 350,
          windowWidth: 1800,
          azimuth: 25,
          elevation: 18,
          zoom: 1,
        ),
        VtkVolumeLocatorRequest(azimuth: 61, elevation: -11, zoom: 2.5),
      ];

      expect(requests.map((request) => request.mode), VtkRenderMode.values);
    });

    test('rejects invalid window, plane and camera values', () {
      expect(
        () => VtkObliqueMprRequest(
          windowCenter: 350,
          windowWidth: 0,
          origin: [10, 20, 30],
          normal: [0, 0, 1],
        ),
        throwsA(isA<VtkValidationException>()),
      );
      expect(
        () => VtkObliqueMprRequest(
          windowCenter: 350,
          windowWidth: 1800,
          origin: [10, 20],
          normal: [0, 0, 1],
        ),
        throwsA(isA<VtkValidationException>()),
      );
      expect(
        () => VtkObliqueMprRequest(
          windowCenter: 350,
          windowWidth: 1800,
          origin: [10, 20, 30],
          normal: [0, 0, 0],
        ),
        throwsA(isA<VtkValidationException>()),
      );
      expect(
        () => VtkVolume3dRequest(
          windowCenter: double.nan,
          windowWidth: 1800,
          azimuth: 25,
          elevation: 18,
          zoom: 1,
        ),
        throwsA(isA<VtkValidationException>()),
      );
      expect(
        () => VtkVolumeLocatorRequest(azimuth: 25, elevation: 18, zoom: 0),
        throwsA(isA<VtkValidationException>()),
      );
    });
  });

  test('retains renderer capabilities without exposing transport', () {
    final capabilities = VtkCapabilities(
      renderModes: VtkRenderMode.values.toSet(),
      maxVolumeBytes: vtkMaximumVolumeBytes,
      supportsExternalTexture: true,
    );

    expect(capabilities.renderModes, VtkRenderMode.values.toSet());
    expect(capabilities.maxVolumeBytes, 256 * 1024 * 1024);
    expect(capabilities.supportsExternalTexture, isTrue);
    expect(capabilities.isSupported, isTrue);
  });

  test('retains frame, presentation and rendering evidence', () {
    final metrics = VtkFrameMetrics(
      textureId: 42,
      width: 640,
      height: 320,
      volumeBytes: 983040,
      frameBytes: 819200,
      residentBytes: 1802240,
      renderMicroseconds: 3000,
      blitSubmitMicroseconds: 60,
      gpuSyncWaitMicroseconds: 200,
      readbackMicroseconds: 850,
      frameId: 4,
      presentedFrameCount: 7,
      presentedFrameId: 4,
      graphicsContextGeneration: 2,
      handoffMode: 'iosurface_opengl_blit',
      contentEvidence: const VtkFrameContentEvidence(
        fingerprint: 'fnv1a64-rgba-v1:fedcba9876543210',
        changedPixelCount: 172800,
        uniqueByteValueCount: 193,
      ),
      artifactEvidence: const VtkFrameArtifactEvidence(
        path: '/tmp/frame.bmp',
        sha256:
            '0123456789abcdef0123456789abcdef'
            '0123456789abcdef0123456789abcdef',
        byteCount: 819254,
      ),
      patientToClip: _identity,
    );

    expect(metrics.textureId, 42);
    expect(metrics.width, 640);
    expect(metrics.height, 320);
    expect(metrics.volumeBytes, 983040);
    expect(metrics.frameBytes, 819200);
    expect(metrics.residentBytes, 1802240);
    expect(metrics.renderMicroseconds, 3000);
    expect(metrics.blitSubmitMicroseconds, 60);
    expect(metrics.gpuSyncWaitMicroseconds, 200);
    expect(metrics.readbackMicroseconds, 850);
    expect(metrics.frameId, 4);
    expect(metrics.presentedFrameCount, 7);
    expect(metrics.presentedFrameId, 4);
    expect(metrics.graphicsContextGeneration, 2);
    expect(metrics.handoffMode, 'iosurface_opengl_blit');
    expect(metrics.contentEvidence?.changedPixelCount, 172800);
    expect(metrics.artifactEvidence?.byteCount, 819254);
    expect(metrics.patientToClip, _identity);
  });

  test('copies the patient-to-clip projection', () {
    final patientToClip = [..._identity];
    final metrics = _metrics(patientToClip: patientToClip);

    patientToClip[0] = 2;

    expect(metrics.patientToClip, _identity);
  });

  test('retains session lifecycle and presentation status', () {
    const status = VtkSessionStatus(
      textureId: 42,
      ready: true,
      initializing: false,
      disposing: false,
      pendingTextureUnregistrations: 0,
      queuedInitializationCount: 3,
      presentedFrameCount: 7,
      presentedFrameId: 4,
      graphicsContextGeneration: 2,
      graphicsSupport: 'OpenGL renderer: Metal',
    );

    expect(status.isReady, isTrue);
    expect(status.isDisposed, isFalse);
    expect(status.presentedFrameId, 4);
    expect(status.graphicsSupport, contains('Metal'));
  });
}

VtkFrameMetrics _metrics({List<double>? patientToClip}) => VtkFrameMetrics(
  textureId: 42,
  width: 640,
  height: 320,
  volumeBytes: 8,
  frameBytes: 819200,
  residentBytes: 819208,
  renderMicroseconds: 3000,
  blitSubmitMicroseconds: 60,
  gpuSyncWaitMicroseconds: 200,
  readbackMicroseconds: 850,
  frameId: 4,
  presentedFrameCount: 7,
  presentedFrameId: 4,
  graphicsContextGeneration: 2,
  handoffMode: 'test',
  patientToClip: patientToClip,
);

const _identity = <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
