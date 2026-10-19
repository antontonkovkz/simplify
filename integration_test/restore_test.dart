import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simplefy/main.dart' as ui;
import 'package:simplefy/application/app_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('a fresh coordinator restores persisted queue without autoplay', (
    tester,
  ) async {
    await ui.main();
    await tester.pump();
    final app = tester.widget<ui.SimplefyApp>(find.byType(ui.SimplefyApp)).app;
    final end = DateTime.now().add(const Duration(seconds: 45));
    while (!app.initialized && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    expect(
      app.loggedIn,
      true,
      reason:
          'Run the main integration test first to create the Keychain session',
    );
    final playlist = (await app.root(true)).first;
    final tracks = await app.tracks(playlist);
    app.setBrowse(1, [playlist]);
    app.queue.replace(tracks, start: 1);
    await app.seek(const Duration(seconds: 8));
    await app.pause();
    await app.save();
    runApp(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 350));
    final store = app.store;
    final audio = app.audio;
    app.dispose();
    final restored = AppController(store, audio);
    runApp(ui.SimplefyApp(app: restored));
    await restored.initialize();
    expect(restored.queue.entries.length, tracks.length);
    expect(restored.queue.current?.track.id, tracks[1].id);
    expect(restored.isPlaying, false);
    expect(restored.browse.tab, 1);
    expect(restored.browse.path.single.id, playlist.id);
    expect(restored.position.inSeconds, inInclusiveRange(7, 10));
    expect(
      restored.audio.playbackState.value.updatePosition.inSeconds,
      inInclusiveRange(7, 10),
    );
    expect(
      restored.audio.mediaItem.value?.title,
      restored.queue.current!.track.title,
    );
  });
}
