import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/presentation/widgets.dart';

void main() {
  testWidgets(
    'long press opens the menu without opening the group; count remains visible',
    (tester) async {
      var taps = 0;
      var menus = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ItemTile(
              item: const LibraryItem(
                id: 'folder',
                name: 'Album',
                kind: ItemKind.folder,
              ),
              onTap: () => taps++,
              onMenu: () => menus++,
              trailing: const Text('12'),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
      expect(find.text('12'), findsOneWidget);
      await tester.longPress(find.text('12'));
      expect(menus, 1);
      expect(taps, 0);
      await tester.tap(find.text('Album'));
      expect(taps, 1);
      expect(menus, 1);
    },
  );

  testWidgets('row remains tappable after its long-press sheet is dismissed', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ItemTile(
              item: const LibraryItem(
                id: 'p',
                name: 'Playlist',
                kind: ItemKind.playlist,
              ),
              onTap: () => taps++,
              onMenu: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => const Text('Actions'),
              ),
              trailing: const Text('3'),
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.byType(ItemTile));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('Actions'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ItemTile));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('track rows show duration and retain long-press actions', (
    tester,
  ) async {
    var menus = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ItemTile(
            item: const LibraryItem(
              id: 'song',
              name: 'Song',
              kind: ItemKind.track,
              durationMs: 125000,
            ),
            onTap: () {},
            onMenu: () => menus++,
          ),
        ),
      ),
    );
    expect(find.text('2:05'), findsOneWidget);
    await tester.longPress(find.text('Song'));
    expect(menus, 1);
  });
}
