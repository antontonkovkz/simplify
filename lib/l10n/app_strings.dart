import 'package:flutter/widgets.dart';
import 'generated/app_localizations.dart';

/// Current strings for application services that do not own a BuildContext.
class L10n {
  static AppLocalizations _current = lookupAppLocalizations(const Locale('en'));
  static AppLocalizations get current => _current;
  static String resolveLanguage(String code) =>
      code.toLowerCase().split(RegExp('[-_]')).first == 'ru' ? 'ru' : 'en';
  static void useLanguage(String code) {
    _current = lookupAppLocalizations(Locale(resolveLanguage(code)));
  }
}
