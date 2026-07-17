import 'package:test/test.dart';

import '../../tool/generate_native_licenses.dart';

void main() {
  group('nativeLicenseInventoryMatches', () {
    test('accepts a CRLF Git checkout of canonical LF content', () {
      expect(
        nativeLicenseInventoryMatches(
          existing: 'first\r\nsecond\r\n',
          generated: 'first\nsecond\n',
        ),
        isTrue,
      );
    });

    test('rejects content changes after newline normalization', () {
      expect(
        nativeLicenseInventoryMatches(
          existing: 'first\r\nchanged\r\n',
          generated: 'first\nsecond\n',
        ),
        isFalse,
      );
    });
  });
}
