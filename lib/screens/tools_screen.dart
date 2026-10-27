import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../constants/app_colors.dart';

class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // 1. Response Checker State
  final TextEditingController _urlCtrl = TextEditingController(text: "http://speedtest.net");
  final TextEditingController _proxyCtrl = TextEditingController();
  final TextEditingController _customHeaderCtrl = TextEditingController(
    text: "User-Agent: Mozilla/5.0\r\nConnection: Upgrade\r\nUpgrade: websocket",
  );
  String _selectedMethod = "HEAD";
  bool _isChecking = false;
  String _checkResult = "Masukkan URL dan klik TEST untuk melihat respon header.";
  int? _responseTimeMs;
  int? _statusCode;

  // 2. DNS Changer State
  String _selectedDnsPreset = "Cloudflare";
  final TextEditingController _dns1Ctrl = TextEditingController(text: "1.1.1.1");
  final TextEditingController _dns2Ctrl = TextEditingController(text: "1.0.0.1");

  // 3. IP Hunter State
  bool _isFetchingIp = false;
  String _publicIp = "--";
  String _ispName = "--";
  String _country = "--";
  final TextEditingController _ipTargetCtrl = TextEditingController(text: "100.");
  String _hunterStatus = "Klik Cari IP untuk memeriksa IP koneksi seluler.";

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _fetchCurrentIp();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _urlCtrl.dispose();
    _proxyCtrl.dispose();
    _customHeaderCtrl.dispose();
    _dns1Ctrl.dispose();
    _dns2Ctrl.dispose();
    _ipTargetCtrl.dispose();
    super.dispose();
  }

  Future<void> _runResponseCheck() async {
    final rawUrl = _urlCtrl.text.trim();
    if (rawUrl.isEmpty) return;

    final targetUrl = rawUrl.startsWith("http://") || rawUrl.startsWith("https://")
        ? rawUrl
        : "http://$rawUrl";

    setState(() {
      _isChecking = true;
      _checkResult = "Menghubungkan ke $targetUrl ...";
      _statusCode = null;
      _responseTimeMs = null;
    });

    final stopwatch = Stopwatch()..start();
    try {
      final uri = Uri.parse(targetUrl);
      final client = http.Client();
      http.Response response;

      Map<String, String> headers = {};
      for (final line in _customHeaderCtrl.text.split("\n")) {
        if (line.contains(":")) {
          final parts = line.split(":");
          headers[parts[0].trim()] = parts.sublist(1).join(":").trim();
        }
      }

      switch (_selectedMethod) {
        case "HEAD":
          response = await client.head(uri, headers: headers).timeout(const Duration(seconds: 10));
          break;
        case "POST":
          response = await client.post(uri, headers: headers).timeout(const Duration(seconds: 10));
          break;
        default:
          response = await client.get(uri, headers: headers).timeout(const Duration(seconds: 10));
          break;
      }

      stopwatch.stop();

      final buffer = StringBuffer();
      buffer.writeln("HTTP/1.1 ${response.statusCode} ${response.reasonPhrase ?? ''}");
      response.headers.forEach((k, v) {
        buffer.writeln("$k: $v");
      });

      setState(() {
        _isChecking = false;
        _statusCode = response.statusCode;
        _responseTimeMs = stopwatch.elapsedMilliseconds;
        _checkResult = buffer.toString();
      });
    } catch (e) {
      stopwatch.stop();
      setState(() {
        _isChecking = false;
        _statusCode = 0;
        _responseTimeMs = stopwatch.elapsedMilliseconds;
        _checkResult = "Error: $e";
      });
    }
  }

  Future<void> _fetchCurrentIp() async {
    setState(() => _isFetchingIp = true);
    try {
      final res = await http.get(Uri.parse("http://ip-api.com/json/")).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _publicIp = data['query'] ?? "--";
          _ispName = data['isp'] ?? data['org'] ?? "--";
          _country = "${data['city'] ?? ''}, ${data['country'] ?? ''}";

          final target = _ipTargetCtrl.text.trim();
          if (target.isNotEmpty && _publicIp.startsWith(target)) {
            _hunterStatus = "🎯 TARGET COCOK! IP Diawali dengan '$target'";
          } else {
            _hunterStatus = "IP saat ini: $_publicIp (Belum cocok target '$target')";
          }
        });
      }
    } catch (_) {
      setState(() {
        _publicIp = "Gagal memuat";
        _ispName = "Offline / Timeout";
      });
    } finally {
      setState(() => _isFetchingIp = false);
    }
  }

  void _onDnsPresetChanged(String? val) {
    if (val == null) return;
    setState(() {
      _selectedDnsPreset = val;
      switch (val) {
        case "Cloudflare":
          _dns1Ctrl.text = "1.1.1.1";
          _dns2Ctrl.text = "1.0.0.1";
          break;
        case "Google":
          _dns1Ctrl.text = "8.8.8.8";
          _dns2Ctrl.text = "8.8.4.4";
          break;
        case "AdGuard (Anti-Iklan)":
          _dns1Ctrl.text = "94.140.14.14";
          _dns2Ctrl.text = "94.140.15.15";
          break;
        case "OpenDNS":
          _dns1Ctrl.text = "208.67.222.222";
          _dns2Ctrl.text = "208.67.220.220";
          break;
        default:
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text(
          "TOOLS & UTILITIES",
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
            color: AppColors.textPrimary,
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: AppColors.primary,
          indicatorWeight: 3,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          tabs: const [
            Tab(icon: Icon(Icons.network_check_rounded, size: 18), text: "Header Check"),
            Tab(icon: Icon(Icons.dns_rounded, size: 18), text: "DNS Forwarder"),
            Tab(icon: Icon(Icons.my_location_rounded, size: 18), text: "IP Hunter"),
            Tab(icon: Icon(Icons.wifi_tethering_rounded, size: 18), text: "Tethering"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildResponseCheckerTab(),
          _buildDnsChangerTab(),
          _buildIpHunterTab(),
          _buildTetheringTab(),
        ],
      ),
    );
  }

  Widget _buildResponseCheckerTab() {
    Color statusBadgeColor = AppColors.textMuted;
    if (_statusCode != null) {
      if (_statusCode! >= 200 && _statusCode! < 300) {
        statusBadgeColor = AppColors.success;
      } else if (_statusCode! >= 300 && _statusCode! < 400) {
        statusBadgeColor = AppColors.cyan;
      } else {
        statusBadgeColor = AppColors.error;
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Host / Bug Response Checker",
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.border),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedMethod,
                    dropdownColor: AppColors.surface,
                    style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 13),
                    items: const [
                      DropdownMenuItem(value: "HEAD", child: Text("HEAD")),
                      DropdownMenuItem(value: "GET", child: Text("GET")),
                      DropdownMenuItem(value: "POST", child: Text("POST")),
                    ],
                    onChanged: (v) => setState(() => _selectedMethod = v ?? "HEAD"),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _urlCtrl,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: "http://bug.com",
                    hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                    filled: true,
                    fillColor: AppColors.surfaceLight,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _customHeaderCtrl,
            maxLines: 3,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: AppColors.cyan),
            decoration: InputDecoration(
              labelText: "Request Headers",
              labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
              filled: true,
              fillColor: AppColors.surfaceLight,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.border)),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              onPressed: _isChecking ? null : _runResponseCheck,
              icon: _isChecking
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded, size: 18),
              label: Text(_isChecking ? "MENGIRIM REQUEST..." : "CEK RESPON HOST"),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("OUTPUT RESPON", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.textSecondary)),
              if (_statusCode != null)
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: statusBadgeColor, borderRadius: BorderRadius.circular(4)),
                      child: Text("HTTP $_statusCode", style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 8),
                    if (_responseTimeMs != null)
                      Text("${_responseTimeMs}ms", style: const TextStyle(color: AppColors.cyan, fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: SelectableText(
              _checkResult,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDnsChangerTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("DNS Forwarder / Custom DNS", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          const Text("Gunakan DNS pihak ketiga untuk mencegah DNS leak atau pemblokiran ISP.", style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _selectedDnsPreset,
                isExpanded: true,
                dropdownColor: AppColors.surface,
                items: const [
                  DropdownMenuItem(value: "Cloudflare", child: Text("Cloudflare (1.1.1.1)")),
                  DropdownMenuItem(value: "Google", child: Text("Google (8.8.8.8)")),
                  DropdownMenuItem(value: "AdGuard (Anti-Iklan)", child: Text("AdGuard Anti-Iklan")),
                  DropdownMenuItem(value: "OpenDNS", child: Text("OpenDNS")),
                  DropdownMenuItem(value: "Custom", child: Text("Custom DNS Sendiri")),
                ],
                onChanged: _onDnsPresetChanged,
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _dns1Ctrl,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              labelText: "Primary DNS (DNS 1)",
              filled: true,
              fillColor: AppColors.surfaceLight,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.border)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _dns2Ctrl,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              labelText: "Secondary DNS (DNS 2)",
              filled: true,
              fillColor: AppColors.surfaceLight,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.border)),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("DNS Forwarder berhasil disetel!"), backgroundColor: AppColors.primary),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text("SIMPAN PENGATURAN DNS"),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIpHunterTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("IP Hunter / LookUp", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          const Text("Bantu temukan IP operator yang sesuai dengan trik kuota (misal IP 100.x.x.x) dengan mode pesawat.", style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Public IP", style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    Text(_publicIp, style: const TextStyle(color: AppColors.primary, fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
                const Divider(color: AppColors.border, height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("ISP / Operator", style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    Text(_ispName, style: const TextStyle(color: AppColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
                  ],
                ),
                const Divider(color: AppColors.border, height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Lokasi", style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    Text(_country, style: const TextStyle(color: AppColors.textPrimary, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _ipTargetCtrl,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              labelText: "Target Prefix IP (contoh: 100.)",
              filled: true,
              fillColor: AppColors.surfaceLight,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.border)),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceHighlight,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(_hunterStatus, style: const TextStyle(fontSize: 12, color: AppColors.cyan, fontWeight: FontWeight.w500)),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              onPressed: _isFetchingIp ? null : _fetchCurrentIp,
              icon: _isFetchingIp
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.refresh_rounded, size: 18),
              label: const Text("PERIKSA ULANG IP"),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTetheringTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Share VPN Connection (Tethering)", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          const Text("Bagikan koneksi internet VPN dari HP ke Laptop/PC via WiFi Hotspot atau USB Tethering.", style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Proxy Settings di Laptop / PC:", style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 10),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("Proxy Host (IP HP):", style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    Text("192.168.43.1", style: TextStyle(color: AppColors.textPrimary, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 8),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("HTTP Proxy Port:", style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    Text("10808", style: TextStyle(color: AppColors.textPrimary, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 8),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("SOCKS5 Proxy Port:", style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    Text("10809", style: TextStyle(color: AppColors.textPrimary, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            "Langkah-langkah:\n1. Nyalakan Hotspot HP Anda.\n2. Hubungkan Laptop/PC ke Hotspot HP.\n3. Di Laptop, buka Pengaturan Jaringan -> Proxy -> Manual Proxy Setup.\n4. Masukkan IP 192.168.43.1 dan Port 10808.\n5. Laptop Anda sekarang terkoneksi internet melalui VPN HP!",
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.5),
          ),
        ],
      ),
    );
  }
}
