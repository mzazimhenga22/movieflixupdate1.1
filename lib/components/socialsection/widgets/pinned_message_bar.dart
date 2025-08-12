// /chat/pinned_message_bar.dart
import 'package:flutter/material.dart';

class PinnedMessageBar extends StatelessWidget {
  final String? pinnedText;
  final VoidCallback onDismiss;

  const PinnedMessageBar({
    super.key,
    required this.pinnedText,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    if (pinnedText == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: const Color.fromARGB(255, 132, 118, 252),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.push_pin, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              pinnedText!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: onDismiss,
          )
        ],
      ),
    );
  }
}
