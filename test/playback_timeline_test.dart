import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/l10n/l10n.dart';
import 'package:simplefy/infrastructure/music_audio_handler.dart';
import 'package:simplefy/presentation/playback_timeline.dart';
import 'compact_ui_test.dart' show TestApp, FixturePlayer, FixtureAudio;

class PositionPlayer extends FixturePlayer {
  Duration current = const Duration(seconds: 20);
  Duration? length;
  final positions = StreamController<Duration>.broadcast();
  final durations = StreamController<Duration?>.broadcast();
  @override
  Duration get position => current;
  @override
  Duration? get duration => length;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  Future<void> close() async {
    await positions.close();
    await durations.close();
  }
}

class TimelineApp extends TestApp {
  TimelineApp(this.player) {
    queue.replace([
      const LibraryItem(
        id: 'a',
        name: 'A',
        kind: ItemKind.track,
        durationMs: 180000,
      ),
      const LibraryItem(
        id: 'b',
        name: 'B',
        kind: ItemKind.track,
        durationMs: 180000,
      ),
    ]);
  }
  final PositionPlayer player;
  late final _audio = FixtureAudio(player);
  @override
  MusicAudioHandler get audio => _audio;
  bool loaded = true;
  Duration restored = const Duration(seconds: 50);
  @override
  bool get hasLoadedCurrent => loaded;
  @override
  Duration get position => loaded ? player.position : restored;
  final seeks = <Duration>[];
  Completer<void>? seekGate;
  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    await seekGate?.future;
    player.current = value;
    player.positions.add(value);
    notifyListeners();
  }
}

void main() {
  late PositionPlayer player;
  late TimelineApp app;
  setUp(() {
    player = PositionPlayer();
    app = TimelineApp(player);
  });
  tearDown(() async {
    app.dispose();
    await player.close();
  });
  Future<void> mount(WidgetTester tester, {bool compact = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: PlaybackTimeline(app: app, compact: compact),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'position and duration update independently while keeping the slider usable',
    (tester) async {
      await mount(tester);
      expect(find.text('0:20'), findsOneWidget);
      expect(find.text('3:00'), findsOneWidget);
      player.length = const Duration(minutes: 4);
      player.durations.add(player.length);
      await tester.pumpAndSettle();
      expect(find.text('4:00'), findsOneWidget);
      player.current = const Duration(seconds: 45);
      player.positions.add(player.current);
      await tester.pumpAndSettle();
      expect(find.text('0:45'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).max, 240000);
    },
  );
  testWidgets(
    'compact timeline seeks on tap and keeps paused playback paused',
    (tester) async {
      await mount(tester, compact: true);
      await tester.tap(find.byType(Slider));
      await tester.pumpAndSettle();
      expect(app.seeks, hasLength(1));
      expect(app.seeks.single.inSeconds, closeTo(90, 2));
      expect(app.isPlaying, false);
    },
  );
  testWidgets('drag previews time and commits seek only on release', (
    tester,
  ) async {
    await mount(tester);
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(20000);
    slider.onChanged!(90000);
    await tester.pump();
    expect(find.text('1:30'), findsOneWidget);
    expect(app.seeks, isEmpty);
    slider.onChangeEnd!(90000);
    await tester.pumpAndSettle();
    expect(app.seeks, [const Duration(seconds: 90)]);
  });
  testWidgets('an older seek completion does not clear a newer drag preview', (
    tester,
  ) async {
    await mount(tester);
    app.seekGate = Completer<void>();
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(20000);
    slider.onChanged!(90000);
    slider.onChangeEnd!(90000);
    slider.onChangeStart!(90000);
    slider.onChanged!(120000);
    await tester.pump();
    app.seekGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('2:00'), findsOneWidget);
    expect(app.seeks, [const Duration(seconds: 90)]);
  });

  testWidgets('release from an old occurrence cannot seek the new song', (
    tester,
  ) async {
    await mount(tester);
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(20000);
    slider.onChanged!(90000);
    app.queue.next();
    app.notifyListeners();
    await tester.pump();
    slider.onChangeEnd!(90000);
    await tester.pumpAndSettle();
    expect(app.seeks, isEmpty);
    expect(find.text('1:30'), findsNothing);
  });
  testWidgets(
    'restored unloaded position uses saved playhead and unknown duration disables seeking',
    (tester) async {
      app.loaded = false;
      await mount(tester);
      expect(find.text('0:50'), findsOneWidget);
      app.queue.replace([
        const LibraryItem(id: 'unknown', name: 'Unknown', kind: ItemKind.track),
      ]);
      app.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('--:--'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    },
  );
}
