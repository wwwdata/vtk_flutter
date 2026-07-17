import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/src/api/vtk_api.dart';
import 'package:vtk_flutter/src/ffi/vtk_ffi_transport.dart';

void main() {
  test('native FFI supports every curated typed pipeline', () async {
    final transport = createDefaultVtkFfiTransport();
    if (transport == null) {
      throw StateError('Dart FFI is unavailable');
    }

    final session = await transport.createSession();
    final objects = <VtkBackendObjectHandle>[];

    Future<VtkBackendObjectHandle> create(VtkObjectType type) async {
      final object = await transport.createObject(
        sessionAddress: session,
        type: type,
      );
      objects.add(object);
      return object;
    }

    Future<VtkBackendObjectHandle> output(
      VtkBackendObjectHandle algorithm,
    ) async {
      final result = await transport.invoke(
        sessionAddress: session,
        target: algorithm,
        operation: .getOutputPort,
        arguments: const [0],
      );
      if (result is! VtkBackendObjectHandle) {
        throw StateError('VTK returned no output port');
      }
      objects.add(result);
      return result;
    }

    Future<void> invoke(
      VtkBackendObjectHandle target,
      VtkBackendOperation operation, [
      List<Object?> arguments = const [],
    ]) async {
      await transport.invoke(
        sessionAddress: session,
        target: target,
        operation: operation,
        arguments: arguments,
      );
    }

    try {
      final image = await transport.createImageData(
        sessionAddress: session,
        input: VtkScalarImageInput(
          values: Int16List(8),
          dimensions: VtkDimensions(x: 2, y: 2, z: 2),
        ),
      );
      objects.add(image);

      final reslice = await create(.imageReslice);
      await invoke(reslice, .setInputData, [image]);
      await invoke(reslice, .setResliceAxes, [VtkMatrix4.identity()]);
      await invoke(reslice, .setOutputDimensionality, [2]);
      await invoke(reslice, .setResliceInterpolation, [
        VtkInterpolation.linear,
      ]);
      await invoke(reslice, .setAutoCropOutput, [true]);
      final resliceOutput = await output(reslice);

      final window = await create(.imageMapToWindowLevelColors);
      await invoke(window, .setInputConnection, [0, resliceOutput]);
      await invoke(window, .setWindow, [400.0]);
      await invoke(window, .setLevel, [40.0]);
      final windowOutput = await output(window);

      final imageMapper = await create(.imageSliceMapper);
      await invoke(imageMapper, .setInputConnection, [0, windowOutput]);
      final imageProperty = await create(.imageProperty);
      await invoke(imageProperty, .setImageInterpolation, [
        VtkInterpolation.linear,
      ]);
      final imageActor = await create(.imageActor);
      await invoke(imageActor, .setMapper, [imageMapper]);
      await invoke(imageActor, .setProperty, [imageProperty]);

      final volumeMapper = await create(.smartVolumeMapper);
      await invoke(volumeMapper, .setInputData, [image]);
      await invoke(volumeMapper, .setVolumeBlendMode, [
        VtkVolumeBlendMode.composite,
      ]);
      await invoke(volumeMapper, .setSampleDistance, [1.0]);
      final colors = await create(.colorTransferFunction);
      await invoke(colors, .addRgbPoint, [0.0, 0.1, 0.2, 0.8]);
      final opacity = await create(.piecewiseFunction);
      await invoke(opacity, .addOpacityPoint, [0.0, 0.5]);
      final volumeProperty = await create(.volumeProperty);
      await invoke(volumeProperty, .setColorTransferFunction, [colors]);
      await invoke(volumeProperty, .setScalarOpacity, [opacity]);
      await invoke(volumeProperty, .setVolumeInterpolation, [
        VtkInterpolation.linear,
      ]);
      await invoke(volumeProperty, .setShade, [true]);
      final volume = await create(.volume);
      await invoke(volume, .setMapper, [volumeMapper]);
      await invoke(volume, .setProperty, [volumeProperty]);

      final contour = await create(.flyingEdges3D);
      await invoke(contour, .setInputData, [image]);
      await invoke(contour, .setIsoValue, [0, 0.0]);
      final contourOutput = await output(contour);
      final connectivity = await create(.polyDataConnectivityFilter);
      await invoke(connectivity, .setInputConnection, [0, contourOutput]);
      await invoke(connectivity, .setConnectivityMode, [
        VtkConnectivityMode.largestRegion,
      ]);
      final connectivityOutput = await output(connectivity);
      final smoothing = await create(.windowedSincPolyDataFilter);
      await invoke(smoothing, .setInputConnection, [0, connectivityOutput]);
      await invoke(smoothing, .setNumberOfIterations, [5]);
      await invoke(smoothing, .setPassBand, [0.1]);
      final smoothingOutput = await output(smoothing);
      final mapper = await create(.polyDataMapper);
      await invoke(mapper, .setInputConnection, [0, smoothingOutput]);
      await invoke(mapper, .setScalarVisibility, [false]);
      final property = await create(.property);
      await invoke(property, .setColor, [0.8, 0.7, 0.6]);
      await invoke(property, .setRepresentation, [VtkRepresentation.surface]);
      final actor = await create(.actor);
      await invoke(actor, .setMapper, [mapper]);
      await invoke(actor, .setProperty, [property]);

      final renderer = await create(.renderer);
      await invoke(renderer, .addActor, [imageActor]);
      await invoke(renderer, .addVolume, [volume]);
      await invoke(renderer, .addActor, [actor]);
      await invoke(renderer, .setBackground, [0.05, 0.08, 0.12]);
      final camera = await create(.camera);
      await invoke(camera, .setPosition, [3.0, 3.0, 3.0]);
      await invoke(camera, .setFocalPoint, [0.0, 0.0, 0.0]);
      await invoke(camera, .setViewUp, [0.0, 1.0, 0.0]);
      await invoke(renderer, .setActiveCamera, [camera]);
      await invoke(renderer, .resetCamera);

      stdout.writeln(
        'Native FFI smoke passed with ${objects.length} VTK objects.',
      );
    } finally {
      for (final object in objects.reversed) {
        await transport.destroyObject(sessionAddress: session, object: object);
      }
      await transport.destroySession(session);
    }
  });
}
