import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:simplefy/l10n/l10n.dart';
import 'package:simplefy/infrastructure/music_audio_handler.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/playback_activity.dart';
import 'package:simplefy/presentation/shuffle_button.dart';
import 'compact_ui_test.dart' show TestApp, FixtureAudio;
import 'automatic_shuffle_test.dart' show EventPlayer;

class ActivityApp extends TestApp {
  ActivityApp(this.player);
  final EventPlayer player;
  late final _audio = FixtureAudio(player);
  @override
  MusicAudioHandler get audio => _audio;
  bool intent = true, waiting = false, loaded = true;
  @override
  bool get wantsPlayback => intent;
  @override
  bool get hasLoadedCurrent => loaded;
  @override
  bool get waitingForNetwork => waiting;
  @override
  String? get status => null;
}

void main() {
  Future<void> mount(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: SimplefyTheme.dark,
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: child),
    ),
  );

  testWidgets(
    'shuffle changes icon, selected appearance and semantics in both directions',
    (tester) async {
      final app = TestApp();
      addTearDown(app.dispose);
      await mount(tester, ShuffleButton(app: app));
      expect(find.byTooltip('In order'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_downward_rounded), findsOneWidget);
      final before = tester.widget<IconButton>(find.byType(IconButton));
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(app.queue.shuffled, true);
      expect(find.byTooltip('Shuffle'), findsOneWidget);
      expect(find.byIcon(Icons.shuffle_rounded), findsOneWidget);
      final after = tester.widget<IconButton>(find.byType(IconButton));
      expect(after.isSelected, true);
      expect(
        after.style!.backgroundColor!.resolve({}),
        isNot(before.style!.backgroundColor!.resolve({})),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(app.queue.shuffled, false);
      expect(find.byIcon(Icons.arrow_downward_rounded), findsOneWidget);
    },
  );

  testWidgets(
    'loading, buffering and network wait visible; ready or pause hides indicator',
    (tester) async {
      final player = EventPlayer();
      final app = ActivityApp(player);
      addTearDown(() async {
        app.dispose();
        await player.close();
      });
      await mount(tester, PlaybackActivity(app: app));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      player.emit(ProcessingState.buffering);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Loading audio…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      player.emit(ProcessingState.ready);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      app.waiting = true;
      app.notifyListeners();
      await tester.pump();
      expect(find.text('Waiting for a connection'), findsOneWidget);
      app.waiting = false;
      app.loaded = false;
      app.notifyListeners();
      await tester.pump();
      expect(find.text('Loading audio…'), findsOneWidget);
      app.intent = false;
      app.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );
}
