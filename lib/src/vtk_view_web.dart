import 'package:flutter/widgets.dart';

import 'api/vtk_api.dart';
import 'web/vtk_web_frame_store.dart';

final class VtkView extends StatelessWidget {
  const VtkView({
    required this.session,
    this.filterQuality = FilterQuality.medium,
    super.key,
  });

  final VtkSession session;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<VtkWebFrame?>(
    valueListenable: VtkWebFrameStore.frameFor(session.viewId),
    builder: (context, frame, _) {
      if (frame == null) return const SizedBox.expand();
      return Image.memory(
        frame.pngBytes,
        fit: BoxFit.contain,
        filterQuality: filterQuality,
        gaplessPlayback: true,
      );
    },
  );
}
