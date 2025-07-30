
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'messages_controller.dart';
import 'chat_screen.dart';
import 'Group_chat_screen.dart';
import 'widgets/tabs.dart';

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
  final Color accentColor;

  const MessagesScreen({
    super.key,
    required this.currentUser,
    required this.accentColor,
  });

  @override
  _MessagesScreenState createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late TabController _tabController;
  bool isExpanded = true;
  late MessagesController controller;

  @override
  void initState() {
    super.initState();
    controller = MessagesController(widget.currentUser, context);
    _tabController = TabController(length: 3, vsync: this);
    _scrollController.addListener(() {
      setState(() {
        isExpanded = _scrollController.offset <= 100;
      });
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<List<QueryDocumentSnapshot>> fetchChatsAndGroups(String userId, String tab) async {
    final chatsSnapshot = await FirebaseFirestore.instance
        .collection('chats')
        .where('userIds', arrayContains: userId)
        .orderBy('timestamp', descending: true)
        .get();

    final groupsSnapshot = await FirebaseFirestore.instance
        .collection('groups')
        .where('userIds', arrayContains: userId)
        .orderBy('timestamp', descending: true)
        .get();

    final combined = [...chatsSnapshot.docs, ...groupsSnapshot.docs];

    if (tab == 'Unread') {
      combined.retainWhere((doc) => (doc.data() as Map<String, dynamic>)['unread'] == true);
    } else if (tab == 'Favorites') {
      combined.retainWhere((doc) => (doc.data() as Map<String, dynamic>)['isFavorite'] == true);
    }

    combined.sort((a, b) {
      final aData = a.data() as Map<String, dynamic>;
      final bData = b.data() as Map<String, dynamic>;
      final aTime = aData['timestamp']?.toDate() ?? DateTime(1970);
      final bTime = bData['timestamp']?.toDate() ?? DateTime(1970);
      return bTime.compareTo(aTime);
    });

    return combined;
  }

  Future<int> getUnreadMessageCount(String chatId, String userId, bool isGroup) async {
    final messagesSnapshot = await FirebaseFirestore.instance
        .collection(isGroup ? 'groups' : 'chats')
        .doc(chatId)
        .collection('messages')
        .where('read', isEqualTo: false)
        .where('senderId', isNotEqualTo: userId)
        .get();
    return messagesSnapshot.docs.length;
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final currentUserId = widget.currentUser['id'];

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
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
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverAppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                pinned: true,
                expandedHeight: 200,
                flexibleSpace: FlexibleSpaceBar(
                  title: isExpanded
                      ? null
                      : Text(
                          'Messages',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: widget.accentColor,
                          ),
                        ),
                  centerTitle: true,
                  background: isExpanded
                      ? Container(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
  width: 80,
  height: 80,
  decoration: const BoxDecoration(
    shape: BoxShape.circle,
    gradient: LinearGradient(
      colors: [Color.fromARGB(255, 224, 0, 0), Color(0xFF8E2DE2)], // Example gradient
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
  ),
  child: widget.currentUser['photoUrl'] != null
      ? CircleAvatar(
          radius: 40,
          backgroundImage: NetworkImage(widget.currentUser['photoUrl']),
          backgroundColor: Colors.transparent,
        )
      : Center(
          child: Text(
            widget.currentUser['username']?[0]?.toUpperCase() ?? 'U',
            style: const TextStyle(color: Colors.white, fontSize: 24),
          ),
        ),
),

                              const SizedBox(height: 8),
                              Text(
                                widget.currentUser['username'] ?? 'User',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                              Text(
                                widget.currentUser['email'] ?? 'No email',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        )
                      : null,
                ),
                actions: controller.selectedChatId != null
                    ? [
                        FutureBuilder<bool>(
                          future: controller.isUserBlocked(controller.selectedOtherUser?['id']),
                          builder: (context, snapshot) {
                            final isBlocked = snapshot.data ?? false;
                            return IconButton(
                              icon: Icon(
                                isBlocked ? Icons.lock_open : Icons.block,
                                color: widget.accentColor,
                              ),
                              onPressed: isBlocked ? controller.unblockUser : controller.blockUser,
                              tooltip: isBlocked ? 'Unblock User' : 'Block User',
                            );
                          },
                        ),
                        FutureBuilder<bool>(
                          future: controller.isUserMuted(controller.selectedOtherUser?['id']),
                          builder: (context, snapshot) {
                            final isMuted = snapshot.data ?? false;
                            return IconButton(
                              icon: Icon(
                                isMuted ? Icons.volume_up : Icons.volume_off,
                                color: widget.accentColor,
                              ),
                              onPressed: isMuted ? controller.unmuteUser : controller.muteUser,
                              tooltip: isMuted ? 'Unmute User' : 'Mute User',
                            );
                          },
                        ),
                        FutureBuilder<bool>(
                          future: controller.isChatPinned(controller.selectedChatId!),
                          builder: (context, snapshot) {
                            final isPinned = snapshot.data ?? false;
                            return IconButton(
                              icon: Icon(
                                isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                                color: widget.accentColor,
                              ),
                              onPressed: isPinned ? controller.unpinConversation : controller.pinConversation,
                              tooltip: isPinned ? 'Unpin Conversation' : 'Pin Conversation',
                            );
                          },
                        ),
                        IconButton(
                          icon: Icon(Icons.delete, color: widget.accentColor),
                          onPressed: controller.deleteConversation,
                          tooltip: 'Delete Conversation',
                        ),
                        IconButton(
                          icon: Icon(Icons.close, color: widget.accentColor),
                          onPressed: controller.clearSelection,
                          tooltip: 'Cancel',
                        ),
                      ]
                    : null,
              ),
              MessageTabs(
                tabController: _tabController,
                accentColor: widget.accentColor,
                controller: controller,
              ),
              SliverFillRemaining(
                child: TabBarView(
                  controller: _tabController,
                  children: ['All', 'Unread', 'Favorites'].map((tab) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment.center,
                            radius: 1.6,
                            colors: [
                              widget.accentColor.withOpacity(0.2),
                              Colors.transparent,
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
                                border: Border.all(
                                  color: const Color.fromARGB(0, 255, 255, 255).withOpacity(0.1),
                                ),
                              ),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(minHeight: screenHeight),
                                child: FutureBuilder<List<QueryDocumentSnapshot>>(
                                  future: fetchChatsAndGroups(currentUserId, tab),
                                  builder: (context, snapshot) {
                                    if (!snapshot.hasData) {
                                      return const Center(child: CircularProgressIndicator());
                                    }

                                    final chats = snapshot.data!.where((doc) {
                                      final data = doc.data() as Map<String, dynamic>;
                                      final deletedBy = List<String>.from(data['deletedBy'] ?? []);
                                      return !deletedBy.contains(currentUserId);
                                    }).toList();

                                    if (chats.isEmpty) {
                                      return const Center(
                                        child: Text(
                                          "No conversations yet.",
                                          style: TextStyle(color: Colors.white70),
                                        ),
                                      );
                                    }

                                    return ListView.builder(
                                      physics: const NeverScrollableScrollPhysics(),
                                      shrinkWrap: true,
                                      padding: const EdgeInsets.all(16.0),
                                      itemCount: chats.length,
                                      itemBuilder: (context, index) {
                                        final chat = chats[index];
                                        final data = chat.data() as Map<String, dynamic>;
                                        final userIds = List<String>.from(data['userIds']);
                                        final lastMessage = data['lastMessage'] ?? 'No messages yet';
                                        final timestamp = data['timestamp']?.toDate();
                                        final isGroup = data['isGroup'] ?? false;
                                        final chatId = chat.id;

                                        return FutureBuilder<int>(
                                          future: getUnreadMessageCount(chatId, currentUserId, isGroup),
                                          builder: (context, unreadSnapshot) {
                                            final unreadCount = unreadSnapshot.data ?? 0;

                                            if (isGroup) {
                                              return Card(
                                                elevation: 4,
                                                shape: RoundedRectangleBorder(
                                                  borderRadius: BorderRadius.circular(12),
                                                ),
                                                margin: const EdgeInsets.symmetric(vertical: 8),
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    gradient: LinearGradient(
                                                      colors: [
                                                        widget.accentColor.withOpacity(0.1),
                                                        widget.accentColor.withOpacity(0.3),
                                                      ],
                                                      begin: Alignment.topLeft,
                                                      end: Alignment.bottomRight,
                                                    ),
                                                    borderRadius: BorderRadius.circular(12),
                                                    border: Border.all(
                                                      color: widget.accentColor.withOpacity(0.3),
                                                    ),
                                                  ),
                                                  child: ListTile(
                                                    selected: chatId == controller.selectedChatId,
                                                    selectedTileColor: widget.accentColor.withOpacity(0.1),
                                                    leading: const CircleAvatar(
                                                      child: Icon(Icons.group, color: Colors.white),
                                                    ),
                                                    title: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        Text(
                                                          data['name'] ?? 'Group Chat',
                                                          style: TextStyle(
                                                            color: widget.accentColor,
                                                            fontWeight: FontWeight.bold,
                                                          ),
                                                        ),
                                                        if (unreadCount > 0) ...[
                                                          const SizedBox(width: 6),
                                                          Container(
                                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                            decoration: BoxDecoration(
                                                              color: widget.accentColor,
                                                              borderRadius: BorderRadius.circular(10),
                                                            ),
                                                            child: Text(
                                                              '$unreadCount',
                                                              style: const TextStyle(
                                                                color: Colors.white,
                                                                fontSize: 10,
                                                                fontWeight: FontWeight.bold,
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ],
                                                    ),
                                                    subtitle: Text(
                                                      lastMessage,
                                                      style: const TextStyle(color: Colors.white),
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                    trailing: timestamp != null
                                                        ? Text(
                                                            TimeOfDay.fromDateTime(timestamp).format(context),
                                                            style: TextStyle(
                                                              fontSize: 12,
                                                              color: widget.accentColor,
                                                            ),
                                                          )
                                                        : null,
                                                    onTap: () {
                                                      Navigator.push(
                                                        context,
                                                        MaterialPageRoute(
                                                          builder: (_) => GroupChatScreen(
                                                            chatId: chatId,
                                                            currentUser: widget.currentUser,
                                                            authenticatedUser: widget.currentUser,
                                                            accentColor: widget.accentColor,
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                    onLongPress: () {
                                                      if (controller.selectedChatId == chatId) {
                                                        controller.clearSelection();
                                                      } else {
                                                        setState(() {
                                                          controller.selectedChatId = chatId;
                                                          controller.selectedOtherUser = null;
                                                        });
                                                      }
                                                    },
                                                  ),
                                                ),
                                              );
                                            }

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

                                                return FutureBuilder<bool>(
                                                  future: controller.isUserBlocked(otherUserId),
                                                  builder: (context, blockSnapshot) {
                                                    if (!blockSnapshot.hasData) return const SizedBox();
                                                    final isBlocked = blockSnapshot.data!;

                                                    return Card(
                                                      elevation: 4,
                                                      shape: RoundedRectangleBorder(
                                                        borderRadius: BorderRadius.circular(12),
                                                      ),
                                                      margin: const EdgeInsets.symmetric(vertical: 8),
                                                      child: Container(
                                                        decoration: BoxDecoration(
                                                          gradient: LinearGradient(
                                                            colors: [
                                                              widget.accentColor.withOpacity(0.1),
                                                              widget.accentColor.withOpacity(0.3),
                                                            ],
                                                            begin: Alignment.topLeft,
                                                            end: Alignment.bottomRight,
                                                          ),
                                                          borderRadius: BorderRadius.circular(12),
                                                          border: Border.all(
                                                            color: widget.accentColor.withOpacity(0.3),
                                                          ),
                                                        ),
                                                        child: ListTile(
                                                          selected: chatId == controller.selectedChatId,
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
                                                                    style: const TextStyle(color: Colors.white),
                                                                  )
                                                                : null,
                                                          ),
                                                          title: Row(
                                                            mainAxisSize: MainAxisSize.min,
                                                            children: [
                                                              Text(
                                                                username,
                                                                style: TextStyle(
                                                                  color: widget.accentColor,
                                                                  fontWeight: FontWeight.bold,
                                                                ),
                                                              ),
                                                              if (unreadCount > 0) ...[
                                                                const SizedBox(width: 6),
                                                                Container(
                                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                                  decoration: BoxDecoration(
                                                                    color: widget.accentColor,
                                                                    borderRadius: BorderRadius.circular(10),
                                                                  ),
                                                                  child: Text(
                                                                    '$unreadCount',
                                                                    style: const TextStyle(
                                                                      color: Colors.white,
                                                                      fontSize: 10,
                                                                      fontWeight: FontWeight.bold,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ],
                                                            ],
                                                          ),
                                                          subtitle: Text(
                                                            lastMessage,
                                                            style: TextStyle(
                                                              color: isBlocked ? Colors.grey : Colors.white,
                                                            ),
                                                            overflow: TextOverflow.ellipsis,
                                                          ),
                                                          trailing: timestamp != null
                                                              ? Text(
                                                                  TimeOfDay.fromDateTime(timestamp).format(context),
                                                                  style: TextStyle(
                                                                    fontSize: 12,
                                                                    color: widget.accentColor,
                                                                  ),
                                                                )
                                                              : null,
                                                          onTap: isBlocked
                                                              ? null
                                                              : () {
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
                                                            if (controller.selectedChatId == chatId) {
                                                              controller.clearSelection();
                                                            } else {
                                                              setState(() {
                                                                controller.selectedChatId = chatId;
                                                                controller.selectedOtherUser = {
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
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: controller.showChatCreationOptions,
        backgroundColor: widget.accentColor,
        child: const Icon(Icons.chat, color: Colors.white),
      ),
    );
  }
}