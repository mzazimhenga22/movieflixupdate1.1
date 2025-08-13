// messages_controller.dart (fixed: balanced braces and minor cleanup)
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import 'create_group_screen.dart';
import 'Group_chat_screen.dart';
import 'chat_screen.dart';

String getChatId(String userId1, String userId2) {
  return userId1.compareTo(userId2) < 0 ? '${userId1}_$userId2' : '${userId2}_$userId1';
}

class MessagesController extends ChangeNotifier {
  final Map<String, dynamic> currentUser;
  final BuildContext context;

  String? selectedChatId;
  Map<String, dynamic>? selectedOtherUser;
  bool isGroup = false;
  String groupName = '';

  final List<String> _blockedUsers = [];
  final List<String> _mutedUsers = [];
  final List<String> _pinnedChats = [];

  MessagesController(this.currentUser, this.context) {
    _loadCachedData();
  }

  // Helper: safe decode of a JSON string expected to be a List<String>
  List<String> _safeDecodeStringList(String? raw) {
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).cast<String>().toList();
      }
      debugPrint('[MessagesController] expected list but got: ${decoded.runtimeType}');
      return [];
    } catch (e, st) {
      debugPrint('[MessagesController] failed to decode cached list: $e\n$st');
      return [];
    }
  }

  Future<void> _loadCachedData() async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null || uid.isEmpty) {
        debugPrint('[MessagesController] _loadCachedData: currentUser id missing, skipping cache load');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final blockedRaw = prefs.getString('blockedUsers_$uid');
      final mutedRaw = prefs.getString('mutedUsers_$uid');
      final pinnedRaw = prefs.getString('pinnedChats_$uid');

      final blockedList = _safeDecodeStringList(blockedRaw);
      final mutedList = _safeDecodeStringList(mutedRaw);
      final pinnedList = _safeDecodeStringList(pinnedRaw);

      _blockedUsers
        ..clear()
        ..addAll(blockedList);
      _mutedUsers
        ..clear()
        ..addAll(mutedList);
      _pinnedChats
        ..clear()
        ..addAll(pinnedList);

      notifyListeners();
      debugPrint('[MessagesController] loaded cached lists: blocked=${_blockedUsers.length}, muted=${_mutedUsers.length}, pinned=${_pinnedChats.length}');
    } catch (e, st) {
      debugPrint('Failed to load cached messages controller data: $e\n$st');
    }
  }

  Future<void> _saveCachedData() async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null || uid.isEmpty) {
        debugPrint('[MessagesController] _saveCachedData: currentUser id missing, skipping cache save');
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('blockedUsers_$uid', jsonEncode(_blockedUsers));
      await prefs.setString('mutedUsers_$uid', jsonEncode(_mutedUsers));
      await prefs.setString('pinnedChats_$uid', jsonEncode(_pinnedChats));
      debugPrint('[MessagesController] saved cache for user $uid (blocked=${_blockedUsers.length}, muted=${_mutedUsers.length}, pinned=${_pinnedChats.length})');
    } catch (e, st) {
      debugPrint('Failed to save cached messages controller data: $e\n$st');
    }
  }

  void clearSelection() {
    selectedChatId = null;
    selectedOtherUser = null;
    isGroup = false;
    notifyListeners();
  }

  // synchronous check (fast, uses local cache)
  bool isUserBlocked(String userId) {
    return _blockedUsers.contains(userId);
  }

  // async version (suitable for FutureBuilder): prefer cache, but refresh from server if missing
  Future<bool> isUserBlockedAsync(String userId) async {
    if (_blockedUsers.contains(userId)) return true;
    return await _fetchUserBlocked(userId);
  }

  // async wrapper for muted check
  Future<bool> isUserMutedAsync(String userId) async {
    if (_mutedUsers.contains(userId)) return true;
    return await _fetchUserMuted(userId);
  }

  Future<bool> isChatPinnedAsync(String chatId) async {
    if (_pinnedChats.contains(chatId)) return true;
    return await _fetchChatPinned(chatId);
  }

  bool isUserMuted(String userId) {
    return _mutedUsers.contains(userId);
  }

  bool isChatPinned(String chatId) {
    return _pinnedChats.contains(chatId);
  }

  // server-backed refresh helpers (used by the async wrappers)
  Future<bool> _fetchUserBlocked(String userId) async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null) return false;
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final blockedUsers = List<String>.from(userDoc.data()?['blockedUsers'] ?? []);
      _blockedUsers
        ..clear()
        ..addAll(blockedUsers);
      await _saveCachedData();
      notifyListeners();
      return blockedUsers.contains(userId);
    } catch (e) {
      debugPrint('_fetchUserBlocked error: $e');
      return _blockedUsers.contains(userId);
    }
  }

  Future<bool> _fetchUserMuted(String userId) async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null) return false;
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final mutedUsers = List<String>.from(userDoc.data()?['mutedUsers'] ?? []);
      _mutedUsers
        ..clear()
        ..addAll(mutedUsers);
      await _saveCachedData();
      notifyListeners();
      return mutedUsers.contains(userId);
    } catch (e) {
      debugPrint('_fetchUserMuted error: $e');
      return _mutedUsers.contains(userId);
    }
  }

  Future<bool> _fetchChatPinned(String chatId) async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null) return false;
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final pinnedChats = List<String>.from(userDoc.data()?['pinnedChats'] ?? []);
      _pinnedChats
        ..clear()
        ..addAll(pinnedChats);
      await _saveCachedData();
      notifyListeners();
      return pinnedChats.contains(chatId);
    } catch (e) {
      debugPrint('_fetchChatPinned error: $e');
      return _pinnedChats.contains(chatId);
    }
  }

  /// Get approximate unread count across chats + groups.
  /// Prefer chat/doc metadata (unreadCount or unreadBy) to avoid heavy counting queries.
  Future<int> getUnreadCount(String userId) async {
    try {
      final chatsSnapshot = await FirebaseFirestore.instance.collection('chats').where('userIds', arrayContains: userId).get();
      final groupsSnapshot = await FirebaseFirestore.instance.collection('groups').where('userIds', arrayContains: userId).get();

      int unreadCount = 0;
      for (var doc in [...chatsSnapshot.docs, ...groupsSnapshot.docs]) {
        final data = doc.data();
        // Prefer doc-level fields:
        if (data.containsKey('unreadCount')) {
          unreadCount += (data['unreadCount'] as int?) ?? 0;
          continue;
        }
        if (data.containsKey('unreadBy')) {
          final list = List<dynamic>.from(data['unreadBy'] ?? []);
          if (list.contains(userId)) unreadCount++;
          continue;
        }

        // Fallback: check latest message only (cheap)
        final isGroup = data['isGroup'] ?? false;
        final msgsSnap = await FirebaseFirestore.instance
            .collection(isGroup ? 'groups' : 'chats')
            .doc(doc.id)
            .collection('messages')
            .orderBy('timestamp', descending: true)
            .limit(1)
            .get();
        if (msgsSnap.docs.isNotEmpty) {
          final latest = msgsSnap.docs.first.data();
          final readBy = List<dynamic>.from(latest['readBy'] ?? []);
          if (!readBy.contains(userId)) unreadCount++;
        }
      }

      return unreadCount;
    } catch (e) {
      debugPrint('getUnreadCount error: $e');
      return 0;
    }
  }

  /// Mark chat as read for the user.
  /// We update the chat doc's unreadBy field (remove user), and patch the last N messages to include the reader.
  Future<void> markAsRead(String chatId, String userId, bool isGroup) async {
    try {
      // Remove user from chat's unreadBy array (cheap)
      await FirebaseFirestore.instance.collection(isGroup ? 'groups' : 'chats').doc(chatId).update({
        'unreadBy': FieldValue.arrayRemove([userId]),
      });

      // Update a small recent batch of messages (last 50) to include userId in readBy if missing.
      final msgsSnapshot = await FirebaseFirestore.instance
          .collection(isGroup ? 'groups' : 'chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(50)
          .get();

      final batch = FirebaseFirestore.instance.batch();
      for (final m in msgsSnapshot.docs) {
        final data = m.data();
        final readBy = List<dynamic>.from(data['readBy'] ?? []);
        if (!readBy.contains(userId)) {
          batch.update(m.reference, {'readBy': FieldValue.arrayUnion([userId])});
        }
      }
      await batch.commit();
    } catch (e) {
      debugPrint('markAsRead error: $e');
    }
  }

  Future<void> blockUser() async {
    if (selectedOtherUser == null || isGroup) return;
    final userId = selectedOtherUser!['id'] as String;
    if (!_blockedUsers.contains(userId)) _blockedUsers.add(userId);
    await _saveCachedData();

    try {
      await FirebaseFirestore.instance.collection('users').doc(currentUser['id']).update({
        'blockedUsers': FieldValue.arrayUnion([userId]),
      });

      final chatId = getChatId(currentUser['id'], userId);
      await _deleteChatDocument(chatId);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${selectedOtherUser!['username']} blocked')));
      }
    } catch (e) {
      _blockedUsers.remove(userId);
      await _saveCachedData();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to block user: $e')));
      }
    } finally {
      clearSelection();
    }
  }

  Future<void> unblockUser() async {
    if (selectedOtherUser == null || isGroup) return;
    final userId = selectedOtherUser!['id'] as String;
    _blockedUsers.remove(userId);
    await _saveCachedData();

    try {
      await FirebaseFirestore.instance.collection('users').doc(currentUser['id']).update({
        'blockedUsers': FieldValue.arrayRemove([userId]),
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${selectedOtherUser!['username']} unblocked')));
      }
    } catch (e) {
      _blockedUsers.add(userId);
      await _saveCachedData();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to unblock user: $e')));
      }
    } finally {
      clearSelection();
    }
  }

  Future<void> muteUser() async {
    if (selectedOtherUser == null || isGroup) return;
    final userId = selectedOtherUser!['id'] as String;
    if (!_mutedUsers.contains(userId)) _mutedUsers.add(userId);
    await _saveCachedData();

    try {
      await FirebaseFirestore.instance.collection('users').doc(currentUser['id']).update({
        'mutedUsers': FieldValue.arrayUnion([userId]),
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${selectedOtherUser!['username']} muted')));
      }
    } catch (e) {
      _mutedUsers.remove(userId);
      await _saveCachedData();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to mute user: $e')));
      }
    } finally {
      clearSelection();
    }
  }

  Future<void> unmuteUser() async {
    if (selectedOtherUser == null || isGroup) return;
    final userId = selectedOtherUser!['id'] as String;
    _mutedUsers.remove(userId);
    await _saveCachedData();

    try {
      await FirebaseFirestore.instance.collection('users').doc(currentUser['id']).update({
        'mutedUsers': FieldValue.arrayRemove([userId]),
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${selectedOtherUser!['username']} unmuted')));
      }
    } catch (e) {
      _mutedUsers.add(userId);
      await _saveCachedData();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to unmute user: $e')));
      }
    } finally {
      clearSelection();
    }
  }

  Future<void> muteGroup() async {
    if (selectedChatId == null || !isGroup) return;
    final id = selectedChatId!;
    if (!_mutedUsers.contains(id)) _mutedUsers.add(id);
    await _saveCachedData();

    try {
      await FirebaseFirestore.instance.collection('users').doc(currentUser['id']).update({
        'mutedUsers': FieldValue.arrayUnion([id]),
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Group muted')));
      }
    } catch (e) {
      _mutedUsers.remove(id);
      await _saveCachedData();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to mute group: $e')));
      }
    } finally {
      clearSelection();
    }
  }

  Future<void> unmuteGroup() async {
    if (selectedChatId == null || !isGroup) return;
    final id = selectedChatId!;
    _mutedUsers.remove(id);
    await _saveCachedData();

    try {
      await FirebaseFirestore.instance.collection('users').doc(currentUser['id']).update({
        'mutedUsers': FieldValue.arrayRemove([id]),
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Group unmuted')));
      }
    } catch (e) {
      _mutedUsers.add(id);
      await _saveCachedData();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to unmute group: $e')));
      }
    } finally {
      clearSelection();
    }
  }

  Future<void> pinConversation() async {
    if (selectedChatId == null) return;
    final id = selectedChatId!;
    if (!_pinnedChats.contains(id)) _pinnedChats.add(id);
    await _saveCachedData();

    try {
      await FirebaseFirestore.instance.collection('users').doc(currentUser['id']).update({
        'pinnedChats': FieldValue.arrayUnion([id]),
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Conversation pinned')));
      }
    } catch (e) {
      _pinnedChats.remove(id);
      await _saveCachedData();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to pin conversation: $e')));
      }
    } finally {
      clearSelection();
    }
  }

  Future<void> unpinConversation() async {
    if (selectedChatId == null) return;
    final id = selectedChatId!;
    _pinnedChats.remove(id);
    await _saveCachedData();

    try {
      await FirebaseFirestore.instance.collection('users').doc(currentUser['id']).update({
        'pinnedChats': FieldValue.arrayRemove([id]),
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Conversation unpinned')));
      }
    } catch (e) {
      _pinnedChats.add(id);
      await _saveCachedData();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to unpin conversation: $e')));
      }
    } finally {
      clearSelection();
    }
  }

  Future<void> _deleteChatDocument(String chatId) async {
    try {
      // Mark messages as deletedFor current user (fast)
      final msgs = await FirebaseFirestore.instance.collection('chats').doc(chatId).collection('messages').get();
      final batch = FirebaseFirestore.instance.batch();
      for (var m in msgs.docs) {
        final data = m.data();
        final deletedFor = List<String>.from(data['deletedFor'] ?? []);
        if (!deletedFor.contains(currentUser['id'])) {
          deletedFor.add(currentUser['id']);
          batch.update(m.reference, {'deletedFor': deletedFor});
        }
      }
      // Update chat doc deletedBy
      final chatRef = FirebaseFirestore.instance.collection('chats').doc(chatId);
      batch.update(chatRef, {'deletedBy': FieldValue.arrayUnion([currentUser['id']])});
      await batch.commit();
    } catch (e) {
      debugPrint('Error deleting chat: $e');
    }
  }

  Future<void> deleteConversation() async {
    if (selectedChatId == null) return;
    try {
      if (isGroup) {
        final groupDoc = await FirebaseFirestore.instance.collection('groups').doc(selectedChatId).get();
        if (!groupDoc.exists) {
          throw Exception('Group not found');
        }
        // Remove user from group and mark as deleted
        await FirebaseFirestore.instance.collection('groups').doc(selectedChatId).update({
          'userIds': FieldValue.arrayRemove([currentUser['id']]),
          'deletedBy': FieldValue.arrayUnion([currentUser['id']]),
        });

        // Mark messages' deletedFor for this user
        final msgsSnap = await FirebaseFirestore.instance.collection('groups').doc(selectedChatId).collection('messages').get();
        final batch = FirebaseFirestore.instance.batch();
        for (var m in msgsSnap.docs) {
          final data = m.data();
          final deletedFor = List<String>.from(data['deletedFor'] ?? []);
          if (!deletedFor.contains(currentUser['id'])) {
            deletedFor.add(currentUser['id']);
            batch.update(m.reference, {'deletedFor': deletedFor});
          }
        }
        await batch.commit();

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Left group')));
        }
      } else {
        await _deleteChatDocument(selectedChatId!);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Conversation deleted')));
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete conversation: $e')));
      }
    } finally {
      clearSelection();
    }
  }

  Future<void> showChatCreationOptions() async {
    try {
      final snapshot = await FirebaseFirestore.instance.collection('users').get();
      final allUsers = snapshot.docs.where((doc) => doc.exists && doc.id != currentUser['id'] && !_blockedUsers.contains(doc.id)).map((doc) {
        final data = Map<String, dynamic>.from(doc.data() ?? {});
        data['id'] = doc.id;
        return data;
      }).toList();

      if (!context.mounted) return;

      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (context) => Container(
          decoration: BoxDecoration(
            color: Colors.black.withAlpha((0.3 * 255).round()), // replaced withOpacity
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withAlpha((0.1 * 255).round())), // replaced withOpacity
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.group_add, color: Colors.white),
                title: Text(
                  'New Group Chat',
                  style: TextStyle(
                    color: currentUser['accentColor'] ?? Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  navigateToNewGroupChat();
                },
              ),
              const Divider(color: Colors.white12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: allUsers.map((user) {
                    final userId = user['id'] as String?;
                    if (userId == null) return const SizedBox.shrink();
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundImage: user['photoUrl'] != null ? NetworkImage(user['photoUrl']) as ImageProvider : null,
                        child: user['photoUrl'] == null
                            ? Text(user['username'] != null && user['username'].isNotEmpty ? user['username'][0].toUpperCase() : 'M', style: const TextStyle(color: Colors.white))
                            : null,
                      ),
                      title: Text(
                        user['username'] ?? 'Unknown',
                        style: TextStyle(color: currentUser['accentColor'] ?? Colors.white, fontWeight: FontWeight.bold),
                      ),
                      onTap: () async {
                        final isBlocked = isUserBlocked(userId);
                        if (isBlocked) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${user['username']} is blocked. Unblock to start a chat.')));
                          }
                          return;
                        }

                        final chatId = getChatId(currentUser['id'], userId);
                        await FirebaseFirestore.instance.collection('chats').doc(chatId).set({
                          'userIds': [currentUser['id'], user['id']],
                          'lastMessage': '',
                          'timestamp': FieldValue.serverTimestamp(),
                          'unreadBy': [],
                          'deletedBy': [],
                          'isGroup': false,
                        }, SetOptions(merge: true));

                        if (context.mounted) {
                          Navigator.pop(context);
                          Navigator.push(context, MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: this, child: ChatScreen(
                            chatId: chatId,
                            currentUser: currentUser,
                            otherUser: user,
                            authenticatedUser: currentUser,
                            storyInteractions: const [],
                            accentColor: currentUser['accentColor'] ?? Colors.blueAccent,
                          ))));
                        }
                      },
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to fetch users: $e')));
      }
    }
  }

  Future<void> navigateToNewGroupChat() async {
    final name = await showGroupNameInput(context);
    if (name == null || name.trim().isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Group name is required')));
      }
      return;
    }

    groupName = name.trim();

    try {
      final snapshot = await FirebaseFirestore.instance.collection('users').get();
      final users = snapshot.docs.where((doc) => doc.exists && doc.id != currentUser['id'] && !_blockedUsers.contains(doc.id)).map((doc) => doc.data()).toList();

      if (context.mounted) {
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => ChangeNotifierProvider.value(value: this, child: CreateGroupScreen(
            initialGroupName: groupName,
            availableUsers: users,
            currentUser: currentUser,
            onGroupCreated: (chatId) {
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: this, child: GroupChatScreen(
                chatId: chatId,
                currentUser: currentUser,
                authenticatedUser: currentUser,
                accentColor: currentUser['accentColor'] ?? Colors.blueAccent,
              ))));
            },
          )),
        ));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to fetch users: $e')));
      }
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
          decoration: const InputDecoration(hintText: 'Enter group name', hintStyle: TextStyle(color: Colors.white54)),
          onChanged: (value) => tempName = value,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (tempName.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Group name is required')));
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

