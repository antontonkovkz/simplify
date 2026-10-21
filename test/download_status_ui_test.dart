import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/domain/download_activity.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/download_status_banner.dart';
import 'package:simplefy/presentation/widgets.dart';
import 'compact_ui_test.dart' show TestApp;

const running = DownloadActivity(
  total: 5,
  completed: 2,
  fraction: .5,
  title: 'Загрузка музыки',
  currentTrack: 'Fixture song',
);
const offline = DownloadActivity(
  total: 5,
  completed: 2,
  fraction: .5,
  title: 'Загрузка ожидает сеть',
  currentTrack: 'Fixture song',
  detail: 'Соединение потеряно. Продолжим автоматически, когда появится сеть.',
  canContinue: true,
);

class TransfersApp extends TestApp {
  DownloadActivity? state;
  int continued = 0;
  @override
  DownloadActivity? get downloadActivity => state;
  @override
  Future<void> continueDownloads() async {
    continued++;
  }

  void show(DownloadActivity? value) {
    state = value;
    notifyListeners();
  }
}

void main() {
  Future<void> mount(WidgetTester tester, TransfersApp app) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SimplefyTheme.dark,
        builder: (context, child) =>
            DownloadStatusHost(app: app, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('Library')),
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                slideRoute(
                  Scaffold(
                    appBar: AppBar(title: const Text('Next page')),
                    body: const TextField(),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'global status slides in and out and preserves navigation and text input',
    (tester) async {
      final app = TransfersApp();
      addTearDown(app.dispose);
      await mount(tester, app);
      expect(find.byType(DownloadStatusBanner), findsNothing);
      app.show(running);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 130));
      expect(find.byType(DownloadStatusBanner), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Fixture song'), findsOneWidget);
      expect(find.text('2 из 5 · осталось 3 · 50%'), findsOneWidget);
      expect(find.text('Продолжить'), findsNothing);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Keep this');
      app.show(offline);
      await tester.pumpAndSettle();
      expect(find.text('Next page'), findsOneWidget);
      expect(find.text('Keep this'), findsOneWidget);
      expect(find.byType(DownloadStatusBanner), findsOneWidget);
      await tester.tap(find.text('Продолжить'));
      await tester.pumpAndSettle();
      expect(app.continued, 1);
      app.show(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(DownloadStatusBanner), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(DownloadStatusBanner), findsNothing);
      expect(find.text('Keep this'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'status fits a narrow screen with large text and consumes the top inset once',
    (tester) async {
      final app = TransfersApp()..state = offline;
      addTearDown(app.dispose);
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await mount(tester, app);
      expect(tester.takeException(), null);
      final banner = tester.getRect(find.byType(DownloadStatusBanner));
      final bar = tester.getRect(find.byType(AppBar));
      expect(banner.top, 47);
      final viewport = tester.getRect(
        find.descendant(
          of: find.byType(DownloadStatusHost),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      expect(bar.top, closeTo(viewport.bottom, .01));
      expect(
        tester.getRect(find.text('Продолжить')).right,
        lessThanOrEqualTo(320),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'continuation button is disabled while a retry is already running',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: SimplefyTheme.dark,
          home: Scaffold(
            body: DownloadStatusBanner(
              activity: const DownloadActivity(
                total: 1,
                completed: 0,
                fraction: 0,
                title: 'Ошибка загрузки',
                canContinue: true,
                continuing: true,
              ),
              onContinue: () => taps++,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Продолжаем…'));
      await tester.pump();
      expect(taps, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
