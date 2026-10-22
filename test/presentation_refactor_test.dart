import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/domain/download_group.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/queue_engine.dart';
import 'package:simplefy/domain/track_search_index.dart';
import 'package:simplefy/l10n/l10n.dart';
import 'package:simplefy/presentation/actions.dart';
import 'package:simplefy/presentation/login_screen.dart';
import 'package:simplefy/presentation/widgets.dart';
import 'compact_ui_test.dart' show TestApp, folder;
import 'package:simplefy/presentation/library_screens.dart';

LibraryItem song(String id, {int duration = 1000}) => LibraryItem(
  id: id,
  name: id,
  kind: ItemKind.track,
  durationMs: duration,
  artist: 'Artist',
  fileName: '$id.flac',
);

class CountedTrack extends LibraryItem {
  CountedTrack(String id) : super(id: id, name: id, kind: ItemKind.track);
  static int reads = 0;
  @override
  String get id {
    reads++;
    return super.id;
  }
}

class LargeLibraryApp extends TestApp {
  final items = List<LibraryItem>.generate(
    10000,
    (i) => CountedTrack('track-$i'),
  );
  @override
  Future<List<LibraryItem>> children(LibraryItem item) async => items;
  @override
  Future<List<LibraryItem>> root(bool playlists) async => items;
}

void main() {
  test('duration follows edits, unknown metadata and restored queues', () {
    final queue = QueueEngine()..replace([song('a'), song('b')]);
    expect(queue.totalDuration, const Duration(seconds: 2));
    queue.next();
    expect(queue.totalDuration, const Duration(seconds: 2));
    queue.append([song('c', duration: 0)]);
    expect(queue.totalDuration, isNull);
    queue.remove(queue.entries.last.id);
    expect(queue.totalDuration, const Duration(seconds: 2));
    queue.restore({});
    expect(queue.totalDuration, isNull);
  });

  test(
    'download changes preserve occurrence counts and unique removal IDs',
    () {
      final source = song('source');
      final before = DownloadGroup(
        source: source,
        tracks: [song('a'), song('a'), song('b')],
      );
      final after = DownloadGroup(
        source: source,
        tracks: [song('b'), song('c'), song('c')],
      );
      final change = DownloadChange(before, after);
      expect(change.added, 2);
      expect(change.removed, 2);
      expect(change.removedIds, {'a'});
    },
  );

  test('download reconciliation is linear for 10000 changed tracks', () {
    final before = DownloadGroup(
      source: song('source'),
      tracks: List.generate(10000, (i) => CountedTrack('before-$i')),
    );
    final after = DownloadGroup(
      source: song('source'),
      tracks: List.generate(10000, (i) => CountedTrack('after-$i')),
    );
    final change = DownloadChange(before, after);
    CountedTrack.reads = 0;
    expect(change.added, 10000);
    expect(change.removed, 10000);
    expect(change.removedIds, hasLength(10000));
    expect(CountedTrack.reads, lessThanOrEqualTo(70000));
  });

  test(
    'worker reuses normalized index and preserves duplicate occurrences',
    () async {
      final first = song('Alpha');
      final second = song('Alpha');
      final index = TrackSearchIndex([
        first,
        song('Beta'),
        second,
        ...List.generate(100, (i) => song('other-$i')),
      ]);
      try {
        final results = await index.find(' ALPHA ');
        expect(results, [first, second]);
        expect(identical(results.first, first), isTrue);
        expect(await index.find('beta'), hasLength(1));
        expect(await index.find('missing'), isEmpty);
      } finally {
        index.dispose();
      }
      expect(await index.find('alpha'), isEmpty);
    },
  );

  test('disposing a starting search completes pending callers', () async {
    final index = TrackSearchIndex(List.generate(100, (i) => song('$i')));
    final result = index.find('a');
    index.dispose();
    expect(await result, isEmpty);
  });

  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('login groups autofill and warns only for HTTP', (tester) async {
    final app = TestApp();
    await mount(tester, LoginScreen(app: app));
    expect(find.byType(AutofillGroup), findsOneWidget);
    final server = find.byType(TextField).first;
    await tester.enterText(server, 'http://example.com');
    await tester.pumpAndSettle();
    expect(find.textContaining('without encryption'), findsOneWidget);
    await tester.enterText(server, 'https://example.com');
    await tester.pumpAndSettle();
    expect(find.textContaining('without encryption'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('login meets labelled target and Android target guidelines', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final app = TestApp();
    await mount(tester, LoginScreen(app: app));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await tester.pumpWidget(const SizedBox());
    app.dispose();
    semantics.dispose();
  });

  testWidgets('unrelated library notifications do not rescan 10000 track IDs', (
    tester,
  ) async {
    final app = LargeLibraryApp();
    await mount(tester, LibraryScreen(app: app, parent: folder));
    CountedTrack.reads = 0;
    app.notifyListeners();
    await tester.pumpAndSettle();
    expect(CountedTrack.reads, lessThan(150));
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('tabs retain independent list scroll positions', (tester) async {
    final app = LargeLibraryApp();
    await mount(tester, AppShell(app: app));
    ScrollPosition position() =>
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    position().jumpTo(5000);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).last);
    await tester.pumpAndSettle();
    expect(position().pixels, 0);
    position().jumpTo(3000);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).first);
    await tester.pumpAndSettle();
    expect(position().pixels, closeTo(5000, 1));
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  test('reorder insertion boundaries preserve every occurrence', () {
    for (var from = 0; from < 5; from++) {
      for (var to = 0; to < 5; to++) {
        final queue = QueueEngine()
          ..replace(List.generate(5, (i) => song('$i')));
        final expected = queue.entries.toList();
        final entry = expected.removeAt(from);
        expected.insert(to, entry);
        queue.move(from, to > from ? to + 1 : to);
        expect(queue.entries.map((e) => e.id), expected.map((e) => e.id));
      }
    }
  });

  testWidgets('empty playlist name disables saving until nonblank input', (
    tester,
  ) async {
    await mount(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => askPlaylistName(context),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    FilledButton save() =>
        tester.widget<FilledButton>(find.byType(FilledButton));
    expect(save().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(save().onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Music');
    await tester.pump();
    expect(save().onPressed, isNotNull);
  });

  testWidgets('dialog confirmation dismisses its route in nested navigators', (
    tester,
  ) async {
    bool? result;
    await mount(
      tester,
      Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await confirm(
                  context,
                  'Title',
                  'Body',
                  action: 'Accept',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.text('Open'), findsOneWidget);
  });
}
