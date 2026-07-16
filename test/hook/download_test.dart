import 'dart:io';

import 'package:test/test.dart';

import '../../hook/src/download.dart';

void main() {
  late Directory temporaryDirectory;
  late HttpServer server;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'vtk-download-test-',
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
    await temporaryDirectory.delete(recursive: true);
  });

  test('streams a successful response into the destination', () async {
    server.listen((request) async {
      request.response.write('artifact bytes');
      await request.response.close();
    });
    final destination = _destination(temporaryDirectory);

    final result = await downloadFile(
      source: _serverUri(server),
      destination: destination,
      client: HttpClient(),
    );

    expect(await result.readAsString(), 'artifact bytes');
    expect(await File('${destination.path}.partial').exists(), isFalse);
  });

  test('rejects non-success responses and removes partial files', () async {
    server.listen((request) async {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    final destination = _destination(temporaryDirectory);

    await expectLater(
      downloadFile(
        source: _serverUri(server),
        destination: destination,
        client: HttpClient(),
      ),
      throwsA(isA<HttpException>()),
    );
    expect(await destination.exists(), isFalse);
    expect(await File('${destination.path}.partial').exists(), isFalse);
  });

  test('requires HTTPS for the production client', () async {
    await expectLater(
      downloadFile(
        source: _serverUri(server),
        destination: _destination(temporaryDirectory),
      ),
      throwsArgumentError,
    );
  });
}

File _destination(Directory temporaryDirectory) =>
    File('${temporaryDirectory.path}${Platform.pathSeparator}artifact.zip');

Uri _serverUri(HttpServer server) =>
    Uri.parse('http://${server.address.address}:${server.port}/artifact.zip');
