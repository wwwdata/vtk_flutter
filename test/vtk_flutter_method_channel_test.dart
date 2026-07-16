import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/vtk_flutter.dart';
import 'package:vtk_flutter/src/ffi/vtk_ffi_transport.dart';
import 'package:vtk_flutter/vtk_flutter_method_channel.dart';
import 'package:vtk_flutter/vtk_flutter_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vtk_flutter/session');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'capabilities' => <String, Object>{
              'renderModes': [1, 2, 3],
              'maxVolumeBytes': vtkMaximumVolumeBytes,
              'supportsExternalTexture': true,
            },
            'createSession' => <String, Object>{'textureId': 42},
            'setVolume' || 'resize' || 'disposeSession' => null,
            'render' => _frameMap,
            'status' => _statusMap,
            'recreateGraphicsContext' => <String, Object>{
              'graphicsContextGeneration': 3,
            },
            _ => throw MissingPluginException(),
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('is the default platform implementation', () {
    expect(VtkFlutterPlatform.instance, isA<MethodChannelVtkFlutter>());
    expect(
      (VtkFlutterPlatform.instance as MethodChannelVtkFlutter)
          .methodChannel
          .name,
      'vtk_flutter/session',
    );
  });

  test('maps capabilities and every session operation', () async {
    final platform = MethodChannelVtkFlutter(ffiTransport: _FakeFfiTransport());
    final volume = VtkVolume(
      data: Uint8List.fromList([0, 0, 1, 0, 255, 255, 2, 0]),
      dimensions: const [2, 2, 1],
      affine: _identity,
    );
    final request = VtkObliqueMprRequest(
      windowCenter: 350,
      windowWidth: 1800,
      origin: const [10, 20, 30],
      normal: const [0, 0.34, 0.94],
    );

    final capabilities = await platform.capabilities();
    final textureId = await platform.createSession(
      VtkViewport(width: 640, height: 320),
    );
    await platform.setVolume(volume);
    final frame = await platform.render(request);
    final status = await platform.status();
    await platform.resize(VtkViewport(width: 800, height: 600));
    final generation = await platform.recreateGraphicsContext();
    await platform.disposeSession();

    expect(capabilities.renderModes, VtkRenderMode.values.toSet());
    expect(capabilities.maxVolumeBytes, vtkMaximumVolumeBytes);
    expect(textureId, 42);
    expect(frame.textureId, 42);
    expect(frame.residentBytes, 1802240);
    expect(frame.readbackMicroseconds, 850);
    expect(frame.presentedFrameId, 4);
    expect(frame.contentEvidence?.uniqueByteValueCount, 193);
    expect(frame.artifactEvidence?.sha256, hasLength(64));
    expect(frame.patientToClip, _identity);
    expect(status.isReady, isTrue);
    expect(status.graphicsSupport, contains('Metal'));
    expect(generation, 3);
    expect(calls.map((call) => call.method), [
      'capabilities',
      'createSession',
      'setVolume',
      'render',
      'status',
      'resize',
      'recreateGraphicsContext',
      'disposeSession',
    ]);

    expect(calls[1].arguments, {
      'width': 640,
      'height': 320,
      'coreApiAddress': 4242,
    });
    final volumeArguments = calls[2].arguments as Map<Object?, Object?>;
    expect(volumeArguments['voxels'], volume.data);
    expect(volumeArguments['width'], 2);
    expect(volumeArguments['height'], 2);
    expect(volumeArguments['depth'], 1);
    expect(volumeArguments['indexToPatient'], isA<Float64List>());
    final renderArguments = calls[3].arguments as Map<Object?, Object?>;
    expect(renderArguments['mode'], 1);
    expect(renderArguments['windowCenter'], 350);
    expect(renderArguments['windowWidth'], 1800);
    expect(renderArguments['planeOrigin'], isA<Float64List>());
    expect(renderArguments['planeNormal'], isA<Float64List>());
    expect(calls[5].arguments, {'width': 800, 'height': 600});
  });

  test('maps both camera request variants', () async {
    final platform = MethodChannelVtkFlutter();

    await platform.render(
      VtkVolume3dRequest(
        windowCenter: 350,
        windowWidth: 1800,
        azimuth: 25,
        elevation: 18,
        zoom: 1.5,
      ),
    );
    await platform.render(
      VtkVolumeLocatorRequest(azimuth: 61, elevation: -11, zoom: 2.5),
    );

    expect(calls[0].arguments, {
      'mode': 2,
      'windowCenter': 350.0,
      'windowWidth': 1800.0,
      'cameraAzimuthDegrees': 25.0,
      'cameraElevationDegrees': 18.0,
      'cameraZoom': 1.5,
    });
    expect(calls[1].arguments, {
      'mode': 3,
      'cameraAzimuthDegrees': 61.0,
      'cameraElevationDegrees': -11.0,
      'cameraZoom': 2.5,
    });
  });

  test(
    'routes volume and render through injected FFI for a native session address',
    () async {
      final transport = _FakeFfiTransport();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'createSession' => <String, Object>{
                'textureId': 42,
                'nativeSessionAddress': 4096,
              },
              'presentFrame' => <String, Object>{
                'frameId': 5,
                'presentedFrameCount': 4,
                'presentedFrameId': 4,
                'graphicsContextGeneration': 2,
                'handoffMode': 'iosurface_opengl_blit',
              },
              'disposeSession' => null,
              _ => throw MissingPluginException(),
            };
          });
      final platform = MethodChannelVtkFlutter(ffiTransport: transport);
      final viewport = VtkViewport(width: 640, height: 320);
      final volume = VtkVolume(
        data: Uint8List(2),
        dimensions: const [1, 1, 1],
        affine: _identity,
      );
      final request = VtkVolumeLocatorRequest(
        azimuth: 61,
        elevation: -11,
        zoom: 2.5,
      );

      await platform.createSession(viewport);
      await platform.setVolume(volume);
      final frame = await platform.render(request);
      await platform.disposeSession();

      expect(transport.sessionAddress, 4096);
      expect(transport.volume, same(volume));
      expect(transport.textureId, 42);
      expect(transport.viewport, same(viewport));
      expect(transport.request, same(request));
      expect(frame.frameId, 5);
      expect(frame.presentedFrameId, 4);
      expect(frame.graphicsContextGeneration, 2);
      expect(frame.handoffMode, 'iosurface_opengl_blit');
      expect(calls.map((call) => call.method), [
        'createSession',
        'presentFrame',
        'disposeSession',
      ]);
    },
  );

  test('reports malformed native results as typed errors', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => {'textureId': -1});

    await expectLater(
      MethodChannelVtkFlutter(
        ffiTransport: _FakeFfiTransport(),
      ).createSession(VtkViewport(width: 1, height: 1)),
      throwsA(isA<VtkProtocolException>()),
    );
  });
}

const _identity = <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];

const _frameMap = <String, Object>{
  'textureId': 42,
  'width': 640,
  'height': 320,
  'volumeBytes': 983040,
  'frameBytes': 819200,
  'residentBytes': 1802240,
  'renderUs': 3000,
  'blitSubmitUs': 60,
  'gpuSyncWaitUs': 200,
  'readbackUs': 850,
  'frameId': 4,
  'presentedFrameCount': 7,
  'presentedFrameId': 4,
  'graphicsContextGeneration': 2,
  'handoffMode': 'iosurface_opengl_blit',
  'frameFingerprint': 'fnv1a64-rgba-v1:fedcba9876543210',
  'frameChangedPixels': 172800,
  'frameUniqueByteValues': 193,
  'frameArtifactPath': '/tmp/frame.bmp',
  'frameArtifactSha256':
      '0123456789abcdef0123456789abcdef'
      '0123456789abcdef0123456789abcdef',
  'frameArtifactBytes': 819254,
  'patientToClip': _identity,
};

const _statusMap = <String, Object>{
  'textureId': 42,
  'ready': true,
  'initializing': false,
  'disposing': false,
  'pendingTextureUnregistrations': 0,
  'queuedInitializationCount': 3,
  'presentedFrameCount': 7,
  'presentedFrameId': 4,
  'graphicsContextGeneration': 2,
  'graphicsSupport': 'OpenGL renderer: Metal',
};

final class _FakeFfiTransport implements VtkFfiTransport {
  @override
  int get coreApiAddress => 4242;

  int? sessionAddress;
  int? textureId;
  VtkViewport? viewport;
  VtkVolume? volume;
  VtkRenderRequest? request;

  final frame = VtkFrameMetrics(
    textureId: 42,
    width: 640,
    height: 320,
    volumeBytes: 2,
    frameBytes: 819200,
    residentBytes: 819202,
    renderMicroseconds: 3000,
    blitSubmitMicroseconds: 60,
    gpuSyncWaitMicroseconds: 200,
    readbackMicroseconds: 850,
    frameId: 0,
    presentedFrameCount: 0,
    presentedFrameId: 0,
    graphicsContextGeneration: 0,
    handoffMode: 'ffi',
  );

  @override
  Future<void> setVolume({
    required int sessionAddress,
    required VtkVolume volume,
  }) async {
    this.sessionAddress = sessionAddress;
    this.volume = volume;
  }

  @override
  Future<VtkFrameMetrics> render({
    required int sessionAddress,
    required int textureId,
    required VtkViewport viewport,
    required VtkRenderRequest request,
  }) async {
    this.sessionAddress = sessionAddress;
    this.textureId = textureId;
    this.viewport = viewport;
    this.request = request;
    return frame;
  }
}
