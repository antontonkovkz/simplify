import 'package:integration_test/integration_test.dart';
import '../test/group_play_test.dart' as scenarios;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  scenarios.main();
}
