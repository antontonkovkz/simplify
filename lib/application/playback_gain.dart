/// Applies a per-track player gain; a newer request cancels an older ramp.
/// Device/system volume is never changed.
class PlaybackGain {
  PlaybackGain(this.apply);
  final Future<void> Function(double) apply;
  double _current = 1;
  int _generation = 0;

  void cancel() => _generation++;

  Future<void> set(double target, {bool smooth = false}) async {
    final generation = ++_generation;
    final value = target.isFinite ? target.clamp(0.0, 1.0) : 1.0;
    final start = _current;
    final steps = smooth ? 10 : 1;
    for (var step = 1; step <= steps; step++) {
      if (generation != _generation) return;
      _current = start + (value - start) * step / steps;
      await apply(_current);
      if (step < steps) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  }
}
