// messages_screen.dart
import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, compute, setEquals;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'messages_controller.dart';
import 'chat_screen.dart';
import 'Group_chat_screen.dart';
import 'chat_tile.dart';
import 'forward_message_screen.dart';
import 'package:movie_app/components/socialsection/stories.dart';
import 'package:movie_app/components/socialsection/social_reactions_screen.dart';
import 'post_review_screen.dart';

/// --- Top-level compute worker (unchanged) ---
List<Map<String, dynamic>> _processUserList(Map<String, dynamic> payload) {
  final raw = payload['raw'] as List<dynamic>? ?? [];
  final currentId = payload['currentId'] as String? ?? '';
  final blocked = (payload['blocked'] as List<dynamic>?)?.cast<String>() ?? [];

  final users = <Map<String, dynamic>>[];
  for (final r in raw) {
    if (r is Map) {
      final m = Map<String, dynamic>.from(r);
      final id = (m['id'] ?? '').toString();
      if (id.isEmpty) continue;
      users.add({
        'id': id,
        'username': (m['username'] ?? m['name'] ?? '')?.toString() ?? '',
        'photoUrl': (m['photoUrl'] ?? m['avatar'] ?? m['photo'] ?? '')?.toString(),
      });
    }
  }

  users.removeWhere((u) => u['id'] == currentId || blocked.contains(u['id']));
  users.sort((a, b) => (a['username'] as String).toLowerCase().compareTo((b['username'] as String).toLowerCase()));
  return users;
}

/// Story-like avatar with gradient ring.
class StoryAvatar extends StatelessWidget {
  final double size;
  final String? photoUrl;
  final String label;
  final bool hasStory;
  final Color accentColor;
  final VoidCallback? onTap;

  const StoryAvatar({
    super.key,
    required this.size,
    required this.label,
    required this.accentColor,
    this.photoUrl,
    this.hasStory = false,
    this.onTap,
  });

  ImageProvider? _imageProvider(String? url) {
    if (url == null || url.isEmpty) return null;
    if (kIsWeb || url.startsWith('http')) {
      return CachedNetworkImageProvider(url);
    } else {
      return FileImage(File(url));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ring = 5.0;
    final image = _imageProvider(photoUrl);
    return Semantics(
      label: 'Story avatar for $label',
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(alignment: Alignment.center, children: [
              if (hasStory)
                Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(
                      colors: [
                        accentColor,
                        accentColor.withOpacity(0.85),
                        Colors.blueAccent,
                        Colors.pinkAccent,
                      ],
                    ),
                  ),
                ),
              Container(
                width: size - (hasStory ? ring : 0),
                height: size - (hasStory ? ring : 0),
                decoration: const BoxDecoration(
                  color: Colors.black,
                  shape: BoxShape.circle,
                ),
                child: CircleAvatar(
                  radius: (size - (hasStory ? ring : 0)) / 2,
                  backgroundColor: Colors.grey.shade800,
                  backgroundImage: image,
                  child: image == null
                      ? Text(label.isNotEmpty ? label[0].toUpperCase() : 'U', style: const TextStyle(color: Colors.white))
                      : null,
                ),
              ),
            ]),
            const SizedBox(height: 6),
            SizedBox(
              width: size + 12,
              child: Text(label, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, maxLines: 1, style: const TextStyle(fontSize: 12, color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact shimmer-like skeleton used when lists are loading
class _SkeletonTile extends StatelessWidget {
  const _SkeletonTile({super.key});
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.grey.shade900,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: const SizedBox(
        height: 78,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              CircleAvatar(radius: 24, backgroundColor: Colors.grey),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: 12),
                    SizedBox(height: 10),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MessagesScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  final Color accentColor;

  const MessagesScreen({super.key, required this.currentUser, required this.accentColor});

  @override
  MessagesScreenState createState() => MessagesScreenState();
}

/// MessagesScreenState now observes app lifecycle to re-sync on resume.
class MessagesScreenState extends State<MessagesScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final ScrollController _scrollController = ScrollController();
  late TabController _tabController;
  late MessagesController controller;
  late Future<List<Map<String, dynamic>>>? _suggestedUsersFuture;
  List<Map<String, dynamic>> _lastSuggestedUsers = [];
  final Set<String> _openingChatIds = {};
  final Set<String> _usersWithActiveStories = {};
  // listen to both top-level stories and collectionGroup stories
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _storiesSubGroup;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _storiesSubTop;
  final ValueNotifier<bool> _rebuildNotifier = ValueNotifier(false);

  // Presence tracking
  final Map<String, bool> _onlineMap = {};
  final Map<String, DateTime?> _lastSeenMap = {};
  final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>> _userPresenceSubs = {};

  // conversation-level snapshot to trigger refresh when any convo changes server-side
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _conversationsSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    controller = MessagesController(widget.currentUser, context);
    controller.addListener(_onControllerUpdate);

    _tabController = TabController(length: 3, vsync: this);
    _suggestedUsersFuture = _fetchSuggestedUsers(limit: 6).then((list) {
      _lastSuggestedUsers = list;
      return list;
    });

    _scrollController.addListener(_onScroll);

    // Listen to BOTH a top-level 'stories' collection AND any subcollection named 'stories'
    // unify results into the same _usersWithActiveStories set.
    _storiesSubGroup = FirebaseFirestore.instance
        .collectionGroup('stories')
        .snapshots()
        .listen((snap) {
      _handleStoriesSnapshots(snap);
    }, onError: (e) {
      debugPrint('stories collectionGroup listener error: $e');
    });

    _storiesSubTop = FirebaseFirestore.instance
        .collection('stories')
        .snapshots()
        .listen((snap) {
      _handleStoriesSnapshots(snap);
    }, onError: (e) {
      debugPrint('stories top-level listener error: $e');
    });

    // conversations query - listen for any changes to conversations the user participates in
    try {
      final uid = widget.currentUser['id']?.toString();
      if (uid != null && uid.isNotEmpty) {
        _conversationsSub = FirebaseFirestore.instance
            .collection('conversations')
            .where('participants', arrayContains: uid)
            .snapshots()
            .listen((snap) {
          // Whenever server-side conversations change, try to refresh the controller/UI.
          _refreshFromFirestore();
        }, onError: (e) {
          debugPrint('conversations listener error: $e');
        });
      }
    } catch (e) {
      debugPrint('Failed to subscribe to conversations: $e');
    }

    // initial presence subscriptions (based on initial controller state)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updatePresenceSubsFromSummaries();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // app returned to foreground -> force a refresh/sync from Firestore
      _refreshFromFirestore();
    }
    super.didChangeAppLifecycleState(state);
  }

  void _onControllerUpdate() {
    if (mounted) {
      _rebuildNotifier.value = !_rebuildNotifier.value;
      // Whenever controller changes (chats list changed), refresh presence subscriptions
      _updatePresenceSubsFromSummaries();
    }
  }

  void _onScroll() {
    // placeholder: hide FAB or other scroll-based UI changes here if desired
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _storiesSubGroup?.cancel();
    _storiesSubTop?.cancel();
    _conversationsSub?.cancel();
    _scrollController.dispose();
    _tabController.dispose();
    controller.removeListener(_onControllerUpdate);
    try {
      controller.dispose();
    } catch (_) {}
    _rebuildNotifier.dispose();

    // cancel presence subscriptions
    _clearPresenceSubs();

    super.dispose();
  }

  /// Helper to handle snapshots coming from either collectionGroup('stories') OR collection('stories')
  void _handleStoriesSnapshots(QuerySnapshot<Map<String, dynamic>> snap) {
    final now = DateTime.now();
    final active = <String>{};
    for (final doc in snap.docs) {
      try {
        final data = doc.data() as Map<String, dynamic>;
        String uid = '';
        if (data['userId'] != null) {
          uid = data['userId'].toString();
        } else {
          final parent = doc.reference.parent.parent;
          if (parent != null) uid = parent.id;
        }
        if (uid.isEmpty) continue;
        final ts = data['timestamp'];
        DateTime? dt;
        if (ts is Timestamp) dt = ts.toDate();
        else if (ts is String) dt = DateTime.tryParse(ts);
        else if (ts is int) dt = DateTime.fromMillisecondsSinceEpoch(ts);
        if (dt != null && now.difference(dt) < const Duration(hours: 24)) active.add(uid);
      } catch (e) {
        debugPrint('story parse error (merged): $e');
      }
    }
    if (!setEquals(active, _usersWithActiveStories)) {
      setState(() {
        _usersWithActiveStories
          ..clear()
          ..addAll(active);
      });
    }
  }

  Future<List<Map<String, dynamic>>> _fetchSuggestedUsers({int limit = 6}) async {
    try {
      final snap = await FirebaseFirestore.instance.collection('users').limit(50).get();
      final raw = snap.docs.map((d) {
        final m = Map<String, dynamic>.from(d.data() ?? {});
        m['id'] = d.id;
        return m;
      }).toList();

      final payload = {
        'raw': raw,
        'currentId': widget.currentUser['id']?.toString() ?? '',
        'blocked': controller.chatSummaries
            .where((s) => s.otherUser != null && (s.otherUser?['id'] as String?) != null)
            .map((s) => s.otherUser?['id'] as String)
            .whereType<String>()
            .toList(),
      };

      final processed = await compute(_processUserList, payload);
      if (processed.isEmpty) return [];
      return processed.take(limit).toList();
    } catch (e) {
      debugPrint('Failed to fetch suggested users: $e');
      return [];
    }
  }

  Future<void> _openStoriesForUser(String otherId) async {
    try {
      final snapsLocal = await FirebaseFirestore.instance.collection('users').doc(otherId).collection('stories').get();
      final now = DateTime.now();
      final storiesLocal = snapsLocal.docs.map((d) {
        final m = Map<String, dynamic>.from(d.data() as Map<String, dynamic>);
        m['id'] = d.id;
        if (m['timestamp'] is Timestamp) m['timestamp'] = (m['timestamp'] as Timestamp).toDate().toIso8601String();
        return m;
      }).where((s) {
        try {
          final ts = DateTime.parse(s['timestamp'] ?? DateTime.now().toIso8601String());
          return now.difference(ts) < const Duration(hours: 24);
        } catch (_) {
          return false;
        }
      }).toList();

      var userStories = storiesLocal;
      if (userStories.isEmpty) {
        final snaps = await FirebaseFirestore.instance.collection('stories').where('userId', isEqualTo: otherId).get();
        userStories = snaps.docs.map((d) {
          final m = Map<String, dynamic>.from(d.data() as Map<String, dynamic>);
          m['id'] = d.id;
          if (m['timestamp'] is Timestamp) m['timestamp'] = (m['timestamp'] as Timestamp).toDate().toIso8601String();
          return m;
        }).where((s) {
          try {
            final ts = DateTime.parse(s['timestamp'] ?? DateTime.now().toIso8601String());
            return now.difference(ts) < const Duration(hours: 24);
          } catch (_) {
            return false;
          }
        }).toList();
      }

      if (!mounted) return;
      if (userStories.isEmpty) {
        await controller.openOrCreateDirectChat(context, {'id': otherId});
        return;
      }

      Navigator.push(context, MaterialPageRoute(builder: (_) => StoryScreen(stories: userStories, currentUserId: widget.currentUser['id'] ?? '', initialIndex: 0)));
    } catch (e) {
      debugPrint('Failed to open stories for $otherId: $e');
      await controller.openOrCreateDirectChat(context, {'id': otherId});
    }
  }

  ImageProvider _imageProviderFromUserMap(Map<String, dynamic>? user) {
    final url = (user?['avatar'] ?? user?['photoUrl'] ?? user?['photo'])?.toString() ?? '';
    if (url.isEmpty) return const NetworkImage('https://via.placeholder.com/200');
    if (kIsWeb || url.startsWith('http')) return CachedNetworkImageProvider(url);
    return FileImage(File(url));
  }

  Widget _buildQuickAction({required IconData icon, required String label, required VoidCallback onTap}) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 2,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildSuggestionsSection() {
    _suggestedUsersFuture ??= _fetchSuggestedUsers(limit: 6).then((list) {
      _lastSuggestedUsers = list;
      return list;
    });

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _suggestedUsersFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator(color: widget.accentColor)),
          );
        }
        final users = snap.data ?? _lastSuggestedUsers;
        if (users.isEmpty) {
          return SizedBox(
            height: 120,
            child: Center(child: Text('No suggestions right now', style: TextStyle(color: Colors.white70))),
          );
        }

        return SizedBox(
          height: 120,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            scrollDirection: Axis.horizontal,
            itemCount: users.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, idx) {
              final u = users[idx];
              final id = (u['id'] ?? '').toString();
              final username = (u['username'] ?? 'User').toString();
              final photo = (u['photoUrl'] ?? u['avatar'] ?? u['photo'])?.toString() ?? '';
              final hasStory = _usersWithActiveStories.contains(id);
              return RepaintBoundary(
                child: StoryAvatar(
                  size: 76,
                  photoUrl: photo.isNotEmpty ? photo : null,
                  label: username,
                  hasStory: hasStory,
                  accentColor: widget.accentColor,
                  onTap: () async {
                    if (_openingChatIds.contains(id)) return;
                    _openingChatIds.add(id);
                    try {
                      if (hasStory) await _openStoriesForUser(id);
                      else await controller.openOrCreateDirectChat(context, u);
                      // after opening a chat, refresh summaries/presence
                      _refreshFromFirestore();
                    } finally {
                      _openingChatIds.remove(id);
                    }
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    // --- FIX: explicit typing and casting to avoid ternary inference to Object ---
    final avatarRaw = widget.currentUser['photoUrl'] ?? widget.currentUser['avatar'] ?? '';
    final avatarStr = (avatarRaw is String) ? avatarRaw : (avatarRaw?.toString() ?? '');

    ImageProvider? avatarProvider;
    if (avatarStr.isNotEmpty) {
      if (kIsWeb || avatarStr.startsWith('http')) {
        avatarProvider = CachedNetworkImageProvider(avatarStr);
      } else {
        avatarProvider = FileImage(File(avatarStr));
      }
    } else {
      avatarProvider = null;
    }
    // --- end fix ---

    // Make header responsive by adapting children sizes to available height
    return SliverAppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      pinned: true,
      stretch: true,
      // give decent room but header will adapt to available constraints
      expandedHeight: 260,
      flexibleSpace: LayoutBuilder(builder: (context, constraints) {
        final available = constraints.maxHeight;
        // calculate sizes responsive to available height
        final avatarBoxSize = math.min(88.0, math.max(56.0, available * 0.34));
        final avatarRadius = avatarBoxSize / 2;
        final spacingSmall = math.min(12.0, available * 0.03);
        final listHeight = math.min(46.0, math.max(32.0, available * 0.18));

        return FlexibleSpaceBar(
          centerTitle: true,
          titlePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          title: ValueListenableBuilder<bool>(
            valueListenable: _rebuildNotifier,
            builder: (_, __, ___) {
              // show condensed title when collapsed (Flex-space will handle)
              return Text('Messages', style: TextStyle(color: widget.accentColor, fontWeight: FontWeight.bold));
            },
          ),
          background: Container(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.6, -0.5),
                radius: 1.1,
                colors: [widget.accentColor.withOpacity(0.45), Colors.black],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  const SizedBox(height: 6),
                  Container(
                    width: avatarBoxSize,
                    height: avatarBoxSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: [widget.accentColor, widget.accentColor.withOpacity(0.85)]),
                    ),
                    child: CircleAvatar(
                      radius: avatarRadius,
                      backgroundColor: Colors.transparent,
                      backgroundImage: avatarProvider,
                      child: avatarProvider == null
                          ? Text(widget.currentUser['username']?[0]?.toUpperCase() ?? 'U', style: const TextStyle(color: Colors.white, fontSize: 18))
                          : null,
                    ),
                  ),
                  SizedBox(height: spacingSmall),
                  Text(widget.currentUser['username'] ?? 'User', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 4),
                  Text(widget.currentUser['email'] ?? '', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  SizedBox(height: spacingSmall + 4),
                  // quick actions row: fixed height but responsive
                  SizedBox(
                    height: listHeight,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        _buildQuickAction(icon: Icons.rss_feed, label: 'Feed', onTap: _openFeed),
                        const SizedBox(width: 8),
                        _buildQuickAction(icon: Icons.camera_alt, label: 'Stories', onTap: _openStoriesHub),
                        const SizedBox(width: 8),
                        _buildQuickAction(icon: Icons.rate_review, label: 'Review', onTap: _openPostReview),
                        const SizedBox(width: 8),
                        _buildQuickAction(icon: Icons.whatshot, label: 'Trending', onTap: _openTrending),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: Container(
          color: Colors.black.withOpacity(0.45),
          child: TabBar(
            controller: _tabController,
            indicatorColor: widget.accentColor,
            labelColor: widget.accentColor,
            unselectedLabelColor: Colors.white70,
            tabs: [
              const Tab(text: 'All'),
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Unread'),
                    const SizedBox(width: 6),
                    ValueListenableBuilder<bool>(
                      valueListenable: _rebuildNotifier,
                      builder: (_, __, ___) => _UnreadBadge(controller: controller, accent: widget.accentColor),
                    ),
                  ],
                ),
              ),
              const Tab(text: 'Pinned'),
            ],
            onTap: (_) => setState(() {}),
          ),
        ),
      ),
    );
  }

  Widget _buildChatList(List<ChatSummary> visibleChats) {
    return ListView.separated(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      itemCount: visibleChats.length,
      cacheExtent: 1000,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final s = visibleChats[i];
        return RepaintBoundary(
          key: ValueKey(s.id),
          child: Builder(builder: (context) {
            // Inject online status & lastSeen from our presence map into the otherUser map passed to ChatTile.
            Map<String, dynamic>? otherUserCopy;
            if (s.otherUser != null) {
              otherUserCopy = Map<String, dynamic>.from(s.otherUser as Map<String, dynamic>);
              final otherId = (otherUserCopy['id'] ?? '').toString();
              if (otherId.isNotEmpty) {
                if (_onlineMap.containsKey(otherId)) {
                  otherUserCopy['isOnline'] = _onlineMap[otherId];
                }
                if (_lastSeenMap.containsKey(otherId)) {
                  final dt = _lastSeenMap[otherId];
                  if (dt != null) otherUserCopy['lastSeen'] = dt.toIso8601String();
                }
              }
            }

            return ChatTile(
              summary: s,
              accentColor: widget.accentColor,
              controller: controller,
              hasStory: _usersWithActiveStories.contains(s.otherUser?['id'] ?? ''),
              isSelected: false,
              onAvatarTap: () async {
                final otherId = (s.otherUser?['id'] ?? '').toString();
                if (otherId.isNotEmpty) await _openStoriesForUser(otherId);
              },
              onTap: () async {
                if (_openingChatIds.contains(s.id)) return;
                _openingChatIds.add(s.id);
                try {
                  if (s.unreadCount > 0) await controller.markAsRead(s.id, isGroup: s.isGroup);
                  if (s.isGroup) {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => GroupChatScreen(chatId: s.id, currentUser: widget.currentUser, authenticatedUser: widget.currentUser, accentColor: widget.accentColor)));
                  } else {
                    final other = otherUserCopy ?? (s.otherUser ?? {});
                    Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: s.id, currentUser: widget.currentUser, otherUser: other, authenticatedUser: widget.currentUser, storyInteractions: const [], accentColor: widget.accentColor)));
                  }
                  // ensure UI refresh after opening chat (read flag / unread counts)
                  _refreshFromFirestore();
                } finally {
                  _openingChatIds.remove(s.id);
                }
              },
              onLongPress: () {
                _showSelectionActions(chatId: s.id, otherUser: s.otherUser, isGroup: s.isGroup);
              },
              onChatOpened: () => _rebuildNotifier.value = !_rebuildNotifier.value,
            );
          }),
        );
      },
    );
  }

  Future<void> _showSelectionActions({required String chatId, Map<String, dynamic>? otherUser, required bool isGroup}) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Wrap(
              children: [
                ListTile(leading: Icon(Icons.push_pin, color: widget.accentColor), title: const Text('Pin / Unpin', style: TextStyle(color: Colors.white)), onTap: () async {
                  Navigator.pop(ctx);
                  final isPinned = controller.chatSummaries.any((s) => s.id == chatId && s.isPinned);
                  if (isPinned) await controller.unpinConversation(chatId); else await controller.pinConversation(chatId);
                  // refresh so UI updates right away
                  _refreshFromFirestore();
                }),
                ListTile(leading: Icon(Icons.volume_off, color: widget.accentColor), title: const Text('Mute / Unmute', style: TextStyle(color: Colors.white)), onTap: () async {
                  Navigator.pop(ctx);
                  if (otherUser != null) {
                    final otherId = otherUser['id'] as String?;
                    if (otherId != null) {
                      final wasMuted = controller.chatSummaries.any((s) => s.otherUser?['id'] == otherId && s.isMuted);
                      if (wasMuted) await controller.unmute(otherId); else await controller.mute(otherId);
                    }
                  } else {
                    final wasMuted = controller.chatSummaries.any((s) => s.id == chatId && s.isMuted);
                    if (wasMuted) await controller.unmute(chatId); else await controller.mute(chatId);
                  }
                  _refreshFromFirestore();
                }),
                ListTile(leading: Icon(Icons.delete, color: widget.accentColor), title: Text(isGroup ? 'Leave Group' : 'Delete Conversation', style: const TextStyle(color: Colors.white)), onTap: () async {
                  Navigator.pop(ctx);
                  await controller.deleteConversation(chatId, isGroup: isGroup);
                  _refreshFromFirestore();
                }),
                ListTile(leading: Icon(Icons.block, color: widget.accentColor), title: const Text('Block', style: TextStyle(color: Colors.white)), onTap: () async {
                  Navigator.pop(ctx);
                  if (otherUser != null && otherUser['id'] != null) await controller.blockUser(otherUser['id'] as String, chatId: chatId);
                  _refreshFromFirestore();
                }),
                ListTile(leading: Icon(Icons.forward, color: widget.accentColor), title: const Text('Forward', style: TextStyle(color: Colors.white)), onTap: () async {
                  Navigator.pop(ctx);
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => const ForwardMessageScreen()));
                }),
                ListTile(leading: const Icon(Icons.close, color: Colors.white70), title: const Text('Cancel', style: TextStyle(color: Colors.white70)), onTap: () => Navigator.pop(ctx)),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openFeed() async {
    try {
      Navigator.of(context).pushNamed('/feed');
      return;
    } catch (_) {}
    Navigator.push(context, MaterialPageRoute(builder: (_) => SocialReactionsScreen(accentColor: widget.accentColor)));
  }

  Future<void> _openStoriesHub() async {
    try {
      Navigator.of(context).pushNamed('/stories');
      return;
    } catch (_) {}
    Navigator.push(context, MaterialPageRoute(builder: (_) => SocialReactionsScreen(accentColor: widget.accentColor)));
  }

  Future<void> _openPostReview() async {
    try {
      Navigator.of(context).pushNamed('/post_review');
      return;
    } catch (_) {}
    Navigator.push(context, MaterialPageRoute(builder: (_) => PostReviewScreen(accentColor: Colors.redAccent, currentUser: {
      'id': FirebaseAuth.instance.currentUser?.uid,
      'username': FirebaseAuth.instance.currentUser?.displayName ?? 'Guest',
    })));
  }

  Future<void> _openTrending() async {
    try {
      Navigator.of(context).pushNamed('/trending');
      return;
    } catch (_) {}
    Navigator.push(context, MaterialPageRoute(builder: (_) => SocialReactionsScreen(accentColor: widget.accentColor)));
  }

  @override
  Widget build(BuildContext context) {
    final allChats = controller.chatSummaries;
    final tabIndex = _tabController.index;
    List<ChatSummary> visibleChats;
    if (tabIndex == 1) visibleChats = allChats.where((s) => s.unreadCount > 0).toList();
    else if (tabIndex == 2) visibleChats = allChats.where((s) => s.isPinned).toList();
    else visibleChats = List<ChatSummary>.from(allChats);

    final isEmpty = visibleChats.isEmpty;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [widget.accentColor.withOpacity(0.25), Colors.black87], begin: Alignment.topLeft, end: Alignment.bottomRight),
            ),
          ),
          SafeArea(
            child: RefreshIndicator(
              color: widget.accentColor,
              onRefresh: () async {
                _suggestedUsersFuture = _fetchSuggestedUsers(limit: 6).then((l) {
                  _lastSuggestedUsers = l;
                  return l;
                });
                // explicit refresh from Firestore too
                await _refreshFromFirestore();
                setState(() {});
                await Future.delayed(const Duration(milliseconds: 300));
              },
              child: CustomScrollView(controller: _scrollController, slivers: [
                _buildHeader(),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8),
                    child: Material(
                      color: Colors.black.withOpacity(0.32),
                      elevation: 2,
                      borderRadius: BorderRadius.circular(14),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Column(
                          children: [
                            Padding(padding: const EdgeInsets.symmetric(horizontal: 12.0), child: _buildSuggestionsSection()),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                SliverFillRemaining(
                  hasScrollBody: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.35),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: widget.accentColor.withOpacity(0.08)),
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 260),
                        child: isEmpty ? _buildEmptyState() : _buildChatList(visibleChats),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => controller.showChatCreationOptions(context),
        backgroundColor: widget.accentColor,
        tooltip: 'Start new chat',
        child: const Icon(Icons.chat, color: Colors.white),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(18, 18, 18, 6), child: Text('Start a conversation', style: TextStyle(color: widget.accentColor, fontWeight: FontWeight.bold))),

        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18.0),
          child: Text('No conversations yet. Tap a user above to start chatting, or press the + button to create a new one.', style: const TextStyle(color: Colors.white70)),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: 4,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, __) => const _SkeletonTile(),
          ),
        ),
      ],
    );
  }

  /// ---------------------------
  /// Presence helpers
  /// ---------------------------

  // Create / remove presence subscriptions so we only listen to users currently shown in the list
  void _updatePresenceSubsFromSummaries() {
    try {
      final ids = <String>{};
      for (final s in controller.chatSummaries) {
        final otherId = (s.otherUser?['id'] ?? '').toString();
        if (otherId.isNotEmpty) ids.add(otherId);
      }

      // Add subscriptions for ids that aren't subscribed
      for (final id in ids) {
        if (!_userPresenceSubs.containsKey(id)) {
          final sub = FirebaseFirestore.instance.collection('users').doc(id).snapshots().listen((doc) {
            try {
              if (!doc.exists) return;
              final data = doc.data() as Map<String, dynamic>? ?? {};
              final isOnline = data['isOnline'] == true;
              final prev = _onlineMap[id];
              DateTime? lastSeen;
              final ls = data['lastSeen'];
              if (ls is Timestamp) lastSeen = ls.toDate();
              else if (ls is String) lastSeen = DateTime.tryParse(ls);
              else if (ls is int) lastSeen = DateTime.fromMillisecondsSinceEpoch(ls);
              final prevLastSeen = _lastSeenMap[id];
              var changed = false;
              if (prev != isOnline) {
                _onlineMap[id] = isOnline;
                changed = true;
              }
              if (lastSeen != prevLastSeen) {
                _lastSeenMap[id] = lastSeen;
                changed = true;
              }
              if (changed && mounted) setState(() {});
            } catch (e) {
              debugPrint('presence listener parse error for $id: $e');
            }
          }, onError: (e) {
            debugPrint('presence listen error for $id: $e');
          });
          _userPresenceSubs[id] = sub;
        }
      }

      // Remove subscriptions for ids that are no longer in the visible set
      final toRemove = <String>[];
      for (final existing in _userPresenceSubs.keys) {
        if (!ids.contains(existing)) toRemove.add(existing);
      }
      for (final r in toRemove) {
        try {
          _userPresenceSubs.remove(r)?.cancel();
        } catch (_) {}
        _onlineMap.remove(r);
        _lastSeenMap.remove(r);
      }
    } catch (e) {
      debugPrint('_updatePresenceSubsFromSummaries error: $e');
    }
  }

  void _clearPresenceSubs() {
    for (final sub in _userPresenceSubs.values) {
      try {
        sub.cancel();
      } catch (_) {}
    }
    _userPresenceSubs.clear();
    _onlineMap.clear();
    _lastSeenMap.clear();
  }

  /// Attempts to refresh UI/controller state from Firestore.
  /// If your MessagesController exposes a `.refresh()` or `.reload()` method it will call it.
  /// Otherwise it falls back to safely recreating the controller instance.
  Future<void> _refreshFromFirestore() async {
    try {
      // If controller implements refresh (user's MessagesController might), call it.
      // Use dynamic to avoid analyzer errors if refresh doesn't exist.
      final dyn = controller as dynamic;
      if (dyn != null) {
        try {
          if (dyn.refresh is Function) {
            await dyn.refresh();
            // controller should notify listeners; ensure we update presence subs too
            _updatePresenceSubsFromSummaries();
            _rebuildNotifier.value = !_rebuildNotifier.value;
            return;
          }
        } catch (_) {
          // ignore and fallback
        }
      }

      // fallback: safely recreate controller to ensure fresh listeners
      controller.removeListener(_onControllerUpdate);
      try {
        controller.dispose();
      } catch (_) {}
      controller = MessagesController(widget.currentUser, context);
      controller.addListener(_onControllerUpdate);
      _updatePresenceSubsFromSummaries();
      _rebuildNotifier.value = !_rebuildNotifier.value;
    } catch (e) {
      debugPrint('Failed to refresh controller: $e');
    }
  }
}

/// Small widget to display unread badge inside Tab
class _UnreadBadge extends StatelessWidget {
  final MessagesController controller;
  final Color? accent;
  const _UnreadBadge({required this.controller, this.accent, super.key});

  @override
  Widget build(BuildContext context) {
    final unread = controller.totalUnread;
    if (unread <= 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: accent ?? Theme.of(context).colorScheme.secondary, borderRadius: BorderRadius.circular(10)),
      child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }
}
