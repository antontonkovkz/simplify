import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/presentation/app_theme.dart';

void main() {
  test('brand text and selected controls retain readable contrast', () {
    final scheme = SimplefyTheme.dark.colorScheme;
    final pairs = <(Color, Color)>[
      (scheme.onPrimary, scheme.primary),
      (scheme.onPrimaryContainer, scheme.primaryContainer),
      (scheme.onSecondary, scheme.secondary),
      (scheme.onSecondaryContainer, scheme.secondaryContainer),
      (scheme.onTertiary, scheme.tertiary),
      (scheme.onTertiaryContainer, scheme.tertiaryContainer),
      (scheme.onError, scheme.error),
      (scheme.onErrorContainer, scheme.errorContainer),
      for (final surface in [
        scheme.surface,
        scheme.surfaceContainerLowest,
        scheme.surfaceContainerLow,
        scheme.surfaceContainer,
        scheme.surfaceContainerHigh,
        scheme.surfaceContainerHighest,
      ]) ...[
        (scheme.onSurface, surface),
        (scheme.onSurfaceVariant, surface),
        (scheme.primary, surface),
      ],
    ];
    for (final (foreground, background) in pairs) {
      final light = foreground.computeLuminance();
      final dark = background.computeLuminance();
      final ratio = (max(light, dark) + .05) / (min(light, dark) + .05);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason: '$foreground on $background',
      );
    }
  });
}
