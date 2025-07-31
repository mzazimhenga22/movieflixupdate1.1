import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:shared_preferences/shared_preferences.dart';
import 'create_group_screen.dart';
import 'Group_chat_screen.dart';
import 'chat_screen.dart';
import 'dart:convert';
import 'package:provider/provider.dart';

String getChatId(String userId1, String userId2) {
  return userId1.compareTo(userId2) < 0
      ? '${userId1}_$userId2'
      : '${userId2}_$userId1';
}

class MessagesController extends ChangeNotifier {
  final Map<String, dynamic> currentUser;
  final BuildContext context;
  String? selectedChatId;
  Map<String, dynamic>? selectedOtherUser;
  bool isGroup = false;
  String groupName = '';
  List<String> _blockedUsers = [];
  List<String> _mutedUsers = [];
  List<String> _pinnedChats = [];

  MessagesController(this.currentUser, this.context) {
    _loadCachedData();
  }

  Future<void> _loadCachedData() async {
    final prefs = await SharedPreferences.getInstance();
    _blockedUsers = jsonDecode(prefs.getString('blockedUsers_${currentUser['id']}') ?? '[]').cast<String>();
    _mutedUsers = jsonDecode(prefs.getString('mutedUsers_${currentUser['id']}') ?? '[]').cast<String>();
    _pinnedChats = jsonDecode(prefs.getString('pinnedChats_${currentUser['id']}') ?? '[]').cast<String>();
    notifyListeners();
  }

  Future<void> _saveCachedData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('blockedUsers_${currentUser['id']}', jsonEncode(_blockedUsers));
    await prefs.setString('mutedUsers_${currentUser['id']}', jsonEncode(_mutedUsers));
    await prefs.setString('pinnedChats_${currentUser['id']}', jsonEncode(_pinnedChats));
    notifyListeners();
  }

  void clearSelection() {
    selectedChatId = null;
    selectedOtherUser = null;
    isGroup = false;
    notifyListeners();
  }

  bool isUserBlocked(String userId) {
    return _blockedUsers.contains(userId);
  }

  bool isUserMuted(String userId) {
    return _mutedUsers.contains(userId);
  }

  bool isChatPinned(String chatId) {
    return _pinnedChats.contains(chatId);
  }

  Future<bool> _fetchUserBlocked(String userId) async {
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser['id'])
        .get();
    final blockedUsers = List<String>.from(userDoc.get('blockedUsers') ?? []);
    _blockedUsers = blockedUsers;
    await _saveCachedData();
    return blockedUsers.contains(userId);
  }

  Future<bool> _fetchUserMuted(String userId) async {
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser['id'])
        .get();
    final mutedUsers = List<String>.from(userDoc.get('mutedUsers') ?? []);
    _mutedUsers = mutedUsers;
    await _saveCachedData();
    return mutedUsers.contains(userId);
  }

  Future<bool> _fetchChatPinned(String chatId) async {
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser['id'])
        .get();
    final pinnedChats = List<String>.from(userDoc.get('pinnedChats') ?? []);
    _pinnedChats = pinnedChats;
    await _saveCachedData();
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
    if (selectedOtherUser == null || isGroup) return;

    final userId = selectedOtherUser!['id'];
    _blockedUsers.add(userId);
    await _saveCachedData();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${selectedOtherUser!['username']} blocked')),
    );

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'blockedUsers': FieldValue.arrayUnion([userId])
      });
      final chatId = getChatId(currentUser['id'], userId);
      await _deleteChatDocument(chatId);
    } catch (e) {
      _blockedUsers.remove(userId);
      await _saveCachedData();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to block user: $e')),
      );
    }
    clearSelection();
  }

  Future<void> unblockUser() async {
    if (selectedOtherUser == null || isGroup) return;

    final userId = selectedOtherUser!['id'];
    _blockedUsers.remove(userId);
    await _saveCachedData();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${selectedOtherUser!['username']} unblocked')),
    );

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'blockedUsers': FieldValue.arrayRemove([userId])
      });
    } catch (e) {
      _blockedUsers.add(userId);
      await _saveCachedData();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to unblock user: $e')),
      );
    }
    clearSelection();
  }

  Future<void> muteUser() async {
    if (selectedOtherUser == null || isGroup) return;

    final userId = selectedOtherUser!['id'];
    _mutedUsers.add(userId);
    await _saveCachedData();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${selectedOtherUser!['username']} muted')),
    );

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'mutedUsers': FieldValue.arrayUnion([userId])
      });
    } catch (e) {
      _mutedUsers.remove(userId);
      await _saveCachedData();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to mute user: $e')),
      );
    }
    clearSelection();
  }

  Future<void> unmuteUser() async {
    if (selectedOtherUser == null || isGroup) return;

    final userId = selectedOtherUser!['id'];
    _mutedUsers.remove(userId);
    await _saveCachedData();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${selectedOtherUser!['username']} unmuted')),
    );

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'mutedUsers': FieldValue.arrayRemove([userId])
      });
    } catch (e) {
      _mutedUsers.add(userId);
      await _saveCachedData();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to unmute user: $e')),
      );
    }
    clearSelection();
  }

  Future<void> muteGroup() async {
    if (selectedChatId == null || !isGroup) return;

    _mutedUsers.add(selectedChatId!);
    await _saveCachedData();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Group muted')),
    );

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'mutedUsers': FieldValue.arrayUnion([selectedChatId])
      });
    } catch (e) {
      _mutedUsers.remove(selectedChatId!);
      await _saveCachedData();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to mute group: $e')),
      );
    }
    clearSelection();
  }

  Future<void> unmuteGroup() async {
    if (selectedChatId == null || !isGroup) return;

    _mutedUsers.remove(selectedChatId!);
    await _saveCachedData();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Group unmuted')),
    );

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'mutedUsers': FieldValue.arrayRemove([selectedChatId])
      });
    } catch (e) {
      _mutedUsers.add(selectedChatId!);
      await _saveCachedData();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to unmute group: $e')),
      );
    }
    clearSelection();
  }

  Future<void> pinConversation() async {
    if (selectedChatId == null) return;

    _pinnedChats.add(selectedChatId!);
    await _saveCachedData();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Conversation pinned')),
    );

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'pinnedChats': FieldValue.arrayUnion([selectedChatId])
      });
    } catch (e) {
      _pinnedChats.remove(selectedChatId!);
      await _saveCachedData();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to pin conversation: $e')),
      );
    }
    clearSelection();
  }

  Future<void> unpinConversation() async {
    if (selectedChatId == null) return;

    _pinnedChats.remove(selectedChatId!);
    await _saveCachedData();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Conversation unpinned')),
    );

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .update({
        'pinnedChats': FieldValue.arrayRemove([selectedChatId])
      });
    } catch (e) {
      _pinnedChats.add(selectedChatId!);
      await _saveCachedData();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to unpin conversation: $e')),
      );
    }
    clearSelection();
  }

  Future<void> _deleteChatDocument(String chatId) async {
    final messagesSnapshot = await FirebaseFirestore.instance
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .get();
    for (var doc in messagesSnapshot.docs) {
      await doc.reference.delete();
    }
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(chatId)
        .delete();
  }

  Future<void> deleteConversation() async {
    if (selectedChatId == null) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Conversation deleted')),
    );

    try {
      if (isGroup) {
        await FirebaseFirestore.instance
            .collection('groups')
            .doc(selectedChatId)
            .update({
          'userIds': FieldValue.arrayRemove([currentUser['id']]),
          'deletedBy': FieldValue.arrayUnion([currentUser['id']])
        });
      } else {
        await _deleteChatDocument(selectedChatId!);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete conversation: $e')),
      );
    }
    clearSelection();
  }

  Future<void> showChatCreationOptions() async {
    final snapshot = await FirebaseFirestore.instance.collection('users').get();
    final allUsers = snapshot.docs
        .where((doc) => doc.exists && doc.id != currentUser['id'] && !_blockedUsers.contains(doc.id))
        .map((doc) => doc.data() as Map<String, dynamic>)
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
                          final isBlocked = isUserBlocked(user['id']);
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
                              builder: (_) => ChangeNotifierProvider.value(
                                value: this,
                                child: ChatScreen(
                                  chatId: chatId,
                                  currentUser: currentUser,
                                  otherUser: user,
                                  authenticatedUser: currentUser,
                                  storyInteractions: const [],
                                ),
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
      final snapshot = await FirebaseFirestore.instance.collection('users').get();
      final users = snapshot.docs
          .where((doc) => doc.exists && doc.id != currentUser['id'] && !_blockedUsers.contains(doc.id))
          .map((doc) => doc.data())
          .toList();

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChangeNotifierProvider.value(
            value: this,
            child: CreateGroupScreen(
              initialGroupName: groupName,
              availableUsers: users,
              currentUser: currentUser,
              onGroupCreated: (chatId) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChangeNotifierProvider.value(
                      value: this,
                      child: GroupChatScreen(
                        chatId: chatId,
                        currentUser: currentUser,
                        authenticatedUser: currentUser,
                        accentColor: currentUser['accentColor'] ?? Colors.blueAccent,
                      ),
                    ),
                  ),
                );
              },
            ),
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