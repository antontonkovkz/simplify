import 'package:flutter/widgets.dart';
import 'generated/app_localizations.dart';

/// Current strings for application services that do not own a BuildContext.
class L10n {
  static AppLocalizations _current = lookupAppLocalizations(const Locale('en'));
  static AppLocalizations get current => _current;
  static String resolveLanguage(String code) =>
      switch (code.toLowerCase().split(RegExp('[-_]')).first) {
        'ru' => 'ru',
        'es' => 'es',
        'pt' => 'pt_BR',
        'de' => 'de',
        'fr' => 'fr',
        _ => 'en',
      };

  static Locale localeForCode(String code) {
    final parts = resolveLanguage(code).split('_');
    return Locale.fromSubtags(
      languageCode: parts.first,
      countryCode: parts.length > 1 ? parts[1] : null,
    );
  }

  static void useLanguage(String code) {
    _current = lookupAppLocalizations(localeForCode(code));
  }
}
