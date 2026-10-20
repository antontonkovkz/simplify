import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/app_controller.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/queue_engine.dart';
import 'package:simplefy/infrastructure/local_store.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/group_play_button.dart';
import 'package:simplefy/presentation/widgets.dart';
import 'compact_ui_test.dart' show songs, folder;
import 'playlist_edit_controller_test.dart' show IdleAudio;

class GroupApp extends AppController {
  GroupApp() : super(LocalStore(Directory.systemTemp), IdleAudio());
  List<LibraryItem>? played;
  bool? randomStartReceived;
  String? localSource;
  LibraryItem? serverSource;
  Completer<List<LibraryItem>>? loading;
  String identity = 'fixture';
  @override
  String get libraryIdentity => identity;
  @override
  Future<List<LibraryItem>> tracks(
    LibraryItem item, {
    bool recursive = true,
  }) async => loading == null ? songs : loading!.future;
  @override
  Future<void> playTracks(
    List<LibraryItem> tracks, {
    int start = 0,
    bool randomStart = false,
    String? localPlaylistId,
    LibraryItem? serverPlaylistSource,
  }) async {
    played = tracks;
    randomStartReceived = randomStart;
    localSource = localPlaylistId;
    serverSource = serverPlaylistSource;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'group start respects shuffle and keeps the display order and traversal',
    () {
      final random = Random(42);
      final expected = Random(42).nextInt(songs.length);
      final queue = QueueEngine(random: random)..shuffled = true;
      queue.replace([songs.last]);
      queue.replace(songs, randomStart: true);
      expect(queue.currentIndex, expected);
      expect(queue.entries.map((e) => e.track.id), songs.map((t) => t.id));
      expect(queue.canPrevious, false);
      final visited = {queue.current!.id};
      while (queue.next() != null) {
        expect(visited.add(queue.current!.id), true);
      }
      expect(visited, hasLength(3));
      queue.shuffled = false;
      queue.replace(songs, randomStart: true);
      expect(queue.currentIndex, 0);
      queue.shuffled = true;
      queue.replace(songs, start: 1);
      expect(
        queue.currentIndex,
        1,
        reason: 'Tapping a song still wins over shuffle',
      );
      queue.replace([], randomStart: true);
      expect(queue.current, null);
    },
  );
  test(
    'group command preserves playlist provenance and requests random initial choice',
    () async {
      final app = GroupApp();
      try {
        const server = LibraryItem(
          id: 'p',
          name: 'Server',
          kind: ItemKind.playlist,
        );
        const local = LibraryItem(
          id: 'local-playlist:p',
          name: 'Local',
          kind: ItemKind.playlist,
        );
        await app.playGroup(server);
        expect(app.played, same(songs));
        expect(app.randomStartReceived, true);
        expect(app.serverSource, same(server));
        expect(app.localSource, null);
        await app.playGroup(local);
        expect(app.localSource, local.id);
        expect(app.serverSource, null);
        await app.playGroup(folder);
        expect(app.localSource, null);
        expect(app.serverSource, null);
      } finally {
        app.dispose();
      }
    },
  );
  test('switching account while expanding a group cancels playback', () async {
    final app = GroupApp()..loading = Completer<List<LibraryItem>>();
    try {
      final command = app.playGroup(folder);
      final rejected = expectLater(command, throwsA(isA<AppFailure>()));
      app.identity = 'another';
      app.loading!.complete(songs);
      await rejected;
      expect(app.played, null);
    } finally {
      app.dispose();
    }
  });
  test(
    'a slow previous group cannot replace a more recent selection',
    () async {
      final app = GroupApp();
      final first = Completer<List<LibraryItem>>();
      final second = Completer<List<LibraryItem>>();
      try {
        app.loading = first;
        final oldRequest = app.playGroup(folder);
        app.loading = second;
        final newRequest = app.playGroup(folder);
        second.complete(songs);
        await newRequest;
        first.complete(songs.reversed.toList());
        await oldRequest;
        expect(app.played, same(songs));
      } finally {
        app.dispose();
      }
    },
  );
  testWidgets('rightmost play is a separate target and blocks repeated loads', (
    tester,
  ) async {
    var opened = 0;
    var menus = 0;
    var plays = 0;
    final pending = Completer<void>();
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: SimplefyTheme.dark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: ItemTile(
            item: folder,
            trailing: const Text('1234'),
            onTap: () => opened++,
            onMenu: () => menus++,
            onPlay: () async {
              plays++;
              await pending.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final play = find.byType(GroupPlayButton);
    expect(
      tester.getCenter(play).dx,
      greaterThan(tester.getCenter(find.text('1234')).dx),
    );
    final target = tester.getSize(find.byType(IconButton));
    expect(target.width, greaterThanOrEqualTo(44));
    expect(target.height, greaterThanOrEqualTo(44));
    await tester.tap(play);
    await tester.pump();
    await tester.tap(play);
    expect(plays, 1);
    expect(opened, 0);
    expect(menus, 0);
    pending.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.text(folder.name));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox());
  });
}
