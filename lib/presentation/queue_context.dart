import '../l10n/l10n.dart';
import '../application/app_controller.dart';

String queueSourceLabel(AppController app) {
  final local = app.loadedLocalPlaylist;
  final server = app.serverPlaylist.item;
  return local != null
      ? L10n.current.localPlaylist2((local.displayName).toString())
      : server != null
      ? L10n.current.from((server.displayName).toString())
      : L10n.current.currentQueue;
}

String queuePositionLabel(AppController app) {
  final index = app.queue.currentIndex;
  return index < 0
      ? L10n.current.finishingOutsideTheQueue
      : L10n.current.of2(
          (index + 1).toString(),
          (app.queue.entries.length).toString(),
        );
}
