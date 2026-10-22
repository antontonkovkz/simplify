import 'package:flutter/widgets.dart';
import '../l10n/l10n.dart';
import '../application/app_controller.dart';

String queueSourceLabel(BuildContext context, AppController app) {
  final local = app.loadedLocalPlaylist;
  final server = app.serverPlaylist.item;
  return local != null
      ? context.l10n.localPlaylist2((local.displayName).toString())
      : server != null
      ? context.l10n.from((server.displayName).toString())
      : context.l10n.currentQueue;
}

String queuePositionLabel(BuildContext context, AppController app) {
  final index = app.queue.currentIndex;
  return index < 0
      ? context.l10n.finishingOutsideTheQueue
      : context.l10n.of2(
          (index + 1).toString(),
          (app.queue.entries.length).toString(),
        );
}
