import 'dart:ui';
import 'package:flutter/material.dart';

class MessageActionsOverlay extends StatelessWidget {
  final Widget messageWidget;
  final ValueChanged<String> onReactEmoji;
  final VoidCallback onReply;
  final VoidCallback onPin;
  final VoidCallback onDelete;
  final VoidCallback onBlock;
  final VoidCallback onForward;
  final VoidCallback onEdit;

  const MessageActionsOverlay({
    super.key,
    required this.messageWidget,
    required this.onReactEmoji,
    required this.onReply,
    required this.onPin,
    required this.onDelete,
    required this.onBlock,
    required this.onForward,
    required this.onEdit,
  });

  static const List<String> emojis = [
    "❤️", "😂", "👍", "😮", "😢", "🔥", "😡", "🙏", "🎉", "😍",
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Background blur and dim
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(color: Colors.black.withOpacity(0.6)),
          ),

          // Tap outside to dismiss
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(color: Colors.transparent),
          ),

          // Centered message preview
          Align(
            alignment: Alignment.center,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.85),
                borderRadius: BorderRadius.circular(16),
              ),
              child: messageWidget,
            ),
          ),

          // Emoji reaction row
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 150),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: emojis.map((emoji) {
                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        onReactEmoji(emoji);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 28),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),

          // Bottom action menu
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 36),
              child: Container(
                width: 280,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _menuItem(context, Icons.reply, "Reply", onReply),
                    _menuItem(context, Icons.edit, "Edit", onEdit),
                    _menuItem(context, Icons.forward, "Forward", onForward),
                    _menuItem(context, Icons.push_pin, "Pin", onPin),
                    _menuItem(context, Icons.delete, "Delete", onDelete, isDestructive: true),
                    _menuItem(context, Icons.block, "Block", onBlock, isDestructive: true),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _menuItem(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool isDestructive = false,
  }) {
    return InkWell(
      onTap: () {
        Navigator.pop(context); // Close overlay
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
        child: Row(
          children: [
            Icon(
              icon,
              color: isDestructive ? Colors.redAccent : Colors.white,
              size: 22,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: isDestructive ? Colors.redAccent : Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
