import 'package:flutter/material.dart';
import '../application/app_controller.dart';
import 'actions.dart';
import 'widgets.dart';

class QueuePreparationStatus extends StatelessWidget {
  const QueuePreparationStatus({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final source = app.preparingGroup;
    final error = app.groupPreparationError;
    return AnimatedSize(
      duration: motionDuration,
      child: source == null && error == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: [
                  if (source != null)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  Expanded(
                    child: Text(
                      source == null
                          ? error!
                          : '${app.resolvingGroup ? 'Готовим очередь' : 'Запускаем музыку'} · ${source.name}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (source == null && app.failedGroup != null)
                    TextButton(
                      onPressed: () => perform(app, () async {
                        await app.playGroup(app.failedGroup!);
                      }),
                      child: const Text('Повторить'),
                    ),
                ],
              ),
            ),
    );
  }
}
