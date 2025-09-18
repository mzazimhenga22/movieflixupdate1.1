// group_profile_screen.dart
import 'dart:io' show File;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';

// Replace these imports with the correct paths in your project if necessary:
import 'chat_screen.dart';
import 'Group_chat_screen.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:movie_app/webrtc/group_rtc_manager.dart';

/// GroupProfileScreen - combined UI + features from ProfileScreen + group-specific actions.
class GroupProfileScreen extends StatefulWidget {
  final String groupId;
  final String currentUserId;

  const GroupProfileScreen({
    super.key,
    required this.groupId,
    required this.currentUserId,
  });

  @override
  State<GroupProfileScreen> createState() => _GroupProfileScreenState();
}

class _GroupProfileScreenState extends State<GroupProfileScreen> {
  final TextEditingController _nameController = TextEditingController();
  String? _groupPhotoUrl;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // -----------------------
  // Helpers
  // -----------------------

  Map<String, dynamic> _currentUserMinimal() {
    final auth = FirebaseAuth.instance.currentUser;
    return {
      'id': auth?.uid ?? widget.currentUserId,
      'username': auth?.displayName ?? '',
      'photoUrl': auth?.photoURL ?? '',
    };
  }

  /// Normalize a dynamic list into List<String> (filters null/empty/non-string).
  List<String> _normalizeIdList(dynamic raw) {
    final list = <String>[];
    if (raw is Iterable) {
      for (final item in raw) {
        try {
          final s = item?.toString() ?? '';
          if (s.isNotEmpty) list.add(s);
        } catch (_) {
          // ignore malformed entry
        }
      }
    }
    return list;
  }

  /// Return an ImageProvider that works for network URLs and local file paths.
  ImageProvider? _safeImageProvider(String? path) {
    if (path == null) return null;
    final s = path.trim();
    if (s.isEmpty) return null;

    if (kIsWeb) {
      if (s.startsWith('http')) return NetworkImage(s);
      return null;
    }

    final looksLikeFile = s.startsWith('/') || s.startsWith('file:') || RegExp(r'^[a-zA-Z]:\\').hasMatch(s);
    if (looksLikeFile) {
      try {
        return FileImage(File(s));
      } catch (_) {
        // fallback to network below
      }
    }

    if (s.startsWith('http')) return NetworkImage(s);

    try {
      return NetworkImage(s);
    } catch (_) {
      try {
        return FileImage(File(s));
      } catch (_) {
        return null;
      }
    }
  }

  // -----------------------
  // CRUD / UI actions
  // -----------------------

  Future<void> _updateGroupName(String newName) async {
    if (newName.trim().isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Group name cannot be empty')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      await FirebaseFirestore.instance.collection('groups').doc(widget.groupId).update({
        'name': newName.trim(),
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Group name updated')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update group name: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _updateGroupPhoto() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) return;

    setState(() => _isLoading = true);
    try {
      // In prod: upload to Firebase Storage and set the public URL.
      final photoUrl = pickedFile.path;
      await FirebaseFirestore.instance.collection('groups').doc(widget.groupId).update({'avatarUrl': photoUrl});
      if (mounted) setState(() => _groupPhotoUrl = photoUrl);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Group photo updated')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update group photo: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _addMembers() async {
    setState(() => _isLoading = true);
    try {
      final snapshot = await FirebaseFirestore.instance.collection('users').get();
      final groupDoc = await FirebaseFirestore.instance.collection('groups').doc(widget.groupId).get();
      final currentMembers = _normalizeIdList(groupDoc.data()?['userIds']);

      final availableUsers = snapshot.docs
          .where((doc) => !currentMembers.contains(doc.id) && doc.id != widget.currentUserId)
          .map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        data['id'] = doc.id;
        return data;
      }).toList();

      setState(() => _isLoading = false);

      showModalBottomSheet(
        context: context,
        isScrollControlled: false,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
        builder: (ctx) {
          final selectedUsers = <String>{};
          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.65,
            child: Column(
              children: [
                const Padding(padding: EdgeInsets.all(16), child: Text('Add Members', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                const Divider(height: 1),
                Expanded(
                  child: availableUsers.isEmpty
                      ? const Center(child: Text('No available users to add'))
                      : ListView.separated(
                          itemCount: availableUsers.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final user = availableUsers[index];
                            final uid = (user['id'] ?? '').toString();
                            final displayName = (user['username'] ?? user['displayName'] ?? user['name'] ?? 'User').toString();
                            final email = (user['email'] ?? '').toString();
                            final isSelected = selectedUsers.contains(uid);
                            return CheckboxListTile(
                              title: Text(displayName),
                              subtitle: email.isNotEmpty ? Text(email) : null,
                              value: isSelected,
                              onChanged: (value) {
                                if (value == true) {
                                  selectedUsers.add(uid);
                                } else {
                                  selectedUsers.remove(uid);
                                }
                                (ctx as Element).markNeedsBuild();
                              },
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: ElevatedButton(
                    onPressed: selectedUsers.isEmpty
                        ? null
                        : () async {
                            Navigator.pop(context);
                            setState(() => _isLoading = true);
                            try {
                              await FirebaseFirestore.instance.collection('groups').doc(widget.groupId).update({
                                'userIds': FieldValue.arrayUnion(selectedUsers.toList()),
                              });
                              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Members added')));
                            } catch (e) {
                              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to add members: $e')));
                            } finally {
                              if (mounted) setState(() => _isLoading = false);
                            }
                          },
                    child: const Text('Add Selected'),
                  ),
                ),
              ],
            ),
          );
        },
      );
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load users: $e')));
    }
  }

  Future<void> _exitGroup(List<String> userIds) async {
    final normalized = userIds.where((x) => x.isNotEmpty).toList();
    if (!normalized.contains(widget.currentUserId)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You are not a member of this group')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      await FirebaseFirestore.instance.collection('groups').doc(widget.groupId).update({
        'userIds': FieldValue.arrayRemove([widget.currentUserId]),
        'deletedBy': FieldValue.arrayUnion([widget.currentUserId]),
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You have left the group')));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to exit group: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _addToFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final favorites = prefs.getStringList('favoriteGroups') ?? <String>[];
      if (!favorites.contains(widget.groupId)) {
        favorites.add(widget.groupId);
        await prefs.setStringList('favoriteGroups', favorites);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Group added to favorites')));
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Group is already in favorites')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update favorites: $e')));
    }
  }

  /// Open group chat screen
  void _openGroupChat() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupChatScreen(
          chatId: widget.groupId,
          currentUser: _currentUserMinimal(),
          authenticatedUser: _currentUserMinimal(),
          accentColor: Colors.blueAccent,
          forwardedMessage: null,
        ),
      ),
    );
  }

  /// Send a "group card" system message to group's messages collection
  Future<void> _sendGroupCard() async {
    try {
      final msgRef = FirebaseFirestore.instance.collection('groups').doc(widget.groupId).collection('messages');
      final payload = {
        'type': 'group_card',
        'senderId': widget.currentUserId,
        'groupId': widget.groupId,
        'text': 'Group info shared',
        'meta': {'sharedBy': widget.currentUserId},
        'timestamp': FieldValue.serverTimestamp(),
        'readBy': [widget.currentUserId],
      };
      await msgRef.add(payload);
      await FirebaseFirestore.instance.collection('groups').doc(widget.groupId).set({
        'lastMessage': 'Group info shared',
        'timestamp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Group info shared to chat')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to share group info: $e')));
    }
  }

  /// Start a watch party for the group (creates a watch_parties doc and posts a watch_party message to the group)
  Future<void> _startGroupWatchParty(List<String> currentMemberIds) async {
    if (currentMemberIds.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No members to invite')));
      return;
    }

    final minutesController = TextEditingController(text: '10');

    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start Watch Party'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Set required minutes to join (minimum 1 minute)'),
            const SizedBox(height: 12),
            TextField(
              controller: minutesController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Required minutes', hintText: 'e.g. 10'),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop({
                      'action': 'create',
                      'minutes': int.tryParse(minutesController.text) ?? 10,
                    });
                  },
                  child: const Text('Create and Invite'),
                ),
              ),
            ])
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancel'))],
      ),
    );

    if (result == null || result['action'] != 'create') return;
    final requiredMinutes = (result['minutes'] as int?)?.clamp(1, 24 * 60) ?? 10;

    setState(() => _isLoading = true);
    try {
      final partiesRef = FirebaseFirestore.instance.collection('watch_parties');
      final docRef = await partiesRef.add({
        'hostId': widget.currentUserId,
        'participantIds': currentMemberIds,
        'createdAt': FieldValue.serverTimestamp(),
        'state': 'open',
        'requiredMinutes': requiredMinutes,
      });

      // Post watch_party message in group's messages collection
      final messagesRef = FirebaseFirestore.instance.collection('groups').doc(widget.groupId).collection('messages');
      final msgData = {
        'type': 'watch_party',
        'senderId': widget.currentUserId,
        'partyId': docRef.id,
        'text': 'Watch party started — tap to join',
        'requiredMinutes': requiredMinutes,
        'timestamp': FieldValue.serverTimestamp(),
        'readBy': [widget.currentUserId],
      };
      await messagesRef.add(msgData);

      await FirebaseFirestore.instance.collection('groups').doc(widget.groupId).set({
        'lastMessage': '🎉 Watch Party — join now',
        'timestamp': FieldValue.serverTimestamp(),
        'unreadBy': FieldValue.arrayUnion(currentMemberIds.where((id) => id != widget.currentUserId).toList()),
      }, SetOptions(merge: true));

      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Watch party created and message posted')));
      _openGroupChat();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to start watch party: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ---------------------
  // Calls
  // ---------------------

  Future<void> _startGroupCall({required bool isVideo, required List<Map<String, dynamic>> participants}) async {
    try {
      // Reuse your GroupRtcManager if available (signature may vary)
      final callId = await GroupRtcManager.startGroupCall(caller: _currentUserMinimal(), participants: participants, isVideo: isVideo);
      // navigate to your call screen (update the target widget as per your app)
      if (isVideo) {
        Navigator.pushNamed(context, '/groupVideoCall', arguments: {'callId': callId, 'groupId': widget.groupId});
      } else {
        Navigator.pushNamed(context, '/groupVoiceCall', arguments: {'callId': callId, 'groupId': widget.groupId});
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to start call: $e')));
    }
  }

  // ---------------------
  // Chat background / Themes
  // ---------------------
  void _showChatSettings(String chatId) {
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
                      await prefs.setString('chat_background_${chatId}', url);
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Background updated!")));
                      Navigator.pop(ctx);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text("Movie Themes", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: _buildThemePreviews(ctx: ctx, themes: movieThemes, chatId: chatId)),
            const SizedBox(height: 24),
            const Text("Standard Themes", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: _buildThemePreviews(ctx: ctx, themes: standardThemes, chatId: chatId)),
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
          if (mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text("Theme '${theme['name']}' applied")));
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

  // -----------------------
  // Edit name dialog
  // -----------------------
  void _editGroupName(String currentName) {
    _nameController.text = currentName;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Group Name'),
        content: TextField(controller: _nameController, decoration: const InputDecoration(hintText: 'Enter new group name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              _updateGroupName(_nameController.text);
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // -----------------------
  // Build
  // -----------------------
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('groups').doc(widget.groupId).get(),
      builder: (context, snapshot) {
        if ((snapshot.connectionState == ConnectionState.waiting) || _isLoading) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        if (snapshot.hasError) {
          return Scaffold(body: Center(child: Text('Error loading group: ${snapshot.error}')));
        }

        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const Scaffold(body: Center(child: Text('Group not found')));
        }

        final rawGroupData = snapshot.data!.data() as Map<String, dynamic>? ?? {};
        final groupName = rawGroupData['name']?.toString() ?? 'Unnamed Group';
        final groupPhotoRaw = rawGroupData['avatarUrl']?.toString();
        final normalizedUserIds = _normalizeIdList(rawGroupData['userIds']);

        // member count snapshot friendly fallback
        final memberCount = normalizedUserIds.length;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.arrow_back, color: Colors.white)),
            title: Text(groupName, style: const TextStyle(color: Colors.white)),
            actions: [
              IconButton(
                onPressed: () => _showChatSettings(widget.groupId),
                icon: const Icon(Icons.wallpaper, color: Colors.white),
                tooltip: 'Chat background',
              ),
            ],
          ),
          backgroundColor: Colors.black,
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            children: [
              // Header — hero look like ProfileScreen
              Container(
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFF6A85B6), Color(0xFFbac8e0)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: _updateGroupPhoto,
                      child: CircleAvatar(
                        radius: 44,
                        backgroundColor: Colors.white,
                        backgroundImage: _safeImageProvider(_groupPhotoUrl ?? groupPhotoRaw),
                        child: (_groupPhotoUrl ?? groupPhotoRaw) == null
                            ? Text(groupName.isNotEmpty ? groupName[0].toUpperCase() : 'G', style: const TextStyle(fontSize: 32, color: Colors.black87))
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(groupName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
                        const SizedBox(height: 6),
                        Text('$memberCount members', style: const TextStyle(color: Colors.white70)),
                      ]),
                    ),
                    Column(
                      children: [
                        IconButton(
                          onPressed: () async {
                            // prepare participants list for calls
                            final membersSnapshot = await FirebaseFirestore.instance.collection('groups').doc(widget.groupId).get();
                            final ids = _normalizeIdList(membersSnapshot.data()?['userIds']);
                            // fetch minimal participants maps
                            final participants = <Map<String, dynamic>>[];
                            for (final id in ids) {
                              final udoc = await FirebaseFirestore.instance.collection('users').doc(id).get();
                              if (udoc.exists) {
                                final d = udoc.data()!;
                                participants.add({'id': udoc.id, 'username': d['username'] ?? '', 'avatarUrl': d['avatarUrl'] ?? d['photoUrl'] ?? ''});
                              }
                            }
                            await _startGroupCall(isVideo: false, participants: participants);
                          },
                          icon: const Icon(Icons.call, color: Colors.white),
                        ),
                        const SizedBox(height: 4),
                        IconButton(
                          onPressed: () async {
                            final membersSnapshot = await FirebaseFirestore.instance.collection('groups').doc(widget.groupId).get();
                            final ids = _normalizeIdList(membersSnapshot.data()?['userIds']);
                            final participants = <Map<String, dynamic>>[];
                            for (final id in ids) {
                              final udoc = await FirebaseFirestore.instance.collection('users').doc(id).get();
                              if (udoc.exists) {
                                final d = udoc.data()!;
                                participants.add({'id': udoc.id, 'username': d['username'] ?? '', 'avatarUrl': d['avatarUrl'] ?? d['photoUrl'] ?? ''});
                              }
                            }
                            await _startGroupCall(isVideo: true, participants: participants);
                          },
                          icon: const Icon(Icons.videocam, color: Colors.white),
                        ),
                      ],
                    )
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Primary actions row
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Message Group'),
                      onPressed: _openGroupChat,
                      style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.group),
                      label: const Text('Add Members'),
                      onPressed: _addMembers,
                      style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // Big feature buttons
              ElevatedButton.icon(
                icon: const Icon(Icons.contact_page),
                label: const Text('Send Group Card'),
                style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: _sendGroupCard,
              ),
              const SizedBox(height: 8),

              ElevatedButton.icon(
                icon: const Icon(Icons.star_border),
                label: const Text('Add to Favorites'),
                style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: _addToFavorites,
              ),
              const SizedBox(height: 8),

              ElevatedButton.icon(
                icon: const Icon(Icons.live_tv),
                label: const Text('Start Watch Party'),
                style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: () => _startGroupWatchParty(normalizedUserIds),
              ),
              const SizedBox(height: 8),

              ElevatedButton.icon(
                icon: const Icon(Icons.exit_to_app),
                label: const Text('Exit Group'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: () => _exitGroup(normalizedUserIds),
              ),

              const SizedBox(height: 16),
              const Text('Members', style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),

              // Members list
              Container(
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.25), borderRadius: BorderRadius.circular(12)),
                child: normalizedUserIds.isEmpty
                    ? const Padding(padding: EdgeInsets.all(16), child: Center(child: Text('No members', style: TextStyle(color: Colors.white70))))
                    : ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: normalizedUserIds.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                        itemBuilder: (context, index) {
                          final userId = normalizedUserIds[index];
                          if (userId.isEmpty) return const SizedBox.shrink();

                          return StreamBuilder<DocumentSnapshot>(
                            stream: FirebaseFirestore.instance.collection('users').doc(userId).snapshots(),
                            builder: (context, userSnapshot) {
                              if (userSnapshot.hasError) {
                                return ListTile(title: Text('Error loading user: ${userSnapshot.error}', style: const TextStyle(color: Colors.white70)));
                              }

                              if (!userSnapshot.hasData) {
                                return const ListTile(title: Text('Loading user...', style: TextStyle(color: Colors.white70)));
                              }

                              if (!userSnapshot.data!.exists) {
                                return const ListTile(title: Text('Unknown user', style: TextStyle(color: Colors.white70)));
                              }

                              final userData = userSnapshot.data!.data()! as Map<String, dynamic>;
                              final username = (userData['username'] ?? userData['displayName'] ?? userData['name'] ?? 'User').toString();
                              final photoUrl = userData['avatarUrl']?.toString();
                              final isOnline = (userData['isOnline'] as bool?) ?? false;
                              final initial = username.isNotEmpty ? username[0].toUpperCase() : 'U';

                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Colors.grey[200],
                                  backgroundImage: _safeImageProvider(photoUrl),
                                  child: (photoUrl == null || photoUrl.isEmpty) ? Text(initial, style: const TextStyle(color: Colors.grey)) : null,
                                ),
                                title: Text(username.isNotEmpty ? username : 'User', style: const TextStyle(color: Colors.white)),
                                subtitle: Text(isOnline ? 'Online' : 'Offline', style: TextStyle(color: isOnline ? Colors.green : Colors.white70)),
                                trailing: Icon(Icons.circle, size: 12, color: isOnline ? Colors.green : Colors.grey),
                                onTap: () {
                                  // open 1:1 profile or start chat as you prefer
                                  Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(
                                    chatId: _getDirectChatId(widget.currentUserId, userId),
                                    currentUser: _currentUserMinimal(),
                                    otherUser: {
                                      'id': userId,
                                      'username': username,
                                      'photoUrl': photoUrl ?? '',
                                    },
                                    authenticatedUser: _currentUserMinimal(),
                                    storyInteractions: const [],
                                    accentColor: Colors.blueAccent,
                                    forwardedMessage: null,
                                  )));
                                },
                              );
                            },
                          );
                        },
                      ),
              ),

              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  // helper for one-to-one chat id
  String _getDirectChatId(String a, String b) => a.compareTo(b) < 0 ? '${a}_$b' : '${b}_$a';
}

// Predefined themes (re-used)
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
