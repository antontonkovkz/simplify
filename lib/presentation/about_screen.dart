import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/l10n.dart';
import 'brand_mark.dart';
import 'widgets.dart';

class AppLinks {
  static final repository = Uri.parse(
    'https://github.com/antontonkovkz/simplify',
  );
  static final support = Uri.parse('$repository/issues');
  static final website = Uri.parse('https://madnum.me');
  static final privacy = Uri.parse('$repository/blob/main/PRIVACY.md');
}

bool _licenseRegistered = false;
void registerSimplefyLicense() {
  if (_licenseRegistered) return;
  _licenseRegistered = true;
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('LICENSE');
    final notice = await rootBundle.loadString('NOTICE');
    yield LicenseEntryWithLineBreaks(['Simplefy'], '$notice\n$text');
  });
}

Future<bool> openExternalAppLink(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

typedef AppLinkOpener = Future<bool> Function(Uri uri);

Future<void> _open(BuildContext context, Uri uri, AppLinkOpener opener) async {
  try {
    if (await opener(uri)) return;
  } on Object catch (_) {
    // A missing browser or platform failure must leave the page usable.
  }
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.openLinkFailed)));
  }
}

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, this.openLink = openExternalAppLink});
  final AppLinkOpener openLink;
  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  late final Future<PackageInfo> _info;
  @override
  void initState() {
    super.initState();
    registerSimplefyLicense();
    _info = PackageInfo.fromPlatform();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.aboutSimplefy)),
    body: ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const SizedBox(height: 16),
        const BrandMark(size: 72),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(
                'Simplefy',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              FutureBuilder<PackageInfo>(
                future: _info,
                builder: (context, snapshot) => Text(
                  snapshot.hasData
                      ? context.l10n.appVersion(
                          snapshot.data!.version,
                          snapshot.data!.buildNumber,
                        )
                      : snapshot.hasError
                      ? context.l10n.versionUnavailable
                      : '',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Just music. Just play.\nYour music. Your way.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.simplefyDescription,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(context.l10n.firstRunHint, textAlign: TextAlign.center),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.help_outline_rounded),
          title: Text(context.l10n.supportAndFeedback),
          subtitle: const Text('GitHub Issues'),
          onTap: () => _open(context, AppLinks.support, widget.openLink),
        ),
        ListTile(
          leading: const Icon(Icons.code_rounded),
          title: Text(context.l10n.sourceCode),
          subtitle: const Text('GitHub'),
          onTap: () => _open(context, AppLinks.repository, widget.openLink),
        ),
        ListTile(
          leading: const Icon(Icons.person_outline_rounded),
          title: const Text('Anton Tonkov'),
          subtitle: const Text('madnum.me'),
          onTap: () => _open(context, AppLinks.website, widget.openLink),
        ),
        ListTile(
          leading: const Icon(Icons.privacy_tip_outlined),
          title: Text(context.l10n.privacyPolicy),
          onTap: () => Navigator.push(
            context,
            slideRoute(PrivacyScreen(openLink: widget.openLink)),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: Text(context.l10n.appLicenses),
          subtitle: const Text('Apache License 2.0'),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Simplefy',
            applicationLegalese: '© 2026 Anton Tonkov',
          ),
        ),
      ],
    ),
  );
}

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key, this.openLink = openExternalAppLink});
  final AppLinkOpener openLink;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.privacyPolicy)),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(context.l10n.privacyLocalData),
        const SizedBox(height: 16),
        Text(context.l10n.privacyServerData),
        const SizedBox(height: 16),
        Text(context.l10n.privacyDataControls),
        const SizedBox(height: 20),
        TextButton.icon(
          icon: const Icon(Icons.open_in_new_rounded),
          label: Text(context.l10n.fullPrivacyPolicy),
          onPressed: () => _open(context, AppLinks.privacy, openLink),
        ),
      ],
    ),
  );
}
