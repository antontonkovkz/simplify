import 'l10n/l10n.dart';
import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'application/app_controller.dart';
import 'application/language_settings.dart';
import 'application/ports.dart';
import 'infrastructure/local_store.dart';
import 'infrastructure/music_audio_handler.dart';
import 'presentation/library_screens.dart';
import 'presentation/widgets.dart';
import 'presentation/app_theme.dart';
import 'presentation/login_screen.dart';
import 'presentation/download_status_banner.dart';
export 'presentation/login_screen.dart';

Future<void> main() async {
  const bootstrap = String.fromEnvironment('BOOTSTRAP_SESSION');
  if (bootstrap.isNotEmpty) {
    throw StateError('Personal credentials are not allowed in a public build');
  }
  await launchApp();
}

Future<void> launchApp({String bootstrapSession = ''}) async {
  final app = await createController();
  runApp(SimplefyApp(app: app));
  unawaited(app.initialize(bootstrapSession: bootstrapSession));
}

Future<AppController> createController({NetworkMonitor? network}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await LocalStore.open();
  final languages = LanguageSettings(
    store,
    systemLanguage:
        WidgetsBinding.instance.platformDispatcher.locale.languageCode,
  );
  await languages.initialize();
  final audio = await AudioService.init(
    builder: MusicAudioHandler.new,
    config: AudioServiceConfig(
      androidNotificationChannelId: 'online.tavhome.simplefy.audio',
      androidNotificationChannelName: L10n.current.music,
      androidNotificationIcon: 'drawable/ic_stat_music',
      androidStopForegroundOnPause: false,
    ),
  );
  await (await AudioSession.instance).configure(
    const AudioSessionConfiguration.music(),
  );
  return AppController(store, audio, network: network, languages: languages);
}

class SimplefyApp extends StatefulWidget {
  const SimplefyApp({super.key, required this.app});
  final AppController app;
  @override
  State<SimplefyApp> createState() => _SimplefyAppState();
}

class _SimplefyAppState extends State<SimplefyApp> with WidgetsBindingObserver {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<String>? _messages;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.app.languages.addListener(_languageChanged);
    _messages = widget.app.messages.stream.listen((text) {
      final messenger = _messenger.currentState;
      messenger?.clearSnackBars();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
    });
  }

  void _languageChanged() => _messenger.currentState?.clearSnackBars();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(widget.app.save());
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.app.resumeTransfers());
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    widget.app.languages.systemChanged(
      locales?.firstOrNull?.languageCode ?? 'en',
    );
    _messenger.currentState?.clearSnackBars();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messages?.cancel();
    widget.app.languages.removeListener(_languageChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.app.languages,
    builder: (context, _) => MaterialApp(
      locale: Locale(widget.app.languages.effectiveCode),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      navigatorObservers: [libraryRouteObserver],
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messenger,
      title: 'Simplefy',
      builder: (context, child) =>
          DownloadStatusHost(app: widget.app, child: child!),
      theme: SimplefyTheme.dark,
      home: ListenableBuilder(
        listenable: widget.app,
        builder: (context, _) => AnimatedSwitcher(
          duration: motionDuration,
          child: !widget.app.initialized
              ? const Scaffold(
                  key: ValueKey('loading'),
                  body: Center(child: CircularProgressIndicator()),
                )
              : widget.app.hasLibrary
              ? AppShell(
                  key: ValueKey(widget.app.libraryIdentity),
                  app: widget.app,
                )
              : LoginScreen(key: const ValueKey('login'), app: widget.app),
        ),
      ),
    ),
  );
}
