import 'package:connectivity_plus/connectivity_plus.dart';
import '../application/ports.dart';

class DeviceNetworkMonitor implements NetworkMonitor {
  final _connectivity = Connectivity();
  static NetworkKind _kind(List<ConnectivityResult> values) {
    if (values.contains(ConnectivityResult.wifi) ||
        values.contains(ConnectivityResult.ethernet)) {
      return NetworkKind.unmetered;
    }
    if (values.contains(ConnectivityResult.mobile)) return NetworkKind.cellular;
    if (values.contains(ConnectivityResult.none)) return NetworkKind.offline;
    return NetworkKind.other;
  }

  @override
  Future<NetworkKind> current() async =>
      _kind(await _connectivity.checkConnectivity());
  @override
  Stream<NetworkKind> get changes =>
      _connectivity.onConnectivityChanged.map(_kind);
}
