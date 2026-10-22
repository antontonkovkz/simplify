import '../l10n/l10n.dart';
import 'package:flutter/material.dart';
import '../application/app_controller.dart';
import 'widgets.dart';
import 'language_picker.dart';
import 'brand_mark.dart';
import 'actions.dart';
import 'about_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.app});
  final AppController app;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController(
    text: const String.fromEnvironment('SERVER_URL'),
  );
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _serverFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  bool get _focused =>
      _serverFocus.hasFocus ||
      _usernameFocus.hasFocus ||
      _passwordFocus.hasFocus;
  @override
  void initState() {
    super.initState();
    for (final node in [_serverFocus, _usernameFocus, _passwordFocus]) {
      node.addListener(_focusChanged);
    }
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  bool _busy = false;
  bool _showPassword = false;
  Object? _error;
  Future<void> _login() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.login(_server.text, _username.text, _password.text);
      _password.clear();
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (error, stack) {
      assert(() {
        debugPrintStack(
          label: 'Connection failure: ${error.runtimeType}',
          stackTrace: stack,
        );
        return true;
      }());
      if (mounted) {
        setState(() {
          _error = error;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = _focused || MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      appBar: Navigator.canPop(context) ? AppBar(toolbarHeight: 48) : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 20 : 28,
              vertical: compact ? 12 : 24,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _LoginHeader(compact: compact),
                  TextField(
                    controller: _server,
                    focusNode: _serverFocus,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: context.l10n.jellyfinServer,
                      hintText: 'https://music.example.com',
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _username,
                    focusNode: _usernameFocus,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.username],
                    decoration: InputDecoration(
                      labelText: context.l10n.username,
                      prefixIcon: Icon(Icons.person_outline_rounded),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _password,
                    focusNode: _passwordFocus,
                    obscureText: !_showPassword,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _login(),
                    decoration: InputDecoration(
                      labelText: context.l10n.password,
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      suffixIcon: IconButton(
                        tooltip: _showPassword
                            ? context.l10n.hidePassword
                            : context.l10n.showPassword,
                        onPressed: () => setState(() {
                          _showPassword = !_showPassword;
                        }),
                        icon: Icon(
                          _showPassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                    ),
                  ),
                  AnimatedSize(
                    duration: motionDuration,
                    child: _error == null
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              AppController.friendly(_error!),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(height: 24),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 52),
                    child: FilledButton(
                      onPressed: _busy ? null : _login,
                      child: AnimatedSwitcher(
                        duration: motionDuration,
                        child: _busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(context.l10n.connect),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: widget.app.importing
                        ? null
                        : () => importMusicMenu(context, widget.app),
                    icon: const Icon(Icons.audio_file_outlined),
                    label: Text(context.l10n.musicFromFilesWithoutAServer),
                  ),
                  TextButton.icon(
                    onPressed: () => chooseAppLanguage(context, widget.app),
                    icon: const Icon(Icons.language_rounded),
                    label: Text(context.l10n.language),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      slideRoute(const AboutScreen()),
                    ),
                    icon: const Icon(Icons.info_outline_rounded),
                    label: Text(context.l10n.aboutSimplefy),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final node in [_serverFocus, _usernameFocus, _passwordFocus]) {
      node.removeListener(_focusChanged);
      node.dispose();
    }
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }
}

class _LoginHeader extends StatelessWidget {
  const _LoginHeader({required this.compact});
  final bool compact;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      TweenAnimationBuilder<double>(
        tween: Tween(end: compact ? 40 : 96),
        duration: motionDuration,
        curve: Curves.easeOutCubic,
        builder: (_, size, _) => BrandMark(size: size),
      ),
      AnimatedContainer(duration: motionDuration, height: compact ? 6 : 16),
      AnimatedDefaultTextStyle(
        duration: motionDuration,
        style: (compact
            ? Theme.of(context).textTheme.titleLarge
            : Theme.of(context).textTheme.displaySmall)!,
        child: const Text('Simplefy', textAlign: TextAlign.center),
      ),
      AnimatedSize(
        duration: motionDuration,
        child: compact
            ? const SizedBox.shrink()
            : const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Just music. Just play.\nYour music. Your way.',
                  textAlign: TextAlign.center,
                ),
              ),
      ),
      AnimatedSize(
        duration: motionDuration,
        child: compact
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  context.l10n.firstRunHint,
                  textAlign: TextAlign.center,
                ),
              ),
      ),
      AnimatedContainer(duration: motionDuration, height: compact ? 16 : 32),
    ],
  );
}
