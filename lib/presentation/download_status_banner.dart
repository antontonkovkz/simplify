import '../l10n/l10n.dart';
import 'package:flutter/material.dart';
import '../application/app_controller.dart';
import '../domain/download_activity.dart';
import 'actions.dart';
import 'widgets.dart';

/// Above the navigator so the same status stays visible across all routes.
class DownloadStatusHost extends StatelessWidget {
  const DownloadStatusHost({super.key, required this.app, required this.child});
  final AppController app;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    child: child,
    builder: (context, navigator) {
      final activity = app.downloadActivity;
      return ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              AnimatedSwitcher(
                duration: motionDuration,
                reverseDuration: motionDuration,
                transitionBuilder: (child, animation) => SizeTransition(
                  sizeFactor: animation,
                  alignment: Alignment.topCenter,
                  child: FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position:
                          Tween(
                            begin: const Offset(0, -.3),
                            end: Offset.zero,
                          ).animate(
                            CurvedAnimation(
                              parent: animation,
                              curve: Curves.easeOutCubic,
                            ),
                          ),
                      child: child,
                    ),
                  ),
                ),
                child: activity == null
                    ? const SizedBox.shrink(key: ValueKey('no-downloads'))
                    : KeyedSubtree(
                        key: const ValueKey('download-status'),
                        child: AnimatedSize(
                          duration: motionDuration,
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.sizeOf(context).height * .45,
                            ),
                            child: SingleChildScrollView(
                              child: DownloadStatusBanner(
                                activity: activity,
                                onContinue: () =>
                                    perform(app, app.continueDownloads),
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
              Expanded(child: navigator!),
            ],
          ),
        ),
      );
    },
  );
}

class DownloadStatusBanner extends StatelessWidget {
  const DownloadStatusBanner({
    super.key,
    required this.activity,
    required this.onContinue,
  });
  final DownloadActivity activity;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHigh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final separateAction =
              constraints.maxWidth < 360 ||
              MediaQuery.textScalerOf(context).scale(14) > 20;
          Widget action() => TextButton(
            onPressed: activity.continuing ? null : onContinue,
            child: Text(
              activity.continuing
                  ? context.l10n.continuing
                  : context.l10n.continueAction,
            ),
          );
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      activity.detail == null
                          ? Icons.downloading_rounded
                          : Icons.info_outline_rounded,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        activity.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    if (activity.canContinue && !separateAction) action(),
                  ],
                ),
                if (activity.canContinue && separateAction)
                  Align(alignment: Alignment.centerRight, child: action()),
                if (activity.currentTrack case final track?)
                  Text(
                    '$track${activity.activeCount > 1 ? context.l10n.more((activity.activeCount - 1).toString()) : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (activity.detail case final detail?)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      detail,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 6),
                TweenAnimationBuilder<double>(
                  tween: Tween(end: activity.fraction),
                  duration: motionDuration,
                  builder: (context, value, _) => LinearProgressIndicator(
                    value: activity.preparing ? null : value,
                    minHeight: 3,
                  ),
                ),
                if (activity.total > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      context.l10n.ofLeft(
                        (activity.completed).toString(),
                        (activity.total).toString(),
                        (activity.remaining).toString(),
                        ((activity.fraction * 100).floor()).toString(),
                      ),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
