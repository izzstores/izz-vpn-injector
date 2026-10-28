import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/app_colors.dart';
import '../models/app_info_model.dart';
import '../models/saved_config_model.dart';
import '../models/template_model.dart';
import '../services/api_service.dart';
import '../services/config_builder.dart';
import '../services/v2ray_parser.dart';
import '../services/vpn_service.dart';
import '../widgets/config_dialogs.dart';
import '../widgets/payload_box.dart';
import '../widgets/stat_badge.dart';
import 'tools_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Active Loaded Config (If imported)
  SavedConfigModel? _loadedConfig;

  // 1. SSH Custom Mode State
  bool _enableSsl = true;
  bool _enablePayload = true;
  bool _enableProxy = false;
  final TextEditingController _sshServerCtrl = TextEditingController();
  final TextEditingController _sshPortCtrl = TextEditingController(text: "443");
  final TextEditingController _sshUserCtrl = TextEditingController();
  final TextEditingController _sshPassCtrl = TextEditingController();
  final TextEditingController _sshSniCtrl = TextEditingController();
  final TextEditingController _sshProxyCtrl = TextEditingController();
  final TextEditingController _sshPayloadCtrl = TextEditingController();
  bool _obscureSshPass = true;

  // 2. V2Ray / Xray Mode State
  String _v2rayProtocol = "vmess"; // 'vmess', 'vless', 'trojan', 'shadowsocks'
  final TextEditingController _v2rayLinkCtrl = TextEditingController();
  final TextEditingController _v2rayServerCtrl = TextEditingController();
  final TextEditingController _v2rayPortCtrl = TextEditingController(text: "443");
  final TextEditingController _v2rayUuidCtrl = TextEditingController();
  String _v2rayTransport = "ws";
  final TextEditingController _v2rayPathCtrl = TextEditingController(text: "/vmess-ws");
  final TextEditingController _v2raySniCtrl = TextEditingController();
  String _v2rayTls = "tls";

  // 3. Cloud Tricks Mode State (Templates without server lock)
  CloudConfigResponse? _cloudConfig;
  bool _isLoadingTemplates = false;
  String _selectedCategory = "All";
  TemplateModel? _selectedTemplate;
  final TextEditingController _memberServerCtrl = TextEditingController();
  final TextEditingController _memberPortCtrl = TextEditingController(text: "443");
  final TextEditingController _memberUserCtrl = TextEditingController();
  final TextEditingController _memberPassCtrl = TextEditingController();

  // 4. Live Terminal Logs
  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();

  // VPN Connection State
  VpnState _vpnState = VpnState.disconnected;
  StreamSubscription? _vpnStateSub;
  StreamSubscription? _vpnStatsSub;
  StreamSubscription? _vpnErrorSub;
  Timer? _durationTimer;
  int _connectedSeconds = 0;
  String _ping = "-- ms";
  String _download = "0 KB/s";
  String _upload = "0 KB/s";

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    VpnService.initialize();

    _addLog("Izz Tunnel Engine Initialized");
    _addLog("Core: sing-box (v1.10.0-native)");

    _vpnStateSub = VpnService.stateStream.listen((state) {
      setState(() {
        _vpnState = state;
        if (state == VpnState.connected) {
          _addLog("Status: CONNECTED! Tunnel interface active.");
          _startDurationTimer();
        } else if (state == VpnState.connecting) {
          _addLog("Status: Connecting to remote endpoint...");
        } else if (state == VpnState.authenticating) {
          _addLog("Status: Handshaking & Authenticating...");
        } else if (state == VpnState.error) {
          final errMsg = VpnService.lastErrorMessage;
          if (errMsg != null && errMsg.isNotEmpty) {
            _addLog("Status: ERROR - $errMsg");
          } else {
            _addLog("Status: ERROR - Connection aborted or timed out.");
          }
          _stopDurationTimer();
        } else {
          _addLog("Status: Disconnected.");
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

    _vpnErrorSub = VpnService.errorStream.listen((errorMsg) {
      _addLog("VPN Error: $errorMsg");
    });

    _loadPreferences();
    _fetchCloudTemplates();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _vpnStateSub?.cancel();
    _vpnStatsSub?.cancel();
    _vpnErrorSub?.cancel();
    _durationTimer?.cancel();
    _logScrollController.dispose();
    _sshServerCtrl.dispose();
    _sshPortCtrl.dispose();
    _sshUserCtrl.dispose();
    _sshPassCtrl.dispose();
    _sshSniCtrl.dispose();
    _sshProxyCtrl.dispose();
    _sshPayloadCtrl.dispose();
    _v2rayLinkCtrl.dispose();
    _v2rayServerCtrl.dispose();
    _v2rayPortCtrl.dispose();
    _v2rayUuidCtrl.dispose();
    _v2rayPathCtrl.dispose();
    _v2raySniCtrl.dispose();
    _memberServerCtrl.dispose();
    _memberPortCtrl.dispose();
    _memberUserCtrl.dispose();
    _memberPassCtrl.dispose();
    super.dispose();
  }

  void _addLog(String msg) {
    final now = DateTime.now();
    final timeStr = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
    setState(() {
      _logs.add("[$timeStr] $msg");
      if (_logs.length > 300) _logs.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
      }
    });
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _connectedSeconds = 0;
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() => _connectedSeconds++);
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

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _sshServerCtrl.text = prefs.getString("ssh_server") ?? "";
      _sshPortCtrl.text = prefs.getString("ssh_port") ?? "443";
      _enableSsl = prefs.getBool("ssh_ssl") ?? true;
      _enablePayload = prefs.getBool("ssh_payload_enable") ?? true;
      _enableProxy = prefs.getBool("ssh_proxy_enable") ?? false;
      _sshUserCtrl.text = prefs.getString("ssh_user") ?? "";
      _sshPassCtrl.text = prefs.getString("ssh_pass") ?? "";
      _sshSniCtrl.text = prefs.getString("ssh_sni") ?? "";
      _sshProxyCtrl.text = prefs.getString("ssh_proxy") ?? "";
      _sshPayloadCtrl.text = prefs.getString("ssh_payload") ?? "";
      _memberServerCtrl.text = prefs.getString("member_server") ?? "";
      _memberPortCtrl.text = prefs.getString("member_port") ?? "443";
      _memberUserCtrl.text = prefs.getString("member_user") ?? "";
      _memberPassCtrl.text = prefs.getString("member_pass") ?? "";
    });
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("ssh_server", _sshServerCtrl.text);
    await prefs.setString("ssh_port", _sshPortCtrl.text);
    await prefs.setBool("ssh_ssl", _enableSsl);
    await prefs.setBool("ssh_payload_enable", _enablePayload);
    await prefs.setBool("ssh_proxy_enable", _enableProxy);
    await prefs.setString("ssh_user", _sshUserCtrl.text);
    await prefs.setString("ssh_pass", _sshPassCtrl.text);
    await prefs.setString("ssh_sni", _sshSniCtrl.text);
    await prefs.setString("ssh_proxy", _sshProxyCtrl.text);
    await prefs.setString("ssh_payload", _sshPayloadCtrl.text);
    await prefs.setString("member_server", _memberServerCtrl.text);
    await prefs.setString("member_port", _memberPortCtrl.text);
    await prefs.setString("member_user", _memberUserCtrl.text);
    await prefs.setString("member_pass", _memberPassCtrl.text);
  }

  Future<void> _fetchCloudTemplates() async {
    setState(() => _isLoadingTemplates = true);
    _addLog("Cloud: Fetching template configs...");
    final resp = await ApiService.fetchTemplates();
    setState(() {
      _isLoadingTemplates = false;
      if (resp != null) {
        _cloudConfig = resp;
        _addLog("Cloud: ${resp.templates.length} template configs loaded.");
        if (resp.templates.isNotEmpty && _selectedTemplate == null) {
          _selectedTemplate = resp.templates.first;
        }
      } else {
        _addLog("Cloud: Failed to fetch templates or offline.");
      }
    });
  }

  void _parsePastedV2RayLink() {
    final raw = _v2rayLinkCtrl.text.trim();
    if (raw.isEmpty) return;

    final parsed = V2RayParser.parse(raw);
    if (parsed != null) {
      setState(() {
        _v2rayProtocol = parsed.protocol;
        _v2rayServerCtrl.text = parsed.server;
        _v2rayPortCtrl.text = parsed.port.toString();
        _v2rayUuidCtrl.text = parsed.uuid;
        _v2rayTransport = parsed.transport;
        _v2rayPathCtrl.text = parsed.path;
        _v2raySniCtrl.text = parsed.sni;
        _v2rayTls = parsed.security;
      });
      _addLog("V2Ray: Parsed ${parsed.protocol.toUpperCase()} config for ${parsed.server}");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Berhasil mem-parsing link ${parsed.protocol.toUpperCase()}!"), backgroundColor: AppColors.primary),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Format link V2Ray tidak dikenali!"), backgroundColor: AppColors.error),
      );
    }
  }

  void _applyLoadedConfig(SavedConfigModel config) {
    setState(() {
      _loadedConfig = config;
      if (config.mode == "v2ray") {
        _tabController.animateTo(1);
        _v2rayProtocol = config.v2rayProtocol;
        _v2rayServerCtrl.text = config.server;
        _v2rayPortCtrl.text = config.port.toString();
        if (config.isAccountLocked) {
          _v2rayUuidCtrl.text = config.v2rayUuid;
        }
        _v2rayTransport = config.v2rayTransport;
        _v2rayPathCtrl.text = config.v2rayPath;
        _v2raySniCtrl.text = config.sni;
        _v2rayTls = config.v2rayTls;
      } else {
        _tabController.animateTo(0);
        _enableSsl = config.sshMethod.contains("ssl") || config.port == 443;
        _enablePayload = config.payload.isNotEmpty || config.sshMethod.contains("ws");
        _enableProxy = config.remoteProxy.isNotEmpty || config.sshMethod == "http_proxy";
        _sshServerCtrl.text = config.server;
        _sshPortCtrl.text = config.port.toString();
        if (config.isAccountLocked) {
          _sshUserCtrl.text = config.username;
          _sshPassCtrl.text = config.password;
        }
        _sshSniCtrl.text = config.sni;
        _sshProxyCtrl.text = config.remoteProxy;
        _sshPayloadCtrl.text = config.payload;
      }
    });

    _addLog("Config Loaded: '${config.name}' (${config.mode.toUpperCase()})");
    if (config.note.isNotEmpty) {
      _addLog("Creator Note: ${config.note}");
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(config.name, style: const TextStyle(color: AppColors.primaryLight, fontSize: 14, fontWeight: FontWeight.bold)),
          content: Text(config.note, style: const TextStyle(color: AppColors.textPrimary, fontSize: 13)),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
              child: const Text("OK"),
            )
          ],
        ),
      );
    }
  }

  void _toggleConnection() async {
    if (_vpnState == VpnState.connected ||
        _vpnState == VpnState.connecting ||
        _vpnState == VpnState.authenticating) {
      _addLog("User requested DISCONNECT.");
      await VpnService.stopVpn();
      return;
    }

    await _savePreferences();

    String configJson = "";
    final currentTab = _tabController.index;

    try {
      if (currentTab == 0) {
        // SSH Custom Mode
        if (_sshServerCtrl.text.trim().isEmpty) {
          _showError("Host Server SSH tidak boleh kosong!");
          return;
        }
        final modeDesc = [
          if (_enableSsl) "SSL",
          if (_enablePayload) "Payload",
          if (_enableProxy) "Proxy",
        ].join(" + ");
        _addLog("Building SSH Config (${modeDesc.isEmpty ? 'Direct' : modeDesc}, Host: ${_sshServerCtrl.text.trim()})...");
        configJson = ConfigBuilder.buildSsh(
          server: _sshServerCtrl.text.trim(),
          port: int.tryParse(_sshPortCtrl.text.trim()) ?? 443,
          username: _sshUserCtrl.text.trim(),
          password: _sshPassCtrl.text.trim(),
          enableSsl: _enableSsl,
          sni: _sshSniCtrl.text.trim(),
          enablePayload: _enablePayload,
          payload: _sshPayloadCtrl.text.trim(),
          enableProxy: _enableProxy,
          remoteProxy: _sshProxyCtrl.text.trim(),
        );
      } else if (currentTab == 1) {
        // V2Ray / Xray Mode
        if (_v2rayServerCtrl.text.trim().isEmpty) {
          _showError("Host Server V2Ray tidak boleh kosong!");
          return;
        }
        _addLog("Building V2Ray Config ($_v2rayProtocol, Host: ${_v2rayServerCtrl.text.trim()})...");
        configJson = ConfigBuilder.buildV2Ray(
          protocol: _v2rayProtocol,
          server: _v2rayServerCtrl.text.trim(),
          port: int.tryParse(_v2rayPortCtrl.text.trim()) ?? 443,
          uuid: _v2rayUuidCtrl.text.trim(),
          transport: _v2rayTransport,
          path: _v2rayPathCtrl.text.trim(),
          sni: _v2raySniCtrl.text.trim(),
          security: _v2rayTls,
        );
      } else if (currentTab == 2) {
        // Cloud Tricks Mode (User's own server + cloud trick payload)
        if (_selectedTemplate == null) {
          _showError("Pilih salah satu template trik kuota!");
          return;
        }
        if (_memberServerCtrl.text.trim().isEmpty) {
          _showError("Masukkan alamat server SSH milik Anda!");
          return;
        }
        _addLog("Applying Trick '${_selectedTemplate!.name}' with server '${_memberServerCtrl.text.trim()}'...");
        configJson = ConfigBuilder.buildFromTemplate(
          template: _selectedTemplate!,
          memberServer: _memberServerCtrl.text.trim(),
          memberPort: int.tryParse(_memberPortCtrl.text.trim()) ?? 443,
          username: _memberUserCtrl.text.trim(),
          password: _memberPassCtrl.text.trim(),
        );
      } else {
        // If on Log tab, use last configured or SSH
        _tabController.animateTo(0);
        return;
      }

      _addLog("Passing configuration to sing-box Core...");
      final success = await VpnService.startVpn(configJson);
      if (!success) {
        _addLog("VpnService: Initialization failed.");
        _showError("Gagal memulai VPN. Periksa parameter server!");
      }
    } catch (e) {
      _addLog("Config Error: $e");
      _showError("Error membangun konfigurasi: $e");
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.error),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildTopBar(),
      body: SafeArea(
        child: Column(
          children: [
            if (_loadedConfig != null) _buildLoadedConfigBanner(),
            _buildAnnouncementBanner(),
            _buildTabBar(),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildSshCustomTab(),
                  _buildV2RayTab(),
                  _buildCloudTricksTab(),
                  _buildLogTab(),
                ],
              ),
            ),
            _buildBottomControlPanel(),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildTopBar() {
    return AppBar(
      backgroundColor: AppColors.primary,
      elevation: 0,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(3),
            ),
            child: const Text(
              "IZ",
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            "Izz Tunnel",
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
              color: Colors.white,
            ),
          ),
        ],
      ),
      actions: [
        // File Icon (Open / Save Config)
        PopupMenuButton<String>(
          icon: const Icon(Icons.folder_open_rounded, color: Colors.white),
          tooltip: "Config Manager",
          color: AppColors.surface,
          onSelected: (val) {
            if (val == "open") {
              ConfigDialogs.showOpenConfigDialog(
                context: context,
                onConfigLoaded: _applyLoadedConfig,
              );
            } else if (val == "save") {
              final isV2Ray = _tabController.index == 1;
              ConfigDialogs.showSaveConfigDialog(
                context: context,
                mode: isV2Ray ? "v2ray" : "ssh",
                sshMethod: _enableSsl && _enablePayload ? "ws_ssl" : (_enableSsl ? "ssl_direct" : (_enableProxy ? "http_proxy" : (_enablePayload ? "ws_direct" : "direct"))),
                server: isV2Ray ? _v2rayServerCtrl.text : _sshServerCtrl.text,
                port: int.tryParse(isV2Ray ? _v2rayPortCtrl.text : _sshPortCtrl.text) ?? 443,
                username: _sshUserCtrl.text,
                password: _sshPassCtrl.text,
                sni: isV2Ray ? _v2raySniCtrl.text : _sshSniCtrl.text,
                payload: _sshPayloadCtrl.text,
                remoteProxy: _sshProxyCtrl.text,
                v2rayProtocol: _v2rayProtocol,
                v2rayUuid: _v2rayUuidCtrl.text,
                v2rayTransport: _v2rayTransport,
                v2rayPath: _v2rayPathCtrl.text,
                v2rayTls: _v2rayTls,
                onSaved: () => setState(() {}),
              );
            } else if (val == "clear") {
              setState(() {
                _loadedConfig = null;
                _sshServerCtrl.clear();
                _sshPortCtrl.text = "443";
                _sshUserCtrl.clear();
                _sshPassCtrl.clear();
                _sshSniCtrl.clear();
                _sshProxyCtrl.clear();
                _sshPayloadCtrl.clear();
                _v2rayServerCtrl.clear();
                _v2rayUuidCtrl.clear();
              });
              _addLog("Config cleared to default.");
            }
          },
          itemBuilder: (ctx) => [
            const PopupMenuItem(value: "open", child: Row(children: [Icon(Icons.folder_rounded, size: 18, color: AppColors.primaryLight), SizedBox(width: 10), Text("Open Config", style: TextStyle(color: AppColors.textPrimary, fontSize: 13))])),
            const PopupMenuItem(value: "save", child: Row(children: [Icon(Icons.save_rounded, size: 18, color: AppColors.primaryLight), SizedBox(width: 10), Text("Save Config", style: TextStyle(color: AppColors.textPrimary, fontSize: 13))])),
            const PopupMenuItem(value: "clear", child: Row(children: [Icon(Icons.clear_all_rounded, size: 18, color: AppColors.error), SizedBox(width: 10), Text("Clear / Reset", style: TextStyle(color: AppColors.textPrimary, fontSize: 13))])),
          ],
        ),
        // Tools Icon
        IconButton(
          icon: const Icon(Icons.build_outlined, color: Colors.white),
          tooltip: "Tools (Response Check, DNS, IP)",
          onPressed: () {
            Navigator.push(context, MaterialPageRoute(builder: (_) => const ToolsScreen()));
          },
        ),
        // Sync Cloud Icon
        IconButton(
          icon: _isLoadingTemplates
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.sync_rounded, color: Colors.white),
          tooltip: "Sync Cloud Tricks",
          onPressed: _isLoadingTemplates ? null : _fetchCloudTemplates,
        ),
      ],
    );
  }

  Widget _buildLoadedConfigBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: AppColors.surfaceHighlight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_rounded, size: 14, color: AppColors.warning),
              const SizedBox(width: 6),
              Text(
                "Config: ${_loadedConfig!.name} ${_loadedConfig!.isLocked ? '(Terkunci)' : ''}",
                style: const TextStyle(fontSize: 11, color: AppColors.textPrimary, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          InkWell(
            onTap: () => setState(() => _loadedConfig = null),
            child: const Text("UNLOAD", style: TextStyle(fontSize: 10, color: AppColors.error, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildAnnouncementBanner() {
    final ann = _cloudConfig?.announcement;
    if (ann == null || ann.message.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: AppColors.surfaceLight,
      child: Row(
        children: [
          const Icon(Icons.campaign_outlined, color: AppColors.warning, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ann.message,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      color: AppColors.surface,
      child: TabBar(
        controller: _tabController,
        isScrollable: false,
        indicatorColor: AppColors.primaryLight,
        indicatorWeight: 3,
        labelColor: AppColors.primaryLight,
        unselectedLabelColor: AppColors.textSecondary,
        labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
        tabs: const [
          Tab(text: "SSH INJECT"),
          Tab(text: "V2RAY/XRAY"),
          Tab(text: "TEMPLATE CONFIG"),
          Tab(text: "LOG"),
        ],
      ),
    );
  }

  // TAB 1: SSH Custom / Manual Injector (Dark Tunnel Style)
  Widget _buildSshCustomTab() {
    final isLocked = _loadedConfig?.isLocked == true;
    final isAccountLocked = _loadedConfig?.isAccountLocked == true;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Dark Tunnel Style Method Checkboxes
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildDarkTunnelCheckbox(
                  title: "SSL / TLS",
                  value: _enableSsl,
                  onChanged: isLocked
                      ? null
                      : (v) {
                          setState(() {
                            _enableSsl = v ?? false;
                            if (_enableSsl && (_sshPortCtrl.text == "22" || _sshPortCtrl.text == "80")) {
                              _sshPortCtrl.text = "443";
                            } else if (!_enableSsl && _enablePayload && _sshPortCtrl.text == "443") {
                              _sshPortCtrl.text = "80";
                            } else if (!_enableSsl && !_enablePayload && _sshPortCtrl.text == "443") {
                              _sshPortCtrl.text = "22";
                            }
                          });
                        },
                ),
                _buildDarkTunnelCheckbox(
                  title: "Payload",
                  value: _enablePayload,
                  onChanged: isLocked
                      ? null
                      : (v) {
                          setState(() {
                            _enablePayload = v ?? false;
                            if (_enablePayload && !_enableSsl && _sshPortCtrl.text == "22") {
                              _sshPortCtrl.text = "80";
                            }
                          });
                        },
                ),
                _buildDarkTunnelCheckbox(
                  title: "Proxy",
                  value: _enableProxy,
                  onChanged: isLocked
                      ? null
                      : (v) => setState(() => _enableProxy = v ?? false),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Server & Port
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _sshServerCtrl,
                  enabled: !isAccountLocked,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: "SSH Server / Host",
                    hintText: "host.com",
                    labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 11),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    isDense: true,
                    border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 1,
                child: TextField(
                  controller: _sshPortCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: "Port",
                    hintText: "443",
                    labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 11),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    isDense: true,
                    border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Username & Password
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _sshUserCtrl,
                  enabled: !isAccountLocked,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: "Username",
                    hintText: "username",
                    labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 11),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    isDense: true,
                    border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _sshPassCtrl,
                  obscureText: _obscureSshPass,
                  enabled: !isAccountLocked,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  decoration: InputDecoration(
                    labelText: "Password",
                    hintText: "password",
                    labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    isDense: true,
                    suffixIcon: IconButton(
                      icon: Icon(_obscureSshPass ? Icons.visibility_off : Icons.visibility, size: 16, color: AppColors.textMuted),
                      onPressed: () => setState(() => _obscureSshPass = !_obscureSshPass),
                    ),
                    border: const OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // SNI / Bug Host (if SSL / TLS checked)
          if (_enableSsl) ...[
            TextField(
              controller: _sshSniCtrl,
              enabled: !isLocked,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
              decoration: InputDecoration(
                labelText: "Server Name Indication (SNI / Bug Host)",
                hintText: isLocked ? "[DIKUNCI OLEH PEMBUAT]" : "host.com",
                labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                filled: true,
                fillColor: AppColors.surfaceLight,
                isDense: true,
                border: const OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
              ),
            ),
            const SizedBox(height: 10),
          ],
          // Remote Proxy (if Proxy checked)
          if (_enableProxy) ...[
            TextField(
              controller: _sshProxyCtrl,
              enabled: !isLocked,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
              decoration: const InputDecoration(
                labelText: "Remote HTTP Proxy (IP:Port)",
                hintText: "1.2.3.4:8080",
                labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 11),
                filled: true,
                fillColor: AppColors.surfaceLight,
                isDense: true,
                border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
              ),
            ),
            const SizedBox(height: 10),
          ],
          // Payload Generator Box (if Payload checked)
          if (_enablePayload) ...[
            PayloadBox(
              controller: _sshPayloadCtrl,
              isLocked: isLocked,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDarkTunnelCheckbox({
    required String title,
    required bool value,
    required ValueChanged<bool?>? onChanged,
  }) {
    return InkWell(
      onTap: onChanged != null ? () => onChanged(!value) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: Checkbox(
              value: value,
              onChanged: onChanged,
              activeColor: AppColors.primary,
              checkColor: Colors.white,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: value ? FontWeight.bold : FontWeight.normal,
              color: value ? AppColors.primaryLight : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  // TAB 2: V2Ray / Xray Configuration
  Widget _buildV2RayTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Paste Link Bar
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _v2rayLinkCtrl,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  decoration: const InputDecoration(
                    hintText: "Tempel link vmess://, vless://, trojan://...",
                    hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 11),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () async {
                  final data = await Clipboard.getData('text/plain');
                  if (data != null && data.text != null) {
                    _v2rayLinkCtrl.text = data.text!;
                    _parsePastedV2RayLink();
                  }
                },
                icon: const Icon(Icons.paste_rounded, size: 16),
                label: const Text("PARSE", style: TextStyle(fontSize: 11)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Protocol Selector
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              border: Border.all(color: AppColors.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _v2rayProtocol,
                isExpanded: true,
                dropdownColor: AppColors.surface,
                style: const TextStyle(color: AppColors.primaryLight, fontWeight: FontWeight.bold, fontSize: 12),
                items: const [
                  DropdownMenuItem(value: "vmess", child: Text("VMess Protocol")),
                  DropdownMenuItem(value: "vless", child: Text("VLess Protocol")),
                  DropdownMenuItem(value: "trojan", child: Text("Trojan Protocol")),
                  DropdownMenuItem(value: "shadowsocks", child: Text("Shadowsocks Protocol")),
                ],
                onChanged: (v) => setState(() => _v2rayProtocol = v ?? "vmess"),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Server & Port
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _v2rayServerCtrl,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: "Server / Address",
                    hintText: "host.com",
                    labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    isDense: true,
                    border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 1,
                child: TextField(
                  controller: _v2rayPortCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: "Port",
                    hintText: "443",
                    labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    isDense: true,
                    border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // UUID / Password
          TextField(
            controller: _v2rayUuidCtrl,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
            decoration: const InputDecoration(
              labelText: "UUID / Password / Key",
              hintText: "00000000-0000-0000-0000-000000000000",
              labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 11),
              filled: true,
              fillColor: AppColors.surfaceLight,
              isDense: true,
              border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
            ),
          ),
          const SizedBox(height: 10),
          // Transport & Path
          Row(
            children: [
              Expanded(
                flex: 1,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLight,
                    border: Border.all(color: AppColors.border),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _v2rayTransport,
                      dropdownColor: AppColors.surface,
                      style: const TextStyle(color: AppColors.cyan, fontWeight: FontWeight.bold, fontSize: 12),
                      items: const [
                        DropdownMenuItem(value: "ws", child: Text("WS (WebSocket)")),
                        DropdownMenuItem(value: "grpc", child: Text("gRPC")),
                        DropdownMenuItem(value: "tcp", child: Text("TCP")),
                      ],
                      onChanged: (v) => setState(() => _v2rayTransport = v ?? "ws"),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _v2rayPathCtrl,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: "Path / Service Name",
                    hintText: "/path",
                    labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    isDense: true,
                    border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // SNI & TLS
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _v2raySniCtrl,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: "SNI / Host Header",
                    hintText: "host.com",
                    labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    isDense: true,
                    border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 1,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLight,
                    border: Border.all(color: AppColors.border),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _v2rayTls,
                      dropdownColor: AppColors.surface,
                      style: const TextStyle(color: AppColors.warning, fontWeight: FontWeight.bold, fontSize: 12),
                      items: const [
                        DropdownMenuItem(value: "tls", child: Text("TLS")),
                        DropdownMenuItem(value: "none", child: Text("None")),
                      ],
                      onChanged: (v) => setState(() => _v2rayTls = v ?? "tls"),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // TAB 3: Cloud Tricks (Member enters their own server)
  Widget _buildCloudTricksTab() {
    final templates = _cloudConfig?.templates ?? [];
    final categories = ["All", ...?_cloudConfig?.categories];

    final filtered = _selectedCategory == "All"
        ? templates
        : templates.where((t) => t.category == _selectedCategory).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("1. PILIH TEMPLATE CONFIG", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.primaryLight)),
          const SizedBox(height: 8),
          // Category Pills
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: categories.map((cat) {
                final isSel = _selectedCategory == cat;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _selectedCategory = cat;
                        if (filtered.isNotEmpty) _selectedTemplate = filtered.first;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: isSel ? AppColors.primary : AppColors.surfaceLight,
                        border: Border.all(color: isSel ? AppColors.primaryLight : AppColors.border),
                      ),
                      child: Text(
                        cat,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                          color: isSel ? Colors.white : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 10),
          // Template Selector
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              border: Border.all(color: AppColors.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<TemplateModel>(
                value: filtered.contains(_selectedTemplate) ? _selectedTemplate : (filtered.isNotEmpty ? filtered.first : null),
                isExpanded: true,
                dropdownColor: AppColors.surface,
                items: filtered.map((t) {
                  return DropdownMenuItem(
                    value: t,
                    child: Text("${t.name} (${t.protocol.toUpperCase()})", style: const TextStyle(fontSize: 12, color: AppColors.textPrimary)),
                  );
                }).toList(),
                onChanged: (v) => setState(() => _selectedTemplate = v),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text("2. MASUKKAN SERVER & AKUN ANDA SENDIRI", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.primaryLight)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _memberServerCtrl,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: "Server VPS Anda",
                    hintText: "host.com",
                    labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    isDense: true,
                    border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 1,
                child: TextField(
                  controller: _memberPortCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: "Port",
                    hintText: "443",
                    labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    isDense: true,
                    border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _memberUserCtrl,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: "Username Akun Anda",
                    hintText: "username",
                    labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    isDense: true,
                    border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _memberPassCtrl,
                  obscureText: true,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: "Password Akun",
                    hintText: "password",
                    labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    isDense: true,
                    border: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // TAB 4: Live Terminal Console Log
  Widget _buildLogTab() {
    return Container(
      color: AppColors.logBg,
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("TERMINAL LOG OUTPUT", style: TextStyle(color: AppColors.logTime, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, color: AppColors.logTime, size: 16),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _logs.join("\n")));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Log disalin ke clipboard!"), backgroundColor: AppColors.primary),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_sweep_rounded, color: AppColors.logTime, size: 16),
                    onPressed: () => setState(() => _logs.clear()),
                  ),
                ],
              ),
            ],
          ),
          const Divider(color: AppColors.border, height: 1),
          Expanded(
            child: ListView.builder(
              controller: _logScrollController,
              itemCount: _logs.length,
              itemBuilder: (context, idx) {
                final line = _logs[idx];
                Color lineColor = AppColors.logText;
                if (line.contains("CONNECTED")) lineColor = AppColors.logGreen;
                if (line.contains("ERROR")) lineColor = AppColors.logRed;
                if (line.contains("Connecting") || line.contains("Handshaking")) lineColor = AppColors.logYellow;
                if (line.contains("sing-box") || line.contains("Core")) lineColor = AppColors.logBlue;

                return Text(
                  line,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: lineColor,
                    height: 1.3,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // Bottom Control Panel: Classic HTTP Custom Connect Button & Stats
  Widget _buildBottomControlPanel() {
    final isConnected = _vpnState == VpnState.connected;
    final isWorking = _vpnState == VpnState.connecting || _vpnState == VpnState.authenticating;

    Color btnColor = AppColors.primaryLight;
    String btnText = "CONNECT";
    if (isConnected) {
      btnColor = AppColors.connected;
      btnText = "DISCONNECT";
    } else if (isWorking) {
      btnColor = AppColors.warning;
      btnText = "CONNECTING...";
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Stat Badges
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatBadge(icon: Icons.speed_rounded, label: "PING", value: _ping, color: AppColors.cyan),
              StatBadge(icon: Icons.arrow_downward_rounded, label: "DOWN", value: _download, color: AppColors.success),
              StatBadge(icon: Icons.arrow_upward_rounded, label: "UP", value: _upload, color: AppColors.info),
              StatBadge(icon: Icons.timer_outlined, label: "TIME", value: _formatDuration(_connectedSeconds), color: AppColors.warning),
            ],
          ),
          const SizedBox(height: 10),
          // Big Utilitarian Solid Connect Button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _toggleConnection,
              style: ElevatedButton.styleFrom(
                backgroundColor: btnColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                elevation: 0,
              ),
              child: isWorking
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                        SizedBox(width: 10),
                        Text("CONNECTING...", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
                      ],
                    )
                  : Text(
                      btnText,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.0),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
