import 'package:flutter/material.dart';
import '../constants/app_colors.dart';

class PayloadBox extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback? onChanged;

  const PayloadBox({
    super.key,
    required this.controller,
    this.onChanged,
  });

  void _insertTag(String tag) {
    final text = controller.text;
    final selection = controller.selection;
    final newText = text.replaceRange(
      selection.start >= 0 ? selection.start : text.length,
      selection.end >= 0 ? selection.end : text.length,
      tag,
    );
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: (selection.start >= 0 ? selection.start : text.length) + tag.length,
      ),
    );
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final tags = ["[crlf]", "[host]", "[port]", "[split]", "[ua]", "[protocol]"];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "HTTP Payload Generator",
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              TextField(
                controller: controller,
                maxLines: 4,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: AppColors.cyan,
                ),
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.all(12),
                  hintText: "GET / HTTP/1.1[crlf]Host: bug.com[crlf]Upgrade: websocket[crlf][crlf]",
                  hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 11),
                  border: InputBorder.none,
                ),
              ),
              const Divider(color: AppColors.border, height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: tags.map((t) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: InkWell(
                          onTap: () => _insertTag(t),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceLight,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Text(
                              t,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.blue,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
