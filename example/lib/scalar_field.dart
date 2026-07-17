import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vtk_flutter/vtk_flutter.dart';

const int syntheticScalarMinimum = 0;
const int syntheticScalarMaximum = 4095;

/// Creates a compact, deterministic scalar field with several smooth features.
///
/// Values are stored x-fastest in a single-component unsigned 16-bit image.
/// The image origin is centered so camera and reslice examples can use world
/// coordinates around zero.
VtkScalarImageInput createSyntheticScalarField({VtkDimensions? dimensions}) {
  final size = dimensions ?? VtkDimensions(x: 64, y: 56, z: 48);
  final values = Uint16List(size.valueCount);

  for (var z = 0; z < size.z; z++) {
    final nz = _normalizedCoordinate(index: z, length: size.z);
    for (var y = 0; y < size.y; y++) {
      final ny = _normalizedCoordinate(index: y, length: size.y);
      for (var x = 0; x < size.x; x++) {
        final nx = _normalizedCoordinate(index: x, length: size.x);

        final mainFeature = math.exp(
          -3.4 *
              (math.pow((nx + 0.18) / 0.58, 2) +
                  math.pow((ny + 0.04) / 0.72, 2) +
                  math.pow((nz - 0.02) / 0.62, 2)),
        );
        final satellite =
            0.78 *
            math.exp(
              -11 *
                  (math.pow(nx - 0.62, 2) +
                      math.pow(ny + 0.28, 2) +
                      math.pow(nz - 0.12, 2)),
            );
        final ringRadius = math.sqrt(nx * nx + ny * ny);
        final ring =
            0.58 *
            math.exp(
              -34 * (math.pow(ringRadius - 0.48, 2) + math.pow(nz * 1.35, 2)),
            );
        final ripple =
            0.08 *
            (1 + math.sin(nx * 12) * math.cos(ny * 10) * math.cos(nz * 8)) /
            2;
        final normalized = math.max(
          satellite,
          math.max(ring, mainFeature + ripple * mainFeature),
        );
        final scalar = (normalized.clamp(0.0, 1.0) * syntheticScalarMaximum)
            .round();
        values[x + size.x * (y + size.y * z)] = scalar;
      }
    }
  }

  return VtkScalarImageInput(
    values: values,
    dimensions: size,
    origin: VtkVector3(
      x: -(size.x - 1) / 2,
      y: -(size.y - 1) / 2,
      z: -(size.z - 1) / 2,
    ),
  );
}

double _normalizedCoordinate({required int index, required int length}) =>
    length == 1 ? 0 : 2 * index / (length - 1) - 1;
