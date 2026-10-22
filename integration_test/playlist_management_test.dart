import 'package:integration_test/integration_test.dart';
import '../test/playlist_management_ui_test.dart' as scenarios;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  scenarios.main();
}
