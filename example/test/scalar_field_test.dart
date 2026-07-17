import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/vtk_flutter.dart';
import 'package:vtk_flutter_example/scalar_field.dart';

void main() {
  test('creates a deterministic unsigned 16-bit scalar field', () {
    final dimensions = VtkDimensions(x: 18, y: 14, z: 10);
    final first = createSyntheticScalarField(dimensions: dimensions);
    final second = createSyntheticScalarField(dimensions: dimensions);

    expect(first.dimensions, dimensions);
    expect(first.scalarType, VtkScalarType.uint16);
    expect(first.componentCount, 1);
    expect(first.valueCount, dimensions.valueCount);
    expect(
      first.byteCount,
      dimensions.valueCount * VtkScalarType.uint16.bytesPerValue,
    );
    expect(first.bytes, orderedEquals(second.bytes));
  });

  test('fills the documented range with nontrivial spatial variation', () {
    final dimensions = VtkDimensions(x: 24, y: 20, z: 16);
    final field = createSyntheticScalarField(dimensions: dimensions);
    final values = Uint16List.view(field.bytes.buffer);
    final minimum = values.reduce((left, right) => left < right ? left : right);
    final maximum = values.reduce((left, right) => left > right ? left : right);
    final centerIndex =
        dimensions.x ~/ 2 +
        dimensions.x * (dimensions.y ~/ 2 + dimensions.y * (dimensions.z ~/ 2));

    expect(minimum, greaterThanOrEqualTo(syntheticScalarMinimum));
    expect(maximum, lessThanOrEqualTo(syntheticScalarMaximum));
    expect(minimum, lessThan(100));
    expect(maximum, greaterThan(3000));
    expect(values.toSet(), hasLength(greaterThan(100)));
    expect(values[centerIndex], greaterThan(values.first));
  });

  test('supports a one-sample axis accepted by VtkDimensions', () {
    final dimensions = VtkDimensions(x: 1, y: 3, z: 2);
    final field = createSyntheticScalarField(dimensions: dimensions);

    expect(field.valueCount, dimensions.valueCount);
    expect(
      Uint16List.view(field.bytes.buffer),
      everyElement(
        inInclusiveRange(syntheticScalarMinimum, syntheticScalarMaximum),
      ),
    );
  });
}
