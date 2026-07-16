import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vtk_flutter/vtk_flutter.dart';
import 'package:vtk_flutter/vtk_flutter_platform_interface.dart';

void main() {
  testWidgets('shows the session texture on native Flutter', (tester) async {
    final platform = _ViewPlatform();
    final session = await VtkRenderer(
      platform: platform,
    ).open(VtkViewport(width: 640, height: 320));

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: VtkView(session: session),
      ),
    );

    final texture = tester.widget<Texture>(find.byType(Texture));
    expect(texture.textureId, 73);
    expect(texture.filterQuality, FilterQuality.medium);
    await session.close();
  });
}

final class _ViewPlatform extends VtkFlutterPlatform {
  @override
  Future<int> createSession(VtkViewport viewport) async => 73;

  @override
  Future<void> disposeSession() async {}
}
