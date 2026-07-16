import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../vtk_flutter_web.dart';
import 'renderer.dart';

final class VtkView extends StatelessWidget {
  const VtkView({
    required this.session,
    this.filterQuality = FilterQuality.medium,
    super.key,
  });

  final VtkRenderSession session;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Uint8List?>(
    valueListenable: VtkFlutterWeb.imageFor(session.textureId),
    builder: (context, bytes, _) {
      if (bytes == null) return const SizedBox.expand();
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        filterQuality: filterQuality,
        gaplessPlayback: true,
      );
    },
  );
}
