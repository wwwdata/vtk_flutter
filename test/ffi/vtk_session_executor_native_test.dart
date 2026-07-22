import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/src/api/vtk_api.dart';
import 'package:vtk_flutter/src/ffi/vtk_ffi_transport_base.dart';
import 'package:vtk_flutter/src/ffi/vtk_session_executor_native.dart';

void main() {
  test('keeps the root isolate responsive during a synchronous call', () async {
    final executor = await _createExecutor();
    var operationCompleted = false;

    final operation = executor.invokeDynamic(
      target: const VtkBackendObjectHandle(1),
      methodName: 'block',
      arguments: const [200],
    )..whenComplete(() => operationCompleted = true);

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(operationCompleted, isFalse);
    expect(await operation, 'complete');
    await executor.close();
  });

  test('does not serialize work from independent sessions', () async {
    final first = await _createExecutor();
    final second = await _createExecutor();

    final blocked = first.invokeDynamic(
      target: const VtkBackendObjectHandle(1),
      methodName: 'block',
      arguments: const [500],
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final independent = second.invokeDynamic(
      target: const VtkBackendObjectHandle(1),
      methodName: 'echo',
      arguments: const ['second'],
    );
    expect(
      await Future.any([
        blocked.then((_) => 'first'),
        independent.then((_) => 'second'),
      ]),
      'second',
    );
    expect(await independent, 'second');
    expect(await blocked, 'complete');

    await Future.wait([first.close(), second.close()]);
  });

  test('preserves request order within one session', () async {
    final executor = await _createExecutor();

    final first = executor.invokeDynamic(
      target: const VtkBackendObjectHandle(1),
      methodName: 'recordAfterDelay',
      arguments: const [1, 50],
    );
    final second = executor.invokeDynamic(
      target: const VtkBackendObjectHandle(1),
      methodName: 'record',
      arguments: const [2],
    );

    expect(await Future.wait([first, second]), [
      const [1],
      const [1, 2],
    ]);
    await executor.close();
  });

  test('propagates typed worker errors and continues processing', () async {
    final executor = await _createExecutor();

    await expectLater(
      executor.invokeDynamic(
        target: const VtkBackendObjectHandle(1),
        methodName: 'fail',
        arguments: const [],
      ),
      throwsA(
        isA<VtkApiStateException>().having(
          (error) => error.message,
          'message',
          'executor test failure',
        ),
      ),
    );
    expect(
      await executor.invokeDynamic(
        target: const VtkBackendObjectHandle(1),
        methodName: 'echo',
        arguments: const ['still alive'],
      ),
      'still alive',
    );

    await executor.close();
  });

  test('worker exit fails pending requests', () async {
    final executor = await _createExecutor();

    await expectLater(
      executor.invokeDynamic(
        target: const VtkBackendObjectHandle(1),
        methodName: 'exit',
        arguments: const [],
      ),
      throwsA(isA<VtkApiStateException>()),
    );
    await expectLater(
      executor.invokeDynamic(
        target: const VtkBackendObjectHandle(1),
        methodName: 'echo',
        arguments: const ['unreachable'],
      ),
      throwsA(isA<VtkApiStateException>()),
    );

    await executor.close();
    await executor.close();
  });

  test('close drains queued work and is idempotent', () async {
    final executor = await _createExecutor();
    final operation = executor.invokeDynamic(
      target: const VtkBackendObjectHandle(1),
      methodName: 'block',
      arguments: const [50],
    );

    final close = executor.close();
    expect(await operation, 'complete');
    await close;
    await executor.close();

    expect(
      () => executor.createObject(type: .actor),
      throwsA(isA<VtkApiStateException>()),
    );
  });

  test('reports startup cleanup failures instead of swallowing them', () async {
    await expectLater(
      _createExecutor(transportFactory: _createStartupCleanupFailureTransport),
      throwsA(
        isA<VtkApiStateException>().having(
          (error) => error.message,
          'message',
          allOf([
            contains('failed to clean up a session'),
            contains('presentation api unavailable'),
            contains('destroy failed'),
          ]),
        ),
      ),
    );
  });
}

Future<VtkIsolateSessionExecutor> _createExecutor({
  VtkFfiTransportFactory transportFactory = _createExecutorTestTransport,
}) => VtkIsolateSessionExecutor.spawn(transportFactory: transportFactory);

VtkFfiTransport _createExecutorTestTransport() => _ExecutorTestTransport();

VtkFfiTransport _createStartupCleanupFailureTransport() =>
    _StartupCleanupFailureTransport();

final class _ExecutorTestTransport implements VtkFfiTransport {
  final List<int> _order = [];

  @override
  int get presentationApiAddress => 200;

  @override
  int createSession() => Isolate.current.hashCode + 1;

  @override
  void destroySession(int sessionAddress) {}

  @override
  VtkBackendObjectHandle createImageData({
    required int sessionAddress,
    required VtkScalarImageInput input,
  }) => const VtkBackendObjectHandle(1);

  @override
  VtkBackendObjectHandle createObject({
    required int sessionAddress,
    required VtkObjectType type,
  }) => const VtkBackendObjectHandle(1);

  @override
  VtkBackendObjectHandle createDynamicObject({
    required int sessionAddress,
    required String className,
  }) => const VtkBackendObjectHandle(1);

  @override
  void destroyObject({
    required int sessionAddress,
    required VtkBackendObjectHandle object,
  }) {}

  @override
  Object? invoke({
    required int sessionAddress,
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    required List<Object?> arguments,
  }) => null;

  @override
  Object? invokeDynamic({
    required int sessionAddress,
    required VtkBackendObjectHandle target,
    required String methodName,
    required List<Object?> arguments,
  }) => switch (methodName) {
    'block' => _block(arguments.single as int),
    'echo' => arguments.single,
    'record' => _record(arguments.single as int),
    'recordAfterDelay' => _recordAfterDelay(
      value: arguments.first as int,
      milliseconds: arguments.last as int,
    ),
    'fail' => throw const VtkApiStateException('executor test failure'),
    'exit' => Isolate.exit(),
    _ => throw VtkApiStateException('Unknown test method $methodName'),
  };

  @override
  VtkRenderResult render({
    required int sessionAddress,
    required VtkBackendObjectHandle renderer,
    required VtkViewport viewport,
  }) => renderLayout(
    sessionAddress: sessionAddress,
    layers: [
      VtkBackendRenderLayer(
        renderer: renderer,
        viewport: VtkNormalizedViewport.full,
      ),
    ],
    viewport: viewport,
    primaryLayer: 0,
  );

  @override
  VtkRenderResult renderLayout({
    required int sessionAddress,
    required List<VtkBackendRenderLayer> layers,
    required VtkViewport viewport,
    required int primaryLayer,
  }) => VtkRenderResult(
    viewport: viewport,
    frameBytes: 0,
    surfaceAllocationBytes: 0,
    renderTime: Duration.zero,
    surfaceSubmitTime: Duration.zero,
    gpuSyncWaitTime: Duration.zero,
    cpuReadbackTime: Duration.zero,
  );

  String _block(int milliseconds) {
    sleep(Duration(milliseconds: milliseconds));
    return 'complete';
  }

  List<int> _record(int value) {
    _order.add(value);
    return [..._order];
  }

  List<int> _recordAfterDelay({required int value, required int milliseconds}) {
    sleep(Duration(milliseconds: milliseconds));
    return _record(value);
  }
}

final class _StartupCleanupFailureTransport implements VtkFfiTransport {
  @override
  int get presentationApiAddress =>
      throw const VtkApiStateException('presentation api unavailable');

  @override
  int createSession() => 41;

  @override
  void destroySession(int sessionAddress) {
    throw const VtkApiStateException('destroy failed');
  }

  @override
  VtkBackendObjectHandle createImageData({
    required int sessionAddress,
    required VtkScalarImageInput input,
  }) => throw UnimplementedError();

  @override
  VtkBackendObjectHandle createObject({
    required int sessionAddress,
    required VtkObjectType type,
  }) => throw UnimplementedError();

  @override
  VtkBackendObjectHandle createDynamicObject({
    required int sessionAddress,
    required String className,
  }) => throw UnimplementedError();

  @override
  void destroyObject({
    required int sessionAddress,
    required VtkBackendObjectHandle object,
  }) => throw UnimplementedError();

  @override
  Object? invoke({
    required int sessionAddress,
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    required List<Object?> arguments,
  }) => throw UnimplementedError();

  @override
  Object? invokeDynamic({
    required int sessionAddress,
    required VtkBackendObjectHandle target,
    required String methodName,
    required List<Object?> arguments,
  }) => throw UnimplementedError();

  @override
  VtkRenderResult render({
    required int sessionAddress,
    required VtkBackendObjectHandle renderer,
    required VtkViewport viewport,
  }) => throw UnimplementedError();

  @override
  VtkRenderResult renderLayout({
    required int sessionAddress,
    required List<VtkBackendRenderLayer> layers,
    required VtkViewport viewport,
    required int primaryLayer,
  }) => throw UnimplementedError();
}
