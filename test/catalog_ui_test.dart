import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/library_screens.dart';
import 'compact_ui_test.dart' show TestApp, songs;

class CachedApp extends TestApp {
  final request = Completer<List<LibraryItem>>();
  List<LibraryItem> snapshot = [songs.first];
  int calls = 0;
  int revision = 0;
  bool updating = true;
  @override
  int get catalogRevision => revision;
  @override
  bool catalogUpdating(String key) => updating;
  @override
  List<LibraryItem>? peekChildren(LibraryItem parent) => snapshot;
  @override
  Future<List<LibraryItem>> children(LibraryItem parent) {
    calls++;
    return request.future;
  }

  void finish() {
    snapshot = songs;
    updating = false;
    revision++;
    request.complete(songs);
    notifyListeners();
  }
}

void main() {
  for (final kind in [
    ItemKind.collection,
    ItemKind.folder,
    ItemKind.playlist,
  ]) {
    testWidgets('$kind shows cached contents during a delayed update', (
      tester,
    ) async {
      final app = CachedApp();
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: SimplefyTheme.dark,
          home: LibraryScreen(
            app: app,
            parent: LibraryItem(id: 'group', name: 'Cached group', kind: kind),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text(songs.first.title), findsWidgets);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(app.calls, 1);
      app.finish();
      await tester.pumpAndSettle();
      expect(find.text(songs.last.title), findsWidgets);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        app.calls,
        1,
        reason: 'Revalidation must not start another fetch loop',
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
