import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/queue_engine.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/library_screens.dart';
import 'package:simplefy/presentation/player_screens.dart';
import 'package:simplefy/presentation/queue_row.dart';
import 'package:simplefy/presentation/widgets.dart';
import 'compact_ui_test.dart' show TestApp, songs;

List<LibraryItem> longQueue(int count) => List.generate(
  count,
  (i) => LibraryItem(
    id: 'song-$i',
    name: i.isOdd
        ? 'Song $i with a longer title that may wrap on narrow screens'
        : 'Song $i',
    artist: 'Fixture',
    kind: ItemKind.track,
  ),
);

class PlayApp extends TestApp {
  bool succeeds = true;
  Completer<void>? gate;
  @override
  Future<bool> playGroup(LibraryItem parent) async {
    if (gate != null) await gate!.future;
    if (!succeeds) return false;
    queue.replace(songs, start: 2);
    notifyListeners();
    return true;
  }
}

void main() {
  test(
    'logical anchor follows occurrence, history and restoration without a screen',
    () {
      final queue = QueueEngine()..replace([songs[0], songs[1], songs[0]]);
      queue.select(queue.entries.last.id);
      final last = queue.viewAnchorId;
      expect(last, queue.entries.last.id);
      queue.previous();
      expect(queue.viewAnchorId, queue.entries[1].id);
      queue.next();
      expect(queue.viewAnchorId, last);
      final restored = QueueEngine()..restore(queue.toJson());
      expect(restored.viewAnchorId, last);
      queue.move(2, 0);
      expect(queue.viewAnchorId, last);
      queue.remove(last!);
      expect(queue.viewAnchorId, queue.entries.first.id);
      queue.replace([]);
      expect(queue.viewAnchorId, null);
    },
  );

  Future<void> mount(WidgetTester tester, TestApp app, {Widget? home}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SimplefyTheme.dark,
        home: home ?? QueueScreen(app: app),
      ),
    );
    await tester.pumpAndSettle();
  }

  void visible(WidgetTester tester, TestApp app) {
    final row = find.byWidgetPredicate(
      (w) => w is QueueRow && w.entry.id == app.queue.viewAnchorId,
    );
    expect(row, findsOneWidget);
    final area = tester.getRect(find.byType(ReorderableListView));
    final rect = tester.getRect(row);
    expect(rect.top, greaterThanOrEqualTo(area.top - 1));
    expect(rect.bottom, lessThanOrEqualTo(area.bottom + 1));
  }

  testWidgets(
    '10000 variable-height entries open and follow distant changes lazily',
    (tester) async {
      final app = TestApp();
      addTearDown(app.dispose);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      app.queue.replace(longQueue(10000), start: 9001);
      await mount(tester, app);
      visible(tester, app);
      expect(find.byType(QueueRow).evaluate().length, lessThan(40));
      await app.selectIndex(42);
      await tester.pumpAndSettle();
      visible(tester, app);
      expect(find.byType(QueueRow).evaluate().length, lessThan(40));
      await app.selectIndex(9999);
      await tester.pumpAndSettle();
      visible(tester, app);
      expect(find.byType(QueueRow).evaluate().length, lessThan(40));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.physicalSize = const Size(320, 844);
      await tester.pumpAndSettle();
      visible(tester, app);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('manual scrolling stays until the current occurrence changes', (
    tester,
  ) async {
    final app = TestApp();
    addTearDown(app.dispose);
    app.queue.replace(longQueue(300), start: 100);
    await mount(tester, app);
    await tester.drag(find.byType(ReorderableListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    final scroll = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ReorderableListView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    final offset = scroll.pixels;
    app.notifyListeners();
    await tester.pumpAndSettle();
    expect(scroll.pixels, offset);
    await app.selectIndex(150);
    await tester.pumpAndSettle();
    visible(tester, app);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'covered queue follows playback and reopening uses the latest anchor',
    (tester) async {
      final app = TestApp();
      addTearDown(app.dispose);
      app.queue.replace(longQueue(1000), start: 500);
      await mount(tester, app);
      final navigator = Navigator.of(tester.element(find.byType(QueueScreen)));
      navigator.push(slideRoute(const Scaffold(body: Text('Cover'))));
      await tester.pumpAndSettle();
      await app.selectIndex(901);
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      visible(tester, app);
      await tester.pumpWidget(const SizedBox());
      await app.selectIndex(12);
      await mount(tester, app);
      visible(tester, app);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'playback clears a filter that hides the newly selected occurrence',
    (tester) async {
      final app = TestApp();
      addTearDown(app.dispose);
      app.queue.replace(longQueue(300));
      await mount(tester, app);
      await tester.longPress(find.text('Очередь'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Song 250');
      await tester.pumpAndSettle();
      expect(find.byType(QueueRow), findsOneWidget);
      await app.selectIndex(10);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      visible(tester, app);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'far indexed jumps build viewport rows rather than intervening widgets',
    (tester) async {
      final entries = List.generate(10000, (i) => i.toString());
      var anchor = '9000';
      var built = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, set) {
                update = set;
                return AnimatedRows<String>(
                  items: entries,
                  idOf: (id) => id,
                  indexed: true,
                  followId: anchor,
                  onReorder: (_, _) {},
                  builder: (_, id, _) {
                    built++;
                    return SizedBox(
                      height: int.parse(id).isEven ? 64 : 140,
                      child: Text(id),
                    );
                  },
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('9000'), findsOneWidget);
      expect(built, lessThan(100));
      built = 0;
      update(() => anchor = '20');
      await tester.pumpAndSettle();
      expect(find.text('20'), findsOneWidget);
      expect(built, lessThan(150));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'new group play opens exactly one queue immediately, including unsuccessful playback',
    (tester) async {
      final app = PlayApp();
      addTearDown(app.dispose);
      await mount(tester, app, home: AppShell(app: app));
      app.gate = Completer<void>();
      await tester.tap(find.byTooltip('Проиграть «Музыка»'));
      await tester.pumpAndSettle();
      expect(find.byType(QueueScreen), findsOneWidget);
      expect(app.queue.entries, isEmpty);
      app.gate!.complete();
      await tester.pumpAndSettle();
      visible(tester, app);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      app.succeeds = false;
      await tester.tap(find.byTooltip('Проиграть «Музыка»'));
      await tester.pumpAndSettle();
      expect(find.byType(QueueScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
