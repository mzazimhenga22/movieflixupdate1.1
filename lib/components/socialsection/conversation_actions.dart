// conversation_actions.dart

import 'package:flutter/material.dart';

class ConversationActionsAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  final VoidCallback onBlock;
  final VoidCallback onMute;
  final VoidCallback onPin;
  final VoidCallback onDelete;
  final VoidCallback onClearSelection;
  final bool isSelected;

  const ConversationActionsAppBar({
    super.key,
    required this.onBlock,
    required this.onMute,
    required this.onPin,
    required this.onDelete,
    required this.onClearSelection,
    required this.isSelected,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      leading: isSelected
          ? IconButton(
              icon: const Icon(Icons.close),
              onPressed: onClearSelection,
            )
          : null,
      title: Text(isSelected ? "1 selected" : "Messages"),
      actions: isSelected
          ? [
              IconButton(icon: const Icon(Icons.block), onPressed: onBlock),
              IconButton(icon: const Icon(Icons.volume_off), onPressed: onMute),
              IconButton(icon: const Icon(Icons.push_pin), onPressed: onPin),
              IconButton(
                  icon: const Icon(Icons.delete), onPressed: onDelete),
            ]
          : null,
    );
  }
}
