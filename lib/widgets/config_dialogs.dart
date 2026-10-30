import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../constants/app_colors.dart';
import '../models/saved_config_model.dart';
import '../services/config_storage_service.dart';

class ConfigDialogs {
  /// Classic HTTP Custom Save Config Dialog
  static Future<void> showSaveConfigDialog({
    required BuildContext context,
    required String mode, // 'ssh' or 'v2ray'
    required String sshMethod,
    required String server,
    required int port,
    required String username,
    required String password,
    required String sni,
    required String payload,
    required String remoteProxy,
    required String v2rayProtocol,
    required String v2rayUuid,
    required String v2rayTransport,
    required String v2rayPath,
    required String v2rayTls,
    required VoidCallback onSaved,
  }) async {
    final nameCtrl = TextEditingController(text: "Config_${DateFormat('ddMM').format(DateTime.now())}");
    final noteCtrl = TextEditingController();
    final passCtrl = TextEditingController();

    bool lockConfig = true;
    bool lockAccount = false;
    bool enableExpiry = false;
    DateTime selectedExpiry = DateTime.now().add(const Duration(days: 7));
    bool blockRoot = false;
    bool enablePassword = false;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              titlePadding: EdgeInsets.zero,
              title: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                color: AppColors.primary,
                child: const Row(
                  children: [
                    Icon(Icons.save_rounded, color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Text(
                      "SAVE CONFIG",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 6),
                    TextField(
                      controller: nameCtrl,
                      style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
                      decoration: const InputDecoration(
                        labelText: "Config File Name",
                        labelStyle: TextStyle(color: AppColors.primaryLight, fontSize: 12),
                        suffixText: ".izz",
                        suffixStyle: TextStyle(color: AppColors.textSecondary),
                        isDense: true,
                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.primaryLight)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: noteCtrl,
                      maxLines: 2,
                      style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                      decoration: const InputDecoration(
                        labelText: "Note / Message for users",
                        labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                        hintText: "Contoh: Config Fast SG, Dilarang Torrent!",
                        hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 11),
                        isDense: true,
                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.primaryLight)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      "LOCK & SECURITY OPTIONS",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textSecondary,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const Divider(color: AppColors.border, height: 12),
                    // Lock Config Checkbox
                    CheckboxListTile(
                      value: lockConfig,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      activeColor: AppColors.primaryLight,
                      title: const Text("Lock Config", style: TextStyle(fontSize: 12, color: AppColors.textPrimary)),
                      subtitle: const Text("Kunci payload & bug agar tidak bisa diintip", style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                      onChanged: (v) => setState(() => lockConfig = v ?? false),
                    ),
                    if (mode == "ssh")
                      CheckboxListTile(
                        value: lockAccount,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        activeColor: AppColors.primaryLight,
                        title: const Text("Lock Account", style: TextStyle(fontSize: 12, color: AppColors.textPrimary)),
                        subtitle: const Text("Kunci server SSH, username, dan password", style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                        onChanged: (v) => setState(() => lockAccount = v ?? false),
                      ),
                    // Set Expiry Checkbox
                    CheckboxListTile(
                      value: enableExpiry,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      activeColor: AppColors.primaryLight,
                      title: const Text("Set Expiration Date", style: TextStyle(fontSize: 12, color: AppColors.textPrimary)),
                      subtitle: Text(
                        enableExpiry ? "Expired: ${DateFormat('dd MMM yyyy').format(selectedExpiry)}" : "Tidak ada batas waktu",
                        style: TextStyle(fontSize: 10, color: enableExpiry ? AppColors.warning : AppColors.textSecondary),
                      ),
                      onChanged: (v) async {
                        if (v == true) {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: selectedExpiry,
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(const Duration(days: 365)),
                          );
                          if (picked != null) {
                            setState(() {
                              selectedExpiry = picked;
                              enableExpiry = true;
                            });
                          }
                        } else {
                          setState(() => enableExpiry = false);
                        }
                      },
                    ),
                    // Block Root Checkbox
                    CheckboxListTile(
                      value: blockRoot,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      activeColor: AppColors.primaryLight,
                      title: const Text("Block Rooted Device", style: TextStyle(fontSize: 12, color: AppColors.textPrimary)),
                      subtitle: const Text("Cegah config dijalankan di HP root", style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                      onChanged: (v) => setState(() => blockRoot = v ?? false),
                    ),
                    // Password Protection
                    CheckboxListTile(
                      value: enablePassword,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      activeColor: AppColors.primaryLight,
                      title: const Text("Password Protect", style: TextStyle(fontSize: 12, color: AppColors.textPrimary)),
                      onChanged: (v) => setState(() => enablePassword = v ?? false),
                    ),
                    if (enablePassword)
                      Padding(
                        padding: const EdgeInsets.only(left: 12, bottom: 8),
                        child: TextField(
                          controller: passCtrl,
                          obscureText: true,
                          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                          decoration: const InputDecoration(
                            labelText: "Password Config",
                            labelStyle: TextStyle(color: AppColors.primaryLight, fontSize: 11),
                            isDense: true,
                            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actionsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("BATAL", style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (nameCtrl.text.trim().isEmpty) return;

                    final newConfig = SavedConfigModel(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      name: nameCtrl.text.trim(),
                      note: noteCtrl.text.trim(),
                      mode: mode,
                      sshMethod: sshMethod,
                      server: server,
                      port: port,
                      // Keep SSH credentials even when Lock Account is off;
                      // the lock controls editing, not credential persistence.
                      username: mode == "ssh" ? username : "",
                      password: mode == "ssh" ? password : "",
                      sni: sni,
                      payload: payload,
                      remoteProxy: remoteProxy,
                      v2rayProtocol: v2rayProtocol,
                      v2rayUuid: v2rayUuid,
                      v2rayTransport: v2rayTransport,
                      v2rayPath: v2rayPath,
                      v2rayTls: v2rayTls,
                      isLocked: lockConfig,
                      isAccountLocked: mode == "ssh" && lockAccount,
                      expiryDate: enableExpiry ? selectedExpiry : null,
                      blockRoot: blockRoot,
                      configPassword: enablePassword ? passCtrl.text.trim() : null,
                      createdAt: DateTime.now(),
                    );

                    await ConfigStorageService.saveConfig(newConfig);
                    Navigator.pop(ctx);
                    onSaved();

                    // Show Share Choice
                    _showShareOption(context, newConfig);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  child: const Text("SAVE CONFIG", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static void _showShareOption(BuildContext context, SavedConfigModel config) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Config '${config.name}' Tersimpan!",
                style: const TextStyle(color: AppColors.primaryLight, fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 14),
              ListTile(
                leading: const Icon(Icons.share_rounded, color: AppColors.primaryLight),
                title: const Text("Export & Bagikan File (.izz)", style: TextStyle(color: AppColors.textPrimary, fontSize: 13)),
                onTap: () {
                  Navigator.pop(ctx);
                  ConfigStorageService.shareConfigFile(config, context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_rounded, color: AppColors.cyan),
                title: const Text("Salin Kode Config ke Clipboard", style: TextStyle(color: AppColors.textPrimary, fontSize: 13)),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: config.toExportString()));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Kode config berhasil disalin!"), backgroundColor: AppColors.primary),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Classic Open / Import Config Dialog
  static Future<void> showOpenConfigDialog({
    required BuildContext context,
    required Function(SavedConfigModel config) onConfigLoaded,
  }) async {
    final configs = await ConfigStorageService.getAllConfigs();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.7,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "OPEN / IMPORT CONFIG",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                          letterSpacing: 1.0,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: AppColors.textSecondary, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Divider(color: AppColors.border),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final data = await Clipboard.getData('text/plain');
                            if (data != null && data.text != null && data.text!.isNotEmpty) {
                              handleImportString(context, data.text!, onConfigLoaded, ctx);
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Clipboard kosong!"), backgroundColor: AppColors.error),
                              );
                            }
                          },
                          icon: const Icon(Icons.content_paste_rounded, size: 16, color: AppColors.primaryLight),
                          label: const Text("Paste dari Clipboard", style: TextStyle(fontSize: 11, color: AppColors.textPrimary)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: AppColors.border),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text("CONFIG TERSIMPAN DI PERANGKAT", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppColors.textSecondary)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: configs.isEmpty
                        ? const Center(
                            child: Text(
                              "Belum ada config tersimpan.\nBuat atau import config untuk memulai.",
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                            ),
                          )
                        : ListView.separated(
                            itemCount: configs.length,
                            separatorBuilder: (_, __) => const Divider(color: AppColors.border, height: 1),
                            itemBuilder: (context, idx) {
                              final item = configs[idx];
                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  item.mode == "v2ray" ? Icons.cloud_queue_rounded : Icons.terminal_rounded,
                                  color: item.isExpired ? AppColors.error : AppColors.primaryLight,
                                  size: 24,
                                ),
                                title: Row(
                                  children: [
                                    Text(
                                      item.name,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: item.isExpired ? AppColors.textMuted : AppColors.textPrimary,
                                        decoration: item.isExpired ? TextDecoration.lineThrough : null,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    if (item.isLocked)
                                      const Icon(Icons.lock_rounded, size: 14, color: AppColors.warning),
                                  ],
                                ),
                                subtitle: Text(
                                  "${item.mode.toUpperCase()} • ${item.sshMethod.toUpperCase()} ${item.expiryDate != null ? '• Exp: ' + DateFormat('dd/MM/yy').format(item.expiryDate!) : ''}",
                                  style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.share_rounded, size: 18, color: AppColors.cyan),
                                      onPressed: () => ConfigStorageService.shareConfigFile(item, context),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.error),
                                      onPressed: () async {
                                        await ConfigStorageService.deleteConfig(item.id);
                                        setSheetState(() {
                                          configs.removeAt(idx);
                                        });
                                      },
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  if (item.isExpired) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text("Config ini sudah kadaluarsa!"), backgroundColor: AppColors.error),
                                    );
                                    return;
                                  }
                                  Navigator.pop(ctx);
                                  onConfigLoaded(item);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  static void handleImportString(
    BuildContext context,
    String raw,
    Function(SavedConfigModel) onLoaded,
    BuildContext bottomSheetCtx,
  ) {
    try {
      final config = ConfigStorageService.parseConfigString(raw);
      if (config != null) {
        if (!identical(bottomSheetCtx, context)) Navigator.pop(bottomSheetCtx);
        onLoaded(config);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Config '${config.name}' berhasil dimuat!"), backgroundColor: AppColors.primary),
        );
      }
    } catch (e) {
      if (e.toString().contains("PASSWORD_REQUIRED")) {
        _promptPassword(context, raw, onLoaded, bottomSheetCtx);
      } else if (e.toString().contains("CONFIG_EXPIRED")) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Gagal: Config sudah melewati tanggal kadaluarsa!"), backgroundColor: AppColors.error),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Format config tidak valid!"), backgroundColor: AppColors.error),
        );
      }
    }
  }

  static void _promptPassword(
    BuildContext context,
    String raw,
    Function(SavedConfigModel) onLoaded,
    BuildContext bottomSheetCtx,
  ) {
    final passCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text("Config Dilindungi Password", style: TextStyle(color: AppColors.textPrimary, fontSize: 14)),
          content: TextField(
            controller: passCtrl,
            obscureText: true,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: const InputDecoration(hintText: "Masukkan password...", hintStyle: TextStyle(color: AppColors.textMuted)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("BATAL")),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                try {
                  final config = ConfigStorageService.parseConfigString(raw, password: passCtrl.text.trim());
                  if (config != null) {
                    Navigator.pop(bottomSheetCtx);
                    onLoaded(config);
                  }
                } catch (_) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Password salah!"), backgroundColor: AppColors.error),
                  );
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
              child: const Text("BUKA"),
            ),
          ],
        );
      },
    );
  }
}
