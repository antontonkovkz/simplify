import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/queue_engine.dart';
import 'package:simplefy/presentation/widgets.dart';

void main() {
  test('queue reuses immutable snapshots until its contents change', () {
    final queue = QueueEngine();
    queue.replace(
      List.generate(
        10000,
        (i) => LibraryItem(id: '$i', name: '$i', kind: ItemKind.track),
      ),
    );
    final before = queue.entries;
    expect(identical(queue.entries, before), true);
    queue.select(before[50].id);
    expect(identical(queue.entries, before), true);
    queue.append([before.first.track]);
    final appended = queue.entries;
    expect(before, hasLength(10000));
    expect(appended, hasLength(10001));
    expect(() => appended.clear(), throwsUnsupportedError);
    queue.move(0, 3);
    expect(identical(queue.entries, appended), false);
    expect(appended.first.id, before.first.id);
    final moved = queue.entries;
    queue.remove(moved.first.id);
    expect(identical(queue.entries, moved), false);
    final removed = queue.entries;
    queue.restore(queue.toJson());
    expect(identical(queue.entries, removed), false);
    queue.replace([]);
    expect(queue.entries, isEmpty);
  });

  for (final reorderable in [false, true]) {
    testWidgets(
      'deep scrolling 10000 rows has constant work per visible row (reorder=$reorderable)',
      (tester) async {
        var identified = 0;
        var built = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AnimatedRows<String>(
                items: List.generate(10000, (i) => '$i'),
                idOf: (item) {
                  identified++;
                  return item;
                },
                onReorder: reorderable ? (_, _) {} : null,
                builder: (_, item, index) {
                  built++;
                  return SizedBox(height: 60, child: Text('$item:$index'));
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(540000);
        await tester.pumpAndSettle();
        identified = 0;
        built = 0;
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
        await tester.pumpAndSettle();
        // Identifier lookups must depend on the viewport, not row number 9000.
        debugPrint(
          'LARGE_LIST_SCROLL reorder=$reorderable idReads=$identified built=$built',
        );
        expect(built, lessThan(60));
        expect(identified, lessThan(1000));
        expect(tester.takeException(), null);
      },
    );
  }

  testWidgets('large server reorder is linear and keeps scrollable rows', (
    tester,
  ) async {
    var identified = 0;
    final items = List.generate(5000, (i) => '$i');
    Widget screen(List<String> values) => MaterialApp(
      home: Scaffold(
        body: AnimatedRows<String>(
          items: values,
          idOf: (item) {
            identified++;
            return item;
          },
          builder: (_, item, _) => SizedBox(height: 60, child: Text(item)),
        ),
      ),
    );
    await tester.pumpWidget(screen(items));
    await tester.pumpAndSettle();
    identified = 0;
    await tester.pumpWidget(screen(items.reversed.toList()));
    await tester.pumpAndSettle();
    debugPrint('LARGE_LIST_REVERSE idReads=$identified');
    expect(identified, lessThan(100000));
    expect(find.text('4999'), findsOneWidget);
    expect(tester.takeException(), null);
  });
  for (final reorderable in [false, true]) {
    testWidgets(
      'bulk edits animate only viewport rows (reorder=$reorderable)',
      (tester) async {
        var built = 0;
        Widget screen(List<String> items) => MaterialApp(
          home: Scaffold(
            body: AnimatedRows<String>(
              items: items,
              idOf: (item) => item,
              onReorder: reorderable ? (_, _) {} : null,
              builder: (_, item, _) {
                built++;
                return SizedBox(height: 60, child: Text(item));
              },
            ),
          ),
        );
        await tester.pumpWidget(screen(['0']));
        await tester.pumpAndSettle();
        built = 0;
        await tester.pumpWidget(screen(List.generate(10000, (i) => '$i')));
        await tester.pumpAndSettle();
        expect(built, lessThan(80));
        built = 0;
        await tester.pumpWidget(screen(['9999']));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        await tester.pumpAndSettle();
        expect(built, lessThan(80));
        expect(find.text('9999'), findsOneWidget);
        expect(tester.takeException(), null);
      },
    );
  }
}
