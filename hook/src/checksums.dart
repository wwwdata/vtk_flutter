import 'dart:io';

import 'package:crypto/crypto.dart';

String checksumForArtifact({
  required String manifest,
  required String artifactName,
}) {
  final matches = <String>[];
  final gnuPattern = RegExp(r'^([a-fA-F0-9]{64})[ \t]+\*?(.+?)\s*$');
  final bsdPattern = RegExp(
    r'^SHA256 \((.+)\) = ([a-fA-F0-9]{64})\s*$',
    caseSensitive: false,
  );

  for (final line in manifest.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    final gnuMatch = gnuPattern.firstMatch(line);
    if (gnuMatch != null && gnuMatch.group(2) == artifactName) {
      matches.add(gnuMatch.group(1)!.toLowerCase());
      continue;
    }

    final bsdMatch = bsdPattern.firstMatch(trimmed);
    if (bsdMatch != null && bsdMatch.group(1) == artifactName) {
      matches.add(bsdMatch.group(2)!.toLowerCase());
    }
  }

  if (matches.isEmpty) {
    throw FormatException(
      'Checksum manifest has no SHA-256 entry for $artifactName.',
    );
  }
  if (matches.length != 1) {
    throw FormatException(
      'Checksum manifest has multiple SHA-256 entries for $artifactName.',
    );
  }
  return matches.single;
}

Future<void> verifySha256({
  required File file,
  required String expectedChecksum,
}) async {
  final normalizedExpected = expectedChecksum.toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalizedExpected)) {
    throw FormatException('Invalid expected SHA-256: $expectedChecksum.');
  }

  final actualChecksum = (await sha256.bind(file.openRead()).first).toString();
  if (actualChecksum != normalizedExpected) {
    throw StateError(
      'SHA-256 verification failed for ${file.path}: expected '
      '$normalizedExpected, found $actualChecksum.',
    );
  }
}
