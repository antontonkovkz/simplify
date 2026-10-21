/// A platform-independent snapshot of the current download batch.
class DownloadActivity {
  const DownloadActivity({
    required this.total,
    required this.completed,
    required this.fraction,
    required this.title,
    this.detail,
    this.currentTrack,
    this.activeCount = 0,
    this.failedCount = 0,
    this.canContinue = false,
    this.continuing = false,
    this.preparing = false,
  });

  final int total;
  final int completed;
  final double fraction;
  final String title;
  final String? detail;
  final String? currentTrack;
  final int activeCount;
  final int failedCount;
  final bool canContinue;
  final bool continuing;
  final bool preparing;
  int get remaining => total - completed;
}
