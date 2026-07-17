part of 'vtk_api.dart';

/// The package-internal seam implemented by native and web adapters.
///
/// Applications use [VtkRuntime] and the typed object wrappers instead of this
/// interface. Keeping the adapter protocol in `lib/src` allows the public
/// wrappers to remain stable when a backend maps these commands to FFI, JSON,
/// JavaScript, or another transport.
abstract interface class VtkBackend {
  Future<VtkCapabilities> capabilities();

  Future<VtkBackendSession> openSession();

  Future<void> close();
}

/// One backend-owned VTK object-manager session.
abstract interface class VtkBackendSession {
  int get viewId;

  Future<VtkBackendObjectHandle> createObject({required VtkObjectType type});

  Future<VtkBackendObjectHandle> createImageData({
    required VtkScalarImageInput input,
  });

  Future<Object?> invoke({
    required VtkBackendObjectHandle target,
    required VtkBackendOperation operation,
    List<Object?> arguments = const [],
  });

  Future<void> destroyObject({required VtkBackendObjectHandle object});

  Future<VtkRenderResult> render({
    required VtkBackendObjectHandle renderer,
    required VtkViewport viewport,
  });

  Future<void> close();
}

/// Optional backend extension used by the separately imported experimental API.
abstract interface class VtkDynamicBackendSession {
  Future<VtkBackendObjectHandle> createDynamicObject({
    required String className,
  });

  Future<Object?> invokeDynamic({
    required VtkBackendObjectHandle target,
    required String methodName,
    List<Object?> arguments = const [],
  });
}

/// An opaque object identifier meaningful only to its backend session.
final class VtkBackendObjectHandle {
  const VtkBackendObjectHandle(this.value);

  final int value;

  @override
  bool operator ==(Object other) =>
      other is VtkBackendObjectHandle && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'VtkBackendObjectHandle($value)';
}

/// Object kinds understood by the adapter protocol.
///
/// Stable typed wrappers are the application-facing interface. Adapters map
/// these values to backend-specific constructors.
enum VtkObjectType {
  imageData,
  imageReslice,
  imageMapToWindowLevelColors,
  imageActor,
  imageSliceMapper,
  imageProperty,
  smartVolumeMapper,
  colorTransferFunction,
  piecewiseFunction,
  volumeProperty,
  volume,
  flyingEdges3D,
  polyDataConnectivityFilter,
  windowedSincPolyDataFilter,
  polyDataMapper,
  actor,
  property,
  renderer,
  camera,
  algorithmOutput,
}

/// Typed commands understood by backend adapters.
///
/// No raw VTK method name crosses the stable wrapper interface.
enum VtkBackendOperation {
  setInputData,
  setInputConnection,
  getOutputPort,
  setResliceAxes,
  setOutputDimensionality,
  setResliceInterpolation,
  setAutoCropOutput,
  setWindow,
  setLevel,
  setMapper,
  setProperty,
  setImageInterpolation,
  setColorWindow,
  setColorLevel,
  setVolumeBlendMode,
  setSampleDistance,
  addRgbPoint,
  removeAllPoints,
  addOpacityPoint,
  setColorTransferFunction,
  setScalarOpacity,
  setVolumeInterpolation,
  setShade,
  setAmbient,
  setDiffuse,
  setSpecular,
  setSpecularPower,
  setScalarOpacityUnitDistance,
  setIsoValue,
  setComputeNormals,
  setConnectivityMode,
  setClosestPoint,
  setColorRegions,
  setNumberOfIterations,
  setPassBand,
  setBoundarySmoothing,
  setFeatureEdgeSmoothing,
  setNormalizeCoordinates,
  setScalarVisibility,
  setColor,
  setOpacity,
  setRepresentation,
  setLineWidth,
  addActor,
  removeActor,
  addVolume,
  removeVolume,
  setBackground,
  setActiveCamera,
  resetCamera,
  setPosition,
  setFocalPoint,
  setViewUp,
  setParallelProjection,
  setParallelScale,
  setClippingRange,
  azimuth,
  elevation,
  roll,
  zoom,
  dolly,
}
