import 'package:flutter/material.dart';

/// Codex Mobile Pro 主题配置
///
/// 参照 Codex 桌面端：近黑画布、白色主色、细描边与克制的圆角。
/// 不使用高饱和品牌色，让代码与内容成为界面主角。
class AppTheme {
  AppTheme._();

  // ── 亮色 ──
  static const Color _lightSurface = Color(0xFFFFFFFF);
  static const Color _lightSurfaceLow = Color(0xFFFAFAFB);
  static const Color _lightSurfaceHigh = Color(0xFFF1F1F3);
  static const Color _lightOutline = Color(0xFFD6D6DA);
  static const Color _lightOutlineVariant = Color(0xFFE8E8EB);
  static const Color _lightText = Color(0xFF111113);
  static const Color _lightMuted = Color(0xFF6B6B72);

  // ── 暗色 ──
  static const Color _darkSurface = Color(0xFF0E0E10);
  static const Color _darkSurfaceLowest = Color(0xFF09090A);
  static const Color _darkSurfaceLow = Color(0xFF141416);
  static const Color _darkSurfaceHigh = Color(0xFF1C1C1F);
  static const Color _darkSurfaceHighest = Color(0xFF232327);
  static const Color _darkOutline = Color(0xFF3A3A40);
  static const Color _darkOutlineVariant = Color(0xFF26262A);
  static const Color _darkText = Color(0xFFECECEE);
  static const Color _darkMuted = Color(0xFF9A9AA1);

  static ColorScheme _lightScheme() {
    final base = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6E6E73),
      brightness: Brightness.light,
    );
    return base.copyWith(
      primary: _lightText,
      onPrimary: Colors.white,
      primaryContainer: _lightSurfaceHigh,
      onPrimaryContainer: _lightText,
      secondary: const Color(0xFF4A4A50),
      onSecondary: Colors.white,
      secondaryContainer: _lightSurfaceHigh,
      onSecondaryContainer: _lightText,
      surface: _lightSurface,
      onSurface: _lightText,
      onSurfaceVariant: _lightMuted,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: _lightSurfaceLow,
      surfaceContainer: const Color(0xFFF6F6F7),
      surfaceContainerHigh: _lightSurfaceHigh,
      surfaceContainerHighest: const Color(0xFFE9E9EC),
      outline: _lightOutline,
      outlineVariant: _lightOutlineVariant,
      inverseSurface: const Color(0xFF1B1B1E),
      onInverseSurface: const Color(0xFFF4F4F5),
    );
  }

  static ColorScheme _darkScheme() {
    final base = ColorScheme.fromSeed(
      seedColor: const Color(0xFF8E8E93),
      brightness: Brightness.dark,
    );
    return base.copyWith(
      primary: const Color(0xFFF2F2F3),
      onPrimary: const Color(0xFF111113),
      primaryContainer: const Color(0xFF26262A),
      onPrimaryContainer: const Color(0xFFF2F2F3),
      secondary: const Color(0xFFB8B8BE),
      onSecondary: const Color(0xFF111113),
      secondaryContainer: _darkSurfaceHighest,
      onSecondaryContainer: _darkText,
      surface: _darkSurface,
      onSurface: _darkText,
      onSurfaceVariant: _darkMuted,
      surfaceContainerLowest: _darkSurfaceLowest,
      surfaceContainerLow: _darkSurfaceLow,
      surfaceContainer: const Color(0xFF18181B),
      surfaceContainerHigh: _darkSurfaceHigh,
      surfaceContainerHighest: _darkSurfaceHighest,
      outline: _darkOutline,
      outlineVariant: _darkOutlineVariant,
      inverseSurface: const Color(0xFFECECEE),
      onInverseSurface: const Color(0xFF111113),
    );
  }

  static ThemeData _build(ColorScheme scheme, String fontFamily) {
    final isDark = scheme.brightness == Brightness.dark;
    final radius = BorderRadius.circular(12);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: scheme.brightness,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: scheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.outline, width: 1.2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 64,
        backgroundColor: scheme.surface,
        indicatorColor: scheme.surfaceContainerHighest,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? const Color(0xFF26262A)
            : const Color(0xFF1B1B1E),
        contentTextStyle: const TextStyle(color: Color(0xFFF4F4F5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
          letterSpacing: 0.1,
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: scheme.surfaceContainerLow,
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: scheme.outlineVariant,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          side: BorderSide(color: scheme.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.onSurface,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: Colors.transparent,
      ),
    );
  }

  // ── 亮色主题 ──
  static ThemeData light({String fontFamily = 'Roboto'}) =>
      _build(_lightScheme(), fontFamily);

  // ── 暗色主题 ──
  static ThemeData dark({String fontFamily = 'Roboto'}) =>
      _build(_darkScheme(), fontFamily);
}
