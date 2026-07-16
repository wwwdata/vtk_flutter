import 'dart:io';

Future<File> downloadFile({
  required Uri source,
  required File destination,
  HttpClient? client,
}) async {
  if (source.scheme != 'https' && client == null) {
    throw ArgumentError.value(source, 'source', 'must use HTTPS');
  }

  final ownsClient = client == null;
  final httpClient = client ?? HttpClient();
  final partial = File('${destination.path}.partial');
  await destination.parent.create(recursive: true);
  if (await partial.exists()) await partial.delete();

  try {
    final request = await httpClient.getUrl(source);
    request
      ..followRedirects = true
      ..maxRedirects = 5
      ..headers.set(HttpHeaders.userAgentHeader, 'vtk_flutter-build-hook');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'Download failed with HTTP ${response.statusCode}',
        uri: source,
      );
    }

    final sink = partial.openWrite();
    try {
      await response.pipe(sink);
    } on Object {
      await sink.close();
      rethrow;
    }

    if (await destination.exists()) await destination.delete();
    return partial.rename(destination.path);
  } on Object {
    if (await partial.exists()) await partial.delete();
    rethrow;
  } finally {
    if (ownsClient) httpClient.close(force: true);
  }
}
