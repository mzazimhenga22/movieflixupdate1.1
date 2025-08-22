// messages_screen.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'messages_controller.dart';
import 'chat_screen.dart';
import 'Group_chat_screen.dart';
import 'chat_tile.dart';
import 'forward_message_screen.dart';
import 'package:movie_app/components/socialsection/stories.dart';
import 'package:movie_app/components/socialsection/social_reactions_screen.dart';
import 'post_review_screen.dart'; // <-- added per request
import 'package:firebase_auth/firebase_auth.dart';



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

    // Scroll listener: update only the small expanded/not-expanded state via ValueNotifier,
    // avoid calling setState repeatedly.
    _scrollController.addListener(() {
      final newExpanded = _scrollController.offset <= 100;
      if (_isExpandedNotifier.value != newExpanded) {
        _isExpandedNotifier.value = newExpanded;
      }
    });

    // Start a single Firestore listener for stories and compute which users have active stories.
    // Lightweight: we only keep a set of userIds which are used to render avatar rings.
    _storiesSub = FirebaseFirestore.instance.collection('stories').snapshots().listen((snap) {
      final now = DateTime.now();
      final activeUsers = <String>{};
      for (final doc in snap.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          final tsStr = (data['timestamp'] ?? '').toString();
          final ts = DateTime.parse(tsStr);
          if (now.difference(ts) < const Duration(hours: 24)) {
            final uid = (data['userId'] ?? '').toString();
            if (uid.isNotEmpty) activeUsers.add(uid);
          }
        } catch (_) {
          // ignore parse errors
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
  // Attempts to navigate using named routes; if the route isn't configured,
  // falls back to a SnackBar so this file doesn't require imports that may
  // produce compile errors in projects with different layouts.
  void _performInterlinkAction(String actionRoute, String friendlyName) {
    try {
      // try navigating by named route if your app registers them
      Navigator.of(context).pushNamed(actionRoute);
    } catch (e) {
      // Fallback: show SnackBar telling developer/user which action was requested.
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
    } catch (_) {
      // fall through
    }
    // fallback to SocialReactionsScreen
    Navigator.push(context, MaterialPageRoute(builder: (_) => SocialReactionsScreen(accentColor: widget.accentColor)));
  }

  Future<void> _openStoriesHub() async {
    try {
      Navigator.of(context).pushNamed('/stories');
      return;
    } catch (_) {
      // If route not present, show a helpful SnackBar then fallback.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Route "/stories" not registered. Add it to open Stories hub directly. Falling back to Social screen.')),
        );
      }
    }
    // fallback: open the social screen (it contains stories tab), user can switch to stories quickly
    Navigator.push(context, MaterialPageRoute(builder: (_) => SocialReactionsScreen(accentColor: widget.accentColor)));
  }

  Future<void> _openPostReview() async {
    try {
      Navigator.of(context).pushNamed('/post_review');
      return;
    } catch (_) {
      // fallback to PostReviewScreen widget (imported)
    }
    
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => PostReviewScreen(
      accentColor: Colors.redAccent, // pick your theme/accent color
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
    } catch (_) {
      // fallback to SocialReactionsScreen
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => SocialReactionsScreen(accentColor: widget.accentColor)));
  }

  Future<void> _openWatchParty() async {
    // show bottom sheet to ask user if they want to open watch party
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
                          // try named route first, fallback to SocialReactionsScreen
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
    } catch (_) {
      // fallback to social/profile tab if user navigates there
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => SocialReactionsScreen(accentColor: widget.accentColor)));
  }

  Widget _buildQuickAction({required IconData icon, required String label, required VoidCallback onTap}) {
    // Gradient shader for icon — cheap and isolated to icon paint
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
          elevation: 1, // low elevation for performance
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: onTap,
        child: Row(
          children: [
            // ShaderMask paints the Icon with a gradient
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
              expandedHeight: 260, // increased to ensure TabBar won't overlap quick-actions
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

                                // --- Compact interlink quick actions (non-invasive) ---
                                const SizedBox(height: 14),
                                // use Row inside SingleChildScrollView to avoid heavy ListView in header
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
                                // --- end quick actions ---
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
                      // use controller.totalUnread for badge
                      final unreadCount = controller.totalUnread;
                      return TabBar(
                        controller: _tabController,
                        indicatorColor: widget.accentColor,
                        labelColor: widget.accentColor,
                        unselectedLabelColor: Colors.white54,
                        onTap: (_) {
                          // redraw when switching tabs
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
                    // Show nothing if no selection
                    if (_selectedChatId == null) return const SizedBox.shrink();
                    final otherUser = _selectedOtherUser;
                    final chatId = _selectedChatId;
                    // use summary.isGroup directly where needed (no unused local)
                    return Row(
                      children: [
                        FutureBuilder<bool>(
                          // quick check: see if otherUser is blocked by checking controller lists
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
                          if (isEmpty) {
                            // show placeholder / skeleton
                            return ListView.builder(
                              padding: const EdgeInsets.all(16.0),
                              itemCount: 5,
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
                            );
                          }

                          return ListView.builder(
                            padding: const EdgeInsets.all(16.0),
                            itemCount: visibleChats.length,
                            itemBuilder: (context, index) {
                              final summary = visibleChats[index];
                              // use summary.isGroup inline to avoid unused local variable warning
                              return ChatTile(
                                summary: summary,
                                accentColor: widget.accentColor,
                                controller: controller,
                                isSelected: summary.id == _selectedChatId,
                                // NEW: tell ChatTile whether other user has an active story
                                hasStory: _usersWithActiveStories.contains(summary.otherUser?['id'] ?? ''),
                                // NEW: tapping avatar opens that user's StoryScreen
                                onAvatarTap: () async {
                                  final otherId = (summary.otherUser?['id'] ?? '').toString();
                                  if (otherId.isEmpty) return;
                                  final now = DateTime.now();
                                  try {
                                    final snaps = await FirebaseFirestore.instance.collection('stories').where('userId', isEqualTo: otherId).get();
                                    final userStories = snaps.docs.map((d) {
                                      final m = Map<String, dynamic>.from(d.data() as Map<String, dynamic>);
                                      m['id'] = d.id;
                                      return m;
                                    }).where((s) {
                                      try {
                                        final ts = DateTime.parse(s['timestamp'] ?? DateTime.now().toIso8601String());
                                        return now.difference(ts) < const Duration(hours: 24);
                                      } catch (_) {
                                        return false;
                                      }
                                    }).toList();

                                    if (!mounted) return;
                                    if (userStories.isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No active stories')));
                                      return;
                                    }

                                    // Optional: mark as viewed here (commented out - enable if desired)
                                    // for (final s in userStories) {
                                    //   await FirebaseFirestore.instance.collection('stories').doc(s['id']).collection('views').doc(widget.currentUser['id']).set({'viewedAt': DateTime.now().toIso8601String()});
                                    // }

                                    Navigator.push(context, MaterialPageRoute(builder: (_) => StoryScreen(stories: userStories, currentUserId: widget.currentUser['id'] ?? '', initialIndex: 0)));
                                  } catch (e) {
                                    debugPrint('Failed to open stories for $otherId: $e');
                                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load stories: $e')));
                                  }
                                },
                                onTap: () async {
                                  // clear any previous selection
                                  _clearLocalSelection();

                                  // mark as read (WhatsApp-like)
                                  if (summary.unreadCount > 0) {
                                    await controller.markAsRead(summary.id, isGroup: summary.isGroup);
                                  }

                                  // navigate
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
                                  // set selection and show actions
                                  _selectedChatId = summary.id;
                                  _selectedOtherUser = summary.otherUser;
                                  _selectedIsGroup = summary.isGroup;
                                  _reloadTrigger.value = !_reloadTrigger.value;
                                  _showSelectionActions(chatId: summary.id, otherUser: summary.otherUser, isGroup: summary.isGroup);
                                },
                                onChatOpened: () {
                                  // small trigger to refresh topbar badges
                                  _reloadTrigger.value = !_reloadTrigger.value;
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
        onPressed: () => controller.showChatCreationOptions(context),
        backgroundColor: widget.accentColor,
        tooltip: fabTooltip,
        child: const Icon(Icons.chat, color: Colors.white),
      ),
    );
  }
}
