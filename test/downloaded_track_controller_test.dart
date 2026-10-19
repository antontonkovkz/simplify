import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/app_controller.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/infrastructure/local_store.dart';
import 'compact_ui_test.dart' show songs;
import 'downloaded_tracks_ui_test.dart' show DownloadFiles;
import 'playlist_edit_controller_test.dart' show IdleAudio;

class FileRemovalApp extends AppController {
  FileRemovalApp() : super(LocalStore(Directory.systemTemp), IdleAudio());
  int releases = 0;
  Completer<void>? releaseGate;
  @override
  bool get loggedIn => true;
  @override
  Future<void> releaseLocalAudio() async {
    releases++;
    await releaseGate?.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'only deleting the current song releases its audio; queue is preserved',
    () async {
      final app = FileRemovalApp();
      final files = DownloadFiles();
      app.downloads = files;
      app.queue.replace(songs);
      final queue = app.queue.entries;
      try {
        await app.removeDownloadedTrack(songs[1]);
        expect(app.releases, 0);
        await app.removeDownloadedTrack(songs[0]);
        expect(app.releases, 1);
        expect(files.removed, [songs[1].id, songs[0].id]);
        expect(app.queue.entries, same(queue));
      } finally {
        app.dispose();
      }
    },
  );
  test('account change while releasing audio cancels file deletion', () async {
    final app = FileRemovalApp();
    final files = DownloadFiles();
    app.downloads = files;
    app.queue.replace(songs);
    app.releaseGate = Completer<void>();
    try {
      final removal = app.removeDownloadedTrack(songs[0]);
      final rejected = expectLater(removal, throwsA(isA<AppFailure>()));
      app.downloads = DownloadFiles();
      app.releaseGate!.complete();
      await rejected;
      expect(files.removed, isEmpty);
    } finally {
      files.dispose();
      app.dispose();
    }
  });
}
