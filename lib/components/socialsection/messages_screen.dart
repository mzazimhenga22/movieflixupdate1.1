import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'chat_screen.dart';
import 'conversation_actions.dart';

String getChatId(String userId1, String userId2) {
  return userId1.compareTo(userId2) < 0
      ? '${userId1}_$userId2'
      : '${userId2}_$userId1';
}

class AnimatedBackground extends StatelessWidget {
  const AnimatedBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.redAccent, Colors.blueAccent],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
    );
  }
}

class MessagesScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  final List<Map<String, dynamic>> otherUsers;
  final Color accentColor;

  const MessagesScreen({
    super.key,
    required this.currentUser,
    required this.otherUsers,
    required this.accentColor,
  });

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  String? selectedChatId;
  Map<String, dynamic>? selectedOtherUser;

  void _clearSelection() {
    setState(() {
      selectedChatId = null;
      selectedOtherUser = null;
    });
  }

  void _blockUser() {
    if (selectedOtherUser != null) {
      FirebaseFirestore.instance
          .collection('users')
          .doc(widget.currentUser['id'])
          .update({
        'blockedUsers': FieldValue.arrayUnion([selectedOtherUser!['id']])
      });
      _clearSelection();
    }
  }

  void _muteUser() {
    if (selectedOtherUser != null) {
      FirebaseFirestore.instance
          .collection('users')
          .doc(widget.currentUser['id'])
          .update({
        'mutedUsers': FieldValue.arrayUnion([selectedOtherUser!['id']])
      });
      _clearSelection();
    }
  }

  void _pinConversation() {
    if (selectedChatId != null) {
      FirebaseFirestore.instance
          .collection('users')
          .doc(widget.currentUser['id'])
          .update({
        'pinnedChats': FieldValue.arrayUnion([selectedChatId])
      });
      _clearSelection();
    }
  }

  void _deleteConversation() {
    if (selectedChatId != null) {
      FirebaseFirestore.instance
          .collection('chats')
          .doc(selectedChatId)
          .update({
        'deletedBy': FieldValue.arrayUnion([widget.currentUser['id']])
      });
      _clearSelection();
    }
  }

  void _navigateToNewChat() async {
    final snapshot = await FirebaseFirestore.instance.collection('users').get();
    final allUsers = snapshot.docs
        .map((doc) => doc.data())
        .where((user) => user['id'] != widget.currentUser['id'])
        .toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: ListView(
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
                        color: widget.accentColor, fontWeight: FontWeight.bold),
                  ),
                  onTap: () {
                    final chatId = getChatId(widget.currentUser['id'], user['id']);
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatScreen(
                          chatId: chatId,
                          currentUser: widget.currentUser,
                          otherUser: user,
                          authenticatedUser: widget.currentUser,
                          storyInteractions: const [],
                        ),
                      ),
                    );
                  },
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final currentUserId = widget.currentUser['id'];

    final chatQuery = FirebaseFirestore.instance
        .collection('chats')
        .where('userIds', arrayContains: currentUserId)
        .orderBy('timestamp', descending: true);

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: selectedChatId == null
            ? Text(
                'Messages',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: widget.accentColor,
                ),
              )
            : null,
        centerTitle: true,
        actions: selectedChatId != null
            ? [
                IconButton(
                  icon: Icon(Icons.block, color: widget.accentColor),
                  onPressed: _blockUser,
                  tooltip: 'Block User',
                ),
                IconButton(
                  icon: Icon(Icons.volume_off, color: widget.accentColor),
                  onPressed: _muteUser,
                  tooltip: 'Mute User',
                ),
                IconButton(
                  icon: Icon(Icons.push_pin, color: widget.accentColor),
                  onPressed: _pinConversation,
                  tooltip: 'Pin Conversation',
                ),
                IconButton(
                  icon: Icon(Icons.delete, color: widget.accentColor),
                  onPressed: _deleteConversation,
                  tooltip: 'Delete Conversation',
                ),
                IconButton(
                  icon: Icon(Icons.close, color: widget.accentColor),
                  onPressed: _clearSelection,
                  tooltip: 'Cancel',
                ),
              ]
            : null,
      ),
      body: Stack(
        children: [
          const AnimatedBackground(),
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.1, -0.4),
                radius: 1.2,
                colors: [widget.accentColor.withOpacity(0.4), Colors.black],
                stops: const [0.0, 0.6],
              ),
            ),
          ),
          Positioned.fill(
            top: kToolbarHeight + MediaQuery.of(context).padding.top,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.6,
                    colors: [
                      widget.accentColor.withOpacity(0.2),
                      Colors.transparent
                    ],
                    stops: const [0.0, 1.0],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: widget.accentColor.withOpacity(0.4),
                      blurRadius: 10,
                      spreadRadius: 1,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color.fromARGB(59, 105, 3, 20),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color.fromARGB(0, 255, 255, 255).withOpacity(0.1)),
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: screenHeight),
                        child: StreamBuilder<QuerySnapshot>(
                          stream: chatQuery.snapshots(),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return const Center(child: CircularProgressIndicator());
                            }

                            final chats = snapshot.data!.docs;
                            if (chats.isEmpty) {
                              return const Center(
                                  child: Text("No conversations yet.",
                                      style: TextStyle(color: Colors.white70)));
                            }

                            return ListView.builder(
                              padding: const EdgeInsets.all(16.0),
                              itemCount: chats.length,
                              itemBuilder: (context, index) {
                                final chat = chats[index];
                                final data = chat.data() as Map<String, dynamic>;
                                final userIds = List<String>.from(data['userIds']);
                                final lastMessage = data['lastMessage'] ?? '';
                                final timestamp = data['timestamp']?.toDate();
                                final otherUserId = userIds.firstWhere(
                                  (uid) => uid != currentUserId,
                                  orElse: () => 'Unknown',
                                );

                                return FutureBuilder<DocumentSnapshot>(
                                  future: FirebaseFirestore.instance
                                      .collection('users')
                                      .doc(otherUserId)
                                      .get(),
                                  builder: (context, userSnapshot) {
                                    if (!userSnapshot.hasData) return const SizedBox();

                                    final userDoc = userSnapshot.data!;
                                    final userData = userDoc.data() as Map<String, dynamic>?;

                                    final photoUrl = userData?['photoUrl'] ?? '';
                                    final username = userData?['username'] ?? 'Unknown';
                                    final chatId = getChatId(currentUserId, otherUserId);

                                    return Card(
                                      elevation: 4,
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12)),
                                      margin: const EdgeInsets.symmetric(vertical: 8),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              widget.accentColor.withOpacity(0.1),
                                              widget.accentColor.withOpacity(0.3)
                                            ],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                              color: widget.accentColor.withOpacity(0.3)),
                                        ),
                                        child: ListTile(
                                          selected: chatId == selectedChatId,
                                          selectedTileColor: widget.accentColor.withOpacity(0.1),
                                          leading: CircleAvatar(
                                            backgroundImage: photoUrl.isNotEmpty
                                                ? NetworkImage(photoUrl)
                                                : null,
                                            child: photoUrl.isEmpty
                                                ? Text(
                                                    username.isNotEmpty
                                                        ? username[0].toUpperCase()
                                                        : 'M',
                                                    style: const TextStyle(color: Color.fromARGB(255, 255, 255, 255)),
                                                  )
                                                : null,
                                          ),
                                          title: Text(
                                            username,
                                            style: TextStyle(
                                                color: widget.accentColor,
                                                fontWeight: FontWeight.bold),
                                          ),
                                          subtitle: Text(
                                            lastMessage,
                                            style: const TextStyle(color: Color.fromARGB(255, 252, 1, 1)),
                                          ),
                                          trailing: timestamp != null
                                              ? Text(
                                                  TimeOfDay.fromDateTime(timestamp).format(context),
                                                  style: TextStyle(
                                                      fontSize: 12, color: widget.accentColor),
                                                )
                                              : null,
                                          onTap: () {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) => ChatScreen(
                                                  chatId: chatId,
                                                  currentUser: widget.currentUser,
                                                  otherUser: {
                                                    'id': otherUserId,
                                                    'username': username,
                                                    'photoUrl': photoUrl,
                                                  },
                                                  authenticatedUser: widget.currentUser,
                                                  storyInteractions: const [],
                                                ),
                                              ),
                                            );
                                          },
                                          onLongPress: () {
                                            if (selectedChatId == chatId) {
                                              _clearSelection();
                                            } else {
                                              setState(() {
                                                selectedChatId = chatId;
                                                selectedOtherUser = {
                                                  'id': otherUserId,
                                                  'username': username,
                                                  'photoUrl': photoUrl,
                                                };
                                              });
                                            }
                                          },
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _navigateToNewChat,
        backgroundColor: widget.accentColor,
        child: const Icon(Icons.chat, color: Colors.white),
      ),
    );
  }
}