import 'package:flutter/material.dart';
import '../application/app_controller.dart';
import '../l10n/l10n.dart';

class ShuffleButton extends StatelessWidget {
  const ShuffleButton({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final shuffled = app.queue.shuffled;
      final colors = Theme.of(context).colorScheme;
      return IconButton(
        tooltip: shuffled
            ? context.l10n.shuffle
            : context.l10n.sequentialPlayback,
        isSelected: shuffled,
        style: IconButton.styleFrom(
          foregroundColor: shuffled
              ? colors.onPrimaryContainer
              : colors.onSurfaceVariant,
          backgroundColor: shuffled
              ? colors.primaryContainer
              : Colors.transparent,
          minimumSize: const Size(48, 48),
        ),
        icon: Icon(
          shuffled ? Icons.shuffle_rounded : Icons.arrow_downward_rounded,
        ),
        onPressed: () => app.setShuffle(!app.queue.shuffled),
      );
    },
  );
}
