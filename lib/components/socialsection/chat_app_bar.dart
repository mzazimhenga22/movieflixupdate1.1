import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Map<String, dynamic> otherUser;
  final VoidCallback onBack;
  final VoidCallback onSearch;
  final VoidCallback onStories;
  final VoidCallback onChangeBackground;
  final VoidCallback onCall;
  final VoidCallback onVideoCall;

  const ChatAppBar({
    super.key,
    required this.otherUser,
    required this.onBack,
    required this.onSearch,
    required this.onStories,
    required this.onChangeBackground,
    required this.onCall,
    required this.onVideoCall,
  });

  @override
  Widget build(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.deepPurple,
      leadingWidth: 100,
      leading: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: onBack,
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 36,
            height: 36,
            child: _buildProfileAvatar(),
          ),
        ],
      ),
      title: Text(
        otherUser['username']?.toString() ?? 'User',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.call),
          tooltip: 'Voice Call',
          onPressed: onCall,
        ),
        IconButton(
          icon: const Icon(Icons.video_call),
          tooltip: 'Video Call',
          onPressed: onVideoCall,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: 'Options',
          onSelected: (value) {
            switch (value) {
              case 'change_background':
                onChangeBackground();
                break;
              case 'search':
                onSearch();
                break;
              case 'stories':
                onStories();
                break;
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem<String>(
              value: 'change_background',
              child: Text('Change Background'),
            ),
            PopupMenuItem<String>(
              value: 'search',
              child: Text('Search Messages'),
            ),
            PopupMenuItem<String>(
              value: 'stories',
              child: Text('View Stories'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildProfileAvatar() {
    final profilePicture = otherUser['profile_picture']?.toString();
    final username = otherUser['username']?.toString() ?? '';
    final firstLetter = username.isNotEmpty ? username[0].toUpperCase() : 'U';

    return CachedNetworkImage(
      imageUrl: profilePicture ?? '',
      imageBuilder: (context, imageProvider) => CircleAvatar(
        backgroundImage: imageProvider,
      ),
      placeholder: (context, url) => const CircleAvatar(
        backgroundColor: Colors.deepPurple,
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        ),
      ),
      errorWidget: (context, url, error) => CircleAvatar(
        backgroundColor: Colors.deepPurple,
        child: Text(firstLetter, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}