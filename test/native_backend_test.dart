import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/src/api/vtk_api.dart';
import 'package:vtk_flutter/src/ffi/vtk_ffi_transport_base.dart';
import 'package:vtk_flutter/src/native_backend.dart';
import 'package:vtk_flutter/src/vtk_flutter_platform_interface.dart';

void main() {
  test('keeps VTK ownership in Dart and delegates presentation only', () async {
    final events = <String>[];
    final transport = _FakeTransport(events);
    final platform = _FakePlatform(events);
    final backend = VtkNativeBackend(transport: transport, platform: platform);
    final session = await backend.openSession();

    expect(session.viewId, 73);
    expect(platform.presentationApiAddress, 200);
    expect(platform.nativeSessionAddress, 100);

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
    final result = await session.render(renderer: renderer, viewport: viewport);

    expect(result.viewport, viewport);
    expect(platform.resizedTo, viewport);
    expect(platform.presentCount, 1);
    expect(transport.lastOperation, VtkBackendOperation.addActor);

    await session.close();

    expect(events.sublist(events.length - 2), [
      'platform.disposeView',
      'ffi.destroySession',
    ]);
  });

  test('allows only one native presentation session at a time', () async {
    final events = <String>[];
    final backend = VtkNativeBackend(
      transport: _FakeTransport(events),
      platform: _FakePlatform(events),
    );
    final session = await backend.openSession();

    await expectLater(
      backend.openSession(),
      throwsA(isA<VtkApiStateException>()),
    );
    await session.close();
    final replacement = await backend.openSession();
    await replacement.close();
    await backend.close();
  });

  test(
    'keeps the session alive when presentation teardown must be retried',
    () async {
      final events = <String>[];
      final transport = _FakeTransport(events);
      final platform = _FakePlatform(events)..disposeFailuresRemaining = 1;
      final backend = VtkNativeBackend(
        transport: transport,
        platform: platform,
      );
      final session = await backend.openSession();

      await expectLater(session.close(), throwsStateError);
      expect(events, isNot(contains('ffi.destroySession')));
      expect(
        () => session.createObject(type: .actor),
        throwsA(isA<VtkApiStateException>()),
      );
      await expectLater(
        backend.openSession(),
        throwsA(isA<VtkApiStateException>()),
      );

      await session.close();

      expect(
        events.where((event) => event == 'platform.disposeView'),
        hasLength(2),
      );
      expect(
        events.where((event) => event == 'ffi.destroySession'),
        hasLength(1),
      );
      final replacement = await backend.openSession();
      await replacement.close();
      await backend.close();
    },
  );

  test('retains failed view initialization for safe cleanup retry', () async {
    final events = <String>[];
    final transport = _FakeTransport(events);
    final platform = _FakePlatform(events)
      ..createFailuresRemaining = 1
      ..disposeFailuresRemaining = 1;
    final backend = VtkNativeBackend(transport: transport, platform: platform);

    await expectLater(backend.openSession(), throwsStateError);

    expect(events, isNot(contains('ffi.destroySession')));
    await expectLater(
      backend.openSession(),
      throwsA(isA<VtkApiStateException>()),
    );

    await backend.close();
    expect(
      events.where((event) => event == 'platform.disposeView'),
      hasLength(2),
    );
    expect(
      events.where((event) => event == 'ffi.destroySession'),
      hasLength(1),
    );
  });

  test(
    'gates raw class and method strings behind the experimental import',
    () async {
      final events = <String>[];
      final runtime = createVtkRuntimeForBackend(
        VtkNativeBackend(
          transport: _FakeTransport(events),
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

final class _FakeTransport implements VtkFfiTransport {
  _FakeTransport(this.events);

  final List<String> events;
  int _nextHandle = 1;
  VtkBackendOperation? lastOperation;

  @override
  int get presentationApiAddress => 200;

  @override
  Future<int> createSession() async {
    events.add('ffi.createSession');
    return 100;
  }

  @override
  Future<void> destroySession(int sessionAddress) async {
    expect(sessionAddress, 100);
    events.add('ffi.destroySession');
  }

  @override
  Future<VtkBackendObjectHandle> createImageData({
    required int sessionAddress,
    required VtkScalarImageInput input,
  }) async => VtkBackendObjectHandle(_nextHandle++);

  @override
  Future<VtkBackendObjectHandle> createObject({
    required int sessionAddress,
    required VtkObjectType type,
  }) async => VtkBackendObjectHandle(_nextHandle++);

  @override
  Future<VtkBackendObjectHandle> createDynamicObject({
    required int sessionAddress,
    required String className,
  }) async => VtkBackendObjectHandle(_nextHandle++);

  @override
  Future<void> destroyObject({
    required int sessionAddress,
    required VtkBackendObjectHandle object,
  }) async {}

  @override
  Future<Object?> invoke({
    required int sessionAddress,
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    required List<Object?> arguments,
  }) async {
    lastOperation = operation;
    return null;
  }

  @override
  Future<Object?> invokeDynamic({
    required int sessionAddress,
    required VtkBackendObjectHandle target,
    required String methodName,
    required List<Object?> arguments,
  }) async => VtkBackendObjectHandle(_nextHandle++);

  @override
  Future<VtkRenderResult> render({
    required int sessionAddress,
    required VtkBackendObjectHandle renderer,
    required VtkViewport viewport,
  }) async => VtkRenderResult(
    viewport: viewport,
    frameBytes: viewport.pixelCount * 4,
    surfaceAllocationBytes: viewport.pixelCount * 4,
    renderTime: const Duration(milliseconds: 1),
    surfaceSubmitTime: Duration.zero,
    gpuSyncWaitTime: Duration.zero,
    cpuReadbackTime: Duration.zero,
  );
}

final class _FakePlatform extends VtkFlutterPlatform {
  _FakePlatform(this.events);

  final List<String> events;
  int? presentationApiAddress;
  int? nativeSessionAddress;
  VtkViewport? resizedTo;
  int presentCount = 0;
  int createFailuresRemaining = 0;
  int disposeFailuresRemaining = 0;

  @override
  Future<int> createView({
    required VtkViewport viewport,
    required int presentationApiAddress,
    required int nativeSessionAddress,
  }) async {
    events.add('platform.createView');
    this.presentationApiAddress = presentationApiAddress;
    this.nativeSessionAddress = nativeSessionAddress;
    if (createFailuresRemaining > 0) {
      createFailuresRemaining--;
      throw StateError('presentation creation failed');
    }
    return 73;
  }

  @override
  Future<void> disposeView() async {
    events.add('platform.disposeView');
    if (disposeFailuresRemaining > 0) {
      disposeFailuresRemaining--;
      throw StateError('presentation teardown failed');
    }
  }

  @override
  Future<void> presentFrame() async {
    presentCount++;
  }

  @override
  Future<void> resize(VtkViewport viewport) async {
    resizedTo = viewport;
  }
}
