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
        'de': 'de',
        'de-DE': 'de',
        'de_AT': 'de',
        'es-MX': 'es',
        'es_ES': 'es',
        'fr-CA': 'fr',
        'pt': 'pt_BR',
        'pt-BR': 'pt_BR',
        'pt_PT': 'pt_BR',
        'ja': 'en',
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
      restored.systemChanged('ja');
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
      final keys = en.keys.where((k) => !k.startsWith('@')).toSet();
      Set<String> arguments(String text) =>
          RegExp(r'\{(\w+)[,}]').allMatches(text).map((m) => m[1]!).toSet();
      for (final locale in ['en', 'ru', 'es', 'pt', 'pt_BR', 'de', 'fr']) {
        final catalog =
            jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
                as Map<String, dynamic>;
        expect(
          catalog.keys.where((k) => !k.startsWith('@')).toSet(),
          keys,
          reason: locale,
        );
        for (final key in keys) {
          expect(
            (catalog[key] as String).trim(),
            isNotEmpty,
            reason: '$locale/$key',
          );
          expect(
            arguments(catalog[key] as String),
            arguments(en[key] as String),
            reason: '$locale/$key',
          );
          if (locale != 'ru' && key != 'russianAutonym') {
            expect(
              RegExp(r'[А-Яа-яЁё]').hasMatch(catalog[key] as String),
              false,
              reason: '$locale/$key',
            );
          }
        }
      }
      final pt =
          jsonDecode(File('lib/l10n/app_pt.arb').readAsStringSync())
              as Map<String, dynamic>;
      final ptBR =
          jsonDecode(File('lib/l10n/app_pt_BR.arb').readAsStringSync())
              as Map<String, dynamic>;
      expect(
        {for (final k in keys) k: pt[k]},
        {for (final k in keys) k: ptBR[k]},
        reason: 'Portuguese fallback must match Brazilian Portuguese',
      );
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

  test(
    'all new language preferences restore and translate deferred messages with correct regional locales',
    () async {
      final expected = {
        AppLanguage.es: [
          'es',
          'Reproducir',
          '0 canciones',
          '1 canción',
          '2 canciones',
          'La cuenta ha cambiado',
        ],
        AppLanguage.ptBR: [
          'pt_BR',
          'Reproduzir',
          '0 faixa',
          '1 faixa',
          '2 faixas',
          'A conta mudou',
        ],
        AppLanguage.de: [
          'de',
          'Abspielen',
          '0 Titel',
          '1 Titel',
          '2 Titel',
          'Das Konto wurde geändert',
        ],
        AppLanguage.fr: [
          'fr',
          'Lire',
          '0 morceau',
          '1 morceau',
          '2 morceaux',
          'Le compte a changé',
        ],
      };
      const failure = AppFailure(AppMessage.theAccountHasChanged);
      for (final entry in expected.entries) {
        final settings = LanguageSettings(store, systemLanguage: 'ja');
        await settings.initialize();
        await settings.setPreference(entry.key);
        settings.systemChanged('ru');
        expect(settings.effectiveCode, entry.value[0]);
        expect(L10n.current.localeName, entry.value[0]);
        expect(L10n.current.play, entry.value[1]);
        for (var count = 0; count <= 2; count++) {
          expect(L10n.current.trackCount(count), entry.value[2 + count]);
        }
        expect(failure.message, entry.value[5]);
        settings.dispose();
        final restored = LanguageSettings(store, systemLanguage: 'en');
        await restored.initialize();
        expect(restored.preference, entry.key);
        expect(restored.effectiveCode, entry.value[0]);
        restored.dispose();
      }
      expect(L10n.localeForCode('pt-BR').countryCode, 'BR');
      expect(L10n.localeForCode('pt-BR').languageCode, 'pt');
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
