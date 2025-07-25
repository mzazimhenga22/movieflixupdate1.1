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
  });

  @override
  Widget build(BuildContext context) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
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
                        color: Colors.purple,
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
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
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
          icon: const Icon(Icons.call),
          onPressed: onVoiceCall,
        ),
        IconButton(
          icon: const Icon(Icons.videocam),
          onPressed: onVideoCall,
        ),
      ],
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}
