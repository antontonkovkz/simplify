import 'l10n/l10n.dart';
import 'dart:ui';
import 'application/diagnostics.dart';
import 'application/app_build.dart';
import 'package:package_info_plus/package_info_plus.dart';
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

bool _errorHandlersInstalled = false;
void installErrorHandlers() {
  if (_errorHandlersInstalled) return;
  _errorHandlersInstalled = true;
  final previous = FlutterError.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    Diagnostics.record('platform-unhandled', error);
    return true;
  };
  FlutterError.onError = (details) {
    Diagnostics.record('flutter-framework', details.exception);
    previous?.call(
      FlutterErrorDetails(
        exception: StateError(
          'Framework error: ${details.exception.runtimeType}',
        ),
        stack: details.stack,
        library: details.library,
      ),
    );
  };
}

Future<void> main() async {
  const bootstrap = String.fromEnvironment('BOOTSTRAP_SESSION');
  if (bootstrap.isNotEmpty) {
    throw StateError('Personal credentials are not allowed in a public build');
  }
  await launchApp();
}

Future<void> launchApp({String bootstrapSession = ''}) async {
  WidgetsFlutterBinding.ensureInitialized();
  installErrorHandlers();
  try {
    final app = await createController();
    runApp(SimplefyApp(app: app));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        Diagnostics.guard(
          'initialize-unhandled',
          app.initialize(bootstrapSession: bootstrapSession),
        ),
      );
    });
  } on Object catch (error) {
    Diagnostics.record('bootstrap', error);
    runApp(
      MaterialApp(
        theme: SimplefyTheme.dark,
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      L10n.current.couldNotCompleteTheOperationCheckYour,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => unawaited(
                        launchApp(bootstrapSession: bootstrapSession),
                      ),
                      child: Text(L10n.current.retry),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<AppController> createController({NetworkMonitor? network}) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    AppBuild.version = (await PackageInfo.fromPlatform()).version;
  } on Object catch (error) {
    Diagnostics.record('package-version', error);
  }
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
      locale: L10n.localeForCode(widget.app.languages.effectiveCode),
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
