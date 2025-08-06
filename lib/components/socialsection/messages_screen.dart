import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'messages_controller.dart';
import 'chat_screen.dart';
import 'Group_chat_screen.dart';
import 'widgets/mark_read_unread.dart'; // Import updated MessageStatusUtils
import 'chat_tile.dart';

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

class ChatInfo {
  final QueryDocumentSnapshot doc;
  final int unreadCount;
  final Map<String, dynamic>? otherUser;

  ChatInfo({required this.doc, required this.unreadCount, this.otherUser});
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
  MessagesScreenState createState() => MessagesScreenState();
}

class MessagesScreenState extends State<MessagesScreen>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late TabController _tabController;
  bool isExpanded = true;
  late ValueNotifier<bool> _reloadTrigger;
  late MessagesController controller;

  @override
  void initState() {
    super.initState();
    controller = MessagesController(widget.currentUser, context);
    _tabController = TabController(length: 3, vsync: this);
    _reloadTrigger = ValueNotifier<bool>(false);
    _scrollController.addListener(() {
      if (mounted) {
        setState(() => isExpanded = _scrollController.offset <= 100);
      }
    });

    FirebaseFirestore.instance
        .collection('chats')
        .where('userIds', arrayContains: widget.currentUser['id'])
        .snapshots()
        .listen((_) {
      _reloadTrigger.value = !_reloadTrigger.value;
    });

    FirebaseFirestore.instance
        .collection('groups')
        .where('userIds', arrayContains: widget.currentUser['id'])
        .snapshots()
        .listen((_) {
      _reloadTrigger.value = !_reloadTrigger.value;
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _tabController.dispose();
    _reloadTrigger.dispose();
    super.dispose();
  }

  Future<List<ChatInfo>> fetchChatsAndGroups(String userId, String tab) async {
    final chatsSnapshot = await FirebaseFirestore.instance
        .collection('chats')
        .where('userIds', arrayContains: userId)
        .orderBy('timestamp', descending: true)
        .limit(20)
        .get();

    final groupsSnapshot = await FirebaseFirestore.instance
        .collection('groups')
        .where('userIds', arrayContains: userId)
        .orderBy('timestamp', descending: true)
        .limit(20)
        .get();

    final combined =
        [...chatsSnapshot.docs, ...groupsSnapshot.docs].where((doc) {
      final data = doc.data();
      final deletedBy = List<String>.from(data['deletedBy'] ?? []);
      return !deletedBy.contains(userId);
    }).toList();

    if (tab == 'Unread') {
      final filtered = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      for (var doc in combined) {
        final isGroup = doc.data()['isGroup'] ?? false;
        if (await MessageStatusUtils.isUnread(
          chatId: doc.id,
          userId: userId,
          isGroup: isGroup,
        )) {
          filtered.add(doc);
        }
      }
      combined
        ..clear()
        ..addAll(filtered);
    } else if (tab == 'Favorites') {
      combined.retainWhere((doc) {
        final data = doc.data();
        return data['isFavorite'] == true;
      });
    }

    final userDoc =
        await FirebaseFirestore.instance.collection('users').doc(userId).get();
    final pinnedChats = List<String>.from(userDoc.get('pinnedChats') ?? []);

    combined.sort((a, b) {
      final aTime =
          (a.data()['timestamp'] as Timestamp?)?.toDate() ?? DateTime(1970);
      final bTime =
          (b.data()['timestamp'] as Timestamp?)?.toDate() ?? DateTime(1970);
      final aPinned = pinnedChats.contains(a.id);
      final bPinned = pinnedChats.contains(b.id);

      if (aPinned && !bPinned) return -1;
      if (!aPinned && bPinned) return 1;
      return bTime.compareTo(aTime);
    });

    final chatInfoList = <ChatInfo>[];
    for (final doc in combined) {
      final data = doc.data();
      final isGroup = data['isGroup'] ?? false;
      final chatId = doc.id;

      final unreadCount = await FirebaseFirestore.instance
          .collection(isGroup ? 'groups' : 'chats')
          .doc(chatId)
          .collection('messages')
          .where('readBy', arrayContains: userId, isEqualTo: false)
          .count()
          .get()
          .then((res) => res.count);

      Map<String, dynamic>? otherUser;
      if (!isGroup) {
        final userIds = List<String>.from(data['userIds'] ?? []);
        final otherUserId = userIds.firstWhere(
          (uid) => uid != userId,
          orElse: () => '',
        );

        if (otherUserId.isNotEmpty) {
          final userDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(otherUserId)
              .get();
          if (userDoc.exists) {
            otherUser = userDoc.data()!..['id'] = userDoc.id;
          }
        }
      }

      chatInfoList.add(ChatInfo(
        doc: doc,
        unreadCount: unreadCount ?? 0,
        otherUser: otherUser,
      ));
    }

    return chatInfoList;
  }

  @override
  Widget build(BuildContext context) {
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
                colors: [
                  widget.accentColor.withOpacity(0.4),
                  Colors.black,
                ],
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
                                    colors: [
                                      Color.fromARGB(255, 224, 0, 0),
                                      Color(0xFF8E2DE2)
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                ),
                                child: widget.currentUser['photoUrl'] != null
                                    ? CircleAvatar(
                                        radius: 40,
                                        backgroundImage: NetworkImage(
                                            widget.currentUser['photoUrl']),
                                        backgroundColor: Colors.transparent,
                                      )
                                    : Center(
                                        child: Text(
                                          widget.currentUser['username']?[0]
                                                  ?.toUpperCase() ??
                                              'U',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 24),
                                        ),
                                      ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                widget.currentUser['username'] ?? 'User',
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                              Text(
                                widget.currentUser['email'] ?? 'No email',
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        )
                      : null,
                ),
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(48),
                  child: Material(
                    elevation: 4,
                    color: Colors.black.withOpacity(0.5),
                    child: FutureBuilder<int>(
                      future: controller.getUnreadCount(currentUserId),
                      builder: (context, snapshot) {
                        final unreadCount = snapshot.data ?? 0;
                        return TabBar(
                          controller: _tabController,
                          indicatorColor: widget.accentColor,
                          labelColor: widget.accentColor,
                          unselectedLabelColor: Colors.white54,
                          tabs: [
                            const Tab(text: 'All'),
                            Tab(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('Unread'),
                                  if (unreadCount > 0) ...[
                                    const SizedBox(width: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: widget.accentColor,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        '$unreadCount',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const Tab(text: 'Favorites'),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                actions: controller.selectedChatId != null
                    ? [
                        if (controller.selectedOtherUser != null)
                          IconButton(
                            icon: ValueListenableBuilder<bool>(
                              valueListenable: _reloadTrigger,
                              builder: (_, __, ___) {
                                final otherUser = controller.selectedOtherUser;
                                final isBlocked = otherUser != null
                                    ? controller.isUserBlocked(otherUser['id'])
                                    : false;

                                return Icon(
                                  isBlocked ? Icons.lock_open : Icons.block,
                                  color: widget.accentColor,
                                );
                              },
                            ),
                            onPressed: () async {
                              await (controller.isUserBlocked(
                                      controller.selectedOtherUser!['id'])
                                  ? controller.unblockUser()
                                  : controller.blockUser());
                              _reloadTrigger.value = !_reloadTrigger.value;
                            },
                            tooltip: controller.isUserBlocked(
                                    controller.selectedOtherUser!['id'])
                                ? 'Unblock User'
                                : 'Block User',
                          ),
                        IconButton(
                          icon: ValueListenableBuilder<bool>(
                            valueListenable: _reloadTrigger,
                            builder: (_, __, ___) {
                              final otherUser = controller.selectedOtherUser;
                              final id = otherUser != null
                                  ? otherUser['id']
                                  : controller.selectedChatId;

                              if (id == null) {
                                return const Icon(Icons.volume_down_alt);
                              }

                              final isMuted = controller.isUserMuted(id);

                              return Icon(
                                isMuted ? Icons.volume_up : Icons.volume_off,
                                color: widget.accentColor,
                              );
                            },
                          ),
                          onPressed: () async {
                            final otherUser = controller.selectedOtherUser;
                            final id = otherUser != null
                                ? otherUser['id']
                                : controller.selectedChatId;

                            if (id == null) {
                              print("No user or chat selected.");
                              return;
                            }

                            final isMuted = controller.isUserMuted(id);

                            if (isMuted) {
                              if (otherUser != null) {
                                await controller.unmuteUser();
                              } else {
                                await controller.unmuteGroup();
                              }
                            } else {
                              if (otherUser != null) {
                                await controller.muteUser();
                              } else {
                                await controller.muteGroup();
                              }
                            }

                            _reloadTrigger.value = !_reloadTrigger.value;
                          },
                          tooltip: controller.isUserMuted(
                                  controller.selectedOtherUser != null
                                      ? controller.selectedOtherUser!['id']
                                      : controller.selectedChatId!)
                              ? 'Unmute'
                              : 'Mute',
                        ),
                        IconButton(
                          icon: ValueListenableBuilder<bool>(
                            valueListenable: _reloadTrigger,
                            builder: (_, __, ___) {
                              final chatId = controller.selectedChatId;

                              if (chatId == null) {
                                return const Icon(Icons.push_pin,
                                    color: Colors.grey);
                              }

                              final isPinned = controller.isChatPinned(chatId);

                              return Icon(
                                isPinned
                                    ? Icons.push_pin_outlined
                                    : Icons.push_pin,
                                color: widget.accentColor,
                              );
                            },
                          ),
                          onPressed: () async {
                            final chatId = controller.selectedChatId;

                            if (chatId == null) {
                              print("No chat selected");
                              return;
                            }

                            final isPinned = controller.isChatPinned(chatId);

                            if (isPinned) {
                              await controller.unpinConversation();
                            } else {
                              await controller.pinConversation();
                            }

                            _reloadTrigger.value = !_reloadTrigger.value;
                          },
                          tooltip: controller
                                  .isChatPinned(controller.selectedChatId!)
                              ? 'Unpin Conversation'
                              : 'Pin Conversation',
                        ),
                        IconButton(
                          icon: Icon(Icons.delete, color: widget.accentColor),
                          onPressed: () async {
                            await controller.deleteConversation();
                            _reloadTrigger.value = !_reloadTrigger.value;
                          },
                          tooltip: controller.selectedOtherUser != null
                              ? 'Delete Conversation'
                              : 'Leave Group',
                        ),
                        IconButton(
                          icon: Icon(Icons.close, color: widget.accentColor),
                          onPressed: () {
                            controller.clearSelection();
                          },
                          tooltip: 'Cancel',
                        ),
                      ]
                    : null,
              ),
              SliverFillRemaining(
                child: TabBarView(
                  controller: _tabController,
                  children: ['All', 'Unread', 'Favorites'].map((tab) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: widget.accentColor.withOpacity(0.1),
                          ),
                        ),
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _reloadTrigger,
                          builder: (context, _, __) =>
                              FutureBuilder<List<ChatInfo>>(
                            future: fetchChatsAndGroups(currentUserId, tab),
                            builder: (context, snapshot) {
                              if (!snapshot.hasData) {
                                return ListView.builder(
                                  padding: const EdgeInsets.all(16.0),
                                  itemCount: 5,
                                  itemBuilder: (context, index) => Card(
                                    elevation: 4,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    margin:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    child: ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor:
                                            Colors.black.withOpacity(0.3),
                                      ),
                                      title: Container(
                                        width: 100,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              widget.accentColor
                                                  .withOpacity(0.1),
                                              widget.accentColor
                                                  .withOpacity(0.3),
                                            ],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                        ),
                                      ),
                                      subtitle: Container(
                                        width: 150,
                                        height: 12,
                                        margin: const EdgeInsets.only(top: 4),
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              widget.accentColor
                                                  .withOpacity(0.1),
                                              widget.accentColor
                                                  .withOpacity(0.3),
                                            ],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                        ),
                                      ),
                                      trailing: Container(
                                        width: 50,
                                        height: 12,
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              widget.accentColor
                                                  .withOpacity(0.1),
                                              widget.accentColor
                                                  .withOpacity(0.3),
                                            ],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }

                              final chats = snapshot.data!;
                              if (chats.isEmpty) {
                                return const Center(
                                  child: Text(
                                    "No conversations yet.",
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                );
                              }

                              return ListView.builder(
                                padding: const EdgeInsets.all(16.0),
                                itemCount: chats.length,
                                itemBuilder: (context, index) {
                                  final chatInfo = chats[index];
                                  final chat = chatInfo.doc;
                                  final data =
                                      chat.data()! as Map<String, dynamic>;
                                  final isGroup = data['isGroup'] ?? false;
                                  final chatId = chat.id;
                                  final lastMessage =
                                      data['lastMessage'] ?? 'No messages yet';
                                  final timestamp =
                                      (data['timestamp'] as Timestamp?)
                                          ?.toDate();
                                  final unreadCount = chatInfo.unreadCount;

                                  if (isGroup) {
                                    return ChatTile(
                                      isGroup: true,
                                      chatId: chatId,
                                      title: data['name'] ?? 'Group Chat',
                                      lastMessage: lastMessage,
                                      timestamp: timestamp,
                                      unreadCount: unreadCount,
                                      accentColor: widget.accentColor,
                                      isSelected:
                                          chatId == controller.selectedChatId,
                                      controller: controller,
                                      onTap: () {
                                        controller.clearSelection();
                                        MessageStatusUtils.markAsRead(
                                          chatId: chatId,
                                          userId: currentUserId,
                                          isGroup: true,
                                        ).then((_) {
                                          _reloadTrigger.value =
                                              !_reloadTrigger.value;
                                        });
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => GroupChatScreen(
                                              chatId: chatId,
                                              currentUser: widget.currentUser,
                                              authenticatedUser:
                                                  widget.currentUser,
                                              accentColor: widget.accentColor,
                                            ),
                                          ),
                                        );
                                      },
                                      onLongPress: () {
                                        controller.selectedChatId = chatId;
                                        controller.selectedOtherUser = null;
                                        controller.isGroup = true;
                                      },
                                      onChatOpened: () {
                                        _reloadTrigger.value =
                                            !_reloadTrigger.value;
                                      },
                                    );
                                  }

                                  final otherUser = chatInfo.otherUser;
                                  if (otherUser == null)
                                    return const SizedBox();

                                  return ChatTile(
                                    isGroup: false,
                                    chatId: chatId,
                                    title: otherUser['username'] ?? 'Unknown',
                                    lastMessage: lastMessage,
                                    timestamp: timestamp,
                                    unreadCount: unreadCount,
                                    photoUrl: otherUser['photoUrl'] ?? '',
                                    accentColor: widget.accentColor,
                                    isSelected:
                                        chatId == controller.selectedChatId,
                                    isBlocked: controller
                                        .isUserBlocked(otherUser['id']),
                                    controller: controller,
                                    onTap: controller
                                            .isUserBlocked(otherUser['id'])
                                        ? null
                                        : () {
                                            controller.clearSelection();
                                            MessageStatusUtils.markAsRead(
                                              chatId: chatId,
                                              userId: currentUserId,
                                              isGroup: false,
                                            ).then((_) {
                                              _reloadTrigger.value =
                                                  !_reloadTrigger.value;
                                            });
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) => ChatScreen(
                                                  chatId: chatId,
                                                  currentUser:
                                                      widget.currentUser,
                                                  otherUser: otherUser,
                                                  authenticatedUser:
                                                      widget.currentUser,
                                                  storyInteractions: const [],
                                                  accentColor:
                                                      widget.accentColor,
                                                ),
                                              ),
                                            );
                                          },
                                    onLongPress: () {
                                      controller.selectedChatId = chatId;
                                      controller.selectedOtherUser = otherUser;
                                      controller.isGroup = false;
                                    },
                                    onChatOpened: () {
                                      _reloadTrigger.value =
                                          !_reloadTrigger.value;
                                    },
                                  );
                                },
                              );
                            },
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
