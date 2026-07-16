import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vtk_flutter/vtk_flutter.dart';
import 'package:vtk_flutter_example/main.dart';
import 'package:vtk_flutter_example/synthetic_volume.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opens the renderer lab and reports native capability', (
    tester,
  ) async {
    await tester.pumpWidget(const RendererLabApp());
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(find.text('vtk_flutter renderer lab'), findsOneWidget);
    final capabilities = await VtkRenderer().capabilities();
    expect(capabilities.renderModes, isNotEmpty);
  });

  testWidgets('renders every native mode and survives lifecycle operations', (
    tester,
  ) async {
    final renderer = VtkRenderer();
    final capabilities = await renderer.capabilities();
    expect(capabilities.renderModes, containsAll(VtkRenderMode.values));

    final session = await renderer.open(VtkViewport(width: 192, height: 160));
    addTearDown(session.close);
    final volume = createSyntheticVolume();
    await session.setVolume(volume);

    final requests = <VtkRenderRequest>[
      VtkObliqueMprRequest(
        windowCenter: 350,
        windowWidth: 1800,
        origin: const [0, 0, 0],
        normal: const [0, 0.3, 1],
      ),
      VtkVolume3dRequest(
        windowCenter: 350,
        windowWidth: 1800,
        azimuth: 35,
        elevation: 20,
        zoom: 1.35,
      ),
      VtkVolumeLocatorRequest(azimuth: 35, elevation: 20, zoom: 1.35),
    ];

    for (final request in requests) {
      final metrics = await session.render(request);
      expect(metrics.width, 192);
      expect(metrics.height, 160);
      expect(metrics.volumeBytes, volume.byteCount);
      expect(metrics.frameId, greaterThan(0));
      expect(metrics.residentBytes, greaterThan(metrics.volumeBytes));
      expect(metrics.handoffMode, 'iosurface_opengl_blit');
    }

    await session.resize(VtkViewport(width: 160, height: 128));
    final resized = await session.render(requests.last);
    expect((resized.width, resized.height), (160, 128));

    final generation = await session.recreateGraphicsContext();
    expect(generation, greaterThan(1));
    await session.setVolume(createSyntheticVolume(markerOffset: 7));
    final replaced = await session.render(requests.last);
    expect(replaced.frameId, greaterThan(resized.frameId));
    expect(replaced.patientToClip, hasLength(16));
  });
}
