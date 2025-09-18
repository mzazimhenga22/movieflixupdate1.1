import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'Group_chat_screen.dart';
import 'chat_screen.dart';

class ForwardMessageScreen extends StatefulWidget {
  const ForwardMessageScreen({super.key});

  @override
  State<ForwardMessageScreen> createState() => _ForwardMessageScreenState();
}

class _ForwardMessageScreenState extends State<ForwardMessageScreen> {
  late Map<String, dynamic> currentUser;
  late QueryDocumentSnapshot message;
  late bool isForwarded;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    if (args != null) {
      message = args['message'];
      currentUser = args['currentUser'];
      isForwarded = args['isForwarded'] ?? false;
    }
  }

  Future<Map<String, List<Map<String, dynamic>>>> _fetchUsersAndGroups() async {
    final userSnap = await FirebaseFirestore.instance.collection('users').get();
    final groupSnap = await FirebaseFirestore.instance
        .collection('groups')
        .where('isGroup', isEqualTo: true)
        .get();

    final users =
        userSnap.docs.where((doc) => doc.id != currentUser['id']).map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return data;
    }).toList();

    final groups = groupSnap.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return data;
    }).toList();

    return {'users': users, 'groups': groups};
  }

  void _forwardMessageToGroup(Map<String, dynamic> group) async {
    try {
      final newMessage = {
        'text': message['text'],
        'senderId': currentUser['id'],
        'senderName': currentUser['username'] ?? 'You',
        'timestamp': FieldValue.serverTimestamp(),
        'type': message['type'] ?? 'text',
        'forwardedFrom': message['senderId'],
        'readBy': [currentUser['id']],
      };

      await FirebaseFirestore.instance
          .collection('groups')
          .doc(group['id'])
          .collection('messages')
          .add(newMessage);

      if (!mounted) return;

      forwardMessageToChat(
        context,
        newMessage,
        true,
        group['id'],
        group['name'] ?? 'Unnamed Group',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to forward message: $e')),
        );
      }
    }
  }

  void _forwardMessageToUser(Map<String, dynamic> user) async {
    try {
      final newMessage = {
        'text': message['text'],
        'senderId': currentUser['id'],
        'senderName': currentUser['username'] ?? 'You',
        'receiverId': user['id'],
        'timestamp': FieldValue.serverTimestamp(),
        'type': message['type'] ?? 'text',
        'forwardedFrom': message['senderId'],
      };

      final chatId = _generateChatId(currentUser['id'], user['id']);

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add(newMessage);

      await FirebaseFirestore.instance.collection('chats').doc(chatId).set({
        'lastMessage': message['text'],
        'timestamp': FieldValue.serverTimestamp(),
        'userIds': [currentUser['id'], user['id']],
      }, SetOptions(merge: true));

      if (!mounted) return;

      forwardMessageToChat(
        context,
        newMessage,
        false,
        chatId,
        user['username'] ?? 'User',
        otherUser: Map<String, dynamic>.from(user),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to forward message: $e')),
        );
      }
    }
  }

  String _generateChatId(String uid1, String uid2) {
    return uid1.compareTo(uid2) < 0 ? '$uid1\_$uid2' : '$uid2\_$uid1';
  }

  Color _parseAccentColor(dynamic colorData) {
    if (colorData is int) {
      return Color(colorData);
    }
    return const Color.fromARGB(255, 255, 68, 77);
  }

  void forwardMessageToChat(
    BuildContext context,
    Map<String, dynamic> message,
    bool isGroup,
    String chatId,
    String chatName, {
    Map<String, dynamic>? otherUser,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Forwarded to $chatName")),
    );

    Future.delayed(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      if (isGroup) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GroupChatScreen(
              chatId: chatId,
              currentUser: currentUser,
              authenticatedUser: currentUser,
              forwardedMessage: message,
            ),
          ),
        );
      } else {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              chatId: chatId,
              currentUser: currentUser,
              otherUser: otherUser!,
              authenticatedUser: currentUser,
              storyInteractions: [],
              forwardedMessage: message,
            ),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = _parseAccentColor(currentUser['accentColor']);

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.purpleAccent, Colors.deepPurple],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.3, -0.5),
                radius: 1.2,
                colors: [accentColor.withOpacity(0.3), Colors.black],
              ),
            ),
          ),
          CustomScrollView(
            slivers: [
              SliverAppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                pinned: true,
                expandedHeight: 180, // Increased to accommodate message preview
                flexibleSpace: FlexibleSpaceBar(
                  centerTitle: true,
                  title: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Forward Message',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: accentColor.withOpacity(0.3)),
                        ),
                        child: Text(
                          message['text'] ?? '[Media]',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.25),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white.withOpacity(0.1)),
                        ),
                        child: FutureBuilder<Map<String, List<Map<String, dynamic>>>>(
                          future: _fetchUsersAndGroups(),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return const Padding(
                                padding: EdgeInsets.all(24.0),
                                child: Center(child: CircularProgressIndicator()),
                              );
                            }

                            if (!snapshot.hasData ||
                                (snapshot.data!['users']!.isEmpty &&
                                    snapshot.data!['groups']!.isEmpty)) {
                              return const Padding(
                                padding: EdgeInsets.all(24.0),
                                child: Center(
                                  child: Text(
                                    'No recipients found.',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                              );
                            }

                            final users = snapshot.data!['users']!;
                            final groups = snapshot.data!['groups']!;

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (users.isNotEmpty)
                                  _buildSectionHeader('Users', accentColor),
                                ...users.map((user) => _buildRecipientTile(
                                    user, accentColor,
                                    isGroup: false)),
                                if (groups.isNotEmpty)
                                  _buildSectionHeader('Groups', accentColor),
                                ...groups.map((group) => _buildRecipientTile(
                                    group, accentColor,
                                    isGroup: true)),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, Color color) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 20, bottom: 10),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 18,
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildRecipientTile(Map<String, dynamic> item, Color accentColor,
      {required bool isGroup}) {
    final title = isGroup
        ? item['name'] ?? 'Unnamed Group'
        : item['username'] ?? 'Unnamed';
    final subtitle = isGroup
        ? '${(item['userIds'] as List?)?.length ?? 0} members'
        : item['email'] ?? '';
    final photoUrl = isGroup ? item['avatarUrl'] : item['photoUrl'];

    return Card(
      elevation: 4,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: () => isGroup
            ? _forwardMessageToGroup(item)
            : _forwardMessageToUser(item),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                accentColor.withOpacity(0.1),
                accentColor.withOpacity(0.25)
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            leading: CircleAvatar(
              radius: 22,
              backgroundColor: const Color.fromARGB(255, 224, 224, 224),
              backgroundImage:
                  (photoUrl != null && photoUrl.toString().isNotEmpty)
                      ? NetworkImage(photoUrl)
                      : null,
              child: (photoUrl == null || photoUrl.toString().isEmpty)
                  ? Text(
                      title.isNotEmpty ? title[0].toUpperCase() : '?',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    )
                  : null,
            ),
            title: Text(
              title,
              style: TextStyle(fontWeight: FontWeight.bold, color: accentColor),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(color: accentColor.withOpacity(0.7)),
            ),
            trailing: Icon(Icons.forward, color: accentColor),
          ),
        ),
      ),
    );
  }
}