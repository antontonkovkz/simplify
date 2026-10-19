import 'library_item.dart';

/// Counts playlist occurrences, rather than unique audio files. A partial
/// snapshot can establish local availability without claiming a complete total.
class OfflineAvailability {
  const OfflineAvailability({
    required this.available,
    this.total,
    this.downloading = false,
    this.failed = false,
  });

  factory OfflineAvailability.resolve(
    Iterable<LibraryItem> tracks, {
    int? total,
    required bool Function(LibraryItem) isAvailable,
    Set<String> pending = const {},
    Set<String> errors = const {},
  }) {
    final items = tracks.toList();
    final available = items.where(isAvailable).length;
    return OfflineAvailability(
      available: available,
      total: total != null && total >= available ? total : null,
      downloading: items.any((item) => pending.contains(item.id)),
      failed: items.any((item) => errors.contains(item.id)),
    );
  }

  final int available;
  final int? total;
  final bool downloading;
  final bool failed;
  bool get complete => total != null && total! > 0 && available == total;
}
