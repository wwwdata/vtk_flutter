import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/src/api/vtk_api.dart';
import 'package:vtk_flutter/src/ffi/vtk_ffi_transport_native.dart';

void main() {
  test('maps every stable operation to the expected native VTK method', () {
    const expectedMethods = <VtkBackendOperation, String>{
      .setInputData: 'SetInputData',
      .setInputConnection: 'SetInputConnection',
      .getOutputPort: 'GetOutputPort',
      .setOutputDimensionality: 'SetOutputDimensionality',
      .setResliceInterpolation: 'SetInterpolationMode',
      .setAutoCropOutput: 'SetAutoCropOutput',
      .setWindow: 'SetWindow',
      .setLevel: 'SetLevel',
      .setMapper: 'SetMapper',
      .setProperty: 'SetProperty',
      .setImageInterpolation: 'SetInterpolationType',
      .setColorWindow: 'SetColorWindow',
      .setColorLevel: 'SetColorLevel',
      .setVolumeBlendMode: 'SetBlendModeToMaximumIntensity',
      .setSampleDistance: 'SetSampleDistance',
      .addRgbPoint: 'AddRGBPoint',
      .removeAllPoints: 'RemoveAllPoints',
      .addOpacityPoint: 'AddPoint',
      .setColorTransferFunction: 'SetColor',
      .setScalarOpacity: 'SetScalarOpacity',
      .setVolumeInterpolation: 'SetInterpolationType',
      .setShade: 'SetShade',
      .setAmbient: 'SetAmbient',
      .setDiffuse: 'SetDiffuse',
      .setSpecular: 'SetSpecular',
      .setSpecularPower: 'SetSpecularPower',
      .setScalarOpacityUnitDistance: 'SetScalarOpacityUnitDistance',
      .setIsoValue: 'SetValue',
      .setComputeNormals: 'SetComputeNormals',
      .setConnectivityMode: 'SetExtractionModeToLargestRegion',
      .setClosestPoint: 'SetClosestPoint',
      .setColorRegions: 'SetColorRegions',
      .setNumberOfIterations: 'SetNumberOfIterations',
      .setPassBand: 'SetPassBand',
      .setBoundarySmoothing: 'SetBoundarySmoothing',
      .setFeatureEdgeSmoothing: 'SetFeatureEdgeSmoothing',
      .setNormalizeCoordinates: 'SetNormalizeCoordinates',
      .setScalarVisibility: 'SetScalarVisibility',
      .setColor: 'SetColor',
      .setOpacity: 'SetOpacity',
      .setRepresentation: 'SetRepresentationToWireframe',
      .setLineWidth: 'SetLineWidth',
      .addActor: 'AddActor',
      .removeActor: 'RemoveActor',
      .addVolume: 'AddVolume',
      .removeVolume: 'RemoveVolume',
      .setBackground: 'SetBackground',
      .setActiveCamera: 'SetActiveCamera',
      .resetCamera: 'ResetCamera',
      .setPosition: 'SetPosition',
      .setFocalPoint: 'SetFocalPoint',
      .setViewUp: 'SetViewUp',
      .setParallelProjection: 'SetParallelProjection',
      .setParallelScale: 'SetParallelScale',
      .setClippingRange: 'SetClippingRange',
      .azimuth: 'Azimuth',
      .elevation: 'Elevation',
      .roll: 'Roll',
      .zoom: 'Zoom',
      .dolly: 'Dolly',
    };

    expect(
      expectedMethods.keys.toSet(),
      VtkBackendOperation.values.toSet()
        ..remove(VtkBackendOperation.setResliceAxes),
    );

    for (final MapEntry(key: operation, value: method)
        in expectedMethods.entries) {
      final invocation = createVtkNativeInvocations(
        operation: operation,
        arguments: _argumentsFor(operation),
      ).single;
      expect(invocation.method, method, reason: '$operation');
    }
  });

  test('decomposes reslice axes into the two serialized VTK setters', () {
    final invocations = createVtkNativeInvocations(
      operation: .setResliceAxes,
      arguments: [VtkMatrix4(values: List<double>.generate(16, (i) => i + 1))],
    );

    expect(invocations, hasLength(2));
    expect(invocations.first.method, 'SetResliceAxesDirectionCosines');
    expect(invocations.first.arguments, const [
      1.0,
      5.0,
      9.0,
      2.0,
      6.0,
      10.0,
      3.0,
      7.0,
      11.0,
    ]);
    expect(invocations.last.method, 'SetResliceAxesOrigin');
    expect(invocations.last.arguments, const [4.0, 8.0, 12.0]);
  });

  test('encodes handles, matrices, and VTK boolean arguments for JSON', () {
    expect(encodeVtkNativeArgument(const VtkBackendObjectHandle(42)), const {
      'Id': 42,
    });
    expect(encodeVtkNativeArgument(true), 1);
    expect(encodeVtkNativeArgument(false), 0);
    expect(
      encodeVtkNativeArgument(VtkMatrix4.identity()),
      VtkMatrix4.identity().values,
    );
    expect(
      () => encodeVtkNativeArgument(VtkRepresentation.surface),
      throwsA(isA<VtkApiStateException>()),
    );
  });
}

List<Object?> _argumentsFor(VtkBackendOperation operation) =>
    switch (operation) {
      .setResliceInterpolation ||
      .setImageInterpolation ||
      .setVolumeInterpolation => const [VtkInterpolation.linear],
      .setVolumeBlendMode => const [VtkVolumeBlendMode.maximumIntensity],
      .setConnectivityMode => const [VtkConnectivityMode.largestRegion],
      .setRepresentation => const [VtkRepresentation.wireframe],
      _ => const [],
    };
