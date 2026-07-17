import 'dart:math' as math;

import 'package:vtk_flutter/vtk_flutter.dart';

import 'scalar_field.dart';

enum ShowcaseRecipe { obliqueReslice, volumeRayCast, extractedSurface }

extension ShowcaseRecipeInfo on ShowcaseRecipe {
  String get label => switch (this) {
    .obliqueReslice => 'Oblique 2D reslice',
    .volumeRayCast => 'GPU-capable volume ray casting',
    .extractedSurface => 'Extracted surface',
  };

  Set<VtkObjectType> get requiredObjectTypes => switch (this) {
    .obliqueReslice => const {
      VtkObjectType.imageData,
      VtkObjectType.imageReslice,
      VtkObjectType.imageMapToWindowLevelColors,
      VtkObjectType.imageSliceMapper,
      VtkObjectType.imageProperty,
      VtkObjectType.imageActor,
      VtkObjectType.renderer,
      VtkObjectType.camera,
    },
    .volumeRayCast => const {
      VtkObjectType.imageData,
      VtkObjectType.smartVolumeMapper,
      VtkObjectType.colorTransferFunction,
      VtkObjectType.piecewiseFunction,
      VtkObjectType.volumeProperty,
      VtkObjectType.volume,
      VtkObjectType.renderer,
      VtkObjectType.camera,
    },
    .extractedSurface => const {
      VtkObjectType.imageData,
      VtkObjectType.flyingEdges3D,
      VtkObjectType.polyDataConnectivityFilter,
      VtkObjectType.polyDataMapper,
      VtkObjectType.property,
      VtkObjectType.actor,
      VtkObjectType.renderer,
      VtkObjectType.camera,
    },
  };

  bool isSupportedBy(VtkCapabilities capabilities) =>
      capabilities.supportsRendering &&
      capabilities.supportsScalarType(VtkScalarType.uint16) &&
      requiredObjectTypes.every(capabilities.supportsObject);
}

final class VtkRecipeScene {
  const VtkRecipeScene({required this.renderer, required this.camera});

  final VtkRenderer renderer;
  final VtkCamera camera;
}

final class ObliqueResliceSettings {
  const ObliqueResliceSettings({
    this.angleDegrees = 28,
    this.sliceOffset = 0,
    this.window = 2600,
    this.level = 1450,
    this.parallelScale = 34,
  });

  final double angleDegrees;
  final double sliceOffset;
  final double window;
  final double level;
  final double parallelScale;
}

/// Builds ImageReslice -> window/level -> image mapper -> image actor.
Future<VtkRecipeScene> buildObliqueResliceRecipe({
  required VtkSession session,
  required VtkScalarImageInput image,
  ObliqueResliceSettings settings = const ObliqueResliceSettings(),
}) async {
  final imageData = await session.createImageData(image);

  final angle = settings.angleDegrees * math.pi / 180;
  final cosine = math.cos(angle);
  final sine = math.sin(angle);
  final reslice = await session.createImageReslice();
  await reslice.setInputData(imageData);
  await reslice.setResliceAxes(
    VtkMatrix4(
      values: [
        1,
        0,
        0,
        0,
        0,
        cosine,
        -sine,
        -sine * settings.sliceOffset,
        0,
        sine,
        cosine,
        cosine * settings.sliceOffset,
        0,
        0,
        0,
        1,
      ],
    ),
  );
  await reslice.setOutputDimensionality(2);
  await reslice.setInterpolation(VtkInterpolation.linear);
  await reslice.setAutoCropOutput(true);

  final windowLevel = await session.createImageMapToWindowLevelColors();
  await windowLevel.setInputConnection(input: await reslice.output());
  await windowLevel.setWindow(settings.window);
  await windowLevel.setLevel(settings.level);

  final mapper = await session.createImageSliceMapper();
  await mapper.setInputConnection(input: await windowLevel.output());

  final property = await session.createImageProperty();
  await property.setInterpolation(VtkInterpolation.linear);

  final actor = await session.createImageActor();
  await actor.setMapper(mapper);
  await actor.setProperty(property);

  final renderer = await session.createRenderer();
  await renderer.setBackground(VtkColor(red: 0.025, green: 0.035, blue: 0.055));
  await renderer.addActor(actor);

  final camera = await session.createCamera();
  await renderer.setActiveCamera(camera);
  await renderer.resetCamera();
  await camera.setParallelProjection(true);
  await camera.setParallelScale(settings.parallelScale);

  return VtkRecipeScene(renderer: renderer, camera: camera);
}

final class VolumeRayCastSettings {
  const VolumeRayCastSettings({
    this.sampleDistance = 0.8,
    this.opacityScale = 1,
    this.shade = true,
    this.azimuth = 32,
    this.elevation = 18,
    this.zoom = 1.25,
  });

  final double sampleDistance;
  final double opacityScale;
  final bool shade;
  final double azimuth;
  final double elevation;
  final double zoom;
}

/// Builds a composite ray-cast volume with color and opacity transfer functions.
///
/// The public API exposes [VtkSmartVolumeMapper], which selects an available
/// implementation but does not currently let Dart force or inspect GPU mode.
Future<VtkRecipeScene> buildVolumeRayCastRecipe({
  required VtkSession session,
  required VtkScalarImageInput image,
  VolumeRayCastSettings settings = const VolumeRayCastSettings(),
}) async {
  final imageData = await session.createImageData(image);

  final mapper = await session.createSmartVolumeMapper();
  await mapper.setInputData(imageData);
  await mapper.setBlendMode(VtkVolumeBlendMode.composite);
  await mapper.setSampleDistance(settings.sampleDistance);

  final colors = await session.createColorTransferFunction();
  await colors.addPoint(
    value: syntheticScalarMinimum.toDouble(),
    color: VtkColor(red: 0.015, green: 0.025, blue: 0.08),
  );
  await colors.addPoint(
    value: 1100,
    color: VtkColor(red: 0.08, green: 0.3, blue: 0.72),
  );
  await colors.addPoint(
    value: 2300,
    color: VtkColor(red: 0.92, green: 0.34, blue: 0.12),
  );
  await colors.addPoint(
    value: syntheticScalarMaximum.toDouble(),
    color: VtkColor(red: 1, green: 0.94, blue: 0.74),
  );

  final opacity = await session.createPiecewiseFunction();
  await opacity.addPoint(value: syntheticScalarMinimum.toDouble(), opacity: 0);
  await opacity.addPoint(value: 700, opacity: 0);
  await opacity.addPoint(
    value: 1500,
    opacity: _scaledOpacity(base: 0.06, scale: settings.opacityScale),
  );
  await opacity.addPoint(
    value: 2600,
    opacity: _scaledOpacity(base: 0.28, scale: settings.opacityScale),
  );
  await opacity.addPoint(
    value: syntheticScalarMaximum.toDouble(),
    opacity: _scaledOpacity(base: 0.72, scale: settings.opacityScale),
  );

  final property = await session.createVolumeProperty();
  await property.setColor(colors);
  await property.setScalarOpacity(opacity);
  await property.setInterpolation(VtkInterpolation.linear);
  await property.setShade(settings.shade);
  await property.setAmbient(0.2);
  await property.setDiffuse(0.75);
  await property.setSpecular(0.22);
  await property.setSpecularPower(18);
  await property.setScalarOpacityUnitDistance(1.4);

  final volume = await session.createVolume();
  await volume.setMapper(mapper);
  await volume.setProperty(property);

  final renderer = await session.createRenderer();
  await renderer.setBackground(VtkColor(red: 0.018, green: 0.025, blue: 0.05));
  await renderer.addVolume(volume);

  final camera = await session.createCamera();
  await _configurePerspectiveCamera(
    renderer: renderer,
    camera: camera,
    azimuth: settings.azimuth,
    elevation: settings.elevation,
    zoom: settings.zoom,
  );
  return VtkRecipeScene(renderer: renderer, camera: camera);
}

final class ExtractedSurfaceSettings {
  const ExtractedSurfaceSettings({
    this.isoValue = 2050,
    this.smoothing = true,
    this.smoothingIterations = 16,
    this.passBand = 0.12,
    this.azimuth = 34,
    this.elevation = 22,
    this.zoom = 1.3,
  });

  final double isoValue;
  final bool smoothing;
  final int smoothingIterations;
  final double passBand;
  final double azimuth;
  final double elevation;
  final double zoom;
}

/// Builds FlyingEdges3D -> connectivity -> optional smoothing -> mapper -> actor.
Future<VtkRecipeScene> buildExtractedSurfaceRecipe({
  required VtkSession session,
  required VtkScalarImageInput image,
  ExtractedSurfaceSettings settings = const ExtractedSurfaceSettings(),
}) async {
  final imageData = await session.createImageData(image);

  final surface = await session.createFlyingEdges3D();
  await surface.setInputData(imageData);
  await surface.setValue(value: settings.isoValue);
  await surface.setComputeNormals(true);

  final connectivity = await session.createPolyDataConnectivityFilter();
  await connectivity.setInputConnection(input: await surface.output());
  await connectivity.setMode(VtkConnectivityMode.largestRegion);
  await connectivity.setColorRegions(false);

  var output = await connectivity.output();
  if (settings.smoothing) {
    final smoothing = await session.createWindowedSincPolyDataFilter();
    await smoothing.setInputConnection(input: output);
    await smoothing.setNumberOfIterations(settings.smoothingIterations);
    await smoothing.setPassBand(settings.passBand);
    await smoothing.setBoundarySmoothing(false);
    await smoothing.setFeatureEdgeSmoothing(false);
    await smoothing.setNormalizeCoordinates(true);
    output = await smoothing.output();
  }

  final mapper = await session.createPolyDataMapper();
  await mapper.setInputConnection(input: output);
  await mapper.setScalarVisibility(false);

  final property = await session.createProperty();
  await property.setColor(VtkColor(red: 0.24, green: 0.72, blue: 0.96));
  await property.setOpacity(1);
  await property.setRepresentation(VtkRepresentation.surface);

  final actor = await session.createActor();
  await actor.setMapper(mapper);
  await actor.setProperty(property);

  final renderer = await session.createRenderer();
  await renderer.setBackground(VtkColor(red: 0.025, green: 0.035, blue: 0.055));
  await renderer.addActor(actor);

  final camera = await session.createCamera();
  await _configurePerspectiveCamera(
    renderer: renderer,
    camera: camera,
    azimuth: settings.azimuth,
    elevation: settings.elevation,
    zoom: settings.zoom,
  );
  return VtkRecipeScene(renderer: renderer, camera: camera);
}

double _scaledOpacity({required double base, required double scale}) =>
    (base * scale).clamp(0.0, 1.0);

Future<void> _configurePerspectiveCamera({
  required VtkRenderer renderer,
  required VtkCamera camera,
  required double azimuth,
  required double elevation,
  required double zoom,
}) async {
  await renderer.setActiveCamera(camera);
  await renderer.resetCamera();
  await camera.azimuth(azimuth);
  await camera.elevation(elevation);
  await camera.zoom(zoom);
}
