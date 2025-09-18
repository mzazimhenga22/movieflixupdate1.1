// profile_screen.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'chat_screen.dart';
import 'Group_chat_screen.dart';
import 'messages_controller.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';

/// Profile screen enhanced with real messaging features (not placeholders).
/// Features:
/// 1) Start Chat
/// 2) Create Group With (current user + this profile)
/// 3) Send Contact Card (as a message in the chat)
/// 4) Add / Remove Favorite
/// 5) Start Watch Party (creates a watch_parties doc and invites user)
class ProfileScreen extends StatelessWidget {
  final Map<String, dynamic> user;

  const ProfileScreen({super.key, required this.user});

  String _getCurrentUid() => FirebaseAuth.instance.currentUser?.uid ?? '';

  Map<String, dynamic> _currentUserMinimal() {
    final auth = FirebaseAuth.instance.currentUser;
    return {
      'id': auth?.uid,
      'username': auth?.displayName ?? '',
      'photoUrl': auth?.photoURL ?? '',
      'accentColor': Colors.blueAccent, // fallback
    };
  }

  /// Simple helper matching getChatId
  String _getChatId(String a, String b) => a.compareTo(b) < 0 ? '${a}_$b' : '${b}_$a';

  @override
  Widget build(BuildContext context) {
    final viewerId = _getCurrentUid();
    final displayName = user['username'] ?? 'Unknown';
    final photo = (user['photoUrl'] ?? user['avatar'] ?? '') as String;

    if (user['id'] == null || (user['id'] as String).isEmpty) {
      return const Scaffold(
        body: Center(child: Text("User data not provided.", style: TextStyle(fontSize: 16))),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.arrow_back, color: Colors.white)),
        title: Text(displayName, style: const TextStyle(color: Colors.white)),
      ),
      backgroundColor: Colors.black,
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        children: [
          _buildHeader(context, displayName, photo),
          const SizedBox(height: 16),

          // Row of primary actions
          _buildPrimaryActions(context),

          const SizedBox(height: 20),
          const Text('More', style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),

          // Feature buttons (5 real features)
          ElevatedButton.icon(
            icon: const Icon(Icons.message),
            label: const Text('Start Chat'),
            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: () => _openOrCreateChatAndOpen(context),
          ),
          const SizedBox(height: 8),

          ElevatedButton.icon(
            icon: const Icon(Icons.group_add),
            label: Text('Create Group With ${user['username'] ?? ''}'),
            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: () => _createGroupWithUser(context),
          ),
          const SizedBox(height: 8),

          ElevatedButton.icon(
            icon: const Icon(Icons.contact_page),
            label: const Text('Send Contact Card'),
            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: () => _sendContactCard(context),
          ),
          const SizedBox(height: 8),

          ElevatedButton.icon(
            icon: const Icon(Icons.star_border),
            label: const Text('Toggle Favorite'),
            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: () => _toggleFavorite(context),
          ),
          const SizedBox(height: 8),

          ElevatedButton.icon(
            icon: const Icon(Icons.live_tv),
            label: const Text('Start Watch Party'),
            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: () => _startWatchParty(context),
          ),

          const SizedBox(height: 20),
          const Text('Appearance', style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),

          ElevatedButton.icon(
            icon: const Icon(Icons.wallpaper),
            label: const Text('Chat Background'),
            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: () => _showChatSettings(context),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, String name, String photo) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF6A85B6), Color(0xFFbac8e0)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 44,
            backgroundColor: Colors.white,
            backgroundImage: (photo != null && photo.isNotEmpty) ? NetworkImage(photo) : null,
            child: (photo == null || photo.isEmpty) ? Text(name.isNotEmpty ? name[0].toUpperCase() : 'U', style: const TextStyle(fontSize: 32, color: Colors.black87)) : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 6),
              Text(user['email'] ?? '', style: const TextStyle(color: Colors.white70)),
            ]),
          ),
          Column(
            children: [
              IconButton(onPressed: () => _blockOrUnblock(context), icon: const Icon(Icons.block, color: Colors.white)),
              const SizedBox(height: 4),
              IconButton(onPressed: () => _startVoiceCall(context), icon: const Icon(Icons.phone, color: Colors.white)),
              const SizedBox(height: 4),
              IconButton(onPressed: () => _startVideoCall(context), icon: const Icon(Icons.videocam, color: Colors.white)),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildPrimaryActions(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            icon: const Icon(Icons.chat_bubble_outline),
            label: const Text('Message'),
            onPressed: () => _openOrCreateChatAndOpen(context),
            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ElevatedButton.icon(
            icon: const Icon(Icons.group),
            label: const Text('Create Group'),
            onPressed: () => _createGroupWithUser(context),
            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ),
      ],
    );
  }

  // --------------------
  // Implementations
  // --------------------

  Future<void> _openOrCreateChatAndOpen(BuildContext context) async {
    final viewerId = _getCurrentUid();
    final targetId = user['id'] as String;
    if (viewerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sign in to message users.')));
      return;
    }

    final chatId = _getChatId(viewerId, targetId);
    final chatRef = FirebaseFirestore.instance.collection('chats').doc(chatId);

    try {
      // ensure parent doc exists and includes cachedUsers
      final cachedUsers = {
        viewerId: {
          'id': viewerId,
          'username': FirebaseAuth.instance.currentUser?.displayName ?? '',
          'photoUrl': FirebaseAuth.instance.currentUser?.photoURL ?? '',
        },
        targetId: {
          'id': targetId,
          'username': user['username'] ?? '',
          'photoUrl': user['photoUrl'] ?? user['avatar'] ?? '',
        },
      };

      await chatRef.set({
        'userIds': [viewerId, targetId],
        'isGroup': false,
        'cachedUsers': cachedUsers,
        'timestamp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // open chat screen (mimic your existing navigation style)
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: chatId,
            currentUser: _currentUserMinimal(),
            otherUser: user,
            authenticatedUser: _currentUserMinimal(),
            storyInteractions: const [],
            accentColor: Colors.blueAccent,
            forwardedMessage: null,
          ),
        ),
      );
    } catch (e) {
      debugPrint('openOrCreateChat error: $e');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to open chat.')));
    }
  }

  Future<void> _createGroupWithUser(BuildContext context) async {
    final viewerId = _getCurrentUid();
    final targetId = user['id'] as String;
    if (viewerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sign in to create groups.')));
      return;
    }

    final nameController = TextEditingController(text: '${user['username'] ?? 'Friend'} & You');

    final groupName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Group Name'),
        content: TextField(controller: nameController, decoration: const InputDecoration(hintText: 'Enter group name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (groupName == null || groupName.isEmpty) return;

    try {
      final groupsRef = FirebaseFirestore.instance.collection('groups');
      final docRef = await groupsRef.add({
        'name': groupName,
        'userIds': [viewerId, targetId],
        'createdBy': viewerId,
        'timestamp': FieldValue.serverTimestamp(),
        'lastMessage': '',
        'unreadBy': [],
      });

      // Navigate to group chat screen
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => GroupChatScreen(
            chatId: docRef.id,
            currentUser: _currentUserMinimal(),
            authenticatedUser: _currentUserMinimal(),
            accentColor: Colors.blueAccent,
            forwardedMessage: null,
          ),
        ),
      );
    } catch (e) {
      debugPrint('createGroup error: $e');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to create group.')));
    }
  }

  Future<void> _sendContactCard(BuildContext context) async {
    final viewerId = _getCurrentUid();
    final targetId = user['id'] as String;
    if (viewerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sign in to send contact cards.')));
      return;
    }

    final chatId = _getChatId(viewerId, targetId);
    final chatRef = FirebaseFirestore.instance.collection('chats').doc(chatId);

    try {
      // ensure chat exists
      await chatRef.set({
        'userIds': [viewerId, targetId],
        'timestamp': FieldValue.serverTimestamp(),
        'isGroup': false,
      }, SetOptions(merge: true));

      final messagesRef = chatRef.collection('messages');

      // send contact message
      final msgData = {
        'type': 'contact',
        'senderId': viewerId,
        'contact': {
          'id': user['id'],
          'username': user['username'],
          'photoUrl': user['photoUrl'] ?? user['avatar'] ?? '',
          'email': user['email'] ?? '',
        },
        'text': '${user['username'] ?? 'Contact'}',
        'timestamp': FieldValue.serverTimestamp(),
        'readBy': [viewerId],
      };

      await messagesRef.add(msgData);

      // update parent doc lastMessage/unreadBy
      await chatRef.set({
        'lastMessage': 'Contact: ${user['username'] ?? ''}',
        'timestamp': FieldValue.serverTimestamp(),
        'unreadBy': FieldValue.arrayUnion([targetId]),
      }, SetOptions(merge: true));

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Contact card sent.')));
      // navigate to chat
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: chatId,
            currentUser: _currentUserMinimal(),
            otherUser: user,
            authenticatedUser: _currentUserMinimal(),
            storyInteractions: const [],
            accentColor: Colors.blueAccent,
            forwardedMessage: null,
          ),
        ),
      );
    } catch (e) {
      debugPrint('sendContactCard error: $e');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to send contact card.')));
    }
  }

  Future<void> _toggleFavorite(BuildContext context) async {
    final viewerId = _getCurrentUid();
    final targetId = user['id'] as String;
    if (viewerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sign in to manage favorites.')));
      return;
    }

    final userRef = FirebaseFirestore.instance.collection('users').doc(viewerId);
    try {
      final snapshot = await userRef.get();
      final current = List<String>.from(snapshot.data()?['favoriteContacts'] ?? []);
      final isFav = current.contains(targetId);
      if (isFav) {
        await userRef.update({'favoriteContacts': FieldValue.arrayRemove([targetId])});
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Removed from favorites')));
      } else {
        await userRef.update({'favoriteContacts': FieldValue.arrayUnion([targetId])});
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added to favorites')));
      }
    } catch (e) {
      debugPrint('toggleFavorite error: $e');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to update favorites')));
    }
  }

  /// NEW: start watch party with scheduling & send an in-chat watch_party message bubble
  Future<void> _startWatchParty(BuildContext context) async {
    final viewerId = _getCurrentUid();
    final targetId = user['id'] as String;
    if (viewerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sign in to start a watch party.')));
      return;
    }

    // Ask host to choose required minutes or duration
    final minutesController = TextEditingController(text: '10');

    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start Watch Party'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Set how many minutes the invitee should click the invite to join (minimum 1 minute).'),
            const SizedBox(height: 12),
            TextField(
              controller: minutesController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Required minutes', hintText: 'e.g. 10'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                      onPressed: () {
                        Navigator.of(ctx).pop({'action': 'create', 'minutes': int.tryParse(minutesController.text) ?? 10});
                      },
                      child: const Text('Create and Invite')),
                ),
              ],
            )
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancel')),
        ],
      ),
    );

    if (result == null || result['action'] != 'create') return;
    final requiredMinutes = (result['minutes'] as int?)?.clamp(1, 24 * 60) ?? 10;

    try {
      // create watch party document
      final partiesRef = FirebaseFirestore.instance.collection('watch_parties');
      final docRef = await partiesRef.add({
        'hostId': viewerId,
        'participantIds': [viewerId, targetId],
        'createdAt': FieldValue.serverTimestamp(),
        'state': 'open',
        'requiredMinutes': requiredMinutes,
      });

      // send a watch_party message into the 1:1 chat so it appears as a tappable bubble
      final chatId = _getChatId(viewerId, targetId);
      final chatRef = FirebaseFirestore.instance.collection('chats').doc(chatId);

      // ensure chat exists & cachedUsers
      final cachedUsers = {
        viewerId: {
          'id': viewerId,
          'username': FirebaseAuth.instance.currentUser?.displayName ?? '',
          'photoUrl': FirebaseAuth.instance.currentUser?.photoURL ?? '',
        },
        targetId: {
          'id': targetId,
          'username': user['username'] ?? '',
          'photoUrl': user['photoUrl'] ?? user['avatar'] ?? '',
        },
      };

      await chatRef.set({
        'userIds': [viewerId, targetId],
        'isGroup': false,
        'cachedUsers': cachedUsers,
        'timestamp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      final messagesRef = chatRef.collection('messages');
      final msgData = {
        'type': 'watch_party',
        'senderId': viewerId,
        'partyId': docRef.id,
        'text': '${FirebaseAuth.instance.currentUser?.displayName ?? 'Someone'} invited you to a watch party',
        'requiredMinutes': requiredMinutes,
        'timestamp': FieldValue.serverTimestamp(),
        'readBy': [viewerId],
      };

      await messagesRef.add(msgData);

      // update parent chat doc lastMessage/unreadBy
      await chatRef.set({
        'lastMessage': '🎉 Watch Party — join now',
        'timestamp': FieldValue.serverTimestamp(),
        'unreadBy': FieldValue.arrayUnion([targetId]),
      }, SetOptions(merge: true));

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Watch party created and invite sent.')));
      // open chat so host can see the bubble immediately
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: chatId,
            currentUser: _currentUserMinimal(),
            otherUser: user,
            authenticatedUser: _currentUserMinimal(),
            storyInteractions: const [],
            accentColor: Colors.blueAccent,
            forwardedMessage: null,
          ),
        ),
      );
    } catch (e) {
      debugPrint('startWatchParty error: $e');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to create watch party')));
    }
  }

  // ---------------------
  // Calls and Blocking (fixed)
  // ---------------------

  Future<void> _blockOrUnblock(BuildContext context) async {
    final viewerId = _getCurrentUid();
    final targetId = user['id'] as String;
    if (viewerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sign in to block users.')));
      return;
    }

    final viewerRef = FirebaseFirestore.instance.collection('users').doc(viewerId);
    try {
      final doc = await viewerRef.get();
      final blockedUsers = List<String>.from(doc.data()?['blockedUsers'] ?? []);
      final isBlocked = blockedUsers.contains(targetId);

      if (isBlocked) {
        await viewerRef.update({'blockedUsers': FieldValue.arrayRemove([targetId])});
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User unblocked')));
      } else {
        await viewerRef.update({'blockedUsers': FieldValue.arrayUnion([targetId])});
        // optionally delete conversation locally or mark as deleted for user
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User blocked')));
      }
    } catch (e) {
      debugPrint('blockOrUnblock error: $e');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to toggle block')));
    }
  }

  Future<void> _startVoiceCall(BuildContext context) async {
    try {
      final callId = await RtcManager.startVoiceCall(caller: _currentUserMinimal(), receiver: user);
      Navigator.pushNamed(context, '/voiceCall', arguments: {'callId': callId, 'caller': _currentUserMinimal(), 'receiver': user});
    } catch (e) {
      debugPrint('startVoiceCall error: $e');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not start voice call')));
    }
  }

  Future<void> _startVideoCall(BuildContext context) async {
    try {
      final callId = await RtcManager.startVideoCall(caller: _currentUserMinimal(), receiver: user);
      Navigator.pushNamed(context, '/videoCall', arguments: {'callId': callId, 'caller': _currentUserMinimal(), 'receiver': user});
    } catch (e) {
      debugPrint('startVideoCall error: $e');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not start video call')));
    }
  }

  // ---------------------
  // Chat background (unchanged logic adjusted)
  // ---------------------
  void _showChatSettings(BuildContext context) {
    final chatId = "${user['id']}";
    final TextEditingController urlController = TextEditingController();

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color.fromARGB(193, 202, 207, 255),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Text("Change Chat Background", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(
              controller: urlController,
              decoration: InputDecoration(
                labelText: "Enter image URL",
                suffixIcon: IconButton(
                  icon: const Icon(Icons.check),
                  onPressed: () async {
                    final url = urlController.text.trim();
                    if (url.isNotEmpty) {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('chat_background_$chatId', url);
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Background updated!")));
                      Navigator.pop(context);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text("Movie Themes", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: _buildThemePreviews(ctx: context, themes: movieThemes, chatId: chatId)),
            const SizedBox(height: 24),
            const Text("Standard Themes", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: _buildThemePreviews(ctx: context, themes: standardThemes, chatId: chatId)),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildThemePreviews({required BuildContext ctx, required List<Map<String, dynamic>> themes, required String chatId}) {
    return themes.map((theme) {
      return GestureDetector(
        onTap: () async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('chat_background_$chatId', theme['url']);
          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text("Theme '${theme['name']}' applied")));
          Navigator.pop(ctx);
        },
        child: Container(
          width: 100,
          height: 60,
          decoration: BoxDecoration(
            image: DecorationImage(image: NetworkImage(theme['url']), fit: BoxFit.cover),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Container(
            alignment: Alignment.bottomCenter,
            decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(8)),
            child: Text(theme['name'], style: const TextStyle(color: Colors.white, fontSize: 10)),
          ),
        ),
      );
    }).toList();
  }
}

// Predefined themes (re-used from your original)
final List<Map<String, dynamic>> movieThemes = [
  {'name': 'The Matrix', 'url': 'https://wallpapercave.com/wp/wp1826759.jpg'},
  {'name': 'Interstellar', 'url': 'https://wallpapercave.com/wp/wp1944055.jpg'},
  {'name': 'Blade Runner', 'url': 'https://wallpapercave.com/wp/wp2325539.jpg'},
  {'name': 'Dune', 'url': 'https://wallpapercave.com/wp/wp9943687.jpg'},
  {'name': 'Inception', 'url': 'https://wallpapercave.com/wp/wp2486940.jpg'},
];

final List<Map<String, dynamic>> standardThemes = [
  {'name': 'Light Blue', 'url': 'https://via.placeholder.com/300x150/ADD8E6/000000?text=Light+Blue'},
  {'name': 'Dark Mode', 'url': 'https://via.placeholder.com/300x150/1A1A1A/FFFFFF?text=Dark+Mode'},
];
