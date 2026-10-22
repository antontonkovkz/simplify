import 'library_item.dart';

class BrowseLocation {
  const BrowseLocation({this.tab = 0, this.path = const []});
  final int tab;
  final List<LibraryItem> path;
  Map<String, dynamic> toJson() => {
    'tab': tab,
    'path': path.map((e) => e.toJson()).toList(),
  };
  factory BrowseLocation.fromJson(Map<String, dynamic> json) => BrowseLocation(
    tab: (json['tab'] is int ? json['tab'] as int : 0).clamp(0, 1),
    path: decodeItems(json['path']).where((e) => !e.isTrack).toList(),
  );
}
