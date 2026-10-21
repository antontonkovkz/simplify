import 'package:flutter/widgets.dart';
import '../domain/library_item.dart';
import 'app_strings.dart';
import 'generated/app_localizations.dart';
export 'app_strings.dart';
export 'app_message.dart';
export 'generated/app_localizations.dart';

extension LocalizedContext on BuildContext {
  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ??
      L10n.current;
}

extension LocalizedLibraryName on LibraryItem {
  String get displayName => id == 'local:root' ? L10n.current.onDevice : name;
}
