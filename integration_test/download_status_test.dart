import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/domain/download_activity.dart';
import 'package:simplefy/domain/download_group.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/infrastructure/download_backend.dart';
import 'package:simplefy/infrastructure/download_manager.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';
import 'package:simplefy/infrastructure/local_store.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/download_status_banner.dart';
import '../test/compact_ui_test.dart' show TestApp;
import '../test/download_status_ui_test.dart' as ui;

const fixtureServer = String.fromEnvironment('TEST_DOWNLOAD_FIXTURE');

class FixtureLibrary extends JellyfinLibrary {
  FixtureLibrary()
    : super(
        ServerSession(fixtureServer, 'download-fixture', 'fixture', 'fixture'),
      );
  @override
  Map<String, String> get headers => {};
  @override
  Future<void> prepareDownload(
    LibraryItem track, {
    http.Client? transport,
  }) async {}
  @override
  bool requiresConversion(LibraryItem track) => false;
  @override
  Uri downloadUri(LibraryItem track) => Uri.parse(
    '$fixtureServer/${track.name == 'Background fixture' ? 'slow' : 'interrupt'}.wav?case=${track.id}',
  );
}

class ImmediateFailureBackend extends NativeDownloadBackend {
  @override
  Stream<TaskUpdate> get updates => super.updates.map((update) {
    if (update is TaskStatusUpdate) {
      debugPrint(
        'DOWNLOAD_FIXTURE_STATUS ${update.status.name} ${update.exception?.exceptionType ?? ""}',
      );
    }
    return update;
  });
  @override
  Future<bool> enqueue(DownloadTask task) =>
      super.enqueue(task.copyWith(retries: 0, retriesRemaining: 0));
}

class FixtureApp extends TestApp {
  FixtureApp(this.manager) {
    manager.addListener(notifyListeners);
  }
  final DownloadManager manager;
  @override
  DownloadActivity? get downloadActivity => manager.activity;
  @override
  Future<void> continueDownloads() => manager.retryPending(manual: true);
  @override
  void dispose() {
    manager.removeListener(notifyListeners);
    super.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized()
      .platformDispatcher
      .localeTestValue = const Locale(
    'ru',
  );
  ui.main();
  testWidgets(
    'native disconnection, automatic and manual recovery, and background transfer',
    (tester) async {
      final store = LocalStore(await getApplicationSupportDirectory());
      final library = FixtureLibrary();
      final manager = DownloadManager(
        store,
        library,
        backend: ImmediateFailureBackend(),
      );
      final app = FixtureApp(manager);
      final client = HttpClient();
      final run = DateTime.now().microsecondsSinceEpoch.toString();
      LibraryItem track(String suffix, String name) => LibraryItem(
        id: '$run-$suffix',
        name: name,
        artist: 'Fixture',
        fileName: '$suffix.wav',
        kind: ItemKind.track,
      );
      Future<void> until(bool Function() ready, {int seconds = 60}) async {
        final end = DateTime.now().add(Duration(seconds: seconds));
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(ready(), true, reason: 'Native download checkpoint timed out');
        await tester.pump(const Duration(milliseconds: 350));
      }

      Future<void> recover(LibraryItem track) async {
        final request = await client.getUrl(
          Uri.parse('$fixtureServer/recover?case=${track.id}'),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        await response.drain<void>();
      }

      try {
        await manager.initialize();
        await tester.pumpWidget(
          MaterialApp(
            theme: SimplefyTheme.dark,
            builder: (_, child) => DownloadStatusHost(app: app, child: child!),
            home: const Scaffold(
              body: Center(child: Text('Isolated download fixture')),
            ),
          ),
        );
        final automatic = track('automatic', 'Automatic fixture');
        await manager.apply(
          DownloadGroup(source: automatic, tracks: [automatic]),
        );
        await until(() => manager.errors.containsKey(automatic.id));
        expect(find.text('Продолжить'), findsOneWidget);
        manager.setNetwork(NetworkKind.offline);
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.textContaining('Соединение потеряно'), findsOneWidget);
        await recover(automatic);
        manager.setNetwork(NetworkKind.unmetered);
        await until(() => manager.contains(automatic.id));
        expect(
          await File(manager.localPath(automatic.id)!).length(),
          512 * 1024,
        );

        final manual = track('manual', 'Manual fixture');
        await manager.apply(DownloadGroup(source: manual, tracks: [manual]));
        await until(() => manager.errors.containsKey(manual.id));
        await recover(manual);
        await tester.tap(find.text('Продолжить'));
        await until(() => manager.contains(manual.id));
        expect(await File(manager.localPath(manual.id)!).length(), 512 * 1024);
        debugPrint('SIMPLEFY_NATIVE_DOWNLOAD_RECOVERY_PASSED');

        if (const bool.fromEnvironment('TEST_DOWNLOAD_BACKGROUND')) {
          final background = track('background', 'Background fixture');
          await manager.apply(
            DownloadGroup(source: background, tracks: [background]),
          );
          await until(() => (manager.progress[background.id] ?? 0) > 0);
          debugPrint('SIMPLEFY_BACKGROUND_DOWNLOAD_STATUS_BEGIN');
          expect(
            await FlutterLocalNotificationsPlugin()
                .openAppNotificationSettings(),
            true,
          );
          await Future<void>.delayed(const Duration(seconds: 8));
          await manager.reconcile();
          await until(() => manager.contains(background.id));
          expect(
            await File(manager.localPath(background.id)!).length(),
            8 * 1024 * 1024,
          );
          debugPrint('SIMPLEFY_BACKGROUND_DOWNLOAD_STATUS_PASSED');
        }
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(DownloadStatusBanner), findsNothing);
        expect(tester.takeException(), null);
      } finally {
        await manager.clear();
        await FileDownloader().database.deleteAllRecords(
          group: manager.namespace,
        );
        await tester.pumpWidget(const SizedBox());
        app.dispose();
        manager.dispose();
        await store.write('downloads_${manager.namespace}', {});
        final state = File(
          '${store.directory.path}/downloads_${manager.namespace}.json',
        );
        if (await state.exists()) await state.delete();
        client.close(force: true);
        library.close();
      }
    },
    skip: fixtureServer.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
