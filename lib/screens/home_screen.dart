import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/app_colors.dart';
import '../models/app_info_model.dart';
import '../models/template_model.dart';
import '../services/api_service.dart';
import '../services/config_builder.dart';
import '../services/vpn_service.dart';
import '../widgets/connection_button.dart';
import '../widgets/payload_box.dart';
import '../widgets/stat_badge.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late TabController _modeTabController;

  // Cloud Data
  CloudConfigResponse? _cloudConfig;
  bool _isLoadingTemplates = false;
  String _selectedCategory = "All";
  TemplateModel? _selectedTemplate;

  // Simple Mode Inputs
  final TextEditingController _simpleUserCtrl = TextEditingController();
  final TextEditingController _simplePassCtrl = TextEditingController();
  bool _rememberMe = true;
  bool _obscurePass = true;

  // Custom Mode Inputs
  String _customProtocol = "ssh-ws";
  final TextEditingController _customServerCtrl = TextEditingController(text: "rioaja.haikara.biz.id");
  final TextEditingController _customPortCtrl = TextEditingController(text: "80");
  final TextEditingController _customSniCtrl = TextEditingController(text: "zoom.us");
  final TextEditingController _customPayloadCtrl = TextEditingController(
    text: "GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]",
  );
  final TextEditingController _customUserCtrl = TextEditingController();
  final TextEditingController _customPassCtrl = TextEditingController();

  // VPN State & Stats
  VpnState _vpnState = VpnState.disconnected;
  StreamSubscription? _vpnStateSub;
  StreamSubscription? _vpnStatsSub;
  Timer? _durationTimer;
  int _connectedSeconds = 0;
  String _ping = "-- ms";
  String _download = "0 KB/s";
  String _upload = "0 KB/s";

  @override
  void initState() {
    super.initState();
    _modeTabController = TabController(length: 2, vsync: this);
    VpnService.initialize();

    _vpnStateSub = VpnService.stateStream.listen((state) {
      setState(() {
        _vpnState = state;
        if (state == VpnState.connected) {
          _startDurationTimer();
        } else {
          _stopDurationTimer();
        }
      });
    });

    _vpnStatsSub = VpnService.statsStream.listen((stats) {
      setState(() {
        _ping = "${stats['ping_ms'] ?? '--'} ms";
        _download = "${stats['down_speed'] ?? '0 KB/s'}";
        _upload = "${stats['up_speed'] ?? '0 KB/s'}";
      });
    });

    _loadSavedAccounts();
    _fetchCloudTemplates();
  }

  @override
  void dispose() {
    _modeTabController.dispose();
    _vpnStateSub?.cancel();
    _vpnStatsSub?.cancel();
    _durationTimer?.cancel();
    _simpleUserCtrl.dispose();
    _simplePassCtrl.dispose();
    _customServerCtrl.dispose();
    _customPortCtrl.dispose();
    _customSniCtrl.dispose();
    _customPayloadCtrl.dispose();
    _customUserCtrl.dispose();
    _customPassCtrl.dispose();
    super.dispose();
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _connectedSeconds = 0;
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _connectedSeconds++;
      });
    });
  }

  void _stopDurationTimer() {
    _durationTimer?.cancel();
    _connectedSeconds = 0;
  }

  String _formatDuration(int seconds) {
    final d = Duration(seconds: seconds);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return "$h:$m:$s";
  }

  Future<void> _loadSavedAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _simpleUserCtrl.text = prefs.getString("simple_user") ?? "";
      _simplePassCtrl.text = prefs.getString("simple_pass") ?? "";
      _customUserCtrl.text = prefs.getString("custom_user") ?? "";
      _customPassCtrl.text = prefs.getString("custom_pass") ?? "";
    });
  }

  Future<void> _saveAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    if (_rememberMe) {
      await prefs.setString("simple_user", _simpleUserCtrl.text);
      await prefs.setString("simple_pass", _simplePassCtrl.text);
      await prefs.setString("custom_user", _customUserCtrl.text);
      await prefs.setString("custom_pass", _customPassCtrl.text);
    }
  }

  Future<void> _fetchCloudTemplates() async {
    setState(() => _isLoadingTemplates = true);
    final resp = await ApiService.fetchTemplates();
    setState(() {
      _isLoadingTemplates = false;
      if (resp != null) {
        _cloudConfig = resp;
        if (resp.templates.isNotEmpty) {
          _selectedTemplate = resp.templates.first;
        }
      }
    });
  }

  void _toggleConnection() async {
    if (_vpnState == VpnState.connected ||
        _vpnState == VpnState.connecting ||
        _vpnState == VpnState.authenticating) {
      await VpnService.stopVpn();
      return;
    }

    await _saveAccounts();

    String configJson = "";
    if (_modeTabController.index == 0) {
      // Simple Mode
      if (_selectedTemplate == null) {
        _showSnackbar("Pilih template konfigurasi terlebih dahulu!");
        return;
      }
      if (_simpleUserCtrl.text.isEmpty && _selectedTemplate!.protocol.contains("ssh")) {
        _showSnackbar("Username tidak boleh kosong!");
        return;
      }

      configJson = ConfigBuilder.buildFromTemplate(
        template: _selectedTemplate!,
        username: _simpleUserCtrl.text.trim(),
        password: _simplePassCtrl.text.trim(),
      );
    } else {
      // Custom Mode
      if (_customServerCtrl.text.isEmpty) {
        _showSnackbar("Host server tidak boleh kosong!");
        return;
      }

      configJson = ConfigBuilder.buildCustom(
        protocol: _customProtocol,
        server: _customServerCtrl.text.trim(),
        port: int.tryParse(_customPortCtrl.text.trim()) ?? 80,
        username: _customUserCtrl.text.trim(),
        password: _customPassCtrl.text.trim(),
        sni: _customSniCtrl.text.trim(),
        payload: _customPayloadCtrl.text.trim(),
      );
    }

    final success = await VpnService.startVpn(configJson);
    if (!success) {
      _showSnackbar("Gagal memulai koneksi VPN. Periksa config & server.");
    }
  }

  void _showSnackbar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildAppBar(),
            _buildAnnouncementBanner(),
            _buildModeTabs(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  children: [
                    _modeTabController.index == 0
                        ? _buildSimpleModeCard()
                        : _buildCustomModeCard(),
                    const SizedBox(height: 20),
                    _buildConnectionSection(),
                    const SizedBox(height: 20),
                    _buildStatsRow(),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.shield_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "✦ IZZ TUNNELING ✦",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                      color: AppColors.cyan,
                    ),
                  ),
                  Text(
                    _cloudConfig != null
                        ? "v${_cloudConfig!.appVersion} • Cloud Active"
                        : "Cloud Injector Suite",
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                onPressed: _isLoadingTemplates ? null : _fetchCloudTemplates,
                icon: _isLoadingTemplates
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.cyan),
                      )
                    : const Icon(Icons.sync_rounded, color: AppColors.cyan),
                tooltip: "Sync Cloud Config",
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAnnouncementBanner() {
    final ann = _cloudConfig?.announcement;
    if (ann == null || ann.message.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.campaign_rounded, color: AppColors.warning, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (ann.title.isNotEmpty)
                  Text(
                    ann.title,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppColors.warning,
                    ),
                  ),
                Text(
                  ann.message,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeTabs() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: TabBar(
        controller: _modeTabController,
        onTap: (index) => setState(() {}),
        indicator: BoxDecoration(
          gradient: AppColors.primaryGradient,
          borderRadius: BorderRadius.circular(14),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: Colors.black,
        unselectedLabelColor: AppColors.textSecondary,
        labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        tabs: const [
          Tab(
            icon: Icon(Icons.cloud_download_rounded, size: 18),
            text: "Simple (Cloud)",
          ),
          Tab(
            icon: Icon(Icons.tune_rounded, size: 18),
            text: "Custom (Injector)",
          ),
        ],
      ),
    );
  }

  Widget _buildSimpleModeCard() {
    final templates = _cloudConfig?.templates ?? [];
    final categories = ["All", ...?_cloudConfig?.categories];

    final filteredTemplates = _selectedCategory == "All"
        ? templates
        : templates.where((t) => t.category == _selectedCategory).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Pilih Template Config",
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          // Category Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: categories.map((cat) {
                final isSel = _selectedCategory == cat;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    selected: isSel,
                    label: Text(cat),
                    labelStyle: TextStyle(
                      fontSize: 11,
                      fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                      color: isSel ? Colors.black : AppColors.textSecondary,
                    ),
                    backgroundColor: AppColors.surfaceLight,
                    selectedColor: AppColors.cyan,
                    side: BorderSide(
                      color: isSel ? AppColors.cyan : AppColors.border,
                    ),
                    onSelected: (val) {
                      setState(() {
                        _selectedCategory = cat;
                        if (filteredTemplates.isNotEmpty) {
                          _selectedTemplate = filteredTemplates.first;
                        }
                      });
                    },
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 14),
          // Template Selector
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<TemplateModel>(
                value: filteredTemplates.contains(_selectedTemplate)
                    ? _selectedTemplate
                    : (filteredTemplates.isNotEmpty ? filteredTemplates.first : null),
                isExpanded: true,
                dropdownColor: AppColors.surface,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.cyan),
                items: filteredTemplates.map((t) {
                  return DropdownMenuItem<TemplateModel>(
                    value: t,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Text(
                            t.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.border,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            t.protocol.toUpperCase(),
                            style: const TextStyle(fontSize: 10, color: AppColors.cyan),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  setState(() => _selectedTemplate = val);
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          // User Credentials
          TextField(
            controller: _simpleUserCtrl,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              labelText: "Username Akun",
              labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
              prefixIcon: const Icon(Icons.person_outline_rounded, color: AppColors.cyan, size: 20),
              filled: true,
              fillColor: AppColors.surfaceLight,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppColors.border),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _simplePassCtrl,
            obscureText: _obscurePass,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              labelText: "Password / UUID",
              labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
              prefixIcon: const Icon(Icons.lock_outline_rounded, color: AppColors.cyan, size: 20),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePass ? Icons.visibility_off : Icons.visibility,
                  color: AppColors.textMuted,
                  size: 18,
                ),
                onPressed: () => setState(() => _obscurePass = !_obscurePass),
              ),
              filled: true,
              fillColor: AppColors.surfaceLight,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppColors.border),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Checkbox(
                value: _rememberMe,
                activeColor: AppColors.cyan,
                checkColor: Colors.black,
                onChanged: (v) => setState(() => _rememberMe = v ?? true),
              ),
              const Text(
                "Ingat akun di perangkat ini",
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCustomModeCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Konfigurasi Manual (Injector Mode)",
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          // Protocol Selector
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLight,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _customProtocol,
                      dropdownColor: AppColors.surface,
                      items: const [
                        DropdownMenuItem(value: "ssh-ws", child: Text("SSH WebSocket")),
                        DropdownMenuItem(value: "vmess-ws", child: Text("VMess WS")),
                        DropdownMenuItem(value: "vless-ws", child: Text("VLess WS")),
                        DropdownMenuItem(value: "trojan-ws", child: Text("Trojan WS")),
                      ],
                      onChanged: (v) => setState(() => _customProtocol = v ?? "ssh-ws"),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _customServerCtrl,
                  style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: "Server Host",
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 1,
                child: TextField(
                  controller: _customPortCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: "Port",
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _customSniCtrl,
            style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: "Bug SNI / Server Name",
              hintText: "Contoh: zoom.us / line.me",
              filled: true,
              fillColor: AppColors.surfaceLight,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),
          PayloadBox(controller: _customPayloadCtrl),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _customUserCtrl,
                  style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: "Username",
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _customPassCtrl,
                  obscureText: true,
                  style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: "Password",
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionSection() {
    String stateLabel = "DISCONNECTED";
    Color stateColor = AppColors.error;

    switch (_vpnState) {
      case VpnState.connecting:
        stateLabel = "CONNECTING...";
        stateColor = AppColors.warning;
        break;
      case VpnState.authenticating:
        stateLabel = "AUTHENTICATING...";
        stateColor = AppColors.cyan;
        break;
      case VpnState.connected:
        stateLabel = "CONNECTED";
        stateColor = AppColors.success;
        break;
      case VpnState.error:
        stateLabel = "CONNECTION FAILED";
        stateColor = AppColors.error;
        break;
      default:
        stateLabel = "TAP TO CONNECT";
        stateColor = AppColors.textSecondary;
        break;
    }

    return Column(
      children: [
        ConnectionButton(
          state: _vpnState,
          onTap: _toggleConnection,
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: stateColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: stateColor.withOpacity(0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: stateColor,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                stateLabel,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                  color: stateColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        StatBadge(
          icon: Icons.speed_rounded,
          label: "PING",
          value: _ping,
          color: AppColors.cyan,
        ),
        StatBadge(
          icon: Icons.arrow_downward_rounded,
          label: "DOWNLOAD",
          value: _download,
          color: AppColors.success,
        ),
        StatBadge(
          icon: Icons.arrow_upward_rounded,
          label: "UPLOAD",
          value: _upload,
          color: AppColors.blue,
        ),
        StatBadge(
          icon: Icons.timer_outlined,
          label: "DURATION",
          value: _formatDuration(_connectedSeconds),
          color: AppColors.violet,
        ),
      ],
    );
  }
}
