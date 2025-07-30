import 'package:flutter/material.dart';

class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;
  final String chatId;
  final VoidCallback onBack;
  final VoidCallback onProfileTap;
  final VoidCallback onVideoCall;
  final VoidCallback onVoiceCall;
  final bool isOnline;
  final bool hasStory;
  final Color accentColor;

  const ChatAppBar({
    super.key,
    required this.currentUser,
    required this.otherUser,
    required this.chatId,
    required this.onBack,
    required this.onProfileTap,
    required this.onVideoCall,
    required this.onVoiceCall,
    required this.isOnline,
    required this.hasStory,
    this.accentColor = Colors.blueAccent,
  });

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
        icon: Icon(Icons.arrow_back, color: accentColor),
        onPressed: onBack,
      ),
      title: InkWell(
        onTap: onProfileTap,
        child: Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundImage: NetworkImage(
                    otherUser['photoUrl'] ?? 'https://via.placeholder.com/150',
                  ),
                ),
                if (hasStory)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        color: accentColor,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  otherUser['username'] ?? 'User',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: accentColor,
                  ),
                ),
                Text(
                  isOnline ? 'Online' : 'Offline',
                  style: TextStyle(
                    fontSize: 12,
                    color: isOnline ? Colors.green : Colors.grey,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          icon: Icon(Icons.call, color: accentColor),
          onPressed: onVoiceCall,
        ),
        IconButton(
          icon: Icon(Icons.videocam, color: accentColor),
          onPressed: onVideoCall,
        ),
      ],
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}