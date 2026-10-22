import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/language_settings.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/domain/volume_normalization.dart';
import 'package:simplefy/domain/download_activity.dart';
import 'package:simplefy/presentation/download_status_banner.dart';
import 'package:simplefy/infrastructure/local_store.dart';
import 'package:simplefy/l10n/l10n.dart';
import 'package:simplefy/main.dart';
import 'package:simplefy/presentation/library_screens.dart';
import 'package:simplefy/presentation/player_screens.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/settings_screen.dart';
import 'package:simplefy/presentation/widgets.dart';
import 'compact_ui_test.dart' show TestApp, songs, folder;

class MemoryLocaleStore extends LocalStore {
  MemoryLocaleStore(super.directory);
  final values = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>> read(String key) async =>
      Map.of(values[key] ?? {});
  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    values[key] = Map.of(value);
  }
}

class LocaleFixture extends TestApp {
  LocaleFixture(LanguageSettings settings) : super(languageSettings: settings);
  bool showLibrary = true;
  @override
  VolumeNormalizationMode get normalizationMode =>
      VolumeNormalizationMode.track;
  @override
  bool get initialized => true;
  @override
  bool get hasLibrary => showLibrary;
  final _messages = StreamController<String>.broadcast();
  @override
  StreamController<String> get messages => _messages;
  @override
  Future<void> save() async {}
  @override
  Future<void> resumeTransfers() async {}
  @override
  Future<void> login(String server, String username, String password) async =>
      throw const AppFailure(AppMessage.incorrectUsernameOrPassword);
  @override
  void dispose() {
    messages.close();
    super.dispose();
  }
}

void main() {
  late Directory directory;
  late LocalStore store;
  late LocaleFixture app;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('simplefy-locale-ui-');
    store = MemoryLocaleStore(directory);
    app = LocaleFixture(LanguageSettings(store, systemLanguage: 'en'));
  });
  tearDown(() async {
    app.dispose();
    await store.write('flush', {});
    await directory.delete(recursive: true);
    L10n.useLanguage('ru');
  });
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize =
        const Size(390, 844) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(SimplefyApp(app: app));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'English library, search, context actions and playback controls preserve media names',
    (tester) async {
      app.queue.replace(songs);
      await mount(tester);
      expect(find.text('Collections'), findsWidgets);
      expect(find.text('Playlists'), findsWidgets);
      expect(find.text(folder.name), findsOneWidget);
      expect(find.byTooltip('Previous'), findsOneWidget);
      expect(find.byTooltip('Next'), findsOneWidget);
      expect(find.byTooltip('Shuffle'), findsOneWidget);
      await tester.longPress(find.text(folder.name));
      await tester.pumpAndSettle();
      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      Navigator.of(tester.element(find.byType(AppShell))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text(folder.name));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(find.text(songs.first.title), findsWidgets);
      expect(find.byTooltip('Search'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'language changes update covered routes without resetting the queue or its search',
    (tester) async {
      app.queue.replace(songs);
      final queue = app.queue.entries;
      await mount(tester);
      await tester.tap(find.byTooltip('Queue'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Queue').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Кино');
      final navigator = Navigator.of(tester.element(find.byType(QueueScreen)));
      navigator.push(slideRoute(SettingsScreen(app: app)));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      await tester.tap(find.text('Language'));
      await tester.pumpAndSettle();
      expect(find.text('System language'), findsWidgets);
      await tester.tap(find.text('Русский'));
      await tester.pumpAndSettle();
      expect(find.text('Настройки'), findsOneWidget);
      expect(find.text('Язык'), findsOneWidget);
      expect(
        (await tester.runAsync(() => store.read('preferences')))!['language'],
        'ru',
      );
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('Очередь'), findsWidgets);
      expect(find.byTooltip('Закрыть поиск'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Кино',
      );
      expect(app.queue.entries, same(queue));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'login can change language without clearing entered credentials or freezing error translation',
    (tester) async {
      app.showLibrary = false;
      await mount(tester);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('Jellyfin server'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).at(0),
        'https://example.com',
      );
      await tester.enterText(find.byType(TextField).at(1), 'fixture');
      await tester.enterText(find.byType(TextField).at(2), 'fixture');
      await tester.ensureVisible(find.text('Connect'));
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Incorrect username or password'), findsOneWidget);
      await tester.ensureVisible(find.text('Language'));
      await tester.tap(find.text('Language'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Русский'));
      await tester.pumpAndSettle();
      expect(find.text('Неверный логин или пароль'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'fixture',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text,
        'fixture',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unsupported primary system language falls back to English even with Russian as a secondary language',
    (tester) async {
      app.showLibrary = false;
      app.languages.systemChanged('ru');
      await mount(tester);
      expect(find.text('Подключиться'), findsOneWidget);
      tester.platformDispatcher.localesTestValue = const [
        Locale('ja'),
        Locale('ru'),
      ];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await tester.pumpAndSettle();
      expect(find.text('Connect'), findsOneWidget);
      expect(app.languages.effectiveCode, 'en');
      await tester.runAsync(() => app.languages.setPreference(AppLanguage.ru));
      tester.platformDispatcher.localesTestValue = const [Locale('en')];
      await tester.pumpAndSettle();
      expect(find.text('Подключиться'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'English settings and login remain usable with large text at narrow width',
    (tester) async {
      tester.view.physicalSize =
          const Size(320, 568) * tester.view.devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      Future<void> show(Widget screen) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: SimplefyTheme.dark,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: screen,
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(SettingsScreen(app: app));
      await tester.scrollUntilVisible(find.text('Simplefy · 0.8.0'), 180);
      expect(tester.takeException(), isNull);
      await show(LoginScreen(app: app));
      await tester.ensureVisible(find.byTooltip('Show password'));
      await tester.tap(find.byTooltip('Show password'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Hide password'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final language in [
    AppLanguage.es,
    AppLanguage.ptBR,
    AppLanguage.de,
    AppLanguage.fr,
  ]) {
    testWidgets(
      '${language.name} applies through picker and remains usable on narrow screens with large text',
      (tester) async {
        await mount(tester);
        tester.view.physicalSize =
            const Size(320, 568) * tester.view.devicePixelRatio;
        final navigator = Navigator.of(tester.element(find.byType(AppShell)));
        navigator.push(slideRoute(SettingsScreen(app: app)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Language'));
        await tester.pumpAndSettle();
        final autonym = switch (language) {
          AppLanguage.es => 'Español',
          AppLanguage.ptBR => 'Português (Brasil)',
          AppLanguage.de => 'Deutsch',
          _ => 'Français',
        };
        await tester.ensureVisible(find.text(autonym));
        await tester.tap(find.text(autonym));
        await tester.pumpAndSettle();
        final strings = L10n.current;
        expect(app.languages.preference, language);
        expect(find.text(strings.settings), findsOneWidget);
        expect(find.text(strings.language), findsOneWidget);
        expect(find.text(strings.systemLanguage), findsNothing);
        final data = await tester.runAsync(() => store.read('preferences'));
        expect(data!['language'], language.name);
        navigator.pop();
        await tester.pumpAndSettle();
        expect(find.text(strings.collections), findsWidgets);
        await tester.longPress(find.text(folder.name));
        await tester.pumpAndSettle();
        expect(find.text(strings.addToQueue), findsOneWidget);
        navigator.pop();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());

        Future<void> show(Widget screen) async {
          await tester.pumpWidget(
            MaterialApp(
              locale: L10n.localeForCode(language.localeCode),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              theme: SimplefyTheme.dark,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(2)),
                child: child!,
              ),
              home: screen,
            ),
          );
          await tester.pumpAndSettle();
        }

        await show(SettingsScreen(app: app));
        await tester.scrollUntilVisible(find.text('Simplefy · 0.8.0'), 180);
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.text(strings.language), -180);
        await Scrollable.ensureVisible(
          tester.element(find.text(strings.language)),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(strings.language));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Français').last);
        expect(tester.takeException(), isNull);
        Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
        await tester.pumpAndSettle();
        await show(LoginScreen(app: app));
        await tester.ensureVisible(find.byTooltip(strings.showPassword));
        await tester.tap(find.byTooltip(strings.showPassword));
        await tester.pumpAndSettle();
        expect(find.byTooltip(strings.hidePassword), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        app.queue.replace(songs);
        await show(QueueScreen(app: app));
        expect(find.text(strings.queue), findsWidgets);
        expect(find.byTooltip(strings.shuffle), findsOneWidget);
        await tester.tap(find.byTooltip(strings.saveQueue));
        await tester.pumpAndSettle();
        await tester.tap(find.text(strings.saveAs));
        await tester.pumpAndSettle();
        expect(find.text(strings.saveQueueAsPlaylist), findsOneWidget);
        expect(find.text(strings.playlistName), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(strings.cancel));
        await tester.pumpAndSettle();
        await show(
          Scaffold(
            body: SingleChildScrollView(
              child: DownloadStatusBanner(
                activity: DownloadActivity(
                  total: 10,
                  completed: 3,
                  fraction: .3,
                  title: strings.downloadError2,
                  detail: strings
                      .connectionLostDownloadsWillContinueAutomaticallyWhen,
                  currentTrack: songs.first.title,
                  canContinue: true,
                ),
                onContinue: () {},
              ),
            ),
          ),
        );
        expect(find.text(strings.continueAction), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'queue releases player height as soon as keyboard resizes a short screen',
    (tester) async {
      await app.languages.setPreference(AppLanguage.fr);
      app.queue.replace(songs);
      tester.view.physicalSize =
          const Size(320, 568) * tester.view.devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('fr'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: SimplefyTheme.dark,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: QueueScreen(app: app),
        ),
      );
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding(
        bottom: 310 * tester.view.devicePixelRatio,
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
