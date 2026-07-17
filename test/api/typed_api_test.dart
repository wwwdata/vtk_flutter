import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/src/api/vtk_api.dart';

void main() {
  group('values', () {
    test('validates and deep-copies typed scalar image input', () {
      final values = Int16List.fromList(List.generate(8, (index) => index));
      final input = VtkScalarImageInput(
        values: values,
        dimensions: VtkDimensions(x: 2, y: 2, z: 2),
      );

      values[0] = 99;

      expect(input.scalarType, VtkScalarType.int16);
      expect(input.valueCount, 8);
      expect(input.byteCount, 16);
      expect(input.bytes, isNot(equals(values.buffer.asUint8List())));
      expect(input.origin, VtkVector3.zero());
      expect(input.spacing, VtkVector3.one());
      expect(input.direction, VtkMatrix3.identity());
    });

    test('rejects invalid dimensions, matrices, buffers, and viewports', () {
      expect(
        () => VtkDimensions(x: 0, y: 1, z: 1),
        throwsA(isA<VtkApiValidationException>()),
      );
      expect(
        () => VtkMatrix4(values: const [1, 0]),
        throwsA(isA<VtkApiValidationException>()),
      );
      expect(
        () => VtkScalarImageInput(
          values: Int16List(1),
          dimensions: VtkDimensions(x: 2, y: 1, z: 1),
        ),
        throwsA(isA<VtkApiValidationException>()),
      );
      expect(
        () => VtkViewport(width: 0, height: 1),
        throwsA(isA<VtkApiValidationException>()),
      );
    });
  });

  group('typed wrappers', () {
    late _FakeBackend backend;
    late VtkRuntime runtime;
    late VtkSession session;

    setUp(() async {
      backend = _FakeBackend();
      runtime = createVtkRuntimeForBackend(backend);
      session = await runtime.openSession();
    });

    tearDown(() async {
      await runtime.close();
    });

    test('builds a surface pipeline without raw method strings', () async {
      final backendSession = backend.sessions.single;
      final image = await session.createImageData(
        VtkScalarImageInput(
          values: Int16List(8),
          dimensions: VtkDimensions(x: 2, y: 2, z: 2),
        ),
      );
      final contour = await session.createFlyingEdges3D();
      await contour.setInputData(image);
      await contour.setValue(index: 0, value: 12);
      final output = await contour.output();
      final mapper = await session.createPolyDataMapper();
      await mapper.setInputConnection(input: output);
      await mapper.setScalarVisibility(false);
      final actor = await session.createActor();
      await actor.setMapper(mapper);
      final renderer = await session.createRenderer();
      await renderer.addActor(actor);
      await renderer.setBackground(
        VtkColor(red: 0.05, green: 0.08, blue: 0.12),
      );
      await renderer.resetCamera();

      final viewport = VtkViewport(width: 96, height: 64);
      final result = await session.render(
        renderer: renderer,
        viewport: viewport,
      );

      expect(result.viewport, viewport);
      expect(
        backendSession.createdTypes,
        containsAllInOrder([
          VtkObjectType.imageData,
          VtkObjectType.flyingEdges3D,
          VtkObjectType.polyDataMapper,
          VtkObjectType.actor,
          VtkObjectType.renderer,
        ]),
      );
      expect(
        backendSession.calls.map((call) => call.operation),
        containsAllInOrder([
          VtkBackendOperation.setInputData,
          VtkBackendOperation.setIsoValue,
          VtkBackendOperation.getOutputPort,
          VtkBackendOperation.setInputConnection,
          VtkBackendOperation.setScalarVisibility,
          VtkBackendOperation.setMapper,
          VtkBackendOperation.addActor,
          VtkBackendOperation.setBackground,
          VtkBackendOperation.resetCamera,
        ]),
      );
      expect(
        backendSession.calls
            .expand((call) => call.arguments)
            .whereType<String>(),
        isEmpty,
      );
    });

    test('covers the curated image and volume wrappers', () async {
      final image = await session.createImageData(
        VtkScalarImageInput(
          values: Uint8List(1),
          dimensions: VtkDimensions(x: 1, y: 1, z: 1),
        ),
      );
      final reslice = await session.createImageReslice();
      await reslice.setInputData(image);
      await reslice.setResliceAxes(VtkMatrix4.identity());
      await reslice.setOutputDimensionality(2);
      await reslice.setInterpolation(VtkInterpolation.linear);
      final resliceOutput = await reslice.output();

      final window = await session.createImageMapToWindowLevelColors();
      await window.setInputConnection(input: resliceOutput);
      await window.setWindow(400);
      await window.setLevel(40);
      final windowOutput = await window.output();

      final imageMapper = await session.createImageSliceMapper();
      await imageMapper.setInputConnection(input: windowOutput);
      final imageProperty = await session.createImageProperty();
      await imageProperty.setInterpolation(VtkInterpolation.linear);
      final imageActor = await session.createImageActor();
      await imageActor.setMapper(imageMapper);
      await imageActor.setProperty(imageProperty);

      final volumeMapper = await session.createSmartVolumeMapper();
      await volumeMapper.setInputData(image);
      await volumeMapper.setBlendMode(VtkVolumeBlendMode.composite);
      final colors = await session.createColorTransferFunction();
      await colors.addPoint(
        value: 40,
        color: VtkColor(red: 1, green: 0.5, blue: 0.2),
      );
      final opacity = await session.createPiecewiseFunction();
      await opacity.addPoint(value: 40, opacity: 0.5);
      final volumeProperty = await session.createVolumeProperty();
      await volumeProperty.setColor(colors);
      await volumeProperty.setScalarOpacity(opacity);
      await volumeProperty.setShade(true);
      final volume = await session.createVolume();
      await volume.setMapper(volumeMapper);
      await volume.setProperty(volumeProperty);

      final renderer = await session.createRenderer();
      final camera = await session.createCamera();
      await camera.setPosition(VtkVector3(x: 1, y: 2, z: 3));
      await camera.setFocalPoint(VtkVector3.zero());
      await camera.setViewUp(VtkVector3(x: 0, y: 1, z: 0));
      await renderer.setActiveCamera(camera);
      await renderer.addActor(imageActor);
      await renderer.addVolume(volume);

      final calls = backend.sessions.single.calls;
      expect(_singleCall(calls, .setResliceAxes).arguments, [
        VtkMatrix4.identity(),
      ]);
      expect(_singleCall(calls, .setVolumeBlendMode).arguments, const [
        VtkVolumeBlendMode.composite,
      ]);
      expect(_singleCall(calls, .addRgbPoint).arguments, const [
        40.0,
        1.0,
        0.5,
        0.2,
      ]);
      expect(_singleCall(calls, .addOpacityPoint).arguments, const [40.0, 0.5]);
      expect(_singleCall(calls, .setShade).arguments, const [true]);
      expect(_singleCall(calls, .setPosition).arguments, const [1.0, 2.0, 3.0]);
      expect(_singleCall(calls, .setViewUp).arguments, const [0.0, 1.0, 0.0]);
    });

    test('covers connectivity, smoothing, and property wrappers', () async {
      final image = await session.createImageData(
        VtkScalarImageInput(
          values: Uint8List(1),
          dimensions: VtkDimensions(x: 1, y: 1, z: 1),
        ),
      );
      final contour = await session.createFlyingEdges3D();
      await contour.setInputData(image);
      final contourOutput = await contour.output();
      final connectivity = await session.createPolyDataConnectivityFilter();
      await connectivity.setInputConnection(input: contourOutput);
      await connectivity.setMode(VtkConnectivityMode.largestRegion);
      final connectedOutput = await connectivity.output();
      final smoothing = await session.createWindowedSincPolyDataFilter();
      await smoothing.setInputConnection(input: connectedOutput);
      await smoothing.setNumberOfIterations(12);
      await smoothing.setPassBand(0.1);
      final smoothOutput = await smoothing.output();
      final mapper = await session.createPolyDataMapper();
      await mapper.setInputConnection(input: smoothOutput);
      final property = await session.createProperty();
      await property.setColor(VtkColor(red: 0.8, green: 0.7, blue: 0.6));
      await property.setOpacity(0.75);
      await property.setRepresentation(VtkRepresentation.surface);
      final actor = await session.createActor();
      await actor.setMapper(mapper);
      await actor.setProperty(property);

      final calls = backend.sessions.single.calls;
      expect(_singleCall(calls, .setConnectivityMode).arguments, const [
        VtkConnectivityMode.largestRegion,
      ]);
      expect(_singleCall(calls, .setNumberOfIterations).arguments, const [12]);
      expect(_singleCall(calls, .setPassBand).arguments, const [0.1]);
      expect(_singleCall(calls, .setColor).arguments, const [0.8, 0.7, 0.6]);
      expect(_singleCall(calls, .setRepresentation).arguments, const [
        VtkRepresentation.surface,
      ]);
    });
  });

  group('lifecycle and capabilities', () {
    test('rejects unsupported objects and oversized images locally', () async {
      final backend = _FakeBackend(
        capabilities: VtkCapabilities(
          supportedObjectTypes: const {VtkObjectType.imageData},
          supportedScalarTypes: const {VtkScalarType.uint8},
          maxImageBytes: 1,
          supportsRendering: false,
        ),
      );
      final runtime = createVtkRuntimeForBackend(backend);
      final session = await runtime.openSession();

      await expectLater(
        session.createRenderer(),
        throwsA(isA<VtkUnsupportedCapabilityException>()),
      );
      await expectLater(
        session.createImageData(
          VtkScalarImageInput(
            values: Uint8List(2),
            dimensions: VtkDimensions(x: 2, y: 1, z: 1),
          ),
        ),
        throwsA(isA<VtkApiValidationException>()),
      );

      expect(backend.sessions.single.createdTypes, isEmpty);
      await runtime.close();
    });

    test('prevents cross-session connections', () async {
      final backend = _FakeBackend();
      final runtime = createVtkRuntimeForBackend(backend);
      final first = await runtime.openSession();
      final second = await runtime.openSession();
      final actor = await first.createActor();
      final mapper = await second.createPolyDataMapper();

      await expectLater(
        actor.setMapper(mapper),
        throwsA(isA<VtkApiStateException>()),
      );

      await runtime.close();
    });

    test('reuses a wrapper when VTK returns the same object handle', () async {
      final backend = _FakeBackend();
      final runtime = createVtkRuntimeForBackend(backend);
      final session = await runtime.openSession();
      final algorithm = await session.createFlyingEdges3D();

      final first = await algorithm.output();
      final second = await algorithm.output();

      expect(identical(first, second), isTrue);
      await first.dispose();
      expect(second.isDisposed, isTrue);
      expect(
        backend.sessions.single.destroyed.where(
          (handle) => handle == const VtkBackendObjectHandle(2),
        ),
        hasLength(1),
      );
      await runtime.close();
    });

    test(
      'keeps dynamic objects session-scoped and closes them in reverse',
      () async {
        final backend = _FakeBackend();
        final runtime = createVtkRuntimeForBackend(backend);
        final first = await runtime.openSession();
        final second = await runtime.openSession();
        final firstObject = await first.dynamic.create('vtkActor');
        final secondObject = await second.dynamic.create('vtkProperty');

        await expectLater(
          firstObject.invoke('SetProperty', [secondObject]),
          throwsA(isA<VtkApiStateException>()),
        );

        final child =
            await firstObject.invoke('GetProperty') as VtkDynamicObject;
        await first.close();

        expect(firstObject.isDisposed, isTrue);
        expect(child.isDisposed, isTrue);
        expect(backend.sessions.first.destroyed, const [
          VtkBackendObjectHandle(2),
          VtkBackendObjectHandle(1),
        ]);
        expect(secondObject.isDisposed, isFalse);

        await runtime.close();
        expect(secondObject.isDisposed, isTrue);
      },
    );

    test(
      'disposes objects once and closes remaining objects in reverse',
      () async {
        final backend = _FakeBackend();
        final runtime = createVtkRuntimeForBackend(backend);
        final session = await runtime.openSession();
        final backendSession = backend.sessions.single;
        final first = await session.createActor();
        final second = await session.createProperty();
        final third = await session.createRenderer();

        await second.dispose();
        await second.dispose();
        await session.close();
        await session.close();

        expect(backendSession.destroyed, const [
          VtkBackendObjectHandle(2),
          VtkBackendObjectHandle(3),
          VtkBackendObjectHandle(1),
        ]);
        expect(backendSession.closeCount, 1);
        expect(first.isDisposed, isTrue);
        expect(second.isDisposed, isTrue);
        expect(third.isDisposed, isTrue);
        await runtime.close();
      },
    );

    test('drains an accepted operation before closing', () async {
      final backend = _FakeBackend();
      final runtime = createVtkRuntimeForBackend(backend);
      final session = await runtime.openSession();
      final backendSession = backend.sessions.single;
      final property = await session.createProperty();
      backendSession.invokeGate = Completer<void>();

      final update = property.setOpacity(0.5);
      final close = session.close();
      await Future<void>.delayed(Duration.zero);

      expect(backendSession.closeCount, 0);
      backendSession.invokeGate?.complete();
      await update;
      await close;
      expect(backendSession.closeCount, 1);
      await runtime.close();
    });

    test('fails closed while retrying backend session teardown', () async {
      final backend = _FakeBackend();
      final runtime = createVtkRuntimeForBackend(backend);
      final session = await runtime.openSession();
      final backendSession = backend.sessions.single
        ..closeFailuresRemaining = 1;
      final property = await session.createProperty();

      await expectLater(session.close(), throwsStateError);

      expect(session.isClosed, isTrue);
      expect(property.isDisposed, isTrue);
      await expectLater(
        session.createActor(),
        throwsA(isA<VtkApiStateException>()),
      );

      await session.close();
      expect(backendSession.closeCount, 2);
      await runtime.close();
    });

    test('fails closed while retrying runtime backend teardown', () async {
      final backend = _FakeBackend()..closeFailuresRemaining = 1;
      final runtime = createVtkRuntimeForBackend(backend);

      await expectLater(runtime.close(), throwsStateError);

      expect(runtime.isClosed, isTrue);
      expect(runtime.capabilities, throwsA(isA<VtkApiStateException>()));
      await runtime.close();
      expect(backend.closeCount, 2);
    });

    test('rejects object and session operations after disposal', () async {
      final backend = _FakeBackend();
      final runtime = createVtkRuntimeForBackend(backend);
      final session = await runtime.openSession();
      final property = await session.createProperty();
      await property.dispose();

      await expectLater(
        property.setOpacity(0.5),
        throwsA(isA<VtkApiStateException>()),
      );
      await session.close();
      await expectLater(
        session.createActor(),
        throwsA(isA<VtkApiStateException>()),
      );
      await runtime.close();
    });
  });
}

final class _FakeBackend implements VtkBackend {
  _FakeBackend({VtkCapabilities? capabilities})
    : _capabilities =
          capabilities ??
          VtkCapabilities(
            supportedObjectTypes: VtkObjectType.values.toSet(),
            supportedScalarTypes: VtkScalarType.values.toSet(),
            maxImageBytes: vtkMaximumImageBytes,
            supportsRendering: true,
          );

  final VtkCapabilities _capabilities;
  final sessions = <_FakeBackendSession>[];
  int closeCount = 0;
  int closeFailuresRemaining = 0;

  @override
  Future<VtkCapabilities> capabilities() async => _capabilities;

  @override
  Future<VtkBackendSession> openSession() async {
    final session = _FakeBackendSession();
    sessions.add(session);
    return session;
  }

  @override
  Future<void> close() async {
    closeCount++;
    if (closeFailuresRemaining > 0) {
      closeFailuresRemaining--;
      throw StateError('backend teardown failed');
    }
  }
}

final class _FakeBackendSession
    implements VtkBackendSession, VtkDynamicBackendSession {
  @override
  final int viewId = 1;

  final createdTypes = <VtkObjectType>[];
  final calls = <_FakeCall>[];
  final destroyed = <VtkBackendObjectHandle>[];
  int closeCount = 0;
  int closeFailuresRemaining = 0;
  int _nextHandle = 1;
  Completer<void>? invokeGate;
  final _outputHandles = <VtkBackendObjectHandle, VtkBackendObjectHandle>{};

  @override
  Future<VtkBackendObjectHandle> createImageData({
    required VtkScalarImageInput input,
  }) async {
    createdTypes.add(VtkObjectType.imageData);
    return _newHandle();
  }

  @override
  Future<VtkBackendObjectHandle> createObject({
    required VtkObjectType type,
  }) async {
    createdTypes.add(type);
    return _newHandle();
  }

  @override
  Future<VtkBackendObjectHandle> createDynamicObject({
    required String className,
  }) async => _newHandle();

  @override
  Future<Object?> invoke({
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    List<Object?> arguments = const [],
  }) async {
    calls.add(
      _FakeCall(
        target: target,
        operation: operation,
        arguments: List.unmodifiable(arguments),
      ),
    );
    final gate = invokeGate;
    if (gate != null) {
      await gate.future;
      invokeGate = null;
    }
    if (operation == VtkBackendOperation.getOutputPort) {
      return _outputHandles.putIfAbsent(target, _newHandle);
    }
    return null;
  }

  @override
  Future<Object?> invokeDynamic({
    required VtkBackendObjectHandle target,
    required String methodName,
    List<Object?> arguments = const [],
  }) async {
    if (methodName.startsWith('Get')) return _newHandle();
    return null;
  }

  @override
  Future<void> destroyObject({required VtkBackendObjectHandle object}) async {
    destroyed.add(object);
  }

  @override
  Future<VtkRenderResult> render({
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
    worldToClip: VtkMatrix4.identity(),
  );

  @override
  Future<void> close() async {
    closeCount++;
    if (closeFailuresRemaining > 0) {
      closeFailuresRemaining--;
      throw StateError('backend session teardown failed');
    }
  }

  VtkBackendObjectHandle _newHandle() => VtkBackendObjectHandle(_nextHandle++);
}

final class _FakeCall {
  const _FakeCall({
    required this.target,
    required this.operation,
    required this.arguments,
  });

  final VtkBackendObjectHandle target;
  final VtkBackendOperation operation;
  final List<Object?> arguments;
}

_FakeCall _singleCall(List<_FakeCall> calls, VtkBackendOperation operation) =>
    calls.singleWhere((call) => call.operation == operation);
