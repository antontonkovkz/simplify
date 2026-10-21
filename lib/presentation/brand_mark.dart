import '../l10n/l10n.dart';
import 'package:flutter/material.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 80});
  final double size;

  @override
  Widget build(BuildContext context) => Center(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(size * .22),
      child: Image.asset(
        'assets/branding/simplefy-icon.png',
        width: size,
        height: size,
        cacheWidth: (size * 3).round(),
        semanticLabel: context.l10n.simplefyLogo,
      ),
    ),
  );
}
