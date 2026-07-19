import 'package:flutter/widgets.dart';

import 'api/vtk_api.dart';
import 'web/vtk_web_frame_store.dart';

final class VtkView extends StatefulWidget {
  const VtkView({
    required this.session,
    this.filterQuality = FilterQuality.medium,
    this.onFramePresented,
    super.key,
  });

  final VtkSession session;
  final FilterQuality filterQuality;
  final VoidCallback? onFramePresented;

  @override
  State<VtkView> createState() => _VtkViewState();
}

final class _VtkViewState extends State<VtkView> {
  var _notificationScheduled = false;
  var _notified = false;

  @override
  void didUpdateWidget(VtkView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.viewId != widget.session.viewId ||
        oldWidget.onFramePresented != widget.onFramePresented) {
      _notificationScheduled = false;
      _notified = false;
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<VtkWebFrame?>(
    valueListenable: VtkWebFrameStore.frameFor(widget.session.viewId),
    builder: (context, frame, _) {
      if (frame == null) return const SizedBox.expand();
      return Image.memory(
        frame.pngBytes,
        fit: BoxFit.contain,
        filterQuality: widget.filterQuality,
        gaplessPlayback: true,
        frameBuilder: (context, child, frameNumber, wasSynchronouslyLoaded) {
          if (frameNumber != null || wasSynchronouslyLoaded) {
            _schedulePresentationNotification();
          }
          return child;
        },
      );
    },
  );

  void _schedulePresentationNotification() {
    final callback = widget.onFramePresented;
    if (callback == null || _notificationScheduled || _notified) return;
    _notificationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationScheduled = false;
      if (!mounted || _notified) return;
      _notified = true;
      callback();
    });
  }
}
