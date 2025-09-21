// chat_tile.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; // for Timestamp detection
import 'messages_controller.dart';

class ChatTile extends StatelessWidget {
  final ChatSummary summary;
  final Color accentColor;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onChatOpened;
  final MessagesController controller;
  final bool hasStory;
  final VoidCallback? onAvatarTap;

  const ChatTile({
    super.key,
    required this.summary,
    required this.accentColor,
    required this.controller,
    this.isSelected = false,
    this.onTap,
    this.onLongPress,
    this.onChatOpened,
    this.hasStory = false,
    this.onAvatarTap,
  });

  String _formatTimestamp(BuildContext context, DateTime ts) {
    if (ts.millisecondsSinceEpoch == 0) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(ts.year, ts.month, ts.day);
    if (msgDay == today) {
      // show time
      return TimeOfDay.fromDateTime(ts).format(context);
    } else {
      // show short date like "12 Aug"
      return '${ts.day} ${_monthShort(ts.month)}';
    }
  }

  String _monthShort(int month) {
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return months[month];
  }

  /// Flexible parser for presence lastSeen values (String / int / DateTime / Timestamp)
  DateTime? _parseLastSeen(dynamic raw) {
    try {
      if (raw == null) return null;
      if (raw is DateTime) return raw;
      if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
      if (raw is String) return DateTime.tryParse(raw);
      if (raw is Timestamp) return raw.toDate();
    } catch (_) {}
    return null;
  }

  String _formatLastSeen(BuildContext context, DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff < const Duration(minutes: 1)) return 'Last seen just now';
    if (diff < const Duration(hours: 24)) {
      final t = TimeOfDay.fromDateTime(dt);
      return 'Last seen ${t.format(context)}';
    }
    // older: show short date
    return 'Last seen ${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final isPinned = summary.isPinned || controller.isChatPinned(summary.id);
    final isMuted = summary.isMuted || controller.isUserMuted(summary.id);
    final isBlocked = summary.isBlocked; // controller.block list is reflected into summary
    final unread = (summary.unreadCount > 0);

    // --- presence: read from summary.otherUser if available; fallback false/null ---
    final other = summary.otherUser ?? <String, dynamic>{};
    final dynamic onlineVal = other['isOnline'] ?? other['online'];
    final bool isOnline = onlineVal == true;
    final lastSeenRaw = other['lastSeen'] ?? other['lastSeenAt'] ?? other['last_seen'];
    final DateTime? lastSeenDt = _parseLastSeen(lastSeenRaw);

    final titleStyle = TextStyle(
      color: accentColor,
      fontWeight: unread ? FontWeight.bold : FontWeight.w600,
      fontSize: 16,
    );

    final subtitleMsgStyle = TextStyle(
      color: isBlocked ? Colors.grey : Colors.white70,
      fontWeight: unread ? FontWeight.bold : FontWeight.normal,
      fontSize: 13,
    );

    final statusStyle = TextStyle(
      color: isOnline ? Colors.greenAccent : Colors.white54,
      fontSize: 11,
      fontWeight: FontWeight.w500,
    );

    // avatar
    Widget avatar;
    final photoUrl = other != null ? (other['photoUrl'] ?? '') as String : '';
    final initials = summary.isGroup
        ? 'G'
        : (summary.title.isNotEmpty ? summary.title[0].toUpperCase() : 'U');

    if (photoUrl.isNotEmpty) {
      avatar = CircleAvatar(
        backgroundImage: NetworkImage(photoUrl),
        radius: 24,
        backgroundColor: Colors.transparent,
      );
    } else {
      avatar = CircleAvatar(
        radius: 24,
        backgroundColor: accentColor,
        child: Text(
          initials,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      );
    }

    final formattedTime =
        summary.timestamp.millisecondsSinceEpoch == 0 ? '' : _formatTimestamp(context, summary.timestamp);

    return Opacity(
      opacity: isBlocked ? 0.5 : 1.0,
      child: Card(
        elevation: isSelected ? 6 : 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [accentColor.withOpacity(0.03), Colors.black.withOpacity(0.2)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: accentColor.withOpacity(0.08)),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            selected: isSelected,
            selectedTileColor: accentColor.withOpacity(0.06),
            leading: Stack(
              clipBehavior: Clip.none,
              children: [
                avatar,
                // story ring OR small indicator (preserve your group icon)
                if (summary.isGroup)
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black87,
                      ),
                      child: const Icon(Icons.group, size: 12, color: Colors.white70),
                    ),
                  ),
                // presence dot (bottom-right)
                if (isOnline)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.greenAccent,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.black87, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    summary.title.isNotEmpty ? summary.title : (summary.otherUser?['username'] ?? 'Unknown'),
                    style: titleStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isPinned)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(Icons.push_pin, size: 16, color: accentColor.withOpacity(0.9)),
                  ),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // last message snippet
                  Text(
                    summary.lastMessageText.isNotEmpty ? summary.lastMessageText : 'No messages yet',
                    style: subtitleMsgStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // presence/status line
                  Text(
                    isOnline
                        ? 'Online'
                        : (lastSeenDt != null ? _formatLastSeen(context, lastSeenDt) : ''),
                    style: statusStyle,
                  ),
                ],
              ),
            ),
            trailing: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (formattedTime.isNotEmpty)
                  Text(
                    formattedTime,
                    style: TextStyle(fontSize: 12, color: accentColor.withOpacity(0.95)),
                  ),
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isMuted)
                      Padding(
                        padding: const EdgeInsets.only(right: 6.0),
                        child: Icon(Icons.volume_off, size: 18, color: accentColor.withOpacity(0.85)),
                      ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                      child: unread
                          ? Container(
                              key: ValueKey('badge_${summary.id}_${summary.unreadCount}'),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: accentColor,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [BoxShadow(color: accentColor.withOpacity(0.2), blurRadius: 4, offset: const Offset(0,2))],
                              ),
                              child: Text(
                                '${summary.unreadCount}',
                                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            )
                          : SizedBox(
                              key: ValueKey('badge_empty_${summary.id}'),
                              width: 8,
                              height: 8,
                              child: const SizedBox.shrink(),
                            ),
                    ),
                  ],
                ),
              ],
            ),
            onTap: () async {
              try {
                // mark as read if needed (WhatsApp like behaviour)
                if (summary.unreadCount > 0) {
                  await controller.markAsRead(summary.id, isGroup: summary.isGroup);
                }
              } catch (e) {
                debugPrint('ChatTile markAsRead error: $e');
              } finally {
                onTap?.call(); // parent navigation
                onChatOpened?.call();
              }
            },
            onLongPress: onLongPress,
          ),
        ),
      ),
    );
  }
}
