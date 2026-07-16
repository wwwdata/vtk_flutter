import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/vtk_flutter.dart';
import 'package:vtk_flutter/vtk_flutter_platform_interface.dart';

void main() {
  late _FakePlatform platform;
  late VtkRenderer renderer;

  setUp(() {
    platform = _FakePlatform();
    renderer = VtkRenderer(platform: platform);
  });

  test('forwards capabilities and session operations', () async {
    final capabilities = await renderer.capabilities();
    final session = await renderer.open(VtkViewport(width: 640, height: 320));
    final volume = VtkVolume(
      data: Uint8List(2),
      dimensions: const [1, 1, 1],
      affine: _identity,
    );
    final request = VtkVolumeLocatorRequest(
      azimuth: 25,
      elevation: 18,
      zoom: 1,
    );

    await session.setVolume(volume);
    expect(await session.render(request), same(platform.frame));
    expect(await session.status(), same(platform.sessionStatus));
    await session.resize(VtkViewport(width: 800, height: 600));
    expect(await session.recreateGraphicsContext(), 2);
    await session.close();

    expect(capabilities, same(platform.rendererCapabilities));
    expect(session.textureId, 42);
    expect(session.isClosed, isTrue);
    expect(platform.calls, [
      'capabilities',
      'createSession',
      'setVolume',
      'render',
      'status',
      'resize',
      'recreateGraphicsContext',
      'disposeSession',
    ]);
  });

  test('enforces one active session and permits reopen after close', () async {
    final first = await renderer.open(VtkViewport(width: 1, height: 1));

    await expectLater(
      renderer.open(VtkViewport(width: 1, height: 1)),
      throwsA(isA<VtkSessionAlreadyOpenException>()),
    );

    await first.close();
    final second = await renderer.open(VtkViewport(width: 2, height: 2));
    await second.close();

    expect(
      platform.calls.where((call) => call == 'createSession'),
      hasLength(2),
    );
  });

  test('reserves the session while asynchronous open is pending', () async {
    platform.createSessionResult = Completer<int>();
    final firstOpen = renderer.open(VtkViewport(width: 1, height: 1));

    await expectLater(
      renderer.open(VtkViewport(width: 1, height: 1)),
      throwsA(isA<VtkSessionAlreadyOpenException>()),
    );

    platform.createSessionResult?.complete(42);
    await (await firstOpen).close();
  });

  test('shares the one-session reservation across renderers', () async {
    final first = await renderer.open(VtkViewport(width: 1, height: 1));
    final secondRenderer = VtkRenderer(platform: platform);

    await expectLater(
      secondRenderer.open(VtkViewport(width: 1, height: 1)),
      throwsA(isA<VtkSessionAlreadyOpenException>()),
    );

    await first.close();
    final second = await secondRenderer.open(VtkViewport(width: 1, height: 1));
    await second.close();
  });

  test('makes close idempotent', () async {
    final session = await renderer.open(VtkViewport(width: 1, height: 1));

    await session.close();
    await session.close();

    expect(
      platform.calls.where((call) => call == 'disposeSession'),
      hasLength(1),
    );
  });

  test('waits for an in-flight operation before disposal', () async {
    final session = await renderer.open(VtkViewport(width: 1, height: 1));
    platform.renderResult = Completer<VtkFrameMetrics>();
    final render = session.render(
      VtkVolumeLocatorRequest(azimuth: 25, elevation: 18, zoom: 1),
    );
    final close = session.close();

    await Future<void>.delayed(Duration.zero);
    expect(platform.calls, isNot(contains('disposeSession')));

    platform.renderResult?.complete(platform.frame);
    expect(await render, same(platform.frame));
    await close;
    expect(platform.calls.last, 'disposeSession');
  });

  test('rejects every operation after close with a typed error', () async {
    final session = await renderer.open(VtkViewport(width: 1, height: 1));
    await session.close();
    final request = VtkVolumeLocatorRequest(
      azimuth: 25,
      elevation: 18,
      zoom: 1,
    );
    final volume = VtkVolume(
      data: Uint8List(2),
      dimensions: const [1, 1, 1],
      affine: _identity,
    );

    await expectLater(session.setVolume(volume), _throwsClosed);
    await expectLater(session.render(request), _throwsClosed);
    await expectLater(session.status(), _throwsClosed);
    await expectLater(
      session.resize(VtkViewport(width: 2, height: 2)),
      _throwsClosed,
    );
    await expectLater(session.recreateGraphicsContext(), _throwsClosed);
  });

  test('retains the reservation until failed disposal is retried', () async {
    final first = await renderer.open(VtkViewport(width: 1, height: 1));
    platform.disposeError = const VtkPlatformException(
      code: 'dispose',
      message: 'failed',
    );

    await expectLater(first.close(), throwsA(isA<VtkPlatformException>()));
    await expectLater(
      renderer.open(VtkViewport(width: 1, height: 1)),
      throwsA(isA<VtkSessionAlreadyOpenException>()),
    );
    platform.disposeError = null;
    await first.close();
    final second = await renderer.open(VtkViewport(width: 1, height: 1));
    await second.close();
  });
}

final _throwsClosed = throwsA(isA<VtkSessionClosedException>());

final class _FakePlatform extends VtkFlutterPlatform {
  final calls = <String>[];
  Completer<int>? createSessionResult;
  Completer<VtkFrameMetrics>? renderResult;
  VtkPlatformException? disposeError;

  final rendererCapabilities = VtkCapabilities(
    renderModes: VtkRenderMode.values.toSet(),
    maxVolumeBytes: vtkMaximumVolumeBytes,
    supportsExternalTexture: true,
  );
  final frame = VtkFrameMetrics(
    textureId: 42,
    width: 1,
    height: 1,
    volumeBytes: 2,
    frameBytes: 4,
    residentBytes: 6,
    renderMicroseconds: 1,
    blitSubmitMicroseconds: 1,
    gpuSyncWaitMicroseconds: 1,
    readbackMicroseconds: 0,
    frameId: 1,
    presentedFrameCount: 1,
    presentedFrameId: 1,
    graphicsContextGeneration: 1,
    handoffMode: 'fake',
  );
  final sessionStatus = const VtkSessionStatus(
    textureId: 42,
    ready: true,
    initializing: false,
    disposing: false,
    pendingTextureUnregistrations: 0,
    queuedInitializationCount: 1,
    presentedFrameCount: 1,
    presentedFrameId: 1,
    graphicsContextGeneration: 1,
    graphicsSupport: 'fake',
  );

  @override
  Future<VtkCapabilities> capabilities() async {
    calls.add('capabilities');
    return rendererCapabilities;
  }

  @override
  Future<int> createSession(VtkViewport viewport) async {
    calls.add('createSession');
    return createSessionResult?.future ?? 42;
  }

  @override
  Future<void> setVolume(VtkVolume volume) async => calls.add('setVolume');

  @override
  Future<VtkFrameMetrics> render(VtkRenderRequest request) async {
    calls.add('render');
    return renderResult?.future ?? frame;
  }

  @override
  Future<VtkSessionStatus> status() async {
    calls.add('status');
    return sessionStatus;
  }

  @override
  Future<void> resize(VtkViewport viewport) async => calls.add('resize');

  @override
  Future<int> recreateGraphicsContext() async {
    calls.add('recreateGraphicsContext');
    return 2;
  }

  @override
  Future<void> disposeSession() async {
    calls.add('disposeSession');
    final error = disposeError;
    if (error != null) throw error;
  }
}

const _identity = <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
