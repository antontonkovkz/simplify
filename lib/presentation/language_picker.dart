import 'package:flutter/material.dart';
import '../application/app_controller.dart';
import '../application/language_settings.dart';
import '../l10n/l10n.dart';
import 'actions.dart';
import 'widgets.dart';

String languageLabel(BuildContext context, AppLanguage language) =>
    switch (language) {
      AppLanguage.system => context.l10n.systemLanguage,
      AppLanguage.en => context.l10n.englishAutonym,
      AppLanguage.ru => context.l10n.russianAutonym,
      AppLanguage.es => context.l10n.spanishAutonym,
      AppLanguage.ptBR => context.l10n.portugueseBrazilAutonym,
      AppLanguage.de => context.l10n.germanAutonym,
      AppLanguage.fr => context.l10n.frenchAutonym,
    };

Future<void> chooseAppLanguage(BuildContext context, AppController app) async {
  final selected = await appDialog<AppLanguage>(
    context,
    (context) => SimpleDialog(
      title: Text(context.l10n.language),
      children: [
        for (final language in AppLanguage.values)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, language),
            child: Semantics(
              selected: app.languages.preference == language,
              child: Row(
                children: [
                  Icon(
                    app.languages.preference == language
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(languageLabel(context, language))),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
          child: Text(context.l10n.languageHelp),
        ),
      ],
    ),
  );
  if (selected != null) {
    await perform(app, () => app.languages.setPreference(selected));
  }
}
