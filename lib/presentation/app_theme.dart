import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared brand palette for player, library, dialogs and system chrome.
abstract final class SimplefyTheme {
  static const mint = Color(0xFF55E3C2);
  static const navy = Color(0xFF111F32);

  static ThemeData get dark {
    final colors =
        ColorScheme.fromSeed(
          seedColor: mint,
          brightness: Brightness.dark,
        ).copyWith(
          primary: mint,
          onPrimary: navy,
          primaryContainer: const Color(0xFF174C49),
          onPrimaryContainer: const Color(0xFFB8F5E4),
          secondary: const Color(0xFF9DD9D7),
          onSecondary: navy,
          secondaryContainer: const Color(0xFF234450),
          onSecondaryContainer: const Color(0xFFC6E8EC),
          tertiary: const Color(0xFF9FCBFA),
          onTertiary: navy,
          tertiaryContainer: const Color(0xFF203F5B),
          onTertiaryContainer: const Color(0xFFD1E9FF),
          surface: navy,
          onSurface: const Color(0xFFE7F3F5),
          onSurfaceVariant: const Color(0xFFA9C0CF),
          surfaceContainerLowest: const Color(0xFF0A1422),
          surfaceContainerLow: const Color(0xFF14263A),
          surfaceContainer: const Color(0xFF182D42),
          surfaceContainerHigh: const Color(0xFF20374D),
          surfaceContainerHighest: const Color(0xFF294157),
          outline: const Color(0xFF7892A7),
          outlineVariant: const Color(0xFF365168),
          surfaceTint: mint,
          inverseSurface: const Color(0xFFE7F3F5),
          onInverseSurface: navy,
          inversePrimary: const Color(0xFF006B5B),
        );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colors,
      scaffoldBackgroundColor: navy,
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        backgroundColor: navy,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        iconTheme: WidgetStatePropertyAll(IconThemeData(size: 22)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.surfaceContainerHighest,
        contentTextStyle: TextStyle(color: colors.onSurface),
        actionTextColor: mint,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: mint,
        selectionColor: mint.withValues(alpha: .28),
        selectionHandleColor: mint,
      ),
    );
  }
}
