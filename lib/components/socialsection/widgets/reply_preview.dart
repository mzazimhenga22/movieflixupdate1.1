// /chat/reply_preview.dart
import 'package:flutter/material.dart';

class ReplyPreview extends StatelessWidget {
  final String? replyText;
  final VoidCallback onCancel;

  const ReplyPreview({
    super.key,
    required this.replyText,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    if (replyText == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.reply, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              replyText!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: onCancel,
          )
        ],
      ),
    );
  }
}
