import 'package:flutter/material.dart';

class AppColors {
  // Backgrounds
  static const Color background = Color(0xFF0D0E15);
  static const Color surface = Color(0xFF161922);
  static const Color surfaceLight = Color(0xFF1F2330);
  static const Color border = Color(0xFF2A2F3D);

  // Gradient Accents
  static const Color cyan = Color(0xFF00F2FE);
  static const Color blue = Color(0xFF4FACFE);
  static const Color violet = Color(0xFF8A2BE2);
  static const Color purple = Color(0xFF7F00FF);
  
  // Status Colors
  static const Color success = Color(0xFF00E676);
  static const Color warning = Color(0xFFFFB300);
  static const Color error = Color(0xFFFF3D71);

  // Texts
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF8F9BB3);
  static const Color textMuted = Color(0xFF6B7280);

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [cyan, blue, purple],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient connectedGradient = LinearGradient(
    colors: [Color(0xFF00E676), Color(0xFF00B0FF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cardGradient = LinearGradient(
    colors: [Color(0xFF181B26), Color(0xFF12141D)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}
