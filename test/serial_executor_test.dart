import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/serial_executor.dart';

void main() {
  test(
    'resource mutations keep invocation order across asynchronous waits',
    () async {
      final executor = SerialExecutor();
      final gate = Completer<void>();
      final events = <String>[];
      final first = executor.run(() async {
        events.add('first-start');
        await gate.future;
        events.add('first-end');
      });
      final second = executor.run(() async {
        events.add('second');
      });
      await Future<void>.delayed(Duration.zero);
      expect(events, ['first-start']);
      gate.complete();
      await Future.wait([first, second]);
      expect(events, ['first-start', 'first-end', 'second']);
    },
  );
  test(
    'a failed mutation does not prevent cleanup or subsequent work',
    () async {
      final executor = SerialExecutor();
      final failed = executor.run<void>(() async {
        throw StateError('fixture');
      });
      final cleanup = executor.run(() async => 42);
      await expectLater(failed, throwsStateError);
      expect(await cleanup, 42);
    },
  );
}
