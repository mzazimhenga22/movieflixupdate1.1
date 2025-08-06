import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'messages_controller.dart';
import 'chat_screen.dart';
import 'Group_chat_screen.dart';
import 'widgets/mark_read_unread.dart';
import 'chat_tile.dart';
import 'dart:convert';

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
  final String docId;
  final Map<String, dynamic> docData;
  final DocumentSnapshot<Map<String, dynamic>>? snapshot;
  final int unreadCount;
  final Map<String, dynamic>? otherUser;
  final Map<String, dynamic>? lastMessageData;

  ChatInfo({
    required this.docId,
    required this.docData,
    this.snapshot,
    required this.unreadCount,
    this.otherUser,
    this.lastMessageData,
  });

  factory ChatInfo.fromCache(Map<String, dynamic> item) {
    try {
      return ChatInfo(
        docId: item['docId'] as String? ?? '',
        docData: Map<String, dynamic>.from(item['docData'] as Map? ?? {}),
        unreadCount: (item['unreadCount'] is int) ? item['unreadCount'] as int : 0,
        otherUser: item['otherUser'] != null
            ? Map<String, dynamic>.from(item['otherUser'] as Map)
            : null,
        lastMessageData: item['lastMessageData'] != null
            ? Map<String, dynamic>.from(item['lastMessageData'] as Map)
            : null,
      );
    } catch (e) {
      debugPrint('Error parsing cached ChatInfo: $e');
      return ChatInfo(
        docId: '',
        docData: {},
        unreadCount: 0,
        otherUser: null,
        lastMessageData: null,
      );
    }
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
  MessagesScreenState createState() => MessagesScreenState();
}

class MessagesScreenState extends State<MessagesScreen>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late TabController _tabController;
  bool isExpanded = true;
  late ValueNotifier<bool> _reloadTrigger;
  late MessagesController controller;
  final int _pageSize = 20;
  bool _isLoadingMore = false;
  Map<String, ChatInfo> _cachedChats = {};

  @override
  void initState() {
    super.initState();
    controller = MessagesController(widget.currentUser, context);
    _tabController = TabController(length: 3, vsync: this);
    _reloadTrigger = ValueNotifier<bool>(false);
    _scrollController.addListener(() {
      if (mounted) {
        setState(() => isExpanded = _scrollController.offset <= 100);
        if (_scrollController.position.extentAfter < 200 && !_isLoadingMore) {
          _loadMoreChats();
        }
      }
    });

    _loadCachedChats();
    FirebaseFirestore.instance
        .collection('chats')
        .where('userIds', arrayContains: widget.currentUser['id'])
        .snapshots()
        .listen((_) => _reloadTrigger.value = !_reloadTrigger.value);
    FirebaseFirestore.instance
        .collection('groups')
        .where('userIds', arrayContains: widget.currentUser['id'])
        .snapshots()
        .listen((_) => _reloadTrigger.value = !_reloadTrigger.value);
  }

  /// Converts either a Firestore [Timestamp] or a cached [int] (ms since epoch)
  /// into a Dart [DateTime].
  DateTime _parseTimestamp(dynamic ts) {
    if (ts is Timestamp) {
      return ts.toDate();
    } else if (ts is int) {
      return DateTime.fromMillisecondsSinceEpoch(ts);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> _loadCachedChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString('chats_${widget.currentUser['id']}');
      if (cachedJson == null) return;

      final List<dynamic> list = jsonDecode(cachedJson);
      setState(() {
        _cachedChats = {
          for (var item in list)
            item['docId'] as String: ChatInfo.fromCache(item),
        };
      });
    } catch (e) {
      debugPrint('Error loading cached chats: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load cached chats')),
        );
      }
    }
  }

  Future<void> _cacheChats(List<ChatInfo> chats) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<Map<String, dynamic>> toCache = chats.map((c) {
        final docData = Map<String, dynamic>.from(c.docData);
        // Convert Timestamp to milliseconds for JSON serialization
        if (docData['timestamp'] is Timestamp) {
          docData['timestamp'] = (docData['timestamp'] as Timestamp).millisecondsSinceEpoch;
        }
        final lastMessageData = c.lastMessageData != null
            ? Map<String, dynamic>.from(c.lastMessageData!)
            : null;
        if (lastMessageData != null && lastMessageData['timestamp'] is Timestamp) {
          lastMessageData['timestamp'] = (lastMessageData['timestamp'] as Timestamp).millisecondsSinceEpoch;
        }
        return {
          'docId': c.docId,
          'docData': docData,
          'unreadCount': c.unreadCount,
          'otherUser': c.otherUser,
          'lastMessageData': lastMessageData,
        };
      }).toList();

      await prefs.setString(
        'chats_${widget.currentUser['id']}',
        jsonEncode(toCache),
      );
    } catch (e) {
      debugPrint('Error caching chats: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to cache chats')),
        );
      }
    }
  }

  Future<List<ChatInfo>> fetchChatsAndGroups(
    String userId,
    String tab, {
    DocumentSnapshot? lastDoc,
  }) async {
    try {
      // Set query timeout (10 seconds)
      final timeout = const Duration(seconds: 10);
      Query<Map<String, dynamic>> chatsQuery = FirebaseFirestore.instance
          .collection('chats')
          .where('userIds', arrayContains: userId)
          .orderBy('timestamp', descending: true)
          .limit(_pageSize);

      Query<Map<String, dynamic>> groupsQuery = FirebaseFirestore.instance
          .collection('groups')
          .where('userIds', arrayContains: userId)
          .orderBy('timestamp', descending: true)
          .limit(_pageSize);

      if (lastDoc != null) {
        chatsQuery = chatsQuery.startAfterDocument(lastDoc);
        groupsQuery = groupsQuery.startAfterDocument(lastDoc);
      }

      final chatsSnapshot = await chatsQuery.get().timeout(timeout);
      final groupsSnapshot = await groupsQuery.get().timeout(timeout);

      final combined = [...chatsSnapshot.docs, ...groupsSnapshot.docs].where((doc) {
        final deletedBy = List<String>.from(doc.data()['deletedBy'] ?? []);
        return !deletedBy.contains(userId);
      }).toList();

      if (tab == 'Unread') {
        final unreadOnly = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
        for (var doc in combined) {
          final isGroup = doc.data()['isGroup'] ?? false;
          if (await MessageStatusUtils.isUnread(
            chatId: doc.id,
            userId: userId,
            isGroup: isGroup,
          )) {
            unreadOnly.add(doc);
          }
        }
        combined
          ..clear()
          ..addAll(unreadOnly);
      } else if (tab == 'Favorites') {
        combined.retainWhere((doc) => doc.data()['isFavorite'] == true);
      }

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get()
          .timeout(timeout);
      final pinnedChats = List<String>.from(userDoc.get('pinnedChats') ?? []);

      combined.sort((a, b) {
        final aTime = _parseTimestamp(a.data()['timestamp']);
        final bTime = _parseTimestamp(b.data()['timestamp']);
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

        // Fetch last message
        Map<String, dynamic>? lastMessageData;
        final msgsSnap = await FirebaseFirestore.instance
            .collection(isGroup ? 'groups' : 'chats')
            .doc(chatId)
            .collection('messages')
            .orderBy('timestamp', descending: true)
            .limit(1)
            .get()
            .timeout(timeout);
        if (msgsSnap.docs.isNotEmpty) {
          lastMessageData = msgsSnap.docs.first.data();
        }

        // Compute unread count (check all unread messages)
        final unreadCount = await FirebaseFirestore.instance
            .collection(isGroup ? 'groups' : 'chats')
            .doc(chatId)
            .collection('messages')
            .where('readBy', arrayContains: userId, isEqualTo: false)
            .count()
            .get()
            .timeout(timeout)
            .then((res) => res.count ?? 0);

        // Fetch otherUser for 1-1 chats
        Map<String, dynamic>? otherUser;
        if (!isGroup) {
          final otherId = (data['userIds'] as List<dynamic>?)?.firstWhere(
            (id) => id != userId,
            orElse: () => null,
          );
          if (otherId != null) {
            final u = await FirebaseFirestore.instance
                .collection('users')
                .doc(otherId)
                .get()
                .timeout(timeout);
            if (u.exists) {
              otherUser = u.data()!..['id'] = u.id;
            }
          }
        }

        chatInfoList.add(ChatInfo(
          docId: chatId,
          docData: data,
          snapshot: doc,
          unreadCount: unreadCount,
          otherUser: otherUser,
          lastMessageData: lastMessageData,
        ));
      }

      _cachedChats.addAll({for (var chat in chatInfoList) chat.docId: chat});
      await _cacheChats(chatInfoList);
      return chatInfoList;
    } catch (e) {
      debugPrint('Error fetching chats: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to fetch chats')),
        );
      }
      return _cachedChats.values.toList();
    }
  }

  Future<void> _loadMoreChats() async {
    if (_isLoadingMore) return;
    setState(() => _isLoadingMore = true);

    try {
      final lastSnapshot = _cachedChats.values.isNotEmpty
          ? _cachedChats.values.last.snapshot
          : null;

      final newChats = await fetchChatsAndGroups(
        widget.currentUser['id'],
        _tabController.index == 0
            ? 'All'
            : _tabController.index == 1
                ? 'Unread'
                : 'Favorites',
        lastDoc: lastSnapshot,
      );

      setState(() {
        _cachedChats.addAll({for (var chat in newChats) chat.docId: chat});
        _isLoadingMore = false;
      });
    } catch (e) {
      debugPrint('Error loading more chats: $e');
      setState(() => _isLoadingMore = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load more chats')),
        );
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _tabController.dispose();
    _reloadTrigger.dispose();
    super.dispose();
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
                              debugPrint("No user or chat selected.");
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
                              debugPrint("No chat selected");
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
                            _reloadTrigger.value = !_reloadTrigger.value;
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
                            future: fetchChatsAndGroups(currentUserId, tab,
                                lastDoc: null),
                            builder: (context, snapshot) {
                              if (snapshot.connectionState ==
                                      ConnectionState.waiting &&
                                  _cachedChats.isEmpty) {
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

                              final chats =
                                  snapshot.data ?? _cachedChats.values.toList();
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
                                itemCount:
                                    chats.length + (_isLoadingMore ? 1 : 0),
                                itemBuilder: (context, index) {
                                  if (index == chats.length && _isLoadingMore) {
                                    return const Center(
                                      child: CircularProgressIndicator(),
                                    );
                                  }

                                  final chatInfo = chats[index];
                                  final data = chatInfo.docData;
                                  final chatId = chatInfo.docId;
                                  final isGroup = data['isGroup'] ?? false;

                                  final lastMessageData =
                                      chatInfo.lastMessageData;
                                  String lastMessage = 'No messages yet';
                                  if (lastMessageData != null) {
                                    lastMessage =
                                        lastMessageData['text'] ?? 'Media';
                                    if (lastMessageData['forwardedFrom'] !=
                                        null) {
                                      lastMessage =
                                          'Forwarded: ${lastMessageData['text'] ?? 'Media'}';
                                    }
                                  }
                                  final timestamp = _parseTimestamp(
                                      lastMessageData?['timestamp'] ??
                                          data['timestamp']);

                                  if (isGroup) {
                                    return ChatTile(
                                      isGroup: true,
                                      chatId: chatId,
                                      title: data['name'] ?? 'Group Chat',
                                      lastMessage: lastMessage,
                                      timestamp: timestamp,
                                      unreadCount: chatInfo.unreadCount,
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
                                              forwardedMessage: lastMessageData?[
                                                          'forwardedFrom'] !=
                                                      null
                                                  ? lastMessageData
                                                  : null,
                                            ),
                                          ),
                                        );
                                      },
                                      onLongPress: () {
                                        controller.selectedChatId = chatId;
                                        controller.selectedOtherUser = null;
                                        controller.isGroup = true;
                                        _reloadTrigger.value =
                                            !_reloadTrigger.value;
                                      },
                                      onChatOpened: () {
                                        _reloadTrigger.value =
                                            !_reloadTrigger.value;
                                      },
                                    );
                                  }

                                  final otherUser = chatInfo.otherUser;
                                  if (otherUser == null) {
                                    return const SizedBox();
                                  }

                                  return ChatTile(
                                    isGroup: false,
                                    chatId: chatId,
                                    title: otherUser['username'] ?? 'Unknown',
                                    lastMessage: lastMessage,
                                    timestamp: timestamp,
                                    unreadCount: chatInfo.unreadCount,
                                    photoUrl: otherUser['photoUrl'] ?? '',
                                    accentColor: widget.accentColor,
                                    isSelected:
                                        chatId == controller.selectedChatId,
                                    isBlocked: controller
                                        .isUserBlocked(otherUser['id'] ?? ''),
                                    controller: controller,
                                    onTap: controller
                                            .isUserBlocked(otherUser['id'] ?? '')
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
                                                  forwardedMessage:
                                                      lastMessageData?[
                                                                  'forwardedFrom'] !=
                                                              null
                                                          ? lastMessageData
                                                          : null,
                                                ),
                                              ),
                                            );
                                          },
                                    onLongPress: () {
                                      controller.selectedChatId = chatId;
                                      controller.selectedOtherUser = otherUser;
                                      controller.isGroup = false;
                                      _reloadTrigger.value =
                                          !_reloadTrigger.value;
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