import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'message_actions_overlay.dart';

void showMessageActions({
  required BuildContext context,
  required QueryDocumentSnapshot message,
  required bool isMe,
  required VoidCallback onReply,
  required VoidCallback onPin,
  required VoidCallback onDelete,
  required VoidCallback onBlock,
  required VoidCallback onForward,
  required VoidCallback onEdit,
  required GlobalKey messageKey,
  required ValueChanged<String> onReactEmoji,
}) {
  showMessageActionsOverlay(
    context: context,
    messageKey: messageKey,
    messageWidget: Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        message['text'] ?? '',
        style: const TextStyle(
          color: Colors.black87,
          fontSize: 16,
        ),
      ),
    ),
    onReactEmoji: onReactEmoji,
    onReply: onReply,
    onPin: onPin,
    onDelete: onDelete,
    onBlock: onBlock,
    onForward: onForward,
    onEdit: onEdit,
  );
}