import '../l10n/l10n.dart';
import 'package:flutter/material.dart';
import '../application/app_controller.dart';
import 'widgets.dart';

class CatalogUpdateStatus extends StatelessWidget {
  const CatalogUpdateStatus({
    super.key,
    required this.app,
    required this.cacheKey,
  });
  final AppController app;
  final String cacheKey;
  @override
  Widget build(BuildContext context) {
    final busy = app.catalogUpdating(cacheKey);
    final error = app.catalogError(cacheKey);
    return AnimatedSize(
      duration: motionDuration,
      child: busy
          ? const LinearProgressIndicator(minHeight: 2)
          : error == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                context.l10n.couldNotRefreshTheLibrary,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
    );
  }
}
