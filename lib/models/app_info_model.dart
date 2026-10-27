import 'template_model.dart';

class AnnouncementModel {
  final int id;
  final String title;
  final String message;

  AnnouncementModel({
    required this.id,
    required this.title,
    required this.message,
  });

  factory AnnouncementModel.fromJson(Map<String, dynamic> json) {
    return AnnouncementModel(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? '',
      message: json['message'] as String? ?? '',
    );
  }
}

class CloudConfigResponse {
  final String appName;
  final String appVersion;
  final String minVersion;
  final String updateUrl;
  final bool forceUpdate;
  final AnnouncementModel? announcement;
  final List<String> categories;
  final List<TemplateModel> templates;

  CloudConfigResponse({
    required this.appName,
    required this.appVersion,
    required this.minVersion,
    required this.updateUrl,
    required this.forceUpdate,
    this.announcement,
    required this.categories,
    required this.templates,
  });

  factory CloudConfigResponse.fromJson(Map<String, dynamic> json) {
    final info = json['app_info'] as Map<String, dynamic>? ?? {};
    final annJson = json['announcement'] as Map<String, dynamic>?;
    final catList = (json['categories'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    final tplList = (json['templates'] as List<dynamic>?)
            ?.map((e) => TemplateModel.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    return CloudConfigResponse(
      appName: info['name'] as String? ?? 'IZZ TUNNELING',
      appVersion: info['version'] as String? ?? '1.0.0',
      minVersion: info['min_version'] as String? ?? '1.0.0',
      updateUrl: info['update_url'] as String? ?? 'https://t.me/izzcoyy',
      forceUpdate: info['force_update'] as bool? ?? false,
      announcement: annJson != null ? AnnouncementModel.fromJson(annJson) : null,
      categories: catList,
      templates: tplList,
    );
  }
}
