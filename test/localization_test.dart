import 'dart:convert';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/app_controller.dart';
import 'package:simplefy/application/language_settings.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/domain/download_group.dart';
import 'package:simplefy/infrastructure/download_manager.dart';
import 'package:simplefy/infrastructure/local_store.dart';
import 'package:simplefy/l10n/l10n.dart';
import 'compact_ui_test.dart' show songs, folder;
import 'download_activity_test.dart'
    show MemoryDownloadBackend, DownloadFixtureLibrary;
import 'playlist_edit_controller_test.dart' show IdleAudio;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('simplefy-locale-');
    store = LocalStore(directory);
  });
  tearDown(() async {
    await store.write('flush', {});
    await directory.delete(recursive: true);
    L10n.useLanguage('ru');
  });

  test(
    'system is the default and unsupported primary languages use English',
    () async {
      for (final entry in {
        'ru': 'ru',
        'ru_RU': 'ru',
        'en': 'en',
        'en-GB': 'en',
        'de': 'en',
        'uk': 'en',
        'zh': 'en',
      }.entries) {
        final settings = LanguageSettings(store, systemLanguage: entry.key);
        await settings.initialize();
        expect(settings.preference, AppLanguage.system);
        expect(settings.effectiveCode, entry.value);
        settings.dispose();
      }
    },
  );

  test(
    'manual choice is immediate, persists independently, and returning to system uses its latest language',
    () async {
      await store.write('preferences', {'keep': 42});
      final settings = LanguageSettings(store, systemLanguage: 'ru');
      await settings.initialize();
      final write = settings.setPreference(AppLanguage.en);
      expect(settings.effectiveCode, 'en');
      settings.systemChanged('ru');
      expect(settings.effectiveCode, 'en');
      await write;
      expect((await store.read('preferences'))['keep'], 42);
      settings.dispose();
      final restored = LanguageSettings(store, systemLanguage: 'ru');
      await restored.initialize();
      expect(restored.preference, AppLanguage.en);
      restored.systemChanged('de');
      await restored.setPreference(AppLanguage.system);
      expect(restored.effectiveCode, 'en');
      restored.systemChanged('ru');
      expect(restored.effectiveCode, 'ru');
      restored.dispose();
    },
  );

  test(
    'catalogs have complete coverage, matching placeholders, and no untranslated English text',
    () {
      final en =
          jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
              as Map<String, dynamic>;
      final ru =
          jsonDecode(File('lib/l10n/app_ru.arb').readAsStringSync())
              as Map<String, dynamic>;
      final keys = en.keys.where((k) => !k.startsWith('@')).toSet();
      expect(ru.keys.where((k) => !k.startsWith('@')).toSet(), keys);
      for (final key in keys) {
        expect((en[key] as String).trim(), isNotEmpty, reason: key);
        expect((ru[key] as String).trim(), isNotEmpty, reason: key);
        if (key != 'russianAutonym') {
          expect(RegExp(r'[А-Яа-яЁё]').hasMatch(en[key]), false, reason: key);
        }
        Set<String> arguments(String text) =>
            RegExp(r'\{(\w+)[,}]').allMatches(text).map((m) => m[1]!).toSet();
        expect(arguments(en[key]), arguments(ru[key]), reason: key);
      }
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where(
                (f) =>
                    f.path.endsWith('.dart') && !f.path.contains('/generated/'),
              )) {
        expect(
          RegExp(r'[А-Яа-яЁё]').hasMatch(file.readAsStringSync()),
          false,
          reason: 'Keep application text in ARB: ${file.path}',
        );
      }
    },
  );

  test('plural rules and deferred failures translate at presentation time', () {
    const failure = AppFailure(AppMessage.theAccountHasChanged);
    const format = LocalizedFormatException(AppMessage.enterAPlaylistName);
    L10n.useLanguage('en');
    expect(L10n.current.trackCount(1), '1 track');
    expect(L10n.current.trackCount(2), '2 tracks');
    expect(failure.message, 'The account has changed');
    expect(format.message, 'Enter a playlist name');
    L10n.useLanguage('ru');
    expect(L10n.current.trackCount(1), '1 композиция');
    expect(L10n.current.trackCount(2), '2 композиции');
    expect(L10n.current.trackCount(11), '11 композиций');
    expect(L10n.current.trackCount(21), '21 композиция');
    expect(failure.message, 'Учётная запись изменилась');
    expect(format, isA<FormatException>());
    expect(format.message, 'Введите название плейлиста');
  });

  test(
    'native file-picker errors use app language instead of native error text',
    () {
      L10n.useLanguage('en');
      expect(
        AppController.friendly(
          PlatformException(
            code: 'import_failed',
            message: 'private native details',
          ),
        ),
        'Could not import music. Check file access and available storage.',
      );
      L10n.useLanguage('ru');
      expect(
        AppController.friendly(PlatformException(code: 'busy')),
        'Выбор файлов уже открыт',
      );
    },
  );

  test(
    'existing status and download failures change language without restarting tasks or changing the queue',
    () async {
      final settings = LanguageSettings(store, systemLanguage: 'en');
      final backend = MemoryDownloadBackend();
      final downloads = DownloadManager(
        store,
        DownloadFixtureLibrary(),
        backend: backend,
      );
      await downloads.initialize();
      final app = AppController(store, IdleAudio(), languages: settings)
        ..downloads = downloads;
      app.queue.replace(songs);
      final queue = app.queue.entries;
      app.status = AppMessage.connectionInterruptedWaitingToReconnect;
      app.groupPreparationError = const AppFailure(
        AppMessage.thisListHasNoTracks,
      );
      await downloads.apply(
        DownloadGroup(source: folder, tracks: [songs.first]),
      );
      backend.emit(
        backend.enqueued.single,
        TaskStatus.failed,
        TaskConnectionException('private URL'),
      );
      expect(downloads.activity!.title, 'Download error');
      expect(app.status, 'Connection interrupted. Waiting to reconnect');
      await settings.setPreference(AppLanguage.ru);
      expect(downloads.activity!.title, 'Ошибка загрузки');
      expect(downloads.errors.values.first, contains('Ошибка соединения'));
      expect(app.status, 'Соединение прервано. Ожидаем восстановления');
      expect(app.groupPreparationError, 'В этом списке нет композиций');
      expect(app.queue.entries, same(queue));
      expect(backend.enqueued, hasLength(1));
      app.dispose();
      await backend.events.close();
    },
  );
}
