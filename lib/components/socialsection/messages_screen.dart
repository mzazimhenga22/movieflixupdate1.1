// messages_screen.dart
import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/foundation.dart' show kIsWeb, compute, setEquals;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'messages_controller.dart';
import 'chat_screen.dart';
import 'Group_chat_screen.dart';
import 'chat_tile.dart';
import 'forward_message_screen.dart';
import 'package:movie_app/components/socialsection/stories.dart';
import 'package:movie_app/components/socialsection/social_reactions_screen.dart';
import 'post_review_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// --- Top-level compute worker ---
/// Payload: { 'raw': List<Map<String,dynamic>> , 'currentId': String, 'blocked': List<String> }
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
      // basic shape normalization
      users.add({
        'id': id,
        'username': (m['username'] ?? m['name'] ?? '')?.toString() ?? '',
        'photoUrl': (m['photoUrl'] ?? m['avatar'] ?? m['photo'] ?? '')?.toString(),
      });
    }
  }

  // Remove current user and blocked users
  users.removeWhere((u) => u['id'] == currentId || blocked.contains(u['id']));

  // sort by username (stable, then server order)
  users.sort((a, b) => (a['username'] as String).toLowerCase().compareTo((b['username'] as String).toLowerCase()));

  return users;
}

/// Small widget that draws a circular avatar with a story-like gradient ring.
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

  ImageProvider _imageProvider(String? url) {
    if (url == null || url.isEmpty) return const AssetImage('') as ImageProvider; // will be ignored by CircleAvatar if empty
    if (kIsWeb || url.startsWith('http')) {
      return CachedNetworkImageProvider(url);
    } else {
      return FileImage(File(url));
    }
  }

  @override
  Widget build(BuildContext context) {
    // outer ring thickness
    final ring = 6.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              // gradient ring
              if (hasStory)
                Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(
                      startAngle: 0,
                      endAngle: 3.14 * 2,
                      colors: [
                        accentColor,
                        accentColor.withOpacity(0.9),
                        Colors.blueAccent,
                        Colors.pinkAccent,
                        accentColor,
                      ],
                    ),
                  ),
                ),
              // inner circle with background to create ring effect
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
                  backgroundImage: (photoUrl != null && photoUrl!.isNotEmpty) ? _imageProvider(photoUrl) : null,
                  child: (photoUrl == null || photoUrl!.isEmpty)
                      ? Text(
                          label.isNotEmpty ? label[0].toUpperCase() : 'U',
                          style: const TextStyle(color: Colors.white),
                        )
                      : null,
                ),
              ),
              // semi-circle highlight indicator — top-right small overlay (gives "semi" impression)
              if (hasStory)
                Positioned(
                  right: 0,
                  top: 0,
                  child: CustomPaint(
                    size: Size(size * 0.28, size * 0.28),
                    painter: _SemiCirclePainter(accent: Theme.of(context).colorScheme.secondary),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: size + 8,
            child: Text(
              label,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

class _SemiCirclePainter extends CustomPainter {
  final Color accent;
  _SemiCirclePainter({required this.accent});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = RadialGradient(colors: [accent.withOpacity(0.95), accent.withOpacity(0.6)]).createShader(Offset.zero & size)
      ..style = PaintingStyle.fill;
    final rect = Offset.zero & size;
    canvas.drawArc(rect, -3.14 / 2, 3.14, true, paint); // draw semi-circle (top half)
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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

  // cached suggested users future to avoid duplicate fetching on rebuilds
  Future<List<Map<String, dynamic>>>? _suggestedUsersFuture;

  // keep last resolved suggestions (optional reuse)
  List<Map<String, dynamic>> _lastSuggestedUsers = [];

  // guard to avoid duplicate open/create chat actions from quick repeated taps
  final Set<String> _openingChatIds = {};

  // Local selection state for top-bar actions & bottom sheet
  String? _selectedChatId;
  Map<String, dynamic>? _selectedOtherUser;
  bool _selectedIsGroup = false;

  // kept intentionally (was flagged unused previously) — referenced in FAB tooltip to silence analyzer
  final bool _isLoadingMore = false;

  // Tracks users who currently have active stories (<24h)
  final Set<String> _usersWithActiveStories = {};
  StreamSubscription<QuerySnapshot>? _storiesSub;

  late VoidCallback _controllerListener;

  @override
  void initState() {
    super.initState();

    controller = MessagesController(widget.currentUser, context);

    // Rebuild UI whenever controller notifies (realtime updates)
    _controllerListener = () {
      if (mounted) setState(() {});
    };
    controller.addListener(_controllerListener);

    _tabController = TabController(length: 3, vsync: this);
    _reloadTrigger = ValueNotifier<bool>(false);

    // initialize cached future once (safe to do asynchronously)
    _suggestedUsersFuture = _fetchSuggestedUsers(limit: 5).then((list) {
      _lastSuggestedUsers = list;
      return list;
    });

    // if you want suggestions refreshed when reloadTrigger flips, listen:
    _reloadTrigger.addListener(() {
      // refresh suggestions only when explicitly needed
      _refreshSuggestedUsers();
    });

    // Scroll listener: update only the small expanded/not-expanded state via ValueNotifier,
    // avoid calling setState repeatedly.
    _scrollController.addListener(() {
      final newExpanded = _scrollController.offset <= 100;
      if (_isExpandedNotifier.value != newExpanded) {
        _isExpandedNotifier.value = newExpanded;
      }
    });

    // Use collectionGroup to discover stories placed either top-level or under users/{uid}/stories
    _storiesSub = FirebaseFirestore.instance.collectionGroup('stories').snapshots().listen((snap) {
      final now = DateTime.now();
      final activeUsers = <String>{};

      for (final doc in snap.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;

          // determine user id:
          String uid = '';
          if (data['userId'] != null) {
            uid = data['userId'].toString();
          } else {
            // if stored under users/{uid}/stories/{sid}
            final parent = doc.reference.parent.parent;
            if (parent != null) uid = parent.id;
          }
          if (uid.isEmpty) continue;

          final tsVal = data['timestamp'];
          DateTime? ts;
          if (tsVal is Timestamp) {
            ts = tsVal.toDate();
          } else if (tsVal is String) {
            ts = DateTime.tryParse(tsVal);
          } else if (tsVal is int) {
            ts = DateTime.fromMillisecondsSinceEpoch(tsVal);
          }

          if (ts == null) continue;
          if (now.difference(ts) < const Duration(hours: 24)) {
            activeUsers.add(uid);
          }
        } catch (e) {
          debugPrint('story parse error: $e');
        }
      }

      if (!mounted) return;
      if (!setEquals(_usersWithActiveStories, activeUsers)) {
        setState(() {
          _usersWithActiveStories
            ..clear()
            ..addAll(activeUsers);
        });
      }
    }, onError: (e) {
      debugPrint('stories listener error: $e');
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _tabController.dispose();
    _reloadTrigger.dispose();
    _isExpandedNotifier.dispose();
    controller.removeListener(_controllerListener);
    controller.dispose();
    _storiesSub?.cancel();
    super.dispose();
  }

  /// Refresh the cached suggestions future (call when you actually want to refetch)
  void _refreshSuggestedUsers({int limit = 5}) {
    setState(() {
      _suggestedUsersFuture = _fetchSuggestedUsers(limit: limit).then((list) {
        _lastSuggestedUsers = list;
        return list;
      });
    });
  }

  /// Show bottom sheet with actions when a chat is selected via long press.
  Future<void> _showSelectionActions({
    required String chatId,
    Map<String, dynamic>? otherUser,
    required bool isGroup,
  }) async {
    // set selection
    _selectedChatId = chatId;
    _selectedOtherUser = otherUser;
    _selectedIsGroup = isGroup;
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
                  title:
                      const Text('Block', style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.pop(context);
                    if (otherUser != null) {
                      final userId = otherUser['id'] as String?;
                      if (userId != null && userId.isNotEmpty) {
                        await controller.blockUser(userId, chatId: chatId);
                      }
                    }
                    _clearLocalSelection();
                  },
                ),
                ListTile(
                  leading: Icon(Icons.delete, color: widget.accentColor),
                  title: Text(isGroup ? 'Leave Group' : 'Delete Conversation',
                      style: const TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.pop(context);
                    await controller.deleteConversation(chatId, isGroup: isGroup);
                    _clearLocalSelection();
                  },
                ),
                ListTile(
                  leading: Icon(Icons.push_pin, color: widget.accentColor),
                  title:
                      const Text('Pin / Unpin', style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.pop(context);
                    final isPinned = controller.chatSummaries.any((s) => s.id == chatId && s.isPinned);
                    if (isPinned) {
                      await controller.unpinConversation(chatId);
                    } else {
                      await controller.pinConversation(chatId);
                    }
                    _clearLocalSelection();
                  },
                ),
                ListTile(
                  leading: Icon(Icons.volume_off, color: widget.accentColor),
                  title:
                      const Text('Mute / Unmute', style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.pop(context);
                    if (otherUser != null) {
                      final otherId = otherUser['id'] as String?;
                      if (otherId != null) {
                        final isMuted = controller.chatSummaries.any((s) =>
                            (s.otherUser?['id'] == otherId) && s.isMuted);
                        if (isMuted) {
                          await controller.unmute(otherId);
                        } else {
                          await controller.mute(otherId);
                        }
                      }
                    } else {
                      final isMuted = controller.chatSummaries.any((s) => s.id == chatId && s.isMuted);
                      if (isMuted) {
                        await controller.unmute(chatId);
                      } else {
                        await controller.mute(chatId);
                      }
                    }
                    _clearLocalSelection();
                  },
                ),
                ListTile(
                  leading: Icon(Icons.forward, color: widget.accentColor),
                  title: const Text('Forward', style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.pop(context);
                    // open forward screen
                    await Navigator.push(context, MaterialPageRoute(builder: (_) => const ForwardMessageScreen()));
                    _clearLocalSelection();
                  },
                ),
                ListTile(
                  leading: Icon(Icons.close, color: widget.accentColor),
                  title: const Text('Cancel', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    _clearLocalSelection();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _clearLocalSelection() {
    _selectedChatId = null;
    _selectedOtherUser = null;
    _selectedIsGroup = false;
    _reloadTrigger.value = !_reloadTrigger.value;
    if (mounted) setState(() {});
  }

  // -------------------------
  // Lightweight interlink action handler (safe, non-invasive)
  // -------------------------
  void _performInterlinkAction(String actionRoute, String friendlyName) {
    try {
      Navigator.of(context).pushNamed(actionRoute);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Open "$friendlyName" (route: $actionRoute). Implement navigation or register route to open actual page.')),
      );
    }
  }

  // Try to open named route, otherwise fallback to a widget we imported.
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
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Route "/stories" not registered. Add it to open Stories hub directly. Falling back to Social screen.')),
        );
      }
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => SocialReactionsScreen(accentColor: widget.accentColor)));
  }

  Future<void> _openPostReview() async {
    try {
      Navigator.of(context).pushNamed('/post_review');
      return;
    } catch (_) {}
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PostReviewScreen(
          accentColor: Colors.redAccent,
          currentUser: {
            'id': FirebaseAuth.instance.currentUser?.uid,
            'username': FirebaseAuth.instance.currentUser?.displayName ?? 'Guest',
          },
        ),
      ),
    );
  }

  Future<void> _openTrending() async {
    try {
      Navigator.of(context).pushNamed('/trending');
      return;
    } catch (_) {}
    Navigator.push(context, MaterialPageRoute(builder: (_) => SocialReactionsScreen(accentColor: widget.accentColor)));
  }

  Future<void> _openWatchParty() async {
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Open Watch Party?', style: TextStyle(color: widget.accentColor, fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 12),
                const Text('This will take you to the Watch Party area where you can join or start viewing sessions.', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: widget.accentColor),
                        onPressed: () {
                          Navigator.pop(context);
                          try {
                            Navigator.of(this.context).pushNamed('/watch_party');
                          } catch (_) {
                            Navigator.push(context, MaterialPageRoute(builder: (_) => SocialReactionsScreen(accentColor: widget.accentColor)));
                          }
                        },
                        child: const Text('Open Watch Party'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(side: BorderSide(color: widget.accentColor)),
                        child: const Text('Cancel'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openProfile() async {
    try {
      Navigator.of(context).pushNamed('/profile');
      return;
    } catch (_) {}
    Navigator.push(context, MaterialPageRoute(builder: (_) => SocialReactionsScreen(accentColor: widget.accentColor)));
  }

  Widget _buildQuickAction({required IconData icon, required String label, required VoidCallback onTap}) {
    final gradient = LinearGradient(
      colors: [widget.accentColor, widget.accentColor.withOpacity(0.6)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6.0),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          elevation: 1,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: onTap,
        child: Row(
          children: [
            ShaderMask(
              shaderCallback: (bounds) => gradient.createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height)),
              child: Icon(icon, size: 16, color: Colors.white),
            ),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }

  /// Fetch suggested users and process the raw docs on a background isolate via compute.
  /// Returns up to [limit] users (already filtered out current/blocked).
  Future<List<Map<String, dynamic>>> _fetchSuggestedUsers({int limit = 5}) async {
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
    } catch (e, st) {
      debugPrint('Failed to fetch suggested users: $e\n$st');
      return [];
    }
  }

  /// Build an ImageProvider from a user's avatar fields (tries 'avatar', 'photoUrl', 'photo').
  ImageProvider _imageProviderFromUserMap(Map<String, dynamic>? user) {
    final url = (user?['avatar'] ?? user?['photoUrl'] ?? user?['photo'])?.toString() ?? '';
    if (url.isEmpty) {
      // fallback placeholder
      return const NetworkImage('https://via.placeholder.com/200');
    }
    if (kIsWeb || url.startsWith('http')) {
      return CachedNetworkImageProvider(url);
    } else {
      return FileImage(File(url));
    }
  }

  /// Unified story opener: tries users/{uid}/stories subcollection first, then top-level 'stories' with userId field.
  Future<void> _openStoriesForUser(String otherId) async {
    try {
      // try users/{uid}/stories first
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

      List<Map<String, dynamic>> userStories = storiesLocal;

      if (userStories.isEmpty) {
        // fallback: top-level 'stories' collection with userId field
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
        // nothing to show; open chat as fallback
        await controller.openOrCreateDirectChat(context, {'id': otherId});
        return;
      }

      // navigate to story screen
      Navigator.push(context, MaterialPageRoute(builder: (_) => StoryScreen(stories: userStories, currentUserId: widget.currentUser['id'] ?? '', initialIndex: 0)));
    } catch (e) {
      debugPrint('Failed to open stories for $otherId: $e');
      // fallback to opening chat
      await controller.openOrCreateDirectChat(context, {'id': otherId});
    }
  }

  Widget _buildSuggestionsSection() {
    // ensure future is initialized (lazy fallback) — avoids LateInitializationError and helps hot-reload cases.
    _suggestedUsersFuture ??= _fetchSuggestedUsers(limit: 5).then((list) {
      _lastSuggestedUsers = list;
      return list;
    });

    return FutureBuilder<List<Map<String, dynamic>>>(
      // Use the cached future to avoid creating a new Firestore get() each rebuild.
      future: _suggestedUsersFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return SizedBox(
            height: 130,
            child: Center(child: CircularProgressIndicator(color: widget.accentColor)),
          );
        }
        final users = snap.data ?? _lastSuggestedUsers;
        if (users.isEmpty) {
          return SizedBox(
            height: 130,
            child: Center(child: Text('No suggestions right now', style: TextStyle(color: Colors.white70))),
          );
        }

        return SizedBox(
          height: 130,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            scrollDirection: Axis.horizontal,
            itemCount: users.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, idx) {
              final u = users[idx];
              final id = (u['id'] ?? '').toString();
              final username = (u['username'] ?? 'User').toString();
              final photo = (u['photoUrl'] ?? u['avatar'] ?? u['photo'])?.toString() ?? '';
              final hasStory = _usersWithActiveStories.contains(id);
              return GestureDetector(
                onTap: () async {
                  // prevent duplicate quick taps
                  if (_openingChatIds.contains(id)) return;
                  _openingChatIds.add(id);
                  try {
                    if (hasStory) {
                      await _openStoriesForUser(id);
                    } else {
                      // open/create chat via controller
                      await controller.openOrCreateDirectChat(context, u);
                    }
                  } finally {
                    _openingChatIds.remove(id);
                  }
                },
                child: StoryAvatar(
                  size: 72,
                  photoUrl: photo.isNotEmpty ? photo : null,
                  label: username,
                  hasStory: hasStory,
                  accentColor: widget.accentColor,
                ),
              );
            },
          ),
        );
      },
    );
  }

  // -------------------------
  // Build
  // -------------------------
  @override
  Widget build(BuildContext context) {
    // Get controller-managed chat list
    final allChats = controller.chatSummaries;
    // filter by tab
    List<ChatSummary> visibleChats;
    final currentTabIndex = _tabController.index;
    if (currentTabIndex == 1) {
      // Unread
      visibleChats = allChats.where((s) => s.unreadCount > 0).toList();
    } else if (currentTabIndex == 2) {
      // Favorites -> show pinned (as a reasonable stand-in)
      visibleChats = allChats.where((s) => s.isPinned).toList();
    } else {
      visibleChats = List<ChatSummary>.from(allChats);
    }

    // If controller is still empty and you want skeletons, you can detect that here:
    final isEmpty = visibleChats.isEmpty;

    // reference _isLoadingMore in UI to silence unused_field warning while leaving field present
    final fabTooltip = 'New chat' + (_isLoadingMore ? ' · loading more...' : '');

    // Determine avatar for expanded header (follows your UserProfile logic)
    ImageProvider headerAvatar() {
      final u = widget.currentUser;
      final url = (u['avatar'] ?? u['photoUrl'] ?? u['photo'])?.toString() ?? (u['photoUrl']?.toString() ?? '');
      if (url.isEmpty) return const NetworkImage('https://via.placeholder.com/200');
      if (kIsWeb || url.startsWith('http')) return CachedNetworkImageProvider(url);
      return FileImage(File(url));
    }

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
                widget.accentColor.withAlpha((0.4 * 255).round()),
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
              expandedHeight: 260,
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
                            padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.start,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Container(
                                  width: 84,
                                  height: 84,
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
                                  child: widget.currentUser['photoUrl'] != null || widget.currentUser['avatar'] != null
                                      ? CircleAvatar(
                                          radius: 40,
                                          backgroundImage: headerAvatar(),
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
                                const SizedBox(height: 14),
                                SizedBox(
                                  height: 56,
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    child: Row(
                                      children: [
                                        _buildQuickAction(icon: Icons.rss_feed, label: 'Feed', onTap: _openFeed),
                                        _buildQuickAction(icon: Icons.camera_alt, label: 'Stories', onTap: _openStoriesHub),
                                        _buildQuickAction(icon: Icons.rate_review, label: 'Review', onTap: _openPostReview),
                                        _buildQuickAction(icon: Icons.whatshot, label: 'Trending', onTap: _openTrending),
                                        _buildQuickAction(icon: Icons.connected_tv, label: 'Watch', onTap: _openWatchParty),
                                        _buildQuickAction(icon: Icons.person, label: 'Profile', onTap: _openProfile),
                                      ],
                                    ),
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
                preferredSize: const Size.fromHeight(56),
                child: Material(
                  elevation: 4,
                  color: Colors.black.withAlpha((0.5 * 255).round()),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _reloadTrigger,
                    builder: (context, _, __) {
                      final unreadCount = controller.totalUnread;
                      return TabBar(
                        controller: _tabController,
                        indicatorColor: widget.accentColor,
                        labelColor: widget.accentColor,
                        unselectedLabelColor: Colors.white54,
                        onTap: (_) {
                          setState(() {});
                        },
                        tabs: [
                          const Tab(text: 'All'),
                          Tab(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('Unread'),
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
                ValueListenableBuilder<bool>(
                  valueListenable: _reloadTrigger,
                  builder: (context, _, __) {
                    if (_selectedChatId == null) return const SizedBox.shrink();
                    final otherUser = _selectedOtherUser;
                    final chatId = _selectedChatId;
                    return Row(
                      children: [
                        FutureBuilder<bool>(
                          future: Future.value(otherUser != null ? controller.chatSummaries.any((s) => s.otherUser?['id'] == otherUser['id'] && s.isBlocked) : false),
                          builder: (context, snap) {
                            final isBlocked = snap.data ?? false;
                            return IconButton(
                              icon: Icon(isBlocked ? Icons.lock_open : Icons.block, color: widget.accentColor),
                              onPressed: () async {
                                if (otherUser != null) {
                                  final userId = otherUser['id'] as String?;
                                  if (userId != null) {
                                    if (isBlocked) {
                                      await controller.unblockUser(userId);
                                    } else {
                                      await controller.blockUser(userId, chatId: chatId!);
                                    }
                                  }
                                }
                                _clearLocalSelection();
                              },
                              tooltip: isBlocked ? 'Unblock User' : 'Block User',
                            );
                          },
                        ),
                        FutureBuilder<bool>(
                          future: Future.value(_selectedOtherUser != null ? controller.chatSummaries.any((s) => s.otherUser?['id'] == _selectedOtherUser?['id'] && s.isMuted) : controller.chatSummaries.any((s) => s.id == _selectedChatId && s.isMuted)),
                          builder: (context, snap) {
                            final isMuted = snap.data ?? false;
                            return IconButton(
                              icon: Icon(isMuted ? Icons.volume_up : Icons.volume_off, color: widget.accentColor),
                              onPressed: () async {
                                if (otherUser != null) {
                                  final otherId = otherUser['id'] as String?;
                                  if (otherId != null) {
                                    if (isMuted) {
                                      await controller.unmute(otherId);
                                    } else {
                                      await controller.mute(otherId);
                                    }
                                  }
                                } else if (chatId != null) {
                                  if (isMuted) {
                                    await controller.unmute(chatId);
                                  } else {
                                    await controller.mute(chatId);
                                  }
                                }
                                _clearLocalSelection();
                              },
                              tooltip: isMuted ? 'Unmute' : 'Mute',
                            );
                          },
                        ),
                        IconButton(
                          icon: Icon(
                            (controller.chatSummaries.any((s) => s.id == _selectedChatId && s.isPinned))
                                ? Icons.push_pin_outlined
                                : Icons.push_pin,
                            color: widget.accentColor,
                          ),
                          onPressed: () async {
                            if (_selectedChatId == null) return;
                            final isPinned = controller.chatSummaries.any((s) => s.id == _selectedChatId && s.isPinned);
                            if (isPinned) {
                              await controller.unpinConversation(_selectedChatId!);
                            } else {
                              await controller.pinConversation(_selectedChatId!);
                            }
                            _clearLocalSelection();
                          },
                          tooltip: (controller.chatSummaries.any((s) => s.id == _selectedChatId && s.isPinned)) ? 'Unpin Conversation' : 'Pin Conversation',
                        ),
                        IconButton(
                          icon: Icon(Icons.delete, color: widget.accentColor),
                          onPressed: () async {
                            if (_selectedChatId != null) {
                              await controller.deleteConversation(_selectedChatId!, isGroup: _selectedIsGroup);
                            }
                            _clearLocalSelection();
                          },
                          tooltip: _selectedOtherUser != null ? 'Delete Conversation' : 'Leave Group',
                        ),
                        IconButton(
                          icon: Icon(Icons.close, color: widget.accentColor),
                          onPressed: () {
                            _clearLocalSelection();
                          },
                          tooltip: 'Cancel',
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
            // Note: suggestions row was intentionally moved INSIDE the container below
            SliverFillRemaining(
              child: TabBarView(
                controller: _tabController,
                children: ['All', 'Unread', 'Favorites'].map((tab) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha((0.3 * 255).round()),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: widget.accentColor.withAlpha((0.1 * 255).round())),
                      ),
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _reloadTrigger,
                        builder: (context, _, __) {
                          // If there are no visible chats, show suggestions + explanatory placeholder
                          if (isEmpty) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                                  child: Text('Start a conversation', style: TextStyle(color: widget.accentColor, fontWeight: FontWeight.bold)),
                                ),
                                // suggestions row is now inside the container
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                  child: _buildSuggestionsSection(),
                                ),
                                const SizedBox(height: 12),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  child: Text(
                                    'You don\'t have any conversations yet. Tap a user above to start chatting, or press the + button to create a new one.',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                ),
                                Expanded(
                                  child: ListView.builder(
                                    padding: const EdgeInsets.all(16.0),
                                    itemCount: 3,
                                    itemBuilder: (context, index) => Card(
                                      elevation: 4,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      margin: const EdgeInsets.symmetric(vertical: 8),
                                      child: ListTile(
                                        leading: CircleAvatar(backgroundColor: Colors.black.withAlpha((0.3 * 255).round())),
                                        title: Container(height: 16, color: Colors.grey[800]),
                                        subtitle: Container(height: 12, margin: const EdgeInsets.only(top: 4), color: Colors.grey[800]),
                                        trailing: Container(width: 50, height: 12, color: Colors.grey[800]),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          }

                          // When there are chats, show suggestions row above the chat list but inside the container
                          return Column(
                            children: [
                              // small top spacing/title
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text('Messages', style: TextStyle(color: widget.accentColor, fontWeight: FontWeight.bold)),
                                    // optional quick action to refresh suggestions
                                    IconButton(
                                      icon: const Icon(Icons.refresh, size: 20),
                                      color: widget.accentColor,
                                      onPressed: () => _refreshSuggestedUsers(limit: 5),
                                      tooltip: 'Refresh suggestions',
                                    ),
                                  ],
                                ),
                              ),

                              // suggestions row inside the rounded container (keeps it visually grouped)
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                child: _buildSuggestionsSection(),
                              ),

                              const SizedBox(height: 8),

                              // chat list expands to fill remaining space and is scrollable
                              Expanded(
                                child: ListView.builder(
                                  padding: const EdgeInsets.all(16.0),
                                  itemCount: visibleChats.length,
                                  itemBuilder: (context, index) {
                                    final summary = visibleChats[index];
                                    return ChatTile(
                                      summary: summary,
                                      accentColor: widget.accentColor,
                                      controller: controller,
                                      isSelected: summary.id == _selectedChatId,
                                      hasStory: _usersWithActiveStories.contains(summary.otherUser?['id'] ?? ''),
                                      onAvatarTap: () async {
                                        final otherId = (summary.otherUser?['id'] ?? '').toString();
                                        if (otherId.isEmpty) return;
                                        await _openStoriesForUser(otherId);
                                      },
                                      onTap: () async {
                                        _clearLocalSelection();

                                        if (summary.unreadCount > 0) {
                                          await controller.markAsRead(summary.id, isGroup: summary.isGroup);
                                        }

                                        if (summary.isGroup) {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => GroupChatScreen(
                                                chatId: summary.id,
                                                currentUser: widget.currentUser,
                                                authenticatedUser: widget.currentUser,
                                                accentColor: widget.accentColor,
                                                forwardedMessage: null,
                                              ),
                                            ),
                                          );
                                        } else {
                                          final other = summary.otherUser ?? {};
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => ChatScreen(
                                                chatId: summary.id,
                                                currentUser: widget.currentUser,
                                                otherUser: other,
                                                authenticatedUser: widget.currentUser,
                                                storyInteractions: const [],
                                                accentColor: widget.accentColor,
                                                forwardedMessage: null,
                                              ),
                                            ),
                                          );
                                        }
                                      },
                                      onLongPress: () {
                                        _selectedChatId = summary.id;
                                        _selectedOtherUser = summary.otherUser;
                                        _selectedIsGroup = summary.isGroup;
                                        _reloadTrigger.value = !_reloadTrigger.value;
                                        _showSelectionActions(chatId: summary.id, otherUser: summary.otherUser, isGroup: summary.isGroup);
                                      },
                                      onChatOpened: () {
                                        _reloadTrigger.value = !_reloadTrigger.value;
                                      },
                                    );
                                  },
                                ),
                              ),
                            ],
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
        onPressed: () => controller.showChatCreationOptions(context),
        backgroundColor: widget.accentColor,
        tooltip: fabTooltip,
        child: const Icon(Icons.chat, color: Colors.white),
      ),
    );
  }
}
