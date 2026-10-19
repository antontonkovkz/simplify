import 'package:flutter/material.dart';
import 'dart:io';
import 'package:simplefy/main.dart' as ui;

/// Developer-only process-restart probe. Uses the existing Keychain session;
/// contains no credentials and is never the target of the normal app build.
Future<void> main() async {
  final app = await ui.createController();
  runApp(ui.SimplefyApp(app: app));
  await app.initialize();
  if (!app.loggedIn) {
    debugPrint('SIMPLEFY_RESTORE_PROBE_NEEDS_LOGIN');
    return;
  }
  if (app.queue.entries.isEmpty) {
    final tracks = await app.tracks((await app.root(true)).first);
    app.queue.replace(tracks, start: 1);
    await app.seek(const Duration(seconds: 8));
    await app.pause();
    await app.save();
    await File(
      '${app.store.directory.path}/restore-probe-result.txt',
    ).writeAsString('SIMPLEFY_RESTORE_PROBE_SEEDED');
    debugPrint('SIMPLEFY_RESTORE_PROBE_SEEDED');
  } else {
    final correct =
        !app.isPlaying &&
        app.position.inSeconds == 8 &&
        app.audio.playbackState.value.updatePosition.inSeconds == 8;
    final result = correct
        ? 'SIMPLEFY_RESTORE_PROBE_PASSED'
        : 'SIMPLEFY_RESTORE_PROBE_FAILED';
    await File(
      '${app.store.directory.path}/restore-probe-result.txt',
    ).writeAsString(result);
    debugPrint(result);
  }
}
