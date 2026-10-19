import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simplefy/main.dart' as ui;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'server-converted APE can play and seek on iOS',
    (tester) async {
      await ui.main();
      await tester.pump();
      final app = tester
          .widget<ui.SimplefyApp>(find.byType(ui.SimplefyApp))
          .app;
      Future<void> until(bool Function() ready) async {
        final end = DateTime.now().add(const Duration(seconds: 45));
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 200));
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        expect(ready(), true, reason: 'Converted audio did not advance');
      }

      await until(() => app.initialized);
      expect(app.loggedIn, true);
      await app.audio.player.setVolume(0);
      final tracks = await app.tracks((await app.root(false)).first);
      final ape = tracks.firstWhere(
        (t) => t.fileName.toLowerCase().endsWith('.ape'),
      );
      await app.playTracks([ape]);
      await until(
        () => app.isPlaying && app.audio.player.position.inMilliseconds > 1000,
      );
      await app.seek(const Duration(seconds: 30));
      await until(() => app.audio.player.position.inSeconds >= 30);
      await app.stop();
      expect(tester.takeException(), null);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
