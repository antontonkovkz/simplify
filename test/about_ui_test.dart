import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:simplefy/l10n/l10n.dart';
import 'package:simplefy/presentation/about_screen.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/login_screen.dart';
import 'package:simplefy/presentation/settings_screen.dart';
import 'compact_ui_test.dart' show TestApp;
import 'secondary_ui_test.dart' show SettingsApp;

void main() {
  setUp(() {
    L10n.useLanguage('en');
    PackageInfo.setMockInitialValues(
      appName: 'Simplefy',
      packageName: 'online.tavhome.simplefy',
      version: '0.9.0',
      buildNumber: '27',
      buildSignature: '',
    );
  });

  Future<void> mount(
    WidgetTester tester,
    Widget home, {
    String language = 'en',
    double scale = 1,
  }) async {
    L10n.useLanguage(language);
    tester.view.physicalSize =
        const Size(320, 568) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: SimplefyTheme.dark,
        locale: L10n.localeForCode(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 150);
    await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'welcome explains both music sources and opens About without signing in',
    (tester) async {
      final app = TestApp();
      addTearDown(app.dispose);
      await mount(tester, LoginScreen(app: app));
      expect(find.text(L10n.current.firstRunHint), findsOneWidget);
      await tester.ensureVisible(find.text('About Simplefy'));
      await tester.tap(find.text('About Simplefy'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutScreen), findsOneWidget);
      expect(find.text('Version 0.9.0 (27)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings opens the same About page', (tester) async {
    final app = SettingsApp();
    addTearDown(app.dispose);
    await mount(tester, SettingsScreen(app: app));
    await reveal(tester, find.text('About Simplefy'));
    await tester.tap(find.text('About Simplefy'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsOneWidget);
    expect(find.text('Version 0.9.0 (27)'), findsOneWidget);
  });

  testWidgets(
    'support and source open the intended URLs; link failures stay visible',
    (tester) async {
      final opened = <Uri>[];
      await mount(
        tester,
        AboutScreen(
          openLink: (uri) async {
            opened.add(uri);
            return uri != AppLinks.repository;
          },
        ),
      );
      await reveal(tester, find.text('Support and feedback'));
      await tester.tap(find.text('Support and feedback'));
      await tester.pumpAndSettle();
      expect(opened, [AppLinks.support]);
      await reveal(tester, find.text('Source code'));
      await tester.tap(find.text('Source code'));
      await tester.pumpAndSettle();
      expect(opened.last, AppLinks.repository);
      expect(find.text(L10n.current.openLinkFailed), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'privacy text and the bundled app license are available offline',
    (tester) async {
      final opened = <Uri>[];
      await mount(
        tester,
        AboutScreen(
          openLink: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      );
      await reveal(tester, find.text('Privacy policy'));
      await tester.tap(find.text('Privacy policy'));
      await tester.pumpAndSettle();
      expect(find.text(L10n.current.privacyLocalData), findsOneWidget);
      expect(opened, isEmpty);
      await reveal(tester, find.text('Read the full privacy policy'));
      await tester.tap(find.text('Read the full privacy policy'));
      await tester.pumpAndSettle();
      expect(opened, [AppLinks.privacy]);
      final license = await LicenseRegistry.licenses.firstWhere(
        (entry) => entry.packages.contains('Simplefy'),
      );
      final text = license.paragraphs.map((p) => p.text).join('\n');
      expect(text, contains('Apache License'));
      expect(text, contains('Anton Tonkov'));
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in ['en', 'ru', 'es', 'pt_BR', 'de', 'fr']) {
    testWidgets('About and privacy fit large text in $language', (
      tester,
    ) async {
      await mount(tester, const AboutScreen(), language: language, scale: 2);
      await reveal(tester, find.text(L10n.current.privacyPolicy));
      await tester.tap(find.text(L10n.current.privacyPolicy));
      await tester.pumpAndSettle();
      await reveal(tester, find.text(L10n.current.fullPrivacyPolicy));
      expect(tester.takeException(), isNull);
    });
  }
}
