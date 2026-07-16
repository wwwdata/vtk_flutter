import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter_example/synthetic_volume.dart';

void main() {
  test('creates a deterministic x-fastest signed-int16 phantom', () {
    final first = createSyntheticVolume();
    final second = createSyntheticVolume();

    expect(first.dimensions, [96, 80, 64]);
    expect(first.byteCount, 96 * 80 * 64 * 2);
    expect(first.affine, hasLength(16));
    expect(first.data, orderedEquals(second.data));

    final values = Int16List.view(first.data.buffer);
    expect(values.toSet().length, greaterThanOrEqualTo(4));
    expect(values, contains(-1000));
    expect(values, contains(1750));
  });

  test('can replace the asymmetric marker without changing metadata', () {
    final first = createSyntheticVolume();
    final shifted = createSyntheticVolume(markerOffset: 7);

    expect(shifted.dimensions, first.dimensions);
    expect(shifted.affine, first.affine);
    expect(shifted.data, isNot(orderedEquals(first.data)));
  });
}
