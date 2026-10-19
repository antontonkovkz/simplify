import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/domain/volume_normalization.dart';
import 'package:simplefy/presentation/action_sheet.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/login_screen.dart';
import 'package:simplefy/presentation/player_controls.dart';
import 'package:simplefy/presentation/settings_screen.dart';
import 'compact_ui_test.dart' show TestApp, songs;

class SettingsApp extends TestApp {
  @override
  VolumeNormalizationMode get normalizationMode =>
      VolumeNormalizationMode.track;
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    Widget screen, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: SimplefyTheme.dark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: screen,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('player keeps all transport targets at narrow width', (
    tester,
  ) async {
    final app = TestApp();
    addTearDown(app.dispose);
    app.queue.replace(songs);
    await mount(tester, Scaffold(body: PlayerControls(app: app)), scale: 2);
    for (final label in [
      'Случайное воспроизведение',
      'Предыдущая',
      'Продолжить',
      'Следующая',
      'Повтор выключен',
    ]) {
      final size = tester.getSize(find.byTooltip(label));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }
    await tester.tap(find.byTooltip('Случайное воспроизведение'));
    expect(app.queue.shuffled, true);
    expect(tester.takeException(), null);
  });

  testWidgets(
    'login collapse preserves entered credentials and password visibility',
    (tester) async {
      final app = TestApp();
      addTearDown(app.dispose);
      await mount(tester, LoginScreen(app: app), scale: 2);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'https://example.com');
      await tester.enterText(fields.at(1), 'listener');
      await tester.ensureVisible(fields.at(2));
      await tester.enterText(fields.at(2), 'example-password');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(fields.at(0)).controller!.text,
        'https://example.com',
      );
      expect(
        tester.widget<TextField>(fields.at(1)).controller!.text,
        'listener',
      );
      expect(tester.widget<TextField>(fields.at(2)).obscureText, true);
      await tester.ensureVisible(find.byTooltip('Показать пароль'));
      await tester.tap(find.byTooltip('Показать пароль'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(fields.at(2)).obscureText, false);
      expect(tester.takeException(), null);
    },
  );

  testWidgets('settings remain scrollable with large text', (tester) async {
    final app = SettingsApp();
    addTearDown(app.dispose);
    await mount(tester, SettingsScreen(app: app), scale: 2);
    expect(find.text('Библиотека'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Simplefy · 0.6.1'), 180);
    expect(find.text('Simplefy · 0.6.1'), findsOneWidget);
    expect(tester.takeException(), null);
  });

  testWidgets('long action sheets scroll to their final command', (
    tester,
  ) async {
    int? selected;
    await mount(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await showActionSheet<int>(
                context: context,
                title: 'Actions',
                actions: (sheet) => [
                  for (var i = 0; i < 10; i++)
                    ListTile(
                      title: Text('Command $i'),
                      onTap: () => Navigator.pop(sheet, i),
                    ),
                ],
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
      scale: 2,
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Command 9'));
    await tester.tap(find.text('Command 9'));
    await tester.pumpAndSettle();
    expect(selected, 9);
    expect(tester.takeException(), null);
  });
}
