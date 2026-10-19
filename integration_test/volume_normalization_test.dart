import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simplefy/application/app_controller.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/volume_normalization.dart';
import 'package:simplefy/main.dart' as ui;
import 'package:simplefy/presentation/settings_screen.dart';
import 'package:simplefy/presentation/widgets.dart';

import 'local_library_test.dart' show OfflineNetwork, silence;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'normalization defaults on, applies per source, settings persist offline',
    (tester) async {
      final app = await ui.createController(network: OfflineNetwork());
      await app.store.deleteSession();
      await app.store.write('state_local', {});
      const a = LibraryItem(
        id: 'local:gain:a',
        parentId: 'local:root',
        name: 'Gain A',
        artist: 'Fixture',
        kind: ItemKind.track,
        path: 'local_music/gain/A.wav',
        fileName: 'A.wav',
        normalizationGainDb: -6,
        albumNormalizationGainDb: -12,
      );
      const b = LibraryItem(
        id: 'local:gain:b',
        parentId: 'local:root',
        name: 'Gain B',
        artist: 'Fixture',
        kind: ItemKind.track,
        path: 'local_music/gain/B.wav',
        fileName: 'B.wav',
      );
      for (final track in [a, b]) {
        final file = File('${app.store.directory.path}/${track.path}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(silence());
      }
      await app.store.write('local_music', {
        'items': [a.toJson(), b.toJson()],
      });
      runApp(ui.SimplefyApp(app: app));
      await app.initialize();
      Future<void> until(bool Function() ready) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!ready() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
        expect(ready(), true);
        await tester.pump(const Duration(milliseconds: 300));
      }

      expect(app.normalizationMode, VolumeNormalizationMode.track);
      await app.playTracks([a, b]);
      await until(() => app.isPlaying);
      expect(app.audio.player.volume, closeTo(0.501187, 0.000001));
      final entry = app.queue.current!.id;
      Navigator.of(
        tester.element(find.byType(Scaffold).first),
      ).push(slideRoute(SettingsScreen(app: app)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Выравнивание громкости'));
      await tester.pumpAndSettle();
      expect(find.text('Выключено'), findsOneWidget);
      expect(find.text('По альбомам'), findsOneWidget);
      await tester.tap(find.text('По альбомам'));
      await until(
        () =>
            app.normalizationMode == VolumeNormalizationMode.album &&
            (app.audio.player.volume - 0.251189).abs() < 0.000001,
      );
      expect(app.queue.current!.id, entry);
      expect(app.isPlaying, true);
      await tester.tap(find.text('Выравнивание громкости'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Выключено'));
      await until(
        () =>
            app.normalizationMode == VolumeNormalizationMode.off &&
            app.audio.player.volume == 1,
      );
      expect(app.queue.current!.id, entry);
      await app.next(false);
      expect(app.audio.player.volume, 1);
      await app.setVolumeNormalization(VolumeNormalizationMode.track);
      expect(
        app.audio.player.volume,
        1,
        reason: 'Unknown gain resets previous attenuation',
      );
      await app.previous();
      expect(app.audio.player.volume, closeTo(0.501187, 0.000001));
      await app.setVolumeNormalization(VolumeNormalizationMode.album);
      await app.pause();
      await app.save();
      final store = app.store;
      final audio = app.audio;
      runApp(const SizedBox.shrink());
      await tester.pump();
      app.dispose();
      final restored = AppController(store, audio, network: OfflineNetwork());
      runApp(ui.SimplefyApp(app: restored));
      await restored.initialize();
      expect(restored.normalizationMode, VolumeNormalizationMode.album);
      expect(restored.queue.current!.track.albumNormalizationGainDb, -12);
      await restored.resume();
      expect(restored.audio.player.volume, closeTo(0.251189, 0.000001));
      await restored.setVolumeNormalization(VolumeNormalizationMode.off);
      await restored.pause();
      expect((await store.read('state_local'))['volumeNormalization'], 'off');
      expect(restored.audio.player.volume, 1);
      expect(tester.takeException(), null);
      await restored.stop();
      debugPrint('SIMPLEFY_VOLUME_NORMALIZATION_PASSED');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
