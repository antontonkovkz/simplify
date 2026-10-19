import '../application/app_controller.dart';

String queueSourceLabel(AppController app) {
  final local = app.loadedLocalPlaylist;
  final server = app.serverPlaylist.item;
  return local != null
      ? 'Локальный плейлист «${local.name}»'
      : server != null
      ? 'Из «${server.name}»'
      : 'Текущая очередь';
}

String queuePositionLabel(AppController app) {
  final index = app.queue.currentIndex;
  return index < 0
      ? 'Доигрывает вне очереди'
      : '${index + 1} из ${app.queue.entries.length}';
}
