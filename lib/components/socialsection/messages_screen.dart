import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'messages_controller.dart';
import 'chat_screen.dart';
import 'Group_chat_screen.dart';
import 'widgets/mark_read_unread.dart';
import 'chat_tile.dart';
import 'forward_message_screen.dart';

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
  final int unreadCount;
  final Map<String, dynamic>? otherUser;
  final Map<String, dynamic>? lastMessageData;
  final DocumentSnapshot<Map<String, dynamic>>? snapshot;

  ChatInfo({
    required this.docId,
    required this.docData,
    required this.unreadCount,
    this.otherUser,
    this.lastMessageData,
    this.snapshot,
  });

  factory ChatInfo.fromCache(Map<String, dynamic> item) {
    try {
      // validate docId exists and is a non-empty string
      final docId = (item['docId'] as String?) ?? '';
      if (docId.isEmpty) {
        throw FormatException('cached entry missing docId');
      }

      // Convert integer timestamps back to DateTime-friendly values remain ints,
      // callers convert them via _parseTimestamp.
      final docData = Map<String, dynamic>.from(item['docData'] as Map? ?? {});
      final lastMessageData = item['lastMessageData'] != null
          ? Map<String, dynamic>.from(item['lastMessageData'] as Map)
          : null;

      return ChatInfo(
        docId: docId,
        docData: docData,
        unreadCount:
            (item['unreadCount'] is int) ? item['unreadCount'] as int : 0,
        otherUser: item['otherUser'] != null
            ? Map<String, dynamic>.from(item['otherUser'] as Map)
            : null,
        lastMessageData: lastMessageData,
        snapshot: null,
      );
    } catch (e, st) {
      debugPrint('Error parsing cached ChatInfo: $e\n$st');
      return ChatInfo(
        docId: '',
        docData: {},
        unreadCount: 0,
        otherUser: null,
        lastMessageData: null,
        snapshot: null,
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
  final ValueNotifier<bool> _isExpandedNotifier = ValueNotifier<bool>(true);
  late ValueNotifier<bool> _reloadTrigger;
  late MessagesController controller;
  final int _pageSize = 20;
  bool _isLoadingMore = false;
  final Map<String, ChatInfo> _cachedChats = {};
  bool _initialLoadDone = false;

  @override
  void initState() {
    super.initState();
    controller = MessagesController(widget.currentUser, context);
    _tabController = TabController(length: 3, vsync: this);
    _reloadTrigger = ValueNotifier<bool>(false);

    // Scroll listener: update only the small expanded/not-expanded state via ValueNotifier,
    // avoid calling setState repeatedly.
    _scrollController.addListener(() {
      final newExpanded = _scrollController.offset <= 100;
      if (_isExpandedNotifier.value != newExpanded) {
        _isExpandedNotifier.value = newExpanded;
      }

      // Trigger load more when close to bottom
      if (_scrollController.position.extentAfter < 200 && !_isLoadingMore) {
        _loadMoreChats();
      }
    });

    _loadCachedChats().whenComplete(() {
      // If cache loaded, mark initial done; the UI will use cache while fetching fresh data
      _initialLoadDone = true;
      // Listen to collections and flip reload trigger on changes
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
    });
  }

  /// Convert Timestamp/int to DateTime (safe)
  DateTime _parseTimestamp(dynamic ts) {
    if (ts is Timestamp) return ts.toDate();
    if (ts is int) return DateTime.fromMillisecondsSinceEpoch(ts);
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Sanitize a value so it's JSON-serializable for caching.
  dynamic _sanitizeForCache(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.millisecondsSinceEpoch;
    if (value is DateTime) return value.millisecondsSinceEpoch;
    if (value is num || value is String || value is bool) return value;
    if (value is GeoPoint) {
      return {'__geo__': true, 'lat': value.latitude, 'lng': value.longitude};
    }
    // DocumentReference can be represented by its path
    if (value is DocumentReference) {
      return {'__ref__': value.path};
    }
    if (value is Map) {
      final out = <String, dynamic>{};
      (value as Map).forEach((k, v) {
        out[k.toString()] = _sanitizeForCache(v);
      });
      return out;
    }
    if (value is List) {
      return value.map((v) => _sanitizeForCache(v)).toList();
    }
    // fallback - stringify unknown types so jsonEncode won't crash
    try {
      return value.toString();
    } catch (_) {
      return null;
    }
  }

  /// Recursively convert Timestamp instances and other Firestore types in a Map to JSON-serializable values.
  Map<String, dynamic> _convertTimestampsForCache(Map<String, dynamic> map) {
    final out = <String, dynamic>{};
    map.forEach((k, v) {
      out[k] = _sanitizeForCache(v);
    });
    return out;
  }

  Future<void> _loadCachedChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString('chats_${widget.currentUser['id']}');
      if (cachedJson == null) return;

      final decoded = jsonDecode(cachedJson);
      if (decoded is! List) {
        debugPrint('[loadCachedChats] cached payload is not a List');
        return;
      }
      final List<dynamic> list = decoded;
      for (var item in list) {
        try {
          if (item is! Map) {
            debugPrint('[loadCachedChats] skipped non-map cached item');
            continue;
          }
          final chat = ChatInfo.fromCache(Map<String, dynamic>.from(item as Map));
          if (chat.docId.isEmpty) {
            debugPrint('[loadCachedChats] skipped invalid cached chat entry (empty docId)');
            continue;
          }
          _cachedChats[chat.docId] = chat;
        } catch (e, st) {
          debugPrint('[loadCachedChats] failed parsing one cached item: $e\n$st');
        }
      }
      if (mounted) setState(() {}); // initial render with cache
      debugPrint('[loadCachedChats] loaded ${_cachedChats.length} cached chats');
    } catch (e, st) {
      debugPrint('Error loading cached chats: $e\n$st');
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
        final serializableDocData = _convertTimestampsForCache(docData);

        final lastMessageData = c.lastMessageData != null
            ? Map<String, dynamic>.from(c.lastMessageData!)
            : null;
        final serializableLast = lastMessageData != null
            ? _convertTimestampsForCache(lastMessageData)
            : null;

        final otherUser = c.otherUser != null
            ? Map<String, dynamic>.from(c.otherUser!)
            : null;

        return {
          'docId': c.docId,
          'docData': serializableDocData,
          'unreadCount': c.unreadCount,
          'otherUser': otherUser,
          'lastMessageData': serializableLast,
        };
      }).toList();

      final encoded = jsonEncode(toCache);
      debugPrint('[cacheChats] serialised ${toCache.length} chats, size=${encoded.length} bytes');

      // safety guard — warn if cache is getting large
      if (encoded.length > 500000) {
        debugPrint('[cacheChats] WARNING: cache size > 500KB; consider using Hive/sqflite or trimming stored fields');
      }

      await prefs.setString('chats_${widget.currentUser['id']}', encoded);
      debugPrint('[cacheChats] saved cache for user ${widget.currentUser['id']}');
    } catch (e, st) {
      debugPrint('Error caching chats: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to cache chats')),
        );
      }
    }
  }

  /// Fetch chat and group documents and produce ChatInfo list.
  /// NOTE: we avoid expensive per-chat counts and use doc fields like 'unreadCount' or 'unreadBy' when available.
  Future<List<ChatInfo>> fetchChatsAndGroups(String userId, String tab,
      {DocumentSnapshot? lastDoc}) async {
    try {
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

      // Run both queries in parallel
      final results = await Future.wait([
        chatsQuery.get().timeout(timeout),
        groupsQuery.get().timeout(timeout)
      ]);
      final chatsSnapshot = results[0];
      final groupsSnapshot = results[1];

      final combined = <QueryDocumentSnapshot<Map<String, dynamic>>>[
        ...chatsSnapshot.docs,
        ...groupsSnapshot.docs,
      ].where((doc) {
        final deletedBy = List<String>.from(doc.data()['deletedBy'] ?? []);
        return !deletedBy.contains(userId);
      }).toList();

      // If a simple 'Unread' or 'Favorites' filter is requested, try to filter using doc metadata (avoid heavy queries)
      if (tab == 'Unread') {
        combined.retainWhere((doc) {
          final data = doc.data();
          if (data.containsKey('unreadCount')) {
            return (data['unreadCount'] as int? ?? 0) > 0;
          } else if (data.containsKey('unreadBy')) {
            final unreadBy = List<dynamic>.from(data['unreadBy'] ?? []);
            return unreadBy.contains(userId);
          }
          // fallback conservative: include docs and let MessageStatusUtils determine per-chat in UI if necessary
          return true;
        });
      } else if (tab == 'Favorites') {
        combined.retainWhere((doc) => doc.data()['isFavorite'] == true);
      }

      // Try to fetch user's pinned chats once
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get()
          .timeout(timeout);
      final pinnedChats =
          List<String>.from(userDoc.data()?['pinnedChats'] ?? []);

      // Sort: pinned first then by timestamp
      combined.sort((a, b) {
        final aTime = _parseTimestamp(a.data()['timestamp']);
        final bTime = _parseTimestamp(b.data()['timestamp']);
        final aPinned = pinnedChats.contains(a.id);
        final bPinned = pinnedChats.contains(b.id);
        if (aPinned && !bPinned) return -1;
        if (!aPinned && bPinned) return 1;
        return bTime.compareTo(aTime);
      });

      // Build ChatInfo list. We fetch lastMessage in parallel for all docs (still limited by network).
      final chatInfoList = <ChatInfo>[];
      final lastMessageFutures = combined.map((doc) {
        final isGroup = doc.data()['isGroup'] ?? false;
        final ref = FirebaseFirestore.instance
            .collection(isGroup ? 'groups' : 'chats')
            .doc(doc.id)
            .collection('messages');
        return ref
            .orderBy('timestamp', descending: true)
            .limit(1)
            .get()
            .timeout(timeout);
      }).toList();

      final lastMessagesSnapshots = await Future.wait(lastMessageFutures);

      // Build results using available doc fields for unread counts (avoid expensive counting queries)
      for (int i = 0; i < combined.length; i++) {
        final doc = combined[i];
        final data = doc.data();
        final isGroup = data['isGroup'] ?? false;
        final chatId = doc.id;

        Map<String, dynamic>? lastMessageData;
        final msgsSnap = lastMessagesSnapshots[i];
        if (msgsSnap.docs.isNotEmpty) lastMessageData = msgsSnap.docs.first.data();

        // Prefer doc metadata for unreadCount, otherwise default to 0
        int unreadCount = 0;
        if (data.containsKey('unreadCount')) {
          unreadCount = (data['unreadCount'] as int?) ?? 0;
        } else if (data.containsKey('unreadBy')) {
          unreadCount = (data['unreadBy'] as List?)?.length ?? 0;
        } else {
          // Avoid expensive per-chat counting query; fallback to 0
          unreadCount = 0;
        }

        // For 1-1 chats, attempt to fetch the other user quickly (no heavy ops)
        Map<String, dynamic>? otherUser;
        if (!isGroup) {
          final otherId = (data['userIds'] as List<dynamic>?)
              ?.firstWhere((id) => id != userId, orElse: () => null);
          if (otherId != null) {
            try {
              final u = await FirebaseFirestore.instance
                  .collection('users')
                  .doc(otherId)
                  .get()
                  .timeout(timeout);
              if (u.exists) {
                otherUser = Map<String, dynamic>.from(u.data()!);
                otherUser['id'] = u.id;
              }
            } catch (_) {
              // if fetching other user fails, continue with null otherUser (UI shows fallback)
            }
          }
        }

        chatInfoList.add(ChatInfo(
          docId: chatId,
          docData: data,
          unreadCount: unreadCount,
          otherUser: otherUser,
          lastMessageData: lastMessageData,
          snapshot: doc,
        ));
      }

      // Update in-memory cache and persist
      for (var c in chatInfoList) {
        _cachedChats[c.docId] = c;
      }
      await _cacheChats(chatInfoList);

      return chatInfoList;
    } catch (e, st) {
      debugPrint('Error fetching chats: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to fetch chats')),
        );
      }
      // Return what we have in cache (freshest in-memory)
      return _cachedChats.values.toList();
    }
  }

  Future<void> _loadMoreChats() async {
    if (_isLoadingMore) return;
    _isLoadingMore = true;
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

      if (newChats.isNotEmpty) {
        for (var c in newChats) {
          _cachedChats[c.docId] = c;
        }
      }

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Error loading more chats: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load more chats')),
        );
      }
    } finally {
      _isLoadingMore = false;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _tabController.dispose();
    _reloadTrigger.dispose();
    _isExpandedNotifier.dispose();
    super.dispose();
  }

  /// Show bottom sheet with actions when a chat is selected via long press.
  Future<void> _showSelectionActions({
    required String chatId,
    Map<String, dynamic>? otherUser,
    required bool isGroup,
  }) async {
    controller.selectedChatId = chatId;
    controller.selectedOtherUser = otherUser;
    controller.isGroup = isGroup;
    _reloadTrigger.value = !_reloadTrigger.value;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12.0),
            child: Wrap(
              alignment: WrapAlignment.center,
              children: [
                ListTile(
                  leading: Icon(Icons.block, color: widget.accentColor),
                  title: const Text('Block',
                      style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.pop(context);
                    if (otherUser != null) {
                      await controller.blockUser();
                    }
                    _reloadTrigger.value = !_reloadTrigger.value;
                  },
                ),
                ListTile(
                  leading: Icon(Icons.delete, color: widget.accentColor),
                  title: Text(isGroup ? 'Leave Group' : 'Delete Conversation',
                      style: const TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.pop(context);
                    await controller.deleteConversation();
                    controller.clearSelection();
                    _reloadTrigger.value = !_reloadTrigger.value;
                  },
                ),
                ListTile(
                  leading: Icon(Icons.push_pin, color: widget.accentColor),
                  title: const Text('Pin / Unpin',
                      style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.pop(context);
                    final isPinned = controller.selectedChatId != null &&
                        controller.isChatPinned(controller.selectedChatId!);
                    if (isPinned) {
                      await controller.unpinConversation();
                    } else {
                      await controller.pinConversation();
                    }
                    controller.clearSelection();
                    _reloadTrigger.value = !_reloadTrigger.value;
                  },
                ),
                ListTile(
                  leading: Icon(Icons.volume_off, color: widget.accentColor),
                  title: const Text('Mute / Unmute',
                      style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.pop(context);
                    final other = controller.selectedOtherUser;
                    if (other != null) {
                      final isMuted = controller.isUserMuted(other['id']);
                      if (isMuted) {
                        await controller.unmuteUser();
                      } else {
                        await controller.muteUser();
                      }
                    } else {
                      final isMuted =
                          controller.isUserMuted(controller.selectedChatId!);
                      if (isMuted) {
                        await controller.unmuteGroup();
                      } else {
                        await controller.muteGroup();
                      }
                    }
                    controller.clearSelection();
                    _reloadTrigger.value = !_reloadTrigger.value;
                  },
                ),
                ListTile(
                  leading: Icon(Icons.forward, color: widget.accentColor),
                  title: const Text('Forward',
                      style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.pop(context);
                    // open forward screen
                    await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ForwardMessageScreen()));
                    controller.clearSelection();
                    _reloadTrigger.value = !_reloadTrigger.value;
                  },
                ),
                ListTile(
                  leading: Icon(Icons.close, color: widget.accentColor),
                  title: const Text('Cancel',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    controller.clearSelection();
                    _reloadTrigger.value = !_reloadTrigger.value;
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = widget.currentUser['id'];

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: Stack(children: [
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
                title: ValueListenableBuilder<bool>(
                  valueListenable: _isExpandedNotifier,
                  builder: (context, expanded, _) {
                    return expanded
                        ? const SizedBox.shrink()
                        : Text(
                            'Messages',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: widget.accentColor,
                            ),
                          );
                  },
                ),
                centerTitle: true,
                background: ValueListenableBuilder<bool>(
                  valueListenable: _isExpandedNotifier,
                  builder: (context, expanded, _) {
                    return expanded
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
                        : const SizedBox.shrink();
                  },
                ),
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
              actions: [
                // App bar actions that use controller state — wrapped in ValueListenableBuilder where appropriate.
                ValueListenableBuilder<bool>(
                  valueListenable: _reloadTrigger,
                  builder: (context, _, __) {
                    // Show nothing if no selection
                    if (controller.selectedChatId == null)
                      return const SizedBox.shrink();

                    final otherUser = controller.selectedOtherUser;
                    final chatId = controller.selectedChatId;

                    // For blocked state we use a FutureBuilder because it may be async
                    return Row(
                      children: [
                        FutureBuilder<bool>(
                          future: otherUser != null
                              ? controller.isUserBlockedAsync(otherUser['id'])
                              : Future.value(false),
                          builder: (context, snap) {
                            final isBlocked = snap.data ?? false;
                            return IconButton(
                              icon: Icon(
                                  isBlocked ? Icons.lock_open : Icons.block,
                                  color: widget.accentColor),
                              onPressed: () async {
                                if (otherUser != null) {
                                  if (isBlocked) {
                                    await controller.unblockUser();
                                  } else {
                                    await controller.blockUser();
                                  }
                                }
                                _reloadTrigger.value = !_reloadTrigger.value;
                              },
                              tooltip:
                                  isBlocked ? 'Unblock User' : 'Block User',
                            );
                          },
                        ),
                        FutureBuilder<bool>(
                          future: Future.value(otherUser != null
                              ? controller.isUserMuted(otherUser['id'])
                              : controller.isUserMuted(chatId ?? '')),
                          builder: (context, snap) {
                            final isMuted = snap.data ?? false;
                            return IconButton(
                              icon: Icon(
                                  isMuted ? Icons.volume_up : Icons.volume_off,
                                  color: widget.accentColor),
                              onPressed: () async {
                                if (otherUser != null) {
                                  if (isMuted)
                                    await controller.unmuteUser();
                                  else
                                    await controller.muteUser();
                                } else {
                                  if (isMuted)
                                    await controller.unmuteGroup();
                                  else
                                    await controller.muteGroup();
                                }
                                _reloadTrigger.value = !_reloadTrigger.value;
                              },
                              tooltip: isMuted ? 'Unmute' : 'Mute',
                            );
                          },
                        ),
                        IconButton(
                          icon: Icon(
                              controller.selectedChatId != null &&
                                      controller.isChatPinned(
                                          controller.selectedChatId!)
                                  ? Icons.push_pin_outlined
                                  : Icons.push_pin,
                              color: widget.accentColor),
                          onPressed: () async {
                            if (controller.selectedChatId == null) return;
                            final pinned = controller
                                .isChatPinned(controller.selectedChatId!);
                            if (pinned)
                              await controller.unpinConversation();
                            else
                              await controller.pinConversation();
                            _reloadTrigger.value = !_reloadTrigger.value;
                          },
                          tooltip: controller.selectedChatId != null &&
                                  controller
                                      .isChatPinned(controller.selectedChatId!)
                              ? 'Unpin Conversation'
                              : 'Pin Conversation',
                        ),
                        IconButton(
                          icon: Icon(Icons.delete, color: widget.accentColor),
                          onPressed: () async {
                            await controller.deleteConversation();
                            controller.clearSelection();
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
                      ],
                    );
                  },
                ),
              ],
            ),
            SliverFillRemaining(
              child: TabBarView(
                controller: _tabController,
                children: ['All', 'Unread', 'Favorites'].map((tab) {
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: widget.accentColor.withOpacity(0.1)),
                      ),
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _reloadTrigger,
                        builder: (context, _, __) {
                          return FutureBuilder<List<ChatInfo>>(
                            future: fetchChatsAndGroups(currentUserId, tab,
                                lastDoc: null),
                            builder: (context, snapshot) {
                              final isWaiting = snapshot.connectionState ==
                                  ConnectionState.waiting;
                              final chats =
                                  snapshot.data ?? _cachedChats.values.toList();

                              if (isWaiting && chats.isEmpty) {
                                // skeleton loaders
                                return ListView.builder(
                                  padding: const EdgeInsets.all(16.0),
                                  itemCount: 5,
                                  itemBuilder: (context, index) => Card(
                                    elevation: 4,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                    margin:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    child: ListTile(
                                      leading: CircleAvatar(
                                          backgroundColor:
                                              Colors.black.withOpacity(0.3)),
                                      title: Container(
                                          height: 16, color: Colors.grey[800]),
                                      subtitle: Container(
                                          height: 12,
                                          margin: const EdgeInsets.only(top: 4),
                                          color: Colors.grey[800]),
                                      trailing: Container(
                                          width: 50,
                                          height: 12,
                                          color: Colors.grey[800]),
                                    ),
                                  ),
                                );
                              }

                              if (chats.isEmpty) {
                                return const Center(
                                    child: Text("No conversations yet.",
                                        style:
                                            TextStyle(color: Colors.white70)));
                              }

                              return ListView.builder(
                                padding: const EdgeInsets.all(16.0),
                                itemCount:
                                    chats.length + (_isLoadingMore ? 1 : 0),
                                itemBuilder: (context, index) {
                                  if (index == chats.length && _isLoadingMore) {
                                    return const Center(
                                        child: CircularProgressIndicator());
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
                                                isGroup: true)
                                            .then((_) {
                                          _reloadTrigger.value =
                                              !_reloadTrigger.value;
                                        });
                                        Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                                builder: (_) => GroupChatScreen(
                                                      chatId: chatId,
                                                      currentUser:
                                                          widget.currentUser,
                                                      authenticatedUser:
                                                          widget.currentUser,
                                                      accentColor:
                                                          widget.accentColor,
                                                      forwardedMessage:
                                                          lastMessageData?[
                                                                      'forwardedFrom'] !=
                                                                  null
                                                              ? lastMessageData
                                                              : null,
                                                    )));
                                      },
                                      onLongPress: () {
                                        // Show actions sheet immediately for user feedback
                                        _showSelectionActions(
                                            chatId: chatId,
                                            otherUser: null,
                                            isGroup: true);
                                      },
                                      onChatOpened: () {
                                        _reloadTrigger.value =
                                            !_reloadTrigger.value;
                                      },
                                    );
                                  }

                                  final otherUser = chatInfo.otherUser;
                                  if (otherUser == null) return const SizedBox();

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
                                    onTap: controller.isUserBlocked(
                                            otherUser['id'] ?? '')
                                        ? null
                                        : () {
                                            controller.clearSelection();
                                            MessageStatusUtils.markAsRead(
                                                    chatId: chatId,
                                                    userId: currentUserId,
                                                    isGroup: false)
                                                .then((_) {
                                              _reloadTrigger.value =
                                                  !_reloadTrigger.value;
                                            });
                                            Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                    builder: (_) => ChatScreen(
                                                          chatId: chatId,
                                                          currentUser: widget
                                                              .currentUser,
                                                          otherUser: otherUser,
                                                          authenticatedUser:
                                                              widget
                                                                  .currentUser,
                                                          storyInteractions: const [],
                                                          accentColor: widget
                                                              .accentColor,
                                                          forwardedMessage:
                                                              lastMessageData?[
                                                                          'forwardedFrom'] !=
                                                                      null
                                                                  ? lastMessageData
                                                                  : null,
                                                        )));
                                          },
                                    onLongPress: () {
                                      // Show actions sheet immediately for user feedback
                                      _showSelectionActions(
                                          chatId: chatId,
                                          otherUser: otherUser,
                                          isGroup: false);
                                    },
                                    onChatOpened: () {
                                      _reloadTrigger.value =
                                          !_reloadTrigger.value;
                                    },
                                  );
                                },
                              );
                            },
                          );
                        },
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ]),
      floatingActionButton: FloatingActionButton(
        onPressed: controller.showChatCreationOptions,
        backgroundColor: widget.accentColor,
        child: const Icon(Icons.chat, color: Colors.white),
      ),
    );
  }
}
