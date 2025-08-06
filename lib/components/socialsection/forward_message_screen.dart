import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'Group_chat_screen.dart';
import 'chat_screen.dart';
// ... imports remain the same

class ForwardMessageScreen extends StatefulWidget {
  const ForwardMessageScreen({super.key});

  @override
  State<ForwardMessageScreen> createState() => _ForwardMessageScreenState();
}

class _ForwardMessageScreenState extends State<ForwardMessageScreen> {
  late Map<String, dynamic> currentUser;
  late QueryDocumentSnapshot message;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    if (args != null) {
      message = args['message'];
      currentUser = args['currentUser'];
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
        'senderName': currentUser['username'],
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

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Message forwarded to group "${group['name']}"')),
      );
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to forward message: $e')),
      );
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

/// Helper that knows how to open either a 1-on-1 ChatScreen or a GroupChatScreen
void forwardMessageToChat(
  BuildContext context,
  Map<String, dynamic> message,        // the Firestore payload you just sent
  bool isGroup,                        // false → ChatScreen, true → GroupChatScreen
  String chatId,                       // document ID of the chat or group
  String chatName,                     // username (for 1-1) or group name
  { Map<String, dynamic>? otherUser } // pass the user Map when 1-on-1
) {
  // 1) confirmation toast
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text("Forwarded to $chatName")),
  );

  // 2) after a short delay, navigate
  Future.delayed(const Duration(milliseconds: 800), () {
    if (isGroup) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GroupChatScreen(
            chatId:            chatId,
            currentUser:       currentUser,
            authenticatedUser: currentUser,     // or your real auth user
            forwardedMessage:  message,
            // accentColor uses default if you omit
          ),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId:             chatId,
            currentUser:        currentUser,
            otherUser:          otherUser!,      // must supply here
            authenticatedUser:  currentUser,     // or your auth user
            storyInteractions:  [],              // pass your real list here
            forwardedMessage:   message,
            // accentColor uses default if you omit
          ),
        ),
      );
    }
  });
}



void _forwardMessageToUser(Map<String, dynamic> user) async {
final newMessage = {
  'senderId': currentUser['id'],
  'text': message['text'],
  'timestamp': Timestamp.now(),
  'type': message['type'],
  'forwardedFrom': message['senderId'],  // optional: show it's forwarded
};


  final chatId = _generateChatId(currentUser['id'], user['id']);

  await FirebaseFirestore.instance
      .collection('chats')
      .doc(chatId)
      .collection('messages')
      .add(newMessage);

  if (!mounted) return;

  forwardMessageToChat(
    context,
    newMessage,
    false, // isGroup
    chatId,
    user['username'] ?? 'User',
    otherUser: Map<String, dynamic>.from(user), // ✅ cast properly
  );
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
                expandedHeight: 120,
                flexibleSpace: const FlexibleSpaceBar(
                  centerTitle: true,
                  title: Text(
                    'Forward Message',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
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
                          border:
                              Border.all(color: Colors.white.withOpacity(0.1)),
                        ),
                        child: FutureBuilder<
                            Map<String, List<Map<String, dynamic>>>>(
                          future: _fetchUsersAndGroups(),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Padding(
                                padding: EdgeInsets.all(24.0),
                                child:
                                    Center(child: CircularProgressIndicator()),
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
