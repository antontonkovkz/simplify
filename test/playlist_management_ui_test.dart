import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/l10n/l10n.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/library_screens.dart';
import 'package:simplefy/presentation/player_screens.dart';
import 'package:simplefy/presentation/playlist_deletion_screen.dart';
import 'compact_ui_test.dart' show TestApp, songs;
import 'playlist_management_test.dart' show p1, p2;

const devicePlaylist = LibraryItem(
  id: 'local-playlist:copy',
  name: 'Device copy',
  kind: ItemKind.playlist,
);

class ManagedPlaylistApp extends TestApp {
  final playlists = <LibraryItem>[p1, p2, devicePlaylist];
  final deleted = <String>[];
  final created = <String>[];
  final emitted = <String>[];
  String? denied;
  Completer<void>? creationGate;
  Completer<void>? deletionGate;
  Completer<void>? persistenceGate;
  bool creating = false;
  int revision = 0;
  int refreshCalls = 0;
  @override
  Future<void> refresh() async {
    refreshCalls++;
    playlists
      ..clear()
      ..add(p2);
    revision++;
    notifyListeners();
  }

  @override
  int get catalogRevision => revision;
  @override
  bool get loggedIn => true;
  @override
  bool get creatingServerPlaylist => creating;
  @override
  List<LibraryItem>? peekRoot(bool playlists) =>
      playlists ? List.of(this.playlists) : null;
  @override
  Future<List<LibraryItem>> root(bool playlists) async =>
      playlists ? List.of(this.playlists) : [];
  @override
  Future<void> createServerPlaylistFromQueue(String name) async {
    creating = true;
    notifyListeners();
    try {
      created.add(name);
      await creationGate?.future;
    } finally {
      creating = false;
      notifyListeners();
    }
  }

  @override
  Future<void> deletePlaylist(LibraryItem item) async {
    await deletionGate?.future;
    if (denied == item.id) {
      throw const AppFailure(AppMessage.cannotDeleteServerPlaylist);
    }
    deleted.add(item.id);
    playlists.removeWhere((p) => p.id == item.id);
    revision++;
    notifyListeners();
    await persistenceGate?.future;
  }

  @override
  void message(Object text) => emitted.add(text.toString());
}

void main() {
  late ManagedPlaylistApp app;
  setUp(() {
    app = ManagedPlaylistApp();
    app.languages.systemChanged('en');
  });
  tearDown(() {
    app.dispose();
    L10n.useLanguage('ru');
  });
  Future<void> mount(
    WidgetTester tester,
    Widget home, {
    double scale = 1,
  }) async {
    tester.view.physicalSize =
        const Size(320, 568) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: SimplefyTheme.dark,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openDeletion(WidgetTester tester) async {
    await mount(tester, AppShell(app: app));
    await tester.tap(find.text('Playlists').last);
    await tester.pumpAndSettle();
    await tester.longPress(find.text('One'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete playlists'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistDeletionScreen), findsOneWidget);
  }

  CheckboxListTile checkbox(WidgetTester tester, String id) =>
      tester.widget(find.byKey(ValueKey('delete-playlist:$id')));

  testWidgets(
    'file playlists are collapsed after native and local groups, with animated expansion',
    (tester) async {
      const imported = LibraryItem(
        id: 'imported',
        name: '1994 - Album',
        kind: ItemKind.playlist,
        path: '/music/1994 - Album.m3u',
      );
      app.playlists
        ..clear()
        ..addAll([imported, p1, devicePlaylist]);
      await mount(tester, AppShell(app: app));
      await tester.tap(find.text('Playlists').last);
      await tester.pumpAndSettle();
      expect(find.text(imported.name), findsNothing);
      final toggle = find.byKey(const ValueKey('file-playlists-toggle'));
      expect(toggle, findsOneWidget);
      expect(
        tester.getTopLeft(find.text('One')).dy,
        lessThan(tester.getTopLeft(find.text('Device copy')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Device copy')).dy,
        lessThan(tester.getTopLeft(toggle).dy),
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text(imported.name), findsOneWidget);
      app.revision++;
      app.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text(imported.name), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text(imported.name), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final empty in [false, true]) {
    testWidgets(
      'pull to refresh updates a ${empty ? "empty" : "short"} playlist list',
      (tester) async {
        if (empty) app.playlists.clear();
        await mount(tester, AppShell(app: app));
        await tester.tap(find.text('Playlists').last);
        await tester.pumpAndSettle();
        await tester.drag(find.byType(RefreshIndicator), const Offset(0, 450));
        await tester.pumpAndSettle();
        expect(app.refreshCalls, 1);
        expect(find.text('Two'), findsOneWidget);
        expect(find.text('One'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'queue saves a named server copy with visible busy state and leaves the queue unchanged',
    (tester) async {
      app.queue.replace(songs);
      final entries = app.queue.entries;
      app.creationGate = Completer<void>();
      await mount(tester, QueueScreen(app: app), scale: 2);
      await tester.tap(find.byTooltip('Save queue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save as new playlist (server)'));
      await tester.pumpAndSettle();
      expect(find.text('Save as new playlist (server)'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'New server copy');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(app.created, ['New server copy']);
      expect(app.creating, true);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byType(PopupMenuButton<String>),
            )
            .enabled,
        false,
      );
      app.creationGate!.complete();
      await tester.pumpAndSettle();
      expect(app.queue.entries, same(entries));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'long press enters selection with the pressed playlist selected; cancel never deletes',
    (tester) async {
      await openDeletion(tester);
      expect(checkbox(tester, p1.id).value, true);
      expect(checkbox(tester, p2.id).value, false);
      expect(find.text('Server playlists'), findsOneWidget);
      expect(find.text('Local playlists'), findsOneWidget);
      await tester.tap(find.text('Two'));
      expect(app.deleted, isEmpty);
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(PlaylistDeletionScreen), findsNothing);
      expect(app.deleted, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'confirmation can be cancelled; partial failure keeps only failed selection for retry',
    (tester) async {
      app.queue.replace(songs);
      final queue = app.queue.entries;
      app.denied = p2.id;
      await openDeletion(tester);
      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete selected playlists'));
      await tester.pumpAndSettle();
      expect(find.text('Delete selected playlists (2)?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(app.deleted, isEmpty);
      expect(checkbox(tester, p1.id).value, true);
      await tester.tap(find.byTooltip('Delete selected playlists'));
      await tester.pumpAndSettle();
      app.persistenceGate = Completer<void>();
      await tester.tap(find.text('Delete'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      app.persistenceGate!.complete();
      await tester.pumpAndSettle();
      expect(app.deleted, ['p1']);
      expect(find.text('One'), findsNothing);
      expect(checkbox(tester, p2.id).value, true);
      expect(
        find.text(L10n.current.cannotDeleteServerPlaylist),
        findsOneWidget,
      );
      app.denied = null;
      await tester.tap(find.byTooltip('Delete selected playlists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(app.deleted, ['p1', 'p2']);
      expect(find.byType(PlaylistDeletionScreen), findsNothing);
      expect(find.text('One'), findsNothing);
      expect(find.text('Two'), findsNothing);
      expect(find.text('Device copy'), findsOneWidget);
      expect(app.queue.entries, same(queue));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'large text deletion mode supports local selection and prevents duplicate actions while deleting',
    (tester) async {
      app.deletionGate = Completer<void>();
      await mount(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('Open'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      PlaylistDeletionScreen(app: app, initial: devicePlaylist),
                ),
              ),
            ),
          ),
        ),
        scale: 2,
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Device copy'));
      expect(checkbox(tester, devicePlaylist.id).value, true);
      await tester.tap(find.byTooltip('Delete selected playlists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == 'Cancel',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'Delete selected playlists',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      app.deletionGate!.complete();
      await tester.pumpAndSettle();
      expect(app.deleted, [devicePlaylist.id]);
      expect(find.byType(PlaylistDeletionScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
