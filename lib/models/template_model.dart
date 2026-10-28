class TemplateModel {
  final int id;
  final String name;
  final String category;
  final String protocol;
  final String encryptedConfig;
  final String? sni;
  final String? payload;
  final String? updatedAt;

  TemplateModel({
    required this.id,
    required this.name,
    required this.category,
    required this.protocol,
    required this.encryptedConfig,
    this.sni,
    this.payload,
    this.updatedAt,
  });

  factory TemplateModel.fromJson(Map<String, dynamic> json) {
    return TemplateModel(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? 'Unnamed Template',
      category: json['category'] as String? ?? 'Umum',
      protocol: json['protocol'] as String? ?? 'ssh-ws',
      encryptedConfig: json['encrypted_config'] as String? ?? '',
      updatedAt: json['updated_at'] as String?,
    );
  }

  TemplateModel copyWith({
    String? sni,
    String? payload,
  }) {
    return TemplateModel(
      id: id,
      name: name,
      category: category,
      protocol: protocol,
      encryptedConfig: encryptedConfig,
      sni: sni ?? this.sni,
      payload: payload ?? this.payload,
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'category': category,
      'protocol': protocol,
      'encrypted_config': encryptedConfig,
      'sni': sni,
      'payload': payload,
      'updated_at': updatedAt,
    };
  }
}
