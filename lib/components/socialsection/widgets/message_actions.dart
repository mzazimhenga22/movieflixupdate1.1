import 'dart:ui';
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
  required ValueChanged<String> onReactEmoji,
}) {
  showDialog(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    builder: (context) => MessageActionsOverlay(
      messageWidget: Text(
        message['text'],
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
        ),
      ),
      onReactEmoji: onReactEmoji,
      onReply: () {
        Navigator.pop(context);
        onReply();
      },
      onPin: () {
        Navigator.pop(context);
        onPin();
      },
      onDelete: () {
        Navigator.pop(context);
        onDelete();
      },
      onBlock: () {
        Navigator.pop(context);
        onBlock();
      },
      onForward: () {
        Navigator.pop(context);
        onForward();
      },
      onEdit: () {
        Navigator.pop(context);
        onEdit();
      },
    ),
  );
}
