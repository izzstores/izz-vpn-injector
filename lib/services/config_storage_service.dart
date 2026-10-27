import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/saved_config_model.dart';

class ConfigStorageService {
  static const String _keyConfigs = "saved_configs_list";

  static Future<List<SavedConfigModel>> getAllConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList(_keyConfigs) ?? [];
    return rawList.map((item) {
      try {
        return SavedConfigModel.fromJson(jsonDecode(item));
      } catch (_) {
        return null;
      }
    }).whereType<SavedConfigModel>().toList();
  }

  static Future<void> saveConfig(SavedConfigModel config) async {
    final prefs = await SharedPreferences.getInstance();
    final configs = await getAllConfigs();
    configs.removeWhere((c) => c.id == config.id);
    configs.insert(0, config);

    final rawList = configs.map((c) => jsonEncode(c.toJson())).toList();
    await prefs.setStringList(_keyConfigs, rawList);
  }

  static Future<void> deleteConfig(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final configs = await getAllConfigs();
    configs.removeWhere((c) => c.id == id);

    final rawList = configs.map((c) => jsonEncode(c.toJson())).toList();
    await prefs.setStringList(_keyConfigs, rawList);
  }

  static Future<void> shareConfigFile(SavedConfigModel config, BuildContext context) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final sanitizedName = config.name.replaceAll(RegExp(r'[^\w\s\.-]'), '_');
      final file = File('${tempDir.path}/$sanitizedName.izz');
      await file.writeAsString(config.toExportString());

      final box = context.findRenderObject() as RenderBox?;
      await Share.shareXFiles(
        [XFile(file.path, name: '$sanitizedName.izz', mimeType: 'application/octet-stream')],
        text: 'Config IZZ TUNNELING: ${config.name}\n${config.note}',
        sharePositionOrigin: box != null ? box.localToGlobal(Offset.zero) & box.size : null,
      );
    } catch (e) {
      // Fallback: share as text code
      await Share.share(config.toExportString(), subject: config.name);
    }
  }

  static SavedConfigModel? parseConfigString(String text, {String? password}) {
    return SavedConfigModel.fromExportString(text, enteredPassword: password);
  }
}
