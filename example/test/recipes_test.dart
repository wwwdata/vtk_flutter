import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/src/api/vtk_api.dart';
import 'package:vtk_flutter_example/recipes.dart';
import 'package:vtk_flutter_example/scalar_field.dart';

import 'support/recording_vtk_backend.dart';

void main() {
  late RecordingVtkBackend backend;
  late VtkRuntime runtime;
  late VtkSession session;
  late VtkScalarImageInput image;

  setUp(() async {
    backend = RecordingVtkBackend();
    runtime = createVtkRuntimeForBackend(backend);
    session = await runtime.openSession();
    image = createSyntheticScalarField(
      dimensions: VtkDimensions(x: 10, y: 9, z: 8),
    );
  });

  tearDown(() => runtime.close());

  test('builds an oblique reslice pipeline and applies its settings', () async {
    final scene = await buildObliqueResliceRecipe(
      session: session,
      image: image,
      settings: const ObliqueResliceSettings(
        angleDegrees: 35,
        sliceOffset: 4,
        window: 1800,
        level: 900,
        parallelScale: 22,
      ),
    );
    final recording = backend.sessions.single;

    expect(scene.renderer, isA<VtkRenderer>());
    expect(scene.camera, isA<VtkCamera>());
    expect(recording.imageInputs, [same(image)]);
    expect(recording.createdTypes, [
      VtkObjectType.imageData,
      VtkObjectType.imageReslice,
      VtkObjectType.imageMapToWindowLevelColors,
      VtkObjectType.algorithmOutput,
      VtkObjectType.imageSliceMapper,
      VtkObjectType.algorithmOutput,
      VtkObjectType.imageProperty,
      VtkObjectType.imageActor,
      VtkObjectType.renderer,
      VtkObjectType.camera,
    ]);
    expect(recording.calls.map((call) => call.operation), [
      VtkBackendOperation.setInputData,
      VtkBackendOperation.setResliceAxes,
      VtkBackendOperation.setOutputDimensionality,
      VtkBackendOperation.setResliceInterpolation,
      VtkBackendOperation.setAutoCropOutput,
      VtkBackendOperation.getOutputPort,
      VtkBackendOperation.setInputConnection,
      VtkBackendOperation.setWindow,
      VtkBackendOperation.setLevel,
      VtkBackendOperation.getOutputPort,
      VtkBackendOperation.setInputConnection,
      VtkBackendOperation.setImageInterpolation,
      VtkBackendOperation.setMapper,
      VtkBackendOperation.setProperty,
      VtkBackendOperation.setBackground,
      VtkBackendOperation.addActor,
      VtkBackendOperation.setActiveCamera,
      VtkBackendOperation.resetCamera,
      VtkBackendOperation.setParallelProjection,
      VtkBackendOperation.setParallelScale,
    ]);
    expect(
      _argumentsFor(
        recording: recording,
        operation: VtkBackendOperation.setWindow,
      ),
      [1800.0],
    );
    expect(
      _argumentsFor(
        recording: recording,
        operation: VtkBackendOperation.setLevel,
      ),
      [900.0],
    );
    expect(
      _argumentsFor(
        recording: recording,
        operation: VtkBackendOperation.setParallelScale,
      ),
      [22.0],
    );
    final axes =
        _argumentsFor(
              recording: recording,
              operation: VtkBackendOperation.setResliceAxes,
            ).single
            as VtkMatrix4;
    final angle = 35 * math.pi / 180;
    expect(axes.values[7], closeTo(-math.sin(angle) * 4, 1e-12));
    expect(axes.values[11], closeTo(math.cos(angle) * 4, 1e-12));
  });

  test('builds a volume ray-cast pipeline and applies its settings', () async {
    final scene = await buildVolumeRayCastRecipe(
      session: session,
      image: image,
      settings: const VolumeRayCastSettings(
        sampleDistance: 1.25,
        opacityScale: 0.6,
        shade: false,
        azimuth: 12,
        elevation: 8,
        zoom: 1.1,
      ),
    );
    final recording = backend.sessions.single;

    expect(scene.renderer, isA<VtkRenderer>());
    expect(scene.camera, isA<VtkCamera>());
    expect(recording.imageInputs, [same(image)]);
    expect(recording.createdTypes, [
      VtkObjectType.imageData,
      VtkObjectType.smartVolumeMapper,
      VtkObjectType.colorTransferFunction,
      VtkObjectType.piecewiseFunction,
      VtkObjectType.volumeProperty,
      VtkObjectType.volume,
      VtkObjectType.renderer,
      VtkObjectType.camera,
    ]);
    expect(
      recording.calls.map((call) => call.operation),
      containsAllInOrder([
        VtkBackendOperation.setInputData,
        VtkBackendOperation.setVolumeBlendMode,
        VtkBackendOperation.setSampleDistance,
        VtkBackendOperation.addRgbPoint,
        VtkBackendOperation.addOpacityPoint,
        VtkBackendOperation.setColorTransferFunction,
        VtkBackendOperation.setScalarOpacity,
        VtkBackendOperation.setVolumeInterpolation,
        VtkBackendOperation.setShade,
        VtkBackendOperation.setMapper,
        VtkBackendOperation.setProperty,
        VtkBackendOperation.addVolume,
        VtkBackendOperation.setActiveCamera,
        VtkBackendOperation.resetCamera,
        VtkBackendOperation.azimuth,
        VtkBackendOperation.elevation,
        VtkBackendOperation.zoom,
      ]),
    );
    expect(
      _argumentsFor(
        recording: recording,
        operation: VtkBackendOperation.setSampleDistance,
      ),
      [1.25],
    );
    expect(
      _argumentsFor(
        recording: recording,
        operation: VtkBackendOperation.setShade,
      ),
      [false],
    );
    expect(
      _argumentsFor(
        recording: recording,
        operation: VtkBackendOperation.azimuth,
      ),
      [12.0],
    );
    expect(
      _argumentsFor(
        recording: recording,
        operation: VtkBackendOperation.elevation,
      ),
      [8.0],
    );
    expect(
      _argumentsFor(recording: recording, operation: VtkBackendOperation.zoom),
      [1.1],
    );
    expect(
      recording
          .callsFor(VtkObjectType.colorTransferFunction)
          .where((call) => call.operation == VtkBackendOperation.addRgbPoint),
      hasLength(4),
    );
    expect(
      recording
          .callsFor(VtkObjectType.piecewiseFunction)
          .where(
            (call) => call.operation == VtkBackendOperation.addOpacityPoint,
          ),
      hasLength(5),
    );
  });

  test('routes an extracted surface through smoothing when enabled', () async {
    await buildExtractedSurfaceRecipe(
      session: session,
      image: image,
      settings: const ExtractedSurfaceSettings(
        smoothing: true,
        smoothingIterations: 7,
        passBand: 0.2,
      ),
    );
    final recording = backend.sessions.single;

    expect(
      recording.createdTypes,
      contains(VtkObjectType.windowedSincPolyDataFilter),
    );
    expect(
      _argumentsFor(
        recording: recording,
        operation: VtkBackendOperation.setNumberOfIterations,
      ),
      [7],
    );
    expect(
      _argumentsFor(
        recording: recording,
        operation: VtkBackendOperation.setPassBand,
      ),
      [0.2],
    );
    expect(
      _mapperInputSource(recording),
      VtkObjectType.windowedSincPolyDataFilter,
    );
    expect(
      recording.calls.map((call) => call.operation),
      containsAllInOrder([
        VtkBackendOperation.setInputData,
        VtkBackendOperation.setIsoValue,
        VtkBackendOperation.setComputeNormals,
        VtkBackendOperation.getOutputPort,
        VtkBackendOperation.setInputConnection,
        VtkBackendOperation.setConnectivityMode,
        VtkBackendOperation.setColorRegions,
        VtkBackendOperation.getOutputPort,
        VtkBackendOperation.setInputConnection,
        VtkBackendOperation.setNumberOfIterations,
        VtkBackendOperation.setPassBand,
        VtkBackendOperation.setBoundarySmoothing,
        VtkBackendOperation.setFeatureEdgeSmoothing,
        VtkBackendOperation.setNormalizeCoordinates,
        VtkBackendOperation.getOutputPort,
        VtkBackendOperation.setInputConnection,
        VtkBackendOperation.setScalarVisibility,
        VtkBackendOperation.setMapper,
        VtkBackendOperation.setProperty,
        VtkBackendOperation.addActor,
        VtkBackendOperation.setActiveCamera,
        VtkBackendOperation.resetCamera,
      ]),
    );
  });

  test(
    'connects the extracted surface directly when smoothing is disabled',
    () async {
      final scene = await buildExtractedSurfaceRecipe(
        session: session,
        image: image,
        settings: const ExtractedSurfaceSettings(smoothing: false),
      );
      final recording = backend.sessions.single;

      expect(scene.renderer, isA<VtkRenderer>());
      expect(scene.camera, isA<VtkCamera>());
      expect(
        recording.createdTypes,
        isNot(contains(VtkObjectType.windowedSincPolyDataFilter)),
      );
      final operations = recording.calls.map((call) => call.operation);
      expect(
        operations,
        isNot(contains(VtkBackendOperation.setNumberOfIterations)),
      );
      expect(operations, isNot(contains(VtkBackendOperation.setPassBand)));
      expect(
        operations,
        isNot(contains(VtkBackendOperation.setBoundarySmoothing)),
      );
      expect(
        operations,
        isNot(contains(VtkBackendOperation.setFeatureEdgeSmoothing)),
      );
      expect(
        operations,
        isNot(contains(VtkBackendOperation.setNormalizeCoordinates)),
      );
      expect(
        _mapperInputSource(recording),
        VtkObjectType.polyDataConnectivityFilter,
      );
    },
  );
}

List<Object?> _argumentsFor({
  required RecordingVtkBackendSession recording,
  required VtkBackendOperation operation,
}) => recording.calls
    .singleWhere((call) => call.operation == operation)
    .arguments;

VtkObjectType _mapperInputSource(RecordingVtkBackendSession recording) {
  final call = recording
      .callsFor(VtkObjectType.polyDataMapper)
      .singleWhere(
        (call) => call.operation == VtkBackendOperation.setInputConnection,
      );
  final output = call.arguments.whereType<VtkBackendObjectHandle>().single;
  return recording.outputSourceTypeOf(output);
}
