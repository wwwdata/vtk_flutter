import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/src/api/vtk_api.dart';
import 'package:vtk_flutter/src/ffi/vtk_session_executor_base.dart';
import 'package:vtk_flutter/src/native_backend.dart';
import 'package:vtk_flutter/src/vtk_flutter_platform_interface.dart';

void main() {
  test('keeps VTK ownership in Dart and delegates presentation only', () async {
    final events = <String>[];
    final transport = _FakeExecutorFactory(events);
    final platform = _FakePlatform(events);
    final backend = VtkNativeBackend(
      executorFactory: transport,
      platform: platform,
    );
    final session = await backend.openSession();

    expect(session.viewId, 73);
    expect(platform.presentationApiAddress, 200);
    expect(platform.createdSessionAddresses, [100]);

    final image = await session.createImageData(
      input: VtkScalarImageInput(
        values: Uint8List(1),
        dimensions: VtkDimensions(x: 1, y: 1, z: 1),
      ),
    );
    final renderer = await session.createObject(type: .renderer);
    await session.invoke(
      target: renderer,
      operation: .addActor,
      arguments: [image],
    );
    final viewport = VtkViewport(width: 80, height: 40);
    final result = await session.renderLayout(
      layers: [
        VtkBackendRenderLayer(
          renderer: renderer,
          viewport: VtkNormalizedViewport.full,
        ),
      ],
      viewport: viewport,
      primaryLayer: 0,
    );

    expect(result.viewport, viewport);
    expect(platform.resizedTo, viewport);
    expect(platform.resizedSessionAddresses, [100]);
    expect(platform.presentCount, 1);
    expect(platform.presentedSessionAddresses, [100]);
    expect(transport.renderLayoutCount, 1);
    expect(transport.lastPrimaryLayer, 0);
    expect(transport.lastOperation, VtkBackendOperation.addActor);

    await session.close();

    expect(events.sublist(events.length - 2), [
      'platform.disposeView',
      'ffi.destroySession',
    ]);
  });

  test('routes two active presentation sessions independently', () async {
    final events = <String>[];
    final transport = _FakeExecutorFactory(events);
    final platform = _FakePlatform(events);
    final backend = VtkNativeBackend(
      executorFactory: transport,
      platform: platform,
    );
    final first = await backend.openSession();
    final second = await backend.openSession();

    expect(first.viewId, 73);
    expect(second.viewId, 74);

    final firstRenderer = await first.createObject(type: .renderer);
    await first.render(
      renderer: firstRenderer,
      viewport: VtkViewport(width: 80, height: 40),
    );
    await first.close();

    final secondRenderer = await second.createObject(type: .renderer);
    await second.render(
      renderer: secondRenderer,
      viewport: VtkViewport(width: 60, height: 30),
    );

    expect(platform.createdSessionAddresses, [100, 101]);
    expect(platform.resizedSessionAddresses, [100, 101]);
    expect(platform.presentedSessionAddresses, [100, 101]);
    expect(platform.disposedSessionAddresses, [100]);
    expect(transport.createdObjectSessionAddresses, [100, 101]);
    expect(transport.renderedSessionAddresses, [100, 101]);
    expect(transport.destroyedSessionAddresses, [100]);

    await backend.close();

    expect(platform.disposedSessionAddresses, [100, 101]);
    expect(transport.destroyedSessionAddresses, [100, 101]);
  });

  test(
    'routes concurrently opened sessions by their resolved address',
    () async {
      final events = <String>[];
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      final transport = _FakeExecutorFactory(events)
        ..createGates.addAll([firstGate.future, secondGate.future]);
      final platform = _FakePlatform(events);
      final backend = VtkNativeBackend(
        executorFactory: transport,
        platform: platform,
      );

      final firstOpen = backend.openSession();
      final secondOpen = backend.openSession();
      secondGate.complete();
      final second = await secondOpen;
      firstGate.complete();
      final first = await firstOpen;

      expect(first.viewId, 73);
      expect(second.viewId, 74);
      expect(platform.createdSessionAddresses, [101, 100]);

      final firstRenderer = await first.createObject(type: .renderer);
      final secondRenderer = await second.createObject(type: .renderer);
      await Future.wait([
        first.render(
          renderer: firstRenderer,
          viewport: VtkViewport(width: 80, height: 40),
        ),
        second.render(
          renderer: secondRenderer,
          viewport: VtkViewport(width: 60, height: 30),
        ),
      ]);

      expect(platform.presentedSessionAddresses, containsAll([100, 101]));
      await backend.close();
    },
  );

  test('isolates resize and presentation failures between sessions', () async {
    final events = <String>[];
    final transport = _FakeExecutorFactory(events);
    final platform = _FakePlatform(events)
      ..resizeFailuresRemaining[100] = 1
      ..presentFailuresRemaining[100] = 1;
    final backend = VtkNativeBackend(
      executorFactory: transport,
      platform: platform,
    );
    final first = await backend.openSession();
    final second = await backend.openSession();
    final firstRenderer = await first.createObject(type: .renderer);
    final secondRenderer = await second.createObject(type: .renderer);

    await expectLater(
      first.render(
        renderer: firstRenderer,
        viewport: VtkViewport(width: 80, height: 40),
      ),
      throwsStateError,
    );
    await second.render(
      renderer: secondRenderer,
      viewport: VtkViewport(width: 60, height: 30),
    );
    await expectLater(
      first.render(
        renderer: firstRenderer,
        viewport: VtkViewport(width: 80, height: 40),
      ),
      throwsStateError,
    );
    await first.render(
      renderer: firstRenderer,
      viewport: VtkViewport(width: 80, height: 40),
    );

    expect(platform.resizedSessionAddresses, [100, 101, 100]);
    expect(platform.presentedSessionAddresses, [101, 100, 100]);
    expect(transport.renderedSessionAddresses, [101, 100, 100]);
    await backend.close();
  });

  test(
    'rejects overlapping and active sessions for singular platform views',
    () async {
      final events = <String>[];
      final createGate = Completer<void>();
      final executorFactory = _FakeExecutorFactory(events)
        ..createGate = createGate;
      final platform = _FakePlatform(events)
        ..supportsIndependentSessionViews = false;
      final backend = VtkNativeBackend(
        executorFactory: executorFactory,
        platform: platform,
      );

      final firstOpen = backend.openSession();
      await expectLater(
        backend.openSession(),
        throwsA(isA<VtkApiStateException>()),
      );
      createGate.complete();
      final first = await firstOpen;

      await expectLater(
        backend.openSession(),
        throwsA(isA<VtkApiStateException>()),
      );
      expect(
        events.where((event) => event == 'ffi.createSession'),
        hasLength(1),
      );
      expect(platform.disposedSessionAddresses, isEmpty);
      await first.createObject(type: .actor);

      await first.close();
      final replacement = await backend.openSession();
      expect(platform.createdSessionAddresses, [100, 101]);
      await replacement.close();
      await backend.close();
    },
  );

  test(
    'keeps the session alive when presentation teardown must be retried',
    () async {
      final events = <String>[];
      final transport = _FakeExecutorFactory(events);
      final platform = _FakePlatform(events)..disposeFailuresRemaining = 1;
      final backend = VtkNativeBackend(
        executorFactory: transport,
        platform: platform,
      );
      final session = await backend.openSession();

      await expectLater(session.close(), throwsStateError);
      expect(events, isNot(contains('ffi.destroySession')));
      expect(
        () => session.createObject(type: .actor),
        throwsA(isA<VtkApiStateException>()),
      );
      final second = await backend.openSession();
      await second.createObject(type: .actor);
      await backend.close();

      expect(
        events.where((event) => event == 'platform.disposeView'),
        hasLength(3),
      );
      expect(
        events.where((event) => event == 'ffi.destroySession'),
        hasLength(2),
      );
    },
  );

  test('backend close attempts every active session before retrying', () async {
    final events = <String>[];
    final transport = _FakeExecutorFactory(events);
    final platform = _FakePlatform(events)..disposeFailuresRemaining = 1;
    final backend = VtkNativeBackend(
      executorFactory: transport,
      platform: platform,
    );
    final first = await backend.openSession();
    final second = await backend.openSession();

    await expectLater(backend.close(), throwsStateError);

    expect(platform.disposedSessionAddresses, [100, 101]);
    expect(transport.destroyedSessionAddresses, [101]);
    expect(
      () => first.createObject(type: .actor),
      throwsA(isA<VtkApiStateException>()),
    );
    expect(
      () => second.createObject(type: .actor),
      throwsA(isA<VtkApiStateException>()),
    );

    await backend.close();

    expect(platform.disposedSessionAddresses, [100, 101, 100]);
    expect(transport.destroyedSessionAddresses, [101, 100]);
  });

  test('backend close drains a session that is still opening', () async {
    final events = <String>[];
    final createGate = Completer<void>();
    final executorFactory = _FakeExecutorFactory(events)
      ..createGate = createGate;
    final platform = _FakePlatform(events);
    final backend = VtkNativeBackend(
      executorFactory: executorFactory,
      platform: platform,
    );

    final openExpectation = expectLater(
      backend.openSession(),
      throwsA(isA<VtkApiStateException>()),
    );
    final close = backend.close();
    createGate.complete();

    await openExpectation;
    await close;
    expect(platform.createdSessionAddresses, isEmpty);
    expect(platform.disposedSessionAddresses, [100]);
    expect(executorFactory.destroyedSessionAddresses, [100]);
  });

  test('retains failed view initialization for safe cleanup retry', () async {
    final events = <String>[];
    final transport = _FakeExecutorFactory(events);
    final platform = _FakePlatform(events)
      ..createFailuresRemaining = 1
      ..disposeFailuresRemaining = 1;
    final backend = VtkNativeBackend(
      executorFactory: transport,
      platform: platform,
    );

    await expectLater(
      backend.openSession(),
      throwsA(
        isA<VtkApiStateException>()
            .having(
              (error) => error.message,
              'message',
              contains('presentation creation failed'),
            )
            .having(
              (error) => error.message,
              'message',
              contains('presentation teardown failed'),
            ),
      ),
    );

    expect(events, isNot(contains('ffi.destroySession')));
    final second = await backend.openSession();

    await backend.close();
    expect(
      events.where((event) => event == 'platform.disposeView'),
      hasLength(3),
    );
    expect(
      events.where((event) => event == 'ffi.destroySession'),
      hasLength(2),
    );
    expect(second.viewId, 74);
  });

  test(
    'gates raw class and method strings behind the experimental import',
    () async {
      final events = <String>[];
      final runtime = createVtkRuntimeForBackend(
        VtkNativeBackend(
          executorFactory: _FakeExecutorFactory(events),
          platform: _FakePlatform(events),
        ),
      );
      final session = await runtime.openSession();

      final renderer = await session.dynamic.create('vtkRenderer');
      final result = await renderer.invoke('GetActiveCamera');

      expect(result, isA<VtkDynamicObject>());
      await (result! as VtkDynamicObject).dispose();
      await renderer.dispose();
      await runtime.close();
    },
  );
}

final class _FakeExecutorFactory implements VtkSessionExecutorFactory {
  _FakeExecutorFactory(this.events);

  final List<String> events;
  int _nextHandle = 1;
  int _nextSessionAddress = 100;
  VtkBackendOperation? lastOperation;
  int renderLayoutCount = 0;
  int? lastPrimaryLayer;
  final List<int> createdObjectSessionAddresses = [];
  final List<int> renderedSessionAddresses = [];
  final List<int> destroyedSessionAddresses = [];
  Completer<void>? createGate;
  final List<Future<void>> createGates = [];

  @override
  Future<VtkSessionExecutor> create() async {
    events.add('ffi.createSession');
    final address = _nextSessionAddress++;
    if (createGates.isNotEmpty) {
      await createGates.removeAt(0);
    } else {
      await createGate?.future;
    }
    return _FakeExecutor(owner: this, address: address);
  }
}

final class _FakeExecutor implements VtkSessionExecutor {
  _FakeExecutor({required this.owner, required this.address});

  final _FakeExecutorFactory owner;
  final int address;

  @override
  int get nativeSessionAddress => address;

  @override
  int get presentationApiAddress => 200;

  @override
  Future<VtkBackendObjectHandle> createImageData({
    required VtkScalarImageInput input,
  }) async => VtkBackendObjectHandle(owner._nextHandle++);

  @override
  Future<VtkBackendObjectHandle> createObject({
    required VtkObjectType type,
  }) async {
    owner.createdObjectSessionAddresses.add(address);
    return VtkBackendObjectHandle(owner._nextHandle++);
  }

  @override
  Future<VtkBackendObjectHandle> createDynamicObject({
    required String className,
  }) async => VtkBackendObjectHandle(owner._nextHandle++);

  @override
  Future<void> destroyObject({required VtkBackendObjectHandle object}) async {}

  @override
  Future<Object?> invoke({
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    required List<Object?> arguments,
  }) async {
    owner.lastOperation = operation;
    return null;
  }

  @override
  Future<Object?> invokeDynamic({
    required VtkBackendObjectHandle target,
    required String methodName,
    required List<Object?> arguments,
  }) async => VtkBackendObjectHandle(owner._nextHandle++);

  @override
  Future<VtkRenderResult> renderLayout({
    required List<VtkBackendRenderLayer> layers,
    required VtkViewport viewport,
    required int primaryLayer,
  }) async {
    owner.renderLayoutCount++;
    owner.lastPrimaryLayer = primaryLayer;
    owner.renderedSessionAddresses.add(address);
    return VtkRenderResult(
      viewport: viewport,
      frameBytes: viewport.pixelCount * 4,
      surfaceAllocationBytes: viewport.pixelCount * 4,
      renderTime: const Duration(milliseconds: 1),
      surfaceSubmitTime: Duration.zero,
      gpuSyncWaitTime: Duration.zero,
      cpuReadbackTime: Duration.zero,
    );
  }

  @override
  Future<void> close() async {
    owner.destroyedSessionAddresses.add(address);
    owner.events.add('ffi.destroySession');
  }
}

final class _FakePlatform extends VtkFlutterPlatform {
  _FakePlatform(this.events);

  final List<String> events;
  int? presentationApiAddress;
  final List<int> createdSessionAddresses = [];
  final List<int> resizedSessionAddresses = [];
  final List<int> presentedSessionAddresses = [];
  final List<int> disposedSessionAddresses = [];
  VtkViewport? resizedTo;
  int presentCount = 0;
  int createFailuresRemaining = 0;
  int disposeFailuresRemaining = 0;
  final Map<int, int> resizeFailuresRemaining = {};
  final Map<int, int> presentFailuresRemaining = {};

  @override
  bool supportsIndependentSessionViews = true;

  @override
  Future<int> createView({
    required VtkViewport viewport,
    required int presentationApiAddress,
    required int nativeSessionAddress,
  }) async {
    events.add('platform.createView');
    this.presentationApiAddress = presentationApiAddress;
    createdSessionAddresses.add(nativeSessionAddress);
    if (createFailuresRemaining > 0) {
      createFailuresRemaining--;
      throw StateError('presentation creation failed');
    }
    return nativeSessionAddress - 27;
  }

  @override
  Future<void> disposeView({required int nativeSessionAddress}) async {
    events.add('platform.disposeView');
    disposedSessionAddresses.add(nativeSessionAddress);
    if (disposeFailuresRemaining > 0) {
      disposeFailuresRemaining--;
      throw StateError('presentation teardown failed');
    }
  }

  @override
  Future<void> presentFrame({required int nativeSessionAddress}) async {
    presentCount++;
    presentedSessionAddresses.add(nativeSessionAddress);
    final failuresRemaining =
        presentFailuresRemaining[nativeSessionAddress] ?? 0;
    if (failuresRemaining > 0) {
      presentFailuresRemaining[nativeSessionAddress] = failuresRemaining - 1;
      throw StateError('presentation failed');
    }
  }

  @override
  Future<void> resize({
    required int nativeSessionAddress,
    required VtkViewport viewport,
  }) async {
    resizedTo = viewport;
    resizedSessionAddresses.add(nativeSessionAddress);
    final failuresRemaining =
        resizeFailuresRemaining[nativeSessionAddress] ?? 0;
    if (failuresRemaining > 0) {
      resizeFailuresRemaining[nativeSessionAddress] = failuresRemaining - 1;
      throw StateError('resize failed');
    }
  }
}
