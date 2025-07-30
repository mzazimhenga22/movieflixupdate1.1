import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'dart:ui';
import 'create_group_screen.dart';
import 'Group_chat_screen.dart';
import 'chat_screen.dart';

String getChatId(String userId1, String userId2) {
  return userId1.compareTo(userId2) < 0
      ? '${userId1}_$userId2'
      : '${userId2}_$userId1';
}

class MessagesController {
  final Map<String, dynamic> currentUser;
  final BuildContext context;
  String? selectedChatId;
  Map<String, dynamic>? selectedOtherUser;
  String groupName = '';

  MessagesController(this.currentUser, this.context);

  void clearSelection() {
    selectedChatId = null;
    selectedOtherUser = null;
  }

  Future<bool> isUserBlocked(String userId) async {
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser['id'])
        .get();
    final blockedUsers = List<String>.from(userDoc.get('blockedUsers') ?? []);
    return blockedUsers.contains(userId);
  }

  Future<bool> isUserMuted(String userId) async {
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser['id'])
        .get();
    final mutedUsers = List<String>.from(userDoc.get('mutedUsers') ?? []);
    return mutedUsers.contains(userId);
  }

  Future<bool> isChatPinned(String chatId) async {
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser['id'])
        .get();
    final pinnedChats = List<String>.from(userDoc.get('pinnedChats') ?? []);
    return pinnedChats.contains(chatId);
  }

  Future<int> getUnreadCount(String userId) async {
    final chatsSnapshot = await FirebaseFirestore.instance
        .collection('chats')
        .where('userIds', arrayContains: userId)
        .where('unread', isEqualTo: true)
        .get();

    final groupsSnapshot = await FirebaseFirestore.instance
        .collection('groups')
        .where('userIds', arrayContains: userId)
        .where('unread', isEqualTo: true)
        .get();

    return chatsSnapshot.docs.length + groupsSnapshot.docs.length;
  }

  Future<void> blockUser() async {
    if (selectedOtherUser != null) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'blockedUsers': FieldValue.arrayUnion([selectedOtherUser!['id']])
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${selectedOtherUser!['username']} blocked')),
      );
      clearSelection();
    }
  }

  Future<void> unblockUser() async {
    if (selectedOtherUser != null) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'blockedUsers': FieldValue.arrayRemove([selectedOtherUser!['id']])
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${selectedOtherUser!['username']} unblocked')),
      );
      clearSelection();
    }
  }

  Future<void> muteUser() async {
    if (selectedOtherUser != null) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'mutedUsers': FieldValue.arrayUnion([selectedOtherUser!['id']])
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${selectedOtherUser!['username']} muted')),
      );
      clearSelection();
    }
  }

  Future<void> unmuteUser() async {
    if (selectedOtherUser != null) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'mutedUsers': FieldValue.arrayRemove([selectedOtherUser!['id']])
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${selectedOtherUser!['username']} unmuted')),
      );
      clearSelection();
    }
  }

  Future<void> pinConversation() async {
    if (selectedChatId != null) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'pinnedChats': FieldValue.arrayUnion([selectedChatId])
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Conversation pinned')),
      );
      clearSelection();
    }
  }

  Future<void> unpinConversation() async {
    if (selectedChatId != null) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'pinnedChats': FieldValue.arrayRemove([selectedChatId])
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Conversation unpinned')),
      );
      clearSelection();
    }
  }

  Future<void> deleteConversation() async {
    if (selectedChatId != null) {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(selectedChatId)
          .update({
        'deletedBy': FieldValue.arrayUnion([currentUser['id']])
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Conversation deleted')),
      );
      clearSelection();
    }
  }

  Future<void> showChatCreationOptions() async {
    final snapshot = await FirebaseFirestore.instance.collection('users').get();
    final allUsers = snapshot.docs
        .map((doc) => doc.data() as Map<String, dynamic>)
        .where((user) => user['id'] != currentUser['id'])
        .toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: const Color.fromARGB(5, 0, 0, 0),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.group_add, color: Colors.white),
                  title: Text(
                    'New Group Chat',
                    style: TextStyle(
                        color: currentUser['accentColor'] ?? Colors.white,
                        fontWeight: FontWeight.bold),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    navigateToNewGroupChat();
                  },
                ),
                const Divider(color: Colors.white12),
                Expanded(
                  child: ListView(
                    shrinkWrap: true,
                    children: allUsers.map((user) {
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundImage: user['photoUrl'] != null
                              ? NetworkImage(user['photoUrl'])
                              : null,
                          child: user['photoUrl'] == null
                              ? Text(
                                  user['username'] != null &&
                                          user['username'].isNotEmpty
                                      ? user['username'][0].toUpperCase()
                                      : 'M',
                                  style: const TextStyle(color: Colors.white),
                                )
                              : null,
                        ),
                        title: Text(
                          user['username'] ?? 'Unknown',
                          style: TextStyle(
                              color: currentUser['accentColor'] ?? Colors.white,
                              fontWeight: FontWeight.bold),
                        ),
                        onTap: () async {
                          final isBlocked = await isUserBlocked(user['id']);
                          if (isBlocked) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                    '${user['username']} is blocked. Unblock to start a chat.'),
                              ),
                            );
                            return;
                          }

                          final chatId =
                              getChatId(currentUser['id'], user['id']);
                          Navigator.pop(context);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatScreen(
                                chatId: chatId,
                                currentUser: currentUser,
                                otherUser: user,
                                authenticatedUser: currentUser,
                                storyInteractions: const [],
                              ),
                            ),
                          );
                        },
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> navigateToNewGroupChat() async {
    final name = await showGroupNameInput(context);
    if (name == null || name.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group name is required')),
      );
      return;
    }

    groupName = name.trim();

    try {
      final snapshot =
          await FirebaseFirestore.instance.collection('users').get();
      final users = snapshot.docs
          .map((doc) => doc.data())
          .where((user) => user['id'] != currentUser['id'])
          .toList();

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CreateGroupScreen(
            initialGroupName: groupName,
            availableUsers: users,
            currentUser: currentUser,
            onGroupCreated: (chatId) {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => GroupChatScreen(
                    chatId: chatId,
                    currentUser: currentUser,
                    authenticatedUser: currentUser,
                    accentColor: currentUser['accentColor'] ?? Colors.blueAccent,
                  ),
                ),
              );
            },
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to fetch users: $e')),
      );
    }
  }

  Future<String?> showGroupNameInput(BuildContext context) async {
    String tempName = '';
    return await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.black87,
        title: const Text('Group Name', style: TextStyle(color: Colors.white)),
        content: TextField(
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Enter group name',
            hintStyle: TextStyle(color: Colors.white54),
          ),
          onChanged: (value) => tempName = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (tempName.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Group name is required')),
                );
                return;
              }
              Navigator.pop(context, tempName.trim());
            },
            child: const Text('Next'),
          ),
        ],
      ),
    );
  }
}