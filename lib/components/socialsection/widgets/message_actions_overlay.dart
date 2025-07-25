import 'dart:ui';
import 'package:flutter/material.dart';

class MessageActionsOverlay extends StatelessWidget {
  final Widget messageWidget;
  final VoidCallback onReply;
  final VoidCallback onPin;
  final VoidCallback onReact;
  final VoidCallback onDelete;

  const MessageActionsOverlay({
    super.key,
    required this.messageWidget,
    required this.onReply,
    required this.onPin,
    required this.onReact,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black.withOpacity(0.6),
      body: Stack(
        children: [
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
            child: Container(color: Colors.black.withOpacity(0.2)),
          ),
          Center(child: messageWidget),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 16,
            left: 16,
            child: Material(
              color: Colors.transparent,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(icon: const Icon(Icons.reply), onPressed: onReply),
                  IconButton(icon: const Icon(Icons.push_pin), onPressed: onPin),
                  IconButton(icon: const Icon(Icons.emoji_emotions), onPressed: onReact),
                  IconButton(icon: const Icon(Icons.delete), onPressed: onDelete),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
