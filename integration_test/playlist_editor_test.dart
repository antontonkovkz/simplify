import 'package:integration_test/integration_test.dart';
import '../test/playlist_editor_ui_test.dart' as scenarios;

// Run the same editor gestures against the native Flutter engine. All media and
// server writes are fixtures; no account or physical-device data is required.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  scenarios.main();
}
