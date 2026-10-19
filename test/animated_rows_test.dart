import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/presentation/widgets.dart';

void main() {
  Widget screen(List<String> items, {void Function()? built}) => MaterialApp(
    home: Scaffold(
      body: AnimatedRows<String>(
        items: items,
        idOf: (s) => s,
        builder: (_, item, index) {
          built?.call();
          return SizedBox(height: 60, child: Text(item));
        },
      ),
    ),
  );
  testWidgets('large lists build only visible rows', (tester) async {
    var count = 0;
    await tester.pumpWidget(
      screen(List.generate(10000, (i) => '$i'), built: () => count++),
    );
    await tester.pumpAndSettle();
    expect(count, lessThan(40));
    expect(find.text('9999'), findsNothing);
  });
  testWidgets('insert, remove and server reorder animate without losing rows', (
    tester,
  ) async {
    await tester.pumpWidget(screen(['a', 'b', 'c']));
    await tester.pumpAndSettle();
    await tester.pumpWidget(screen(['c', 'a', 'd']));
    await tester.pump();
    expect(
      find.text('b'),
      findsOneWidget,
      reason: 'Removed data remains during its exit transition',
    );
    await tester.pumpAndSettle();
    expect(find.text('b'), findsNothing);
    expect(find.text('a'), findsOneWidget);
    expect(find.text('c'), findsOneWidget);
    expect(find.text('d'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('c')).dy,
      lessThan(tester.getTopLeft(find.text('a')).dy),
    );
    expect(tester.takeException(), null);
  });
  testWidgets('finishing an entrance does not cancel a held context gesture', (
    tester,
  ) async {
    var opened = 0;
    Widget list(List<String> items) => MaterialApp(
      home: Scaffold(
        body: AnimatedRows<String>(
          items: items,
          idOf: (item) => item,
          builder: (_, item, _) => ItemGestures(
            onMenu: () => opened++,
            child: SizedBox(height: 60, child: Text(item)),
          ),
        ),
      ),
    );
    await tester.pumpWidget(list(['a']));
    await tester.pumpAndSettle();
    await tester.pumpWidget(list(['b', 'a']));
    await tester.pump(const Duration(milliseconds: 30));
    final gesture = await tester.startGesture(tester.getCenter(find.text('b')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(opened, 1);
  });
}
