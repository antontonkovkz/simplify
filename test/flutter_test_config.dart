import 'dart:async';
import 'package:simplefy/l10n/l10n.dart';

// Existing fixtures use Russian labels. Locale-specific tests override this.
Future<void> testExecutable(FutureOr<void> Function() main) async {
  L10n.useLanguage('ru');
  await main();
}
