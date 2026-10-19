import 'main.dart' as app;

/// Explicit personal build. Shares the public app identity and Keychain so
/// installing either variant as an update preserves the existing account.
Future<void> main() => app.launchApp(
  bootstrapSession: const String.fromEnvironment('BOOTSTRAP_SESSION'),
);
