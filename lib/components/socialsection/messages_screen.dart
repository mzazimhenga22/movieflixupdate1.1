// messages_screen.dart
import 'package:flutter/material.dart';
import 'messages_controller.dart';
import 'chat_screen.dart';
import 'Group_chat_screen.dart';
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

  final bool _isLoadingMore = false;

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
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _tabController.dispose();
    _reloadTrigger.dispose();
    _isExpandedNotifier.dispose();
    controller.removeListener(_controllerListener);
    controller.dispose();
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
                                  const SizedBox(width: 4),
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
                    final isGroup = _selectedIsGroup;

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
                              final isGroup = summary.isGroup;
                              return ChatTile(
                                summary: summary,
                                accentColor: widget.accentColor,
                                controller: controller,
                                isSelected: summary.id == _selectedChatId,
                                onTap: () async {
                                  // clear any previous selection
                                  _clearLocalSelection();

                                  // mark as read (WhatsApp-like)
                                  if (summary.unreadCount > 0) {
                                    await controller.markAsRead(summary.id, isGroup: isGroup);
                                  }

                                  // navigate
                                  if (isGroup) {
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
        child: const Icon(Icons.chat, color: Colors.white),
      ),
    );
  }
}
