import 'dart:ui';
import 'package:flutter/material.dart';

class MessageActionsOverlay extends StatelessWidget {
  final Widget messageWidget;
  final ValueChanged<String> onReactEmoji;
  final VoidCallback onReply;
  final VoidCallback onPin;
  final VoidCallback onDelete;

  const MessageActionsOverlay({
    super.key,
    required this.messageWidget,
    required this.onReactEmoji,
    required this.onReply,
    required this.onPin,
    required this.onDelete,
  });

  static const List<String> emojis = [
    "❤️", "😂", "👍", "😮", "😢", "🔥", "😡", "🙏", "🎉", "😍",
    "😎", "👏", "💯", "🤯", "😆", "👀", "🥲", "😅", "🙌", "🤔",
    // Add more if needed
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Full-screen blur
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(color: Colors.black.withOpacity(0.4)),
          ),

          // Dismiss anywhere
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(color: Colors.transparent),
          ),

          // Emoji strip above message
          Positioned(
            top: MediaQuery.of(context).size.height * 0.2,
            left: 24,
            right: 24,
            child: Material(
              borderRadius: BorderRadius.circular(32),
              color: Colors.white,
              elevation: 6,
              child: SizedBox(
                height: 56,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: emojis.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, index) {
                    final emoji = emojis[index];
                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        onReactEmoji(emoji);
                      },
                      child: Center(
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 28),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),

          // Centered message
          Center(
            child: Material(
              elevation: 8,
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: messageWidget,
              ),
            ),
          ),

          // Bottom actions
          Positioned(
            bottom: 40,
            left: 24,
            right: 24,
            child: Material(
              borderRadius: BorderRadius.circular(16),
              color: Colors.white,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _actionTile(context, Icons.reply, "Reply", onReply),
                  _actionTile(context, Icons.push_pin, "Pin", onPin),
                  _actionTile(context, Icons.delete, "Delete", onDelete),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionTile(BuildContext context, IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: Colors.black87),
      title: Text(label, style: const TextStyle(fontSize: 16)),
      onTap: () {
        Navigator.pop(context);
        onTap();
      },
    );
  }
}
