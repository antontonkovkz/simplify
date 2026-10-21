import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simplefy/main.dart' as ui;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized()
      .platformDispatcher
      .localeTestValue = const Locale(
    'ru',
  );
  testWidgets(
    'native background audio, background download and converted APE',
    (tester) async {
      await ui.main();
      Future<void> until(bool Function() ready, {int seconds = 90}) async {
        final end = DateTime.now().add(Duration(seconds: seconds));
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 200));
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        expect(
          ready(),
          true,
          reason: 'Background integration checkpoint timed out',
        );
      }

      await until(() => find.byType(ui.SimplefyApp).evaluate().isNotEmpty);
      final app = tester
          .widget<ui.SimplefyApp>(find.byType(ui.SimplefyApp))
          .app;
      await until(() => app.initialized);
      if (app.loggedIn) await app.logout();
      await app.login(
        const String.fromEnvironment('TEST_SERVER'),
        const String.fromEnvironment('TEST_USERNAME'),
        const String.fromEnvironment('TEST_PASSWORD'),
      );
      await app.audio.player.setVolume(0);
      final collection = (await app.root(false)).first;
      final tracks = await app.tracks(collection);
      final track = tracks.firstWhere(
        (t) =>
            t.fileName.toLowerCase().endsWith('.flac') &&
            t.durationMs > 150000 &&
            t.durationMs < 300000,
      );
      await app.playTracks([track]);
      await until(
        () => app.isPlaying && app.audio.player.position.inMilliseconds > 500,
      );
      final start = app.audio.player.position;
      debugPrint('SIMPLEFY_BACKGROUND_AUDIO_BEGIN');
      expect(await app.notifications.openAppNotificationSettings(), true);
      await Future<void>.delayed(const Duration(seconds: 8));
      expect(app.isPlaying, true);
      expect(
        app.audio.player.position - start,
        greaterThan(const Duration(seconds: 4)),
      );
      debugPrint('SIMPLEFY_BACKGROUND_AUDIO_PASSED');
      await tester.pump(const Duration(seconds: 1));
      await app.pause();

      await app.downloads!.add(track);
      debugPrint('SIMPLEFY_BACKGROUND_DOWNLOAD_BEGIN');
      expect(await app.notifications.openAppNotificationSettings(), true);
      await Future<void>.delayed(const Duration(seconds: 8));
      debugPrint('SIMPLEFY_BACKGROUND_DOWNLOAD_RETURN');
      await until(() => app.downloads!.contains(track.id), seconds: 180);
      debugPrint('SIMPLEFY_BACKGROUND_DOWNLOAD_PASSED');
      await app.releaseLocalAudio();
      await app.downloads!.removeGroup(track.id);

      final ape = tracks
          .where((t) => t.fileName.toLowerCase().endsWith('.ape'))
          .firstOrNull;
      if (ape != null) {
        await app.playTracks([ape]);
        await until(
          () =>
              app.isPlaying && app.audio.player.position.inMilliseconds > 1000,
        );
        await app.seek(const Duration(seconds: 30));
        await until(() => app.audio.player.position.inSeconds >= 30);
        await app.pause();
        debugPrint('SIMPLEFY_APE_HLS_AND_SEEK_PASSED');
      }
      expect(tester.takeException(), null);
      await app.stop();
      await app.save();
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
