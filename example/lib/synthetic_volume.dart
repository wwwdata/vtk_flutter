import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vtk_flutter/vtk_flutter.dart';

VtkVolume createSyntheticVolume({int markerOffset = 0}) {
  const width = 96;
  const height = 80;
  const depth = 64;
  final bytes = Uint8List(width * height * depth * 2);
  final values = ByteData.sublistView(bytes);

  for (var z = 0; z < depth; z++) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final dx = (x - 47.5) / 39;
        final dy = (y - 39.5) / 31;
        final dz = (z - 31.5) / 25;
        final radius = dx * dx + dy * dy + dz * dz;
        var value = -1000;
        if (radius < 1) value = 40;
        if (radius < 0.58) value = 280;
        if (radius < 0.18) value = 950;

        final marker =
            math.pow((x - 68 - markerOffset) / 6, 2) +
            math.pow((y - 29) / 5, 2) +
            math.pow((z - 39) / 8, 2);
        if (marker < 1) value = 1750;

        final index = x + width * (y + height * z);
        values.setInt16(index * 2, value, Endian.little);
      }
    }
  }

  return VtkVolume(
    data: bytes,
    dimensions: const [width, height, depth],
    affine: const [
      0.8,
      0,
      0,
      -38.4,
      0,
      0.8,
      0,
      -32,
      0,
      0,
      1.2,
      -38.4,
      0,
      0,
      0,
      1,
    ],
  );
}
