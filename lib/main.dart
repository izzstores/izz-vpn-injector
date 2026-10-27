import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'constants/app_colors.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IzzVpnApp());
}

class IzzVpnApp extends StatelessWidget {
  const IzzVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "IZZ TUNNELING",
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        primaryColor: AppColors.cyan,
        textTheme: GoogleFonts.poppinsTextTheme(
          ThemeData.dark().textTheme,
        ),
        colorScheme: const ColorScheme.dark(
          primary: AppColors.cyan,
          secondary: AppColors.blue,
          surface: AppColors.surface,
          background: AppColors.background,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
