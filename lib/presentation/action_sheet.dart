import 'package:flutter/material.dart';

/// A content-sized action menu that can scroll on short screens or large text.
Future<T?> showActionSheet<T>({
  required BuildContext context,
  required String title,
  required List<Widget> Function(BuildContext) actions,
  String? message,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    builder: (sheet) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheet).height * .78,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: ListTileTheme(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            minLeadingWidth: 24,
            horizontalTitleGap: 12,
            minVerticalPadding: 8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: Theme.of(sheet).textTheme.titleMedium,
                    ),
                  ),
                ),
                ...actions(sheet),
                if (message != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Text(
                      message,
                      style: Theme.of(sheet).textTheme.bodySmall?.copyWith(
                        color: Theme.of(sheet).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
