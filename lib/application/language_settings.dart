import 'package:flutter/foundation.dart';
import '../infrastructure/local_store.dart';
import '../l10n/l10n.dart';

enum AppLanguage {
  system,
  en,
  ru;

  static AppLanguage restore(Object? value) => values.firstWhere(
    (language) => language.name == value,
    orElse: () => system,
  );
}

/// Installation preference, independent of the signed-in music account.
class LanguageSettings extends ChangeNotifier {
  LanguageSettings(this.store, {required String systemLanguage}) {
    _systemLanguage = systemLanguage;
    L10n.useLanguage(effectiveCode);
  }
  final LocalStore store;
  late String _systemLanguage;
  AppLanguage preference = AppLanguage.system;
  Map<String, dynamic> _saved = {};
  String get effectiveCode => preference == AppLanguage.system
      ? L10n.resolveLanguage(_systemLanguage)
      : preference.name;

  Future<void> initialize() async {
    _saved = await store.read('preferences');
    preference = AppLanguage.restore(_saved['language']);
    L10n.useLanguage(effectiveCode);
    notifyListeners();
  }

  Future<void> setPreference(AppLanguage language) async {
    preference = language;
    L10n.useLanguage(effectiveCode);
    notifyListeners();
    _saved = {..._saved, 'language': language.name};
    await store.write('preferences', Map.of(_saved));
  }

  void systemChanged(String language) {
    _systemLanguage = language;
    if (preference == AppLanguage.system) {
      L10n.useLanguage(effectiveCode);
      notifyListeners();
    }
  }
}
