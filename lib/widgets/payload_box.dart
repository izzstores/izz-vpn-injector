import 'package:flutter/material.dart';
import '../constants/app_colors.dart';

class PayloadBox extends StatelessWidget {
  final TextEditingController controller;
  final bool isLocked;
  final VoidCallback? onChanged;

  const PayloadBox({
    super.key,
    required this.controller,
    this.isLocked = false,
    this.onChanged,
  });

  void _insertTag(String tag) {
    if (isLocked) return;
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
    final tags = [
      "[crlf]",
      "[host]",
      "[port]",
      "[split]",
      "[ua]",
      "[protocol]",
      "[cr]",
      "[lf]",
      "[raw]",
      "[real_raw]"
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "HTTP Payload",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            if (isLocked)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.error.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppColors.error, width: 1),
                ),
                child: const Text(
                  "LOCKED BY CREATOR",
                  style: TextStyle(fontSize: 10, color: AppColors.error, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              TextField(
                controller: controller,
                enabled: !isLocked,
                maxLines: 4,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: isLocked ? AppColors.textMuted : AppColors.primary,
                ),
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.all(10),
                  hintText: isLocked ? "[Config ini dikunci oleh pembuat]" : "GET / HTTP/1.1[crlf]Host: host.com[crlf]Upgrade: websocket[crlf][crlf]",
                  hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                  border: InputBorder.none,
                ),
              ),
              if (!isLocked) ...[
                const Divider(color: AppColors.border, height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: tags.map((t) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InkWell(
                            onTap: () => _insertTag(t),
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceHighlight,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: AppColors.border),
                              ),
                              child: Text(
                                t,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: AppColors.cyan,
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
            ],
          ),
        ),
      ],
    );
  }
}
