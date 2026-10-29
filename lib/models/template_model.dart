class TemplateModel {
  final int id;
  final String name;
  final String category;
  final String protocol;
  final String bugMode;
  final bool enableSsl;
  final bool enablePayload;
  final bool enableProxy;
  final String encryptedConfig;
  final String? sni;
  final String? payload;
  final String? proxy;
  final String? updatedAt;

  TemplateModel({
    required this.id,
    required this.name,
    required this.category,
    required this.protocol,
    this.bugMode = "sni",
    this.enableSsl = true,
    this.enablePayload = true,
    this.enableProxy = false,
    required this.encryptedConfig,
    this.sni,
    this.payload,
    this.proxy,
    this.updatedAt,
  });

  factory TemplateModel.fromJson(Map<String, dynamic> json) {
    final sslVal = json['enable_ssl'];
    final plVal = json['enable_payload'];
    final prxVal = json['enable_proxy'];

    return TemplateModel(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? 'Unnamed Template',
      category: json['category'] as String? ?? 'Umum',
      protocol: json['protocol'] as String? ?? 'ssh-ws',
      bugMode: json['bug_mode'] as String? ?? 'sni',
      enableSsl: sslVal == 1 || sslVal == true || sslVal == null,
      enablePayload: plVal == 1 || plVal == true || plVal == null,
      enableProxy: prxVal == 1 || prxVal == true,
      encryptedConfig: json['encrypted_config'] as String? ?? '',
      updatedAt: json['updated_at'] as String?,
    );
  }

  TemplateModel copyWith({
    String? sni,
    String? payload,
    String? proxy,
    bool? enableSsl,
    bool? enablePayload,
    bool? enableProxy,
  }) {
    return TemplateModel(
      id: id,
      name: name,
      category: category,
      protocol: protocol,
      bugMode: bugMode,
      enableSsl: enableSsl ?? this.enableSsl,
      enablePayload: enablePayload ?? this.enablePayload,
      enableProxy: enableProxy ?? this.enableProxy,
      encryptedConfig: encryptedConfig,
      sni: sni ?? this.sni,
      payload: payload ?? this.payload,
      proxy: proxy ?? this.proxy,
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'category': category,
      'protocol': protocol,
      'bug_mode': bugMode,
      'enable_ssl': enableSsl,
      'enable_payload': enablePayload,
      'enable_proxy': enableProxy,
      'encrypted_config': encryptedConfig,
      'sni': sni,
      'payload': payload,
      'proxy': proxy,
      'updated_at': updatedAt,
    };
  }
}
