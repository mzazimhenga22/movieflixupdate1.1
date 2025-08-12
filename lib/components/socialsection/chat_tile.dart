import 'package:flutter/material.dart';
import 'messages_controller.dart';

class ChatTile extends StatelessWidget {
  final bool isGroup;
  final String chatId;
  final String title;
  final String lastMessage;
  final DateTime? timestamp;
  final int unreadCount;
  final String photoUrl;
  final Color accentColor;
  final bool isSelected;
  final bool isBlocked;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onChatOpened;
  final MessagesController controller;

  const ChatTile({
    super.key,
    required this.isGroup,
    required this.chatId,
    required this.title,
    required this.lastMessage,
    this.timestamp,
    required this.unreadCount,
    this.photoUrl = '',
    required this.accentColor,
    required this.isSelected,
    this.isBlocked = false,
    this.onTap,
    this.onLongPress,
    this.onChatOpened,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final isPinned = controller.isChatPinned(chatId);
    final isMuted = controller.isUserMuted(chatId);

    return Opacity(
      opacity: isBlocked ? 0.5 : 1.0,
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                accentColor.withOpacity(0.1),
                accentColor.withOpacity(0.3),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: accentColor.withOpacity(0.3),
            ),
          ),
          child: ListTile(
            selected: isSelected,
            selectedTileColor: accentColor.withOpacity(0.1),
            leading: CircleAvatar(
              backgroundImage: photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
              child: photoUrl.isEmpty
                  ? Text(
                      isGroup ? 'G' : title.isNotEmpty ? title[0].toUpperCase() : 'U',
                      style: const TextStyle(color: Colors.white),
                    )
                  : null,
            ),
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: accentColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (unreadCount > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: accentColor,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$unreadCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            subtitle: Text(
              lastMessage,
              style: TextStyle(
                color: isBlocked ? Colors.grey : Colors.white,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isMuted)
                  Icon(
                    Icons.volume_off,
                    size: 20,
                    color: accentColor.withOpacity(0.7),
                  ),
                if (isPinned)
                  Icon(
                    Icons.push_pin,
                    size: 20,
                    color: accentColor,
                  ),
                if (!isPinned && !isMuted && timestamp != null)
                  Text(
                    TimeOfDay.fromDateTime(timestamp!).format(context),
                    style: TextStyle(
                      fontSize: 12,
                      color: accentColor,
                    ),
                  ),
              ],
            ),
            onTap: () {
              onTap?.call();
              onChatOpened?.call();
            },
            onLongPress: onLongPress,
          ),
        ),
      ),
    );
  }
}