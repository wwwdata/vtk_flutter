import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/src/api/vtk_api.dart';
import 'package:vtk_flutter/src/ffi/vtk_ffi_transport_native.dart';
import 'package:vtk_flutter/src/ffi/vtk_flutter_bindings.g.dart';

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

  test('marshals every render layer into one contiguous native call', () async {
    var callCount = 0;
    final transport = VtkNativeFfiTransport(
      bindingsAlreadyValidated: true,
      renderLayoutCall:
          (
            session,
            layers,
            layerCount,
            viewport,
            primaryLayer,
            metrics,
            status,
          ) {
            callCount++;
            expect(session.address, 123);
            expect(layerCount, 2);
            expect(primaryLayer, 1);
            expect(viewport.ref.width, 200);
            expect(viewport.ref.height, 100);
            expect(layers[0].struct_size, sizeOf<VtkFlutterRenderLayer>());
            expect(layers[0].version, VTK_FLUTTER_RENDER_LAYER_VERSION);
            expect(layers[0].renderer, 7);
            expect(layers[0].left, 0);
            expect(layers[0].bottom, 0.1);
            expect(layers[0].right, 0.25);
            expect(layers[0].top, 0.9);
            expect(layers[1].renderer, 9);
            expect(layers[1].left, 0.25);
            expect(layers[1].bottom, 0.2);
            expect(layers[1].right, 1);
            expect(layers[1].top, 0.8);
            metrics.ref
              ..frame_bytes = 80000
              ..surface_allocation_bytes = 80000
              ..frame_width = 200
              ..frame_height = 100
              ..render_ms = 1.5
              ..surface_submit_ms = 0.25
              ..gpu_sync_wait_ms = 0
              ..cpu_readback_ms = 0.5;
            return VtkFlutterStatusCode.VTK_FLUTTER_STATUS_OK.value;
          },
    );

    final result = transport.renderLayout(
      sessionAddress: 123,
      layers: [
        VtkBackendRenderLayer(
          renderer: const VtkBackendObjectHandle(7),
          viewport: VtkNormalizedViewport(
            left: 0,
            bottom: 0.1,
            right: 0.25,
            top: 0.9,
          ),
        ),
        VtkBackendRenderLayer(
          renderer: const VtkBackendObjectHandle(9),
          viewport: VtkNormalizedViewport(
            left: 0.25,
            bottom: 0.2,
            right: 1,
            top: 0.8,
          ),
        ),
      ],
      viewport: VtkViewport(width: 200, height: 100),
      primaryLayer: 1,
    );

    expect(callCount, 1);
    expect(result.viewport, VtkViewport(width: 200, height: 100));
    expect(result.renderTime, const Duration(microseconds: 1500));
  });

  test('legacy native render marshals one full-viewport layer', () async {
    final transport = VtkNativeFfiTransport(
      bindingsAlreadyValidated: true,
      renderLayoutCall:
          (
            session,
            layers,
            layerCount,
            viewport,
            primaryLayer,
            metrics,
            status,
          ) {
            expect(layerCount, 1);
            expect(primaryLayer, 0);
            expect(layers.ref.renderer, 11);
            expect(layers.ref.left, 0);
            expect(layers.ref.bottom, 0);
            expect(layers.ref.right, 1);
            expect(layers.ref.top, 1);
            metrics.ref
              ..frame_bytes = 16
              ..surface_allocation_bytes = 16
              ..frame_width = 2
              ..frame_height = 2;
            return VtkFlutterStatusCode.VTK_FLUTTER_STATUS_OK.value;
          },
    );

    transport.render(
      sessionAddress: 123,
      renderer: const VtkBackendObjectHandle(11),
      viewport: VtkViewport(width: 2, height: 2),
    );
  });

  test('rejects unsafe native render layer counts before FFI', () async {
    var called = false;
    final transport = VtkNativeFfiTransport(
      bindingsAlreadyValidated: true,
      renderLayoutCall:
          (
            session,
            layers,
            layerCount,
            viewport,
            primaryLayer,
            metrics,
            status,
          ) {
            called = true;
            return VtkFlutterStatusCode.VTK_FLUTTER_STATUS_OK.value;
          },
    );

    expect(
      () => transport.renderLayout(
        sessionAddress: 123,
        layers: const [],
        viewport: VtkViewport(width: 2, height: 2),
        primaryLayer: 0,
      ),
      throwsA(isA<VtkApiValidationException>()),
    );
    expect(
      () => transport.renderLayout(
        sessionAddress: 123,
        layers: [
          for (var index = 0; index <= VTK_FLUTTER_MAX_RENDER_LAYERS; index++)
            VtkBackendRenderLayer(
              renderer: VtkBackendObjectHandle(index + 1),
              viewport: VtkNormalizedViewport.full,
            ),
        ],
        viewport: VtkViewport(width: 2, height: 2),
        primaryLayer: 0,
      ),
      throwsA(isA<VtkApiValidationException>()),
    );

    expect(called, isFalse);
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
