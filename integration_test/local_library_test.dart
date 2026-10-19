import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:simplefy/application/app_controller.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/infrastructure/local_music_library.dart';
import 'package:simplefy/main.dart' as ui;
import 'package:simplefy/presentation/library_screens.dart';

class OfflineNetwork implements NetworkMonitor {
  @override
  Future<NetworkKind> current() async => NetworkKind.offline;
  @override
  Stream<NetworkKind> get changes => const Stream.empty();
}

Uint8List silence() {
  const size = 8000 * 2 * 20;
  final data = ByteData(44 + size);
  void text(int at, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(at + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, 36 + size, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, size, Endian.little);
  return data.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'local-only playback restores folder chain, queue and exact saved position',
    (tester) async {
      final app = await ui.createController(network: OfflineNetwork());
      // Fixture setup, independent of the native document picker. Native copying
      // and metadata have separate XCTest coverage in RunnerTests.
      await app.store.deleteSession();
      const folder = LibraryItem(
        id: 'local:fixture:album',
        name: 'Fixture Album',
        kind: ItemKind.folder,
        parentId: 'local:root',
        path: 'local_music/fixture/Album',
      );
      const song = LibraryItem(
        id: 'local:fixture:song',
        name: 'Fixture song',
        kind: ItemKind.track,
        parentId: 'local:fixture:album',
        fileName: '01 - Silence.wav',
        artist: 'Fixture',
        durationMs: 20000,
        path: 'local_music/fixture/Album/01 - Silence.wav',
      );
      final file = File('${app.store.directory.path}/${song.path}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(silence());
      await app.store.write('local_music', {
        'items': [folder.toJson(), song.toJson()],
      });
      runApp(ui.SimplefyApp(app: app));
      await app.initialize();
      await app.audio.player.setVolume(0);
      Future<void> until(bool Function() condition) async {
        final limit = DateTime.now().add(const Duration(seconds: 40));
        while (!condition() && DateTime.now().isBefore(limit)) {
          await tester.pump(const Duration(milliseconds: 200));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(condition(), true);
        await tester.pump(const Duration(milliseconds: 600));
      }

      expect(app.loggedIn, false);
      expect(app.hasLibrary, true);
      await until(() => find.text('На устройстве').evaluate().isNotEmpty);
      await tester.tap(find.text('На устройстве').first);
      await until(() => find.text('Fixture Album').evaluate().isNotEmpty);
      await tester.tap(find.text('Fixture Album').first);
      await until(() => find.text(song.filenameTitle).evaluate().isNotEmpty);
      await tester.tap(find.text(song.filenameTitle).first);
      await until(() => app.isPlaying);
      expect(
        (app.audio.player.audioSource as UriAudioSource).uri.scheme,
        'file',
      );
      expect(app.queue.current!.track.id, song.id);
      expect(app.browse.path.map((e) => e.id), [
        LocalMusicLibrary.root.id,
        folder.id,
      ]);
      await app.seek(const Duration(milliseconds: 8375));
      await app.pause();
      await app.save();
      final position = app.position.inMilliseconds;
      expect(position, inInclusiveRange(8300, 9000));
      final store = app.store;
      final audio = app.audio;
      runApp(const SizedBox.shrink());
      await tester.pump();
      app.dispose();
      final restored = AppController(store, audio, network: OfflineNetwork());
      runApp(ui.SimplefyApp(app: restored));
      await restored.initialize();
      expect(restored.queue.current!.track.id, song.id);
      expect(restored.position.inMilliseconds, position);
      expect(restored.isPlaying, false);
      await until(() => find.text(song.filenameTitle).evaluate().isNotEmpty);
      expect(find.byType(LibraryScreen), findsOneWidget);
      await tester.timedDragFrom(
        const Offset(1, 300),
        const Offset(350, 0),
        const Duration(milliseconds: 350),
      );
      await until(() => restored.browse.path.length == 1);
      await tester.timedDragFrom(
        const Offset(1, 300),
        const Offset(350, 0),
        const Duration(milliseconds: 350),
      );
      await until(() => restored.browse.path.isEmpty);
      await restored.stop();
      await restored.removeImported(LocalMusicLibrary.root);
      expect(await file.exists(), false);
      expect(tester.takeException(), null);
      debugPrint('SIMPLEFY_LOCAL_LIBRARY_RESTORE_PASSED');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
