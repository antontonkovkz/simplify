import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/library_screens.dart';
import 'package:simplefy/presentation/player_screens.dart';
import 'package:simplefy/presentation/queue_row.dart';
import 'package:simplefy/presentation/widgets.dart';
import '../test/compact_ui_test.dart' show TestApp, folder;

class LargeLibraryApp extends TestApp {
  final fixtureTracks = List.generate(
    5000,
    (i) => LibraryItem(
      id: 'large:$i',
      name: 'Track ${i.toString().padLeft(4, '0')}',
      fileName: 'Track $i.flac',
      artist: 'Fixture artist',
      kind: ItemKind.track,
      durationMs: 180000,
    ),
  );
  @override
  Future<List<LibraryItem>> children(LibraryItem item) async => fixtureTracks;
  @override
  int? knownTrackCount(LibraryItem item) => fixtureTracks.length;
  @override
  Future<int?> trackCount(LibraryItem item) async => fixtureTracks.length;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('5000-track queue and folder scroll without mounting the tail', (
    tester,
  ) async {
    final app = LargeLibraryApp();
    app.queue.replace(app.fixtureTracks);
    Future<void> mount(Widget screen) async {
      await tester.pumpWidget(
        MaterialApp(theme: SimplefyTheme.dark, home: screen),
      );
      await tester.pumpAndSettle();
    }

    Future<void> scroll(Finder rows) async {
      for (var i = 0; i < 8; i++) {
        await tester.fling(
          find.byType(Scrollable).first,
          const Offset(0, -1800),
          3000,
        );
        await tester.pumpAndSettle();
        expect(rows.evaluate().length, lessThan(60));
        expect(tester.takeException(), null);
      }
    }

    await mount(QueueScreen(app: app));
    await scroll(find.byType(QueueRow));
    final offset = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;
    expect(offset, greaterThan(256 * 64));
    debugPrint(
      'SIMPLEFY_LARGE_QUEUE offset=${offset.round()} mounted=${find.byType(QueueRow).evaluate().length}',
    );
    await tester.longPress(find.text('Очередь'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Track 4999');
    await tester.pumpAndSettle();
    expect(find.byType(QueueRow), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(QueueRow),
        matching: find.text('Track 4999'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Закрыть поиск'));
    await tester.pumpAndSettle();
    expect(app.queue.entries, hasLength(5000));
    expect(find.byType(QueueRow).evaluate().length, lessThan(60));
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    final second = app.queue.entries[1].id;
    await tester.drag(
      find.byIcon(Icons.drag_handle_rounded).at(1),
      const Offset(0, 100),
    );
    await tester.pumpAndSettle();
    expect(app.queue.entries[1].id, isNot(second));
    await tester.drag(find.byType(QueueRow).at(1), const Offset(-350, 0));
    await tester.pumpAndSettle();
    expect(app.queue.entries, hasLength(4999));
    await mount(LibraryScreen(app: app, parent: folder));
    await scroll(find.byType(ItemTile));
    final folderOffset = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;
    expect(folderOffset, greaterThan(256 * 56));
    debugPrint(
      'SIMPLEFY_LARGE_FOLDER offset=${folderOffset.round()} mounted=${find.byType(ItemTile).evaluate().length}',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    debugPrint('SIMPLEFY_LARGE_LISTS_PASSED');
  });
}
