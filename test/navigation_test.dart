import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/presentation/widgets.dart';

void main() {
  Future<void> openList(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                slideRoute(
                  Scaffold(
                    appBar: AppBar(title: const Text('Nested list')),
                    body: ListView.builder(
                      itemCount: 100,
                      itemBuilder: (_, index) =>
                          ListTile(title: Text('Row $index')),
                    ),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('left edge swipe interactively returns from a list', (
    tester,
  ) async {
    await openList(tester);
    final originalX = tester.getTopLeft(find.text('Nested list')).dx;
    final gesture = await tester.startGesture(const Offset(1, 300));
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(140, 0));
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('Nested list')).dx,
      greaterThan(originalX + 80),
    );
    await gesture.moveBy(const Offset(500, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Nested list'), findsNothing);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('cancelled edge swipe keeps the list and its scroll position', (
    tester,
  ) async {
    await openList(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    final list = tester.state<ScrollableState>(find.byType(Scrollable));
    final offset = list.position.pixels;
    final gesture = await tester.startGesture(const Offset(1, 300));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-90, 0));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Nested list'), findsOneWidget);
    expect(list.position.pixels, offset);
  });
}
