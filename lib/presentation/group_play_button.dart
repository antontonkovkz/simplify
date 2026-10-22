import '../l10n/l10n.dart';
import 'package:flutter/material.dart';

/// Independent hit target: playing a group never opens its navigation route.
class GroupPlayButton extends StatefulWidget {
  const GroupPlayButton({super.key, required this.name, required this.onPlay});
  final String name;
  final Future<void> Function() onPlay;
  @override
  State<GroupPlayButton> createState() => _GroupPlayButtonState();
}

class _GroupPlayButtonState extends State<GroupPlayButton> {
  bool _busy = false;
  Future<void> _play() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onPlay();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    // A disabled button must still consume taps rather than open its row.
    excludeFromSemantics: true,
    onTap: () {},
    child: IconButton(
      tooltip: context.l10n.play2((widget.name).toString()),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      onPressed: _busy ? null : _play,
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: _busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.play_arrow_rounded),
      ),
    ),
  );
}
