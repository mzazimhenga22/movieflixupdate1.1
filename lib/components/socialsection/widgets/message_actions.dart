import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';


void showMessageActions({
  required BuildContext context,
  required QueryDocumentSnapshot message,
  required bool isMe,
  required VoidCallback onReply,
  required VoidCallback onPin,
}) {
  showModalBottomSheet(
    context: context,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.reply),
          title: const Text('Reply'),
          onTap: () {
            Navigator.pop(context);
            onReply();
          },
        ),
        if (isMe)
          ListTile(
            leading: const Icon(Icons.push_pin),
            title: const Text('Pin Message'),
            onTap: () {
              Navigator.pop(context);
              onPin();
            },
          ),
        // TODO: Add Delete, Edit, Forward, React etc.
        ListTile(
          leading: const Icon(Icons.delete),
          title: const Text('Delete'),
          onTap: () {
            Navigator.pop(context);
            // Placeholder for delete logic
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Delete not implemented yet')),
            );
          },
        ),
      ],
    ),
  );
}
