import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/app_controller.dart';
import 'package:simplefy/application/server_playlist_editor.dart';
import 'package:simplefy/domain/browse_location.dart';
import 'package:simplefy/domain/download_group.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/offline_availability.dart';
import 'package:simplefy/domain/queue_engine.dart' show QueueEngine;
import 'package:simplefy/infrastructure/jellyfin_library.dart';
import 'package:simplefy/infrastructure/download_manager.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/library_screens.dart';
import 'package:simplefy/presentation/player_screens.dart';
import 'package:simplefy/presentation/queue_row.dart';
import 'package:simplefy/presentation/widgets.dart';

const songs = [
  LibraryItem(
    id: 'a',
    name: 'Группа крови',
    artist: 'Кино',
    kind: ItemKind.track,
    durationMs: 222000,
  ),
  LibraryItem(
    id: 'b',
    name: 'Очень длинное название композиции для проверки ширины строки',
    artist: 'Исполнитель с длинным именем',
    kind: ItemKind.track,
    durationMs: 180000,
  ),
  LibraryItem(
    id: 'c',
    name: 'Спокойная ночь',
    artist: 'Кино',
    kind: ItemKind.track,
    durationMs: 240000,
  ),
];
const folder = LibraryItem(
  id: 'folder',
  name: 'Музыка',
  kind: ItemKind.collection,
);

class TestApp extends ChangeNotifier implements AppController {
  @override
  int get catalogRevision => 0;
  @override
  bool catalogUpdating(String key) => false;
  @override
  Object? catalogError(String key) => null;
  @override
  List<LibraryItem>? peekRoot(bool playlists) => null;
  @override
  List<LibraryItem>? peekChildren(LibraryItem item) => null;
  @override
  Future<List<LibraryItem>> freshChildren(LibraryItem item) => children(item);
  @override
  LibraryItem? get preparingGroup => null;
  @override
  bool get resolvingGroup => false;
  @override
  String? get groupPreparationError => null;
  @override
  LibraryItem? get failedGroup => null;
  @override
  final queue = QueueEngine();
  @override
  final serverPlaylist = ServerPlaylistEditor();
  @override
  bool onlyDownloaded = false;
  @override
  bool get hasLibrary => true;
  @override
  bool get loggedIn => false;
  @override
  bool get offline => false;
  @override
  bool get refreshing => false;
  @override
  bool get importing => false;
  @override
  bool get waitingForNetwork => false;
  @override
  bool get isPlaying => false;
  @override
  LibraryItem? get loadedLocalPlaylist => null;
  @override
  bool get queueHasChanges =>
      serverPlaylist.hasChanges(queue.entries.map((e) => e.track.id).toList());
  @override
  JellyfinLibrary? get library => null;
  @override
  DownloadManager? get downloads => null;
  @override
  int get localRevision => 0;
  @override
  int get countRevision => 0;
  @override
  int get serverPlaylistRevision => 0;
  @override
  Future<List<LibraryItem>> children(LibraryItem item) async => songs;
  @override
  String get libraryIdentity => 'fixture';
  @override
  BrowseLocation get browse => const BrowseLocation();
  @override
  List<DownloadChange> get pendingChanges => [];
  @override
  Future<List<LibraryItem>> root(bool playlists) async => [folder];
  @override
  int? knownTrackCount(LibraryItem item) => 6;
  @override
  Future<int?> trackCount(LibraryItem item) async => 6;
  @override
  OfflineAvailability offlineAvailability(LibraryItem item, {int? total}) =>
      const OfflineAvailability(available: 2, total: 6);
  @override
  bool isDownloaded(LibraryItem item) => false;
  @override
  void setOnlyDownloaded(bool value) {
    onlyDownloaded = value;
    notifyListeners();
  }

  @override
  void setBrowse(int tab, List<LibraryItem> path) {}
  @override
  void setShuffle(bool value) {
    queue.shuffled = value;
    notifyListeners();
  }

  @override
  void move(int from, int to) {
    queue.move(from, to);
    notifyListeners();
  }

  @override
  Future<void> selectIndex(int index) async {
    queue.select(queue.entries[index].id);
    notifyListeners();
  }

  @override
  Future<void> remove(String id, {bool finish = false}) async {
    final current = queue.remove(id);
    if (current && !finish) queue.next();
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  void dispose() {
    serverPlaylist.dispose();
    super.dispose();
  }
}

void main() {
  late TestApp app;
  setUp(() {
    app = TestApp();
  });
  tearDown(() {
    app.dispose();
  });
  Future<void> mount(
    WidgetTester tester,
    Widget screen, {
    double width = 402,
    double scale = 1,
    double height = 874,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: SimplefyTheme.dark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: screen,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('mini player retains five touch targets in a compact surface', (
    tester,
  ) async {
    app.queue.replace(songs);
    await mount(
      tester,
      ListenableBuilder(
        listenable: app,
        builder: (_, _) => Scaffold(body: MiniPlayer(app: app)),
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('mini-player-surface'))).height,
      lessThanOrEqualTo(96),
    );
    for (final label in [
      'Случайное воспроизведение',
      'Предыдущая',
      'Продолжить',
      'Следующая',
      'Очередь',
    ]) {
      final size = tester.getSize(find.byTooltip(label));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }
    final previous = tester.getCenter(find.byTooltip('Предыдущая'));
    await tester.tap(find.byTooltip('Случайное воспроизведение'));
    await tester.pumpAndSettle();
    expect(app.queue.shuffled, true);
    expect(tester.getCenter(find.byTooltip('Предыдущая')), previous);
    expect(find.text('Случайно'), findsNothing);
  });

  testWidgets('queue search preserves contents and distinguishes no results', (
    tester,
  ) async {
    app.queue.replace(songs);
    await mount(tester, QueueScreen(app: app));
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('Очередь'), findsNothing);
    expect(find.text('3 композиции · 10:42'), findsOneWidget);
    await tester.longPress(find.text('Очередь'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('Ничего не найдено'), findsOneWidget);
    expect(find.text('Очередь пуста'), findsNothing);
    expect(app.queue.entries, hasLength(3));
    await tester.tap(find.widgetWithText(TextButton, 'Очистить поиск'));
    await tester.pumpAndSettle();
    expect(find.byType(QueueRow), findsNWidgets(3));
    await tester.tap(find.byTooltip('Закрыть поиск'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('pull reveals search without a permanent toolbar button', (
    tester,
  ) async {
    app.queue.replace(songs);
    await mount(tester, QueueScreen(app: app));
    expect(find.byTooltip('Поиск в очереди'), findsNothing);
    expect(find.byTooltip('Закрыть поиск'), findsNothing);
    await tester.drag(find.byType(QueueRow).first, const Offset(0, 180));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      false,
    );
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Закрыть поиск'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(QueueRow), findsNWidgets(3));
    expect(app.queue.entries, hasLength(3));
  });

  testWidgets(
    'swipe removes one occurrence; current removal can be cancelled',
    (tester) async {
      app.queue.replace([songs[0], songs[1], songs[0]]);
      await app.serverPlaylist.open(
        null,
        const LibraryItem(id: 'p', name: 'В дороге', kind: ItemKind.playlist),
        baseline: ['a', 'b', 'a'],
      );
      await mount(tester, QueueScreen(app: app));
      await tester.drag(find.byType(QueueRow).at(1), const Offset(-380, 0));
      await tester.pumpAndSettle();
      expect(app.queue.entries.map((e) => e.track.id), ['a', 'a']);
      expect(find.text('Из «В дороге» · Изменено'), findsOneWidget);
      await tester.drag(find.byType(QueueRow).first, const Offset(-380, 0));
      await tester.pumpAndSettle();
      expect(find.text('Удалить играющую композицию?'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(app.queue.entries, hasLength(2));
      await tester.longPress(find.byType(QueueRow).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить из очереди'));
      await tester.pumpAndSettle();
      expect(app.queue.entries, hasLength(1));
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'compact library exposes partial counts and an explicit filter reset',
    (tester) async {
      await mount(tester, AppShell(app: app));
      expect(find.byType(FilterChip), findsNothing);
      expect(find.byTooltip('Обновить библиотеку'), findsNothing);
      expect(find.text('2/6'), findsOneWidget);
      expect(find.byIcon(Icons.offline_pin_rounded), findsNothing);
      expect(
        tester.getSize(find.byType(ItemTile)).height,
        lessThanOrEqualTo(56),
      );
      await tester.tap(find.byTooltip('На устройстве'));
      await tester.pumpAndSettle();
      expect(find.text('Только на устройстве'), findsOneWidget);
      await tester.tap(find.byTooltip('Сбросить фильтр'));
      await tester.pumpAndSettle();
      expect(app.onlyDownloaded, false);
    },
  );

  testWidgets(
    'queue supports large text on a narrow screen and rapid dialog cancellation',
    (tester) async {
      app.queue.replace(songs);
      await mount(tester, QueueScreen(app: app), width: 320, scale: 2);
      expect(tester.takeException(), null);
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byTooltip('Сохранить очередь'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Сохранить как…'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Отмена'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(tester.takeException(), null);
      }
    },
  );
  testWidgets(
    'queue search remains usable above a keyboard on a short screen',
    (tester) async {
      app.queue.replace(songs);
      await mount(
        tester,
        QueueScreen(app: app),
        width: 320,
        height: 568,
        scale: 2,
        keyboard: 300,
      );
      await tester.longPress(find.text('Очередь'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pumpAndSettle();
      expect(find.text('Ничего не найдено'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );
  testWidgets(
    'folder header grows with large text without hiding the title behind actions',
    (tester) async {
      await mount(
        tester,
        LibraryScreen(app: app, parent: folder, ancestors: [folder]),
        width: 320,
        scale: 2,
      );
      expect(tester.getSize(find.byType(AppBar)).height, greaterThan(56));
      expect(tester.takeException(), null);
    },
  );
  testWidgets('left-edge back takes priority over queue swipe removal', (
    tester,
  ) async {
    app.queue.replace(songs);
    await mount(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                Navigator.push(context, slideRoute(QueueScreen(app: app))),
            child: const Text('Open queue'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open queue'));
    await tester.pumpAndSettle();
    expect(find.byType(QueueScreen), findsOneWidget);
    final gesture = await tester.startGesture(const Offset(1, 300));
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(140, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(400, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(QueueScreen), findsNothing);
    expect(app.queue.entries, hasLength(3));
  });
}
