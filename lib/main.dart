import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/session_log.dart';
import 'src/ui/home_page.dart';
import 'src/ui/odys_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppColors.surface,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(OdysServiceApp(log: SessionLog()));
}

class OdysServiceApp extends StatefulWidget {
  const OdysServiceApp({super.key, required this.log});
  final SessionLog log;

  @override
  State<OdysServiceApp> createState() => _OdysServiceAppState();
}

class _OdysServiceAppState extends State<OdysServiceApp> {
  bool _isDark = true;

  void _toggleTheme() => setState(() => _isDark = !_isDark);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ODYS Service Tool',
      debugShowCheckedModeBanner: false,
      themeMode: _isDark ? ThemeMode.dark : ThemeMode.light,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: HomePage(
        log: widget.log,
        isDark: _isDark,
        onThemeToggle: _toggleTheme,
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final bg = dark ? AppColors.bg : const Color(0xffF4F6FA);
    final surface = dark ? AppColors.surface : Colors.white;
    final surfaceHi = dark ? AppColors.surfaceHi : const Color(0xffE8EDF5);
    final border = dark ? AppColors.border : const Color(0xffD0D8E4);
    final text = dark ? AppColors.text : const Color(0xff0D1B2A);
    final textDim = dark ? AppColors.textDim : const Color(0xff6B7C91);

    return ThemeData(
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: brightness,
        surface: surface,
        error: AppColors.danger,
      ),
      scaffoldBackgroundColor: bg,
      cardTheme: CardThemeData(
        color: surface,
        margin: const EdgeInsets.symmetric(vertical: 4),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          side: BorderSide(color: border),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.bg,
          disabledBackgroundColor: surfaceHi,
          disabledForegroundColor: textDim,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          textStyle:
              const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: BorderSide(color: border),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: AppColors.primary),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.primary
                : textDim),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.primaryDim
                : border),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.primary
                : Colors.transparent),
        checkColor: WidgetStateProperty.all(AppColors.bg),
        side: BorderSide(color: textDim, width: 1.5),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bg,
        labelStyle: TextStyle(color: textDim),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border.withValues(alpha: 0.5)),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: TextStyle(color: text),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.primaryDim,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontSize: 12,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w400,
              color: states.contains(WidgetState.selected)
                  ? AppColors.primary
                  : textDim,
            )),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              size: 22,
              color: states.contains(WidgetState.selected)
                  ? AppColors.primary
                  : textDim,
            )),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceHi,
        contentTextStyle: TextStyle(color: text),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerTheme: DividerThemeData(
        color: border,
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        textColor: text,
        iconColor: textDim,
        contentPadding: EdgeInsets.zero,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: AppColors.primary,
        linearTrackColor: border,
        circularTrackColor: border,
      ),
      iconTheme: IconThemeData(color: textDim, size: 20),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: surfaceHi,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
        ),
        textStyle: TextStyle(color: text, fontSize: 12),
      ),
      // Numbers are the whole point of this app, so the display and title
      // sizes are tightened and the body sizes given a little more leading
      // than Material's defaults.
      textTheme: (dark
              ? Typography.material2021(platform: TargetPlatform.android).white
              : Typography.material2021(platform: TargetPlatform.android).black)
          .apply(bodyColor: text, displayColor: text)
          .copyWith(
            displaySmall: TextStyle(
              color: text,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.5,
            ),
            titleLarge: TextStyle(
              color: text,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
            bodyMedium: TextStyle(color: text, fontSize: 14, height: 1.4),
            bodySmall: TextStyle(color: textDim, fontSize: 12, height: 1.4),
          ),
      splashFactory: InkSparkle.splashFactory,
      useMaterial3: true,
    );
  }
}
