import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/src/api/vtk_api.dart';
import 'package:vtk_flutter/src/web/vtk_web_backend.dart';
import 'package:vtk_flutter/src/web/vtk_web_frame_store.dart';
import 'package:vtk_flutter/src/web/vtk_web_module.dart';

void main() {
  late _FakeWebModule module;
  late VtkWebBackend backend;

  setUp(() {
    module = _FakeWebModule();
    backend = VtkWebBackend(module: module);
  });

  tearDown(() => backend.close());

  test('reports the module whitelist and capability limitations', () async {
    final capabilities = await backend.capabilities();

    expect(
      capabilities.supportedObjectTypes,
      containsAll(const {
        VtkObjectType.imageData,
        VtkObjectType.flyingEdges3D,
        VtkObjectType.polyDataConnectivityFilter,
        VtkObjectType.renderer,
      }),
    );
    expect(
      capabilities.supportedObjectTypes,
      isNot(contains(VtkObjectType.imageMapToWindowLevelColors)),
    );
    expect(capabilities.supportedScalarTypes, VtkScalarType.values.toSet());
    expect(capabilities.maxImageBytes, vtkMaximumImageBytes);
    expect(capabilities.supportsRendering, isTrue);
    expect(
      await backend.capabilityLimitations(),
      containsPair('flyingEdges3D', contains('ImageMarchingCubes')),
    );
  });

  test(
    'maps typed objects, image data, and operations to strict wire names',
    () async {
      final session = await backend.openSession();
      final image = await session.createImageData(
        input: VtkScalarImageInput(
          values: Int16List(8),
          dimensions: VtkDimensions(x: 2, y: 2, z: 2),
        ),
      );
      final contour = await session.createObject(type: .flyingEdges3D);
      await session.invoke(
        target: contour,
        operation: .setInputData,
        arguments: [image],
      );
      await session.invoke(
        target: contour,
        operation: .setIsoValue,
        arguments: const [0, 12.5],
      );
      final output = await session.invoke(
        target: contour,
        operation: .getOutputPort,
        arguments: const [0],
      );

      expect(session.viewId, module.sessionId);
      expect(module.createdTypes, ['flyingEdges3D']);
      expect(module.images.single.scalarType, 'int16');
      expect(module.images.single.dimensions, [2, 2, 2]);
      expect(module.invocations.map((invocation) => invocation.operation), [
        'setInputData',
        'setIsoValue',
        'getOutputPort',
      ]);
      expect(module.invocations[0].arguments, [image.value]);
      expect(module.invocations[1].arguments, [0, 12.5]);
      expect(module.invocations[2].arguments, [0]);
      expect(output, const VtkBackendObjectHandle(99));
    },
  );

  test(
    'publishes rendered PNG bytes under the backend session view id',
    () async {
      final session = await backend.openSession();
      final renderer = await session.createObject(type: .renderer);
      final listenable = VtkWebFrameStore.frameFor(session.viewId);
      final result = await session.render(
        renderer: renderer,
        viewport: VtkViewport(width: 3, height: 2),
      );

      expect(listenable.value?.pngBytes, module.pngBytes);
      expect(listenable.value?.viewport, VtkViewport(width: 3, height: 2));
      expect(result.frameBytes, module.pngBytes.length);
      expect(result.surfaceAllocationBytes, 24);
      expect(result.renderTime, const Duration(microseconds: 1200));
      expect(result.cpuReadbackTime, const Duration(microseconds: 300));
      expect(result.worldToClip, VtkMatrix4.identity());
      expect(module.layoutRequests, hasLength(1));
      expect(module.layoutRequests.single.layers, hasLength(1));
      expect(
        module.layoutRequests.single.layers.single.renderer,
        renderer.value,
      );
      expect(module.layoutRequests.single.layers.single.left, 0);
      expect(module.layoutRequests.single.layers.single.bottom, 0);
      expect(module.layoutRequests.single.layers.single.right, 1);
      expect(module.layoutRequests.single.layers.single.top, 1);
      expect(module.layoutRequests.single.primaryLayer, 0);

      await session.close();
      expect(
        () => VtkWebFrameStore.frameFor(session.viewId),
        throwsA(isA<VtkApiStateException>()),
      );
    },
  );

  test('maps and publishes an atomic multi-renderer layout once', () async {
    final session = await backend.openSession();
    final first = await session.createObject(type: .renderer);
    final second = await session.createObject(type: .renderer);
    final viewport = VtkViewport(width: 800, height: 600);

    final result = await session.renderLayout(
      layers: [
        VtkBackendRenderLayer(
          renderer: first,
          viewport: VtkNormalizedViewport(
            left: 0,
            bottom: 0,
            right: 0.5,
            top: 1,
          ),
        ),
        VtkBackendRenderLayer(
          renderer: second,
          viewport: VtkNormalizedViewport(
            left: 0.5,
            bottom: 0,
            right: 1,
            top: 1,
          ),
        ),
      ],
      viewport: viewport,
      primaryLayer: 1,
    );

    final request = module.layoutRequests.single;
    expect(request.width, 800);
    expect(request.height, 600);
    expect(request.primaryLayer, 1);
    expect(request.layers.map((layer) => layer.renderer), [
      first.value,
      second.value,
    ]);
    expect(request.layers.map((layer) => layer.left), [0, 0.5]);
    expect(request.layers.map((layer) => layer.right), [0.5, 1]);
    expect(
      VtkWebFrameStore.frameFor(session.viewId).value?.pngBytes,
      module.pngBytes,
    );
    expect(result.viewport, viewport);
  });

  test('keeps the last presented frame when a layout render fails', () async {
    final session = await backend.openSession();
    final renderer = await session.createObject(type: .renderer);
    final viewport = VtkViewport(width: 3, height: 2);
    final listenable = VtkWebFrameStore.frameFor(session.viewId);

    await session.render(renderer: renderer, viewport: viewport);
    final presented = listenable.value;
    module.renderError = StateError('injected layout failure');

    await expectLater(
      session.render(renderer: renderer, viewport: viewport),
      throwsA(isA<VtkApiStateException>()),
    );
    expect(listenable.value, same(presented));
  });

  test('validates render metadata before presenting a web frame', () async {
    final session = await backend.openSession();
    final renderer = await session.createObject(type: .renderer);
    final viewport = VtkViewport(width: 3, height: 2);
    final listenable = VtkWebFrameStore.frameFor(session.viewId);

    await session.render(renderer: renderer, viewport: viewport);
    final presented = listenable.value;
    module.renderFrame = VtkWebRenderFrame(
      pngDataUrl: 'data:image/png;base64,${base64Encode(module.pngBytes)}',
      width: viewport.width,
      height: viewport.height,
      renderMicroseconds: 1,
      captureMicroseconds: 1,
      worldToClip: const [1],
    );

    await expectLater(
      session.render(renderer: renderer, viewport: viewport),
      throwsA(isA<VtkApiValidationException>()),
    );
    expect(listenable.value, same(presented));
  });

  test(
    'maps every stable backend operation without raw method strings',
    () async {
      final session = await backend.openSession();
      const target = VtkBackendObjectHandle(1);

      for (final operation in VtkBackendOperation.values) {
        await session.invoke(target: target, operation: operation);
      }

      expect(
        module.invocations.map((invocation) => invocation.operation).toSet(),
        {for (final operation in VtkBackendOperation.values) operation.name},
      );
    },
  );

  test('encodes nontrivial typed arguments for the vtk.js wire API', () async {
    final session = await backend.openSession();
    const target = VtkBackendObjectHandle(1);

    await session.invoke(
      target: target,
      operation: .setResliceAxes,
      arguments: [VtkMatrix4.identity()],
    );
    await session.invoke(
      target: target,
      operation: .setResliceInterpolation,
      arguments: const [VtkInterpolation.cubic],
    );
    await session.invoke(
      target: target,
      operation: .setVolumeBlendMode,
      arguments: const [VtkVolumeBlendMode.maximumIntensity],
    );
    await session.invoke(
      target: target,
      operation: .setConnectivityMode,
      arguments: const [VtkConnectivityMode.closestPointRegion],
    );
    await session.invoke(
      target: target,
      operation: .setRepresentation,
      arguments: const [VtkRepresentation.wireframe],
    );
    await session.invoke(
      target: target,
      operation: .setInputConnection,
      arguments: const [0, VtkBackendObjectHandle(91)],
    );

    expect(module.invocations[0].arguments, [VtkMatrix4.identity().values]);
    expect(module.invocations[1].arguments, const ['cubic']);
    expect(module.invocations[2].arguments, const ['maximumIntensity']);
    expect(module.invocations[3].arguments, const ['closestPointRegion']);
    expect(module.invocations[4].arguments, const ['wireframe']);
    expect(module.invocations[5].arguments, const [0, 91]);
  });

  test(
    'rejects malformed frames, dimension drift, and live handle reuse',
    () async {
      final session = await backend.openSession();
      final renderer = await session.createObject(type: .renderer);
      final viewport = VtkViewport(width: 3, height: 2);

      module.renderFrame = VtkWebRenderFrame(
        pngDataUrl: 'data:text/plain;base64,ZmFpbA==',
        width: 3,
        height: 2,
        renderMicroseconds: 1,
        captureMicroseconds: 1,
        worldToClip: VtkMatrix4.identity().values,
      );
      await expectLater(
        session.render(renderer: renderer, viewport: viewport),
        throwsA(isA<VtkApiStateException>()),
      );

      module.renderFrame = VtkWebRenderFrame(
        pngDataUrl: 'data:image/png;base64,${base64Encode(module.pngBytes)}',
        width: 4,
        height: 2,
        renderMicroseconds: 1,
        captureMicroseconds: 1,
        worldToClip: VtkMatrix4.identity().values,
      );
      await expectLater(
        session.render(renderer: renderer, viewport: viewport),
        throwsA(isA<VtkApiStateException>()),
      );

      module.fixedObjectHandle = renderer.value;
      await expectLater(
        session.createObject(type: .renderer),
        throwsA(isA<VtkApiStateException>()),
      );
    },
  );

  test(
    'dynamic calls reuse the stable class and operation whitelist',
    () async {
      final session = await backend.openSession();
      final dynamicSession = session as VtkDynamicBackendSession;
      final contour = await dynamicSession.createDynamicObject(
        className: 'vtkFlyingEdges3D',
      );
      await dynamicSession.invokeDynamic(
        target: contour,
        methodName: 'SetValue',
        arguments: const [0, 18.0],
      );
      final output = await dynamicSession.invokeDynamic(
        target: contour,
        methodName: 'GetOutputPort',
        arguments: const [0],
      );

      expect(module.createdTypes, ['flyingEdges3D']);
      expect(module.invocations[0].operation, 'setIsoValue');
      expect(output, const VtkBackendObjectHandle(99));
      expect(
        () =>
            dynamicSession.createDynamicObject(className: 'vtkXMLImageReader'),
        throwsA(isA<VtkApiStateException>()),
      );
      expect(
        () =>
            dynamicSession.invokeDynamic(target: contour, methodName: 'Delete'),
        throwsA(isA<VtkApiStateException>()),
      );
    },
  );
}

final class _FakeWebModule implements VtkWebModule {
  final int sessionId = 42;
  final pngBytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
  final createdTypes = <String>[];
  final images = <VtkWebImageInput>[];
  final invocations = <({String operation, List<Object?> arguments})>[];
  final layoutRequests =
      <
        ({
          List<VtkWebRenderLayer> layers,
          int width,
          int height,
          int primaryLayer,
        })
      >[];
  int _nextHandle = 1;
  bool closed = false;
  int? fixedObjectHandle;
  VtkWebRenderFrame? renderFrame;
  Object? renderError;

  @override
  Future<VtkWebModuleCapabilities> capabilities() async =>
      VtkWebModuleCapabilities(
        supportedObjectTypes: const [
          'imageData',
          'flyingEdges3D',
          'polyDataConnectivityFilter',
          'renderer',
          'algorithmOutput',
        ],
        supportedScalarTypes: const [
          'uint8',
          'int8',
          'uint16',
          'int16',
          'uint32',
          'int32',
          'float32',
          'float64',
        ],
        maxImageBytes: vtkMaximumImageBytes,
        supportsRendering: true,
        limitations: const {'flyingEdges3D': 'Uses ImageMarchingCubes.'},
      );

  @override
  Future<int> openSession() async => sessionId;

  @override
  Future<int> createObject({
    required int sessionId,
    required String type,
  }) async {
    createdTypes.add(type);
    return fixedObjectHandle ?? _nextHandle++;
  }

  @override
  Future<int> createImageData({
    required int sessionId,
    required VtkWebImageInput input,
  }) async {
    images.add(input);
    return _nextHandle++;
  }

  @override
  Future<int?> invoke({
    required int sessionId,
    required int target,
    required String operation,
    required List<Object?> arguments,
  }) async {
    invocations.add((operation: operation, arguments: arguments));
    return operation == 'getOutputPort' ? 99 : null;
  }

  @override
  Future<void> destroyObject({
    required int sessionId,
    required int object,
  }) async {}

  @override
  Future<VtkWebRenderFrame> render({
    required int sessionId,
    required int renderer,
    required int width,
    required int height,
  }) => renderLayout(
    sessionId: sessionId,
    layers: [
      VtkWebRenderLayer(
        renderer: renderer,
        left: 0,
        bottom: 0,
        right: 1,
        top: 1,
      ),
    ],
    width: width,
    height: height,
    primaryLayer: 0,
  );

  @override
  Future<VtkWebRenderFrame> renderLayout({
    required int sessionId,
    required List<VtkWebRenderLayer> layers,
    required int width,
    required int height,
    required int primaryLayer,
  }) async {
    layoutRequests.add((
      layers: List.unmodifiable(layers),
      width: width,
      height: height,
      primaryLayer: primaryLayer,
    ));
    if (renderError case final error?) throw error;
    return renderFrame ??
        VtkWebRenderFrame(
          pngDataUrl: 'data:image/png;base64,${base64Encode(pngBytes)}',
          width: width,
          height: height,
          renderMicroseconds: 1200,
          captureMicroseconds: 300,
          worldToClip: VtkMatrix4.identity().values,
        );
  }

  @override
  Future<void> closeSession(int sessionId) async {
    closed = true;
  }
}
