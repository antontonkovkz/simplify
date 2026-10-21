import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/infrastructure/download_manager.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/downloaded_tracks_screen.dart';
import 'compact_ui_test.dart' show TestApp, songs;

class DownloadFiles extends ChangeNotifier implements DownloadManager {
  List<LibraryItem> items = List.of(songs);
  final List<String> removed = [];
  @override
  List<LibraryItem> get completedTracks => items;
  @override
  Future<void> removeTrack(String id) async {
    removed.add(id);
    items = items.where((t) => t.id != id).toList();
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DownloadApp extends TestApp {
  final files = DownloadFiles();
  bool connected = true;
  @override
  bool get loggedIn => connected;
  @override
  DownloadManager? get downloads => connected ? files : null;
  @override
  Future<void> removeDownloadedTrack(LibraryItem item) =>
      files.removeTrack(item.id);
  @override
  void message(Object text) {}
  @override
  void dispose() {
    files.dispose();
    super.dispose();
  }
}

void main() {
  late DownloadApp app;
  setUp(() {
    app = DownloadApp();
  });
  tearDown(() {
    app.dispose();
  });
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SimplefyTheme.dark,
        home: DownloadedTracksScreen(app: app),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'individual deletion asks, supports cancellation and preserves queue',
    (tester) async {
      app.queue.replace(songs);
      final queue = app.queue.entries;
      await open(tester);
      expect(find.byTooltip('Удалить с устройства'), findsNWidgets(3));
      await tester.tap(find.byTooltip('Удалить с устройства').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(app.files.removed, isEmpty);
      await tester.tap(find.byTooltip('Удалить с устройства').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить'));
      await tester.pumpAndSettle();
      expect(app.files.removed, [songs.first.id]);
      expect(find.byTooltip('Удалить с устройства'), findsNWidgets(2));
      expect(app.queue.entries, same(queue));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('search filters completed songs and updates after deletion', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('Поиск композиций'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Спокойная');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Удалить с устройства'), findsOneWidget);
    expect(find.text(songs.last.title), findsOneWidget);
    await tester.tap(find.byTooltip('Удалить с устройства'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить'));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ничего не найдено'), findsOneWidget);
    await tester.tap(find.byTooltip('Закрыть поиск'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Удалить с устройства'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('account change while confirming prevents deletion', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('Удалить с устройства').first);
    await tester.pumpAndSettle();
    app.connected = false;
    app.notifyListeners();
    await tester.pump();
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    expect(app.files.removed, isEmpty);
    expect(find.text('Учётная запись изменилась'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
