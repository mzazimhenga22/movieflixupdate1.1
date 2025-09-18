// social_reactions_screen.dart
// UI-only file that uses SocialReactionsController for logic and data.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart'; // for imageCache tuning
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:universal_html/html.dart' as html;
import 'package:movie_app/components/trending_movies_widget.dart';
import 'feed_reel_player_screen.dart';
import '../../models/reel.dart';
import 'stories.dart';
import 'messages_screen.dart';
import 'search_screen.dart';
import 'user_profile_screen.dart';
import 'streak_section.dart';
import 'notifications_section.dart';
import 'chat_screen.dart';
import 'PostStoryScreen.dart';
import 'chatutils.dart' as chatUtils;
import 'package:share_plus/share_plus.dart';
import 'package:movie_app/components/watch_party_screen.dart';
import 'post_review_screen.dart';
import 'polls_section.dart';
import 'algo.dart';
import 'storiecomponents.dart';

// controller import
import 'social_reactions_controller.dart';

/// Note: helper functions, FeedProvider and SimpleVideoPlayer now live in the controller file.

class PostCardWidget extends StatefulWidget {
  final Map<String, dynamic> post;
  final List<Map<String, dynamic>> allPosts;
  final Map<String, dynamic>? currentUser;
  final List<Map<String, dynamic>> users;
  final Color accentColor;
  final Future<void> Function(String id) onDelete;
  final Future<void> Function(String id, bool isLiked) onLike;
  final void Function(Map<String, dynamic> post) onComment;
  final void Function(Map<String, dynamic> post) onWatchParty;
  final void Function(Map<String, dynamic> post) onSend;
  final void Function(Map<String, dynamic> post) onShare;
  final Future<void> Function(Map<String, dynamic> post) onRetweet;
  final Future<void> Function(Map<String, dynamic> post) onSave;
  final bool muted;
  final Future<void> Function(String userId) onToggleMute;

  const PostCardWidget({
    super.key,
    required this.post,
    required this.allPosts,
    required this.currentUser,
    required this.users,
    required this.accentColor,
    required this.onDelete,
    required this.onLike,
    required this.onComment,
    required this.onWatchParty,
    required this.onSend,
    required this.onShare,
    required this.onRetweet,
    required this.onSave,
    required this.muted,
    required this.onToggleMute,
  });

  @override
  State<PostCardWidget> createState() => _PostCardWidgetState();
}

class _PostCardWidgetState extends State<PostCardWidget> {
  late List<String> likedBy;
  late bool isLiked;
  bool _saving = false;
  bool _muted = false;
  String _username = '';
  String _avatarUrl = '';
  bool _showInlineComments = false;
  final TextEditingController _commentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    likedBy = (widget.post['likedBy'] is List)
        ? (widget.post['likedBy'] as List).map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toList()
        : <String>[];
    final currentUserId = widget.currentUser?['id']?.toString() ?? '';
    isLiked = likedBy.contains(currentUserId);

    final userId = widget.post['userId']?.toString() ?? '';
    final userRecord = widget.users.firstWhere(
        (u) => (u['id']?.toString() ?? '') == userId,
        orElse: () => {'username': widget.post['user'] ?? 'Unknown', 'avatar': ''});
    _username = userRecord['username']?.toString() ?? 'Unknown';
    _avatarUrl = userRecord['avatar']?.toString() ?? '';
    _muted = widget.muted;

    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrecache());
  }

  void _maybePrecache() {
    try {
      if (_avatarUrl.isNotEmpty && _avatarUrl.startsWith('http')) {
        try {
          precacheImage(CachedNetworkImageProvider(_avatarUrl), context);
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _toggleMuteLocal() async {
    setState(() => _muted = !_muted);
    try {
      await widget.onToggleMute(widget.post['userId']?.toString() ?? '');
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_muted ? 'User muted' : 'User unmuted')));
    } catch (e) {
      debugPrint('mute error: $e');
      setState(() => _muted = !_muted);
    }
  }

  Future<void> _onLikePressed() async {
    final id = widget.post['id']?.toString() ?? '';
    final wasLiked = isLiked;
    setState(() {
      isLiked = !isLiked;
      final uid = widget.currentUser?['id']?.toString() ?? '';
      if (isLiked) {
        if (!likedBy.contains(uid)) likedBy.add(uid);
      } else {
        likedBy.remove(uid);
      }
    });
    try {
      await widget.onLike(id, wasLiked);
    } catch (e) {
      debugPrint('like action failed: $e');
      setState(() {
        isLiked = wasLiked;
        final uid = widget.currentUser?['id']?.toString() ?? '';
        if (wasLiked) {
          if (!likedBy.contains(uid)) likedBy.add(uid);
        } else {
          likedBy.remove(uid);
        }
      });
    }
  }

  Future<void> _onSavePressed() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(widget.post);
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      debugPrint('save failed: $e');
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool isValidImageUrl(String url) =>
      url.startsWith('http') &&
      (url.endsWith('.jpg') || url.endsWith('.jpeg') || url.endsWith('.png'));

  Future<void> _postCommentInline() async {
    final post = widget.post;
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    _commentController.clear();
    FocusScope.of(context).unfocus();
    // delegate to controller-less helper via Firebase directly for speed
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(post['userId']?.toString())
          .collection('posts')
          .doc(post['id']?.toString())
          .collection('comments')
          .add({
        'text': text,
        'userId': widget.currentUser?['id'],
        'username': widget.currentUser?['username'],
        'userAvatar': widget.currentUser?['avatar'],
        'timestamp': DateTime.now().toIso8601String(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Comment posted')));
      }
    } catch (e) {
      debugPrint('comment error: $e');
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to post comment: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final id = post['id']?.toString() ?? '';
    final message = post['post']?.toString() ?? '';
    final title = post['title']?.toString() ?? '';
    final season = post['season']?.toString() ?? '';
    final episode = post['episode']?.toString() ?? '';
    final media = post['media']?.toString() ?? '';
    final mediaType = post['mediaType']?.toString() ?? '';
    final thumbnail = post['thumbnail']?.toString() ?? '';
    final userId = post['userId']?.toString() ?? '';

    int parseSafeInt(dynamic v) {
      if (v is int) return v;
      if (v is double) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    final retweetCount = parseSafeInt(post['retweetCount']);
    final currentUserId = widget.currentUser?['id']?.toString() ?? '';

    final screenHeight = MediaQuery.of(context).size.height;
    final imageHeight =
        ((screenHeight * 0.70).clamp(160.0, screenHeight * 0.85));

    final borderRadius = BorderRadius.circular(12.0);

    final DateTime timestampDt = post['timestampDt'] is DateTime ? post['timestampDt'] as DateTime : DateTime.now();

    Widget mediaWidget() {
      if (media.isNotEmpty) {
        if (mediaType == 'photo' && isValidImageUrl(media)) {
          return CachedNetworkImage(
            imageUrl: media,
            fit: BoxFit.cover,
            width: double.infinity,
            height: imageHeight,
            placeholder: (c, url) => Container(
              color: Colors.grey[850],
              alignment: Alignment.center,
              height: imageHeight,
              child: const CircularProgressIndicator(),
            ),
            fadeInDuration: const Duration(milliseconds: 300),
            errorWidget: (c, url, err) => Container(
              color: Colors.grey[800],
              height: imageHeight,
              child: const Icon(Icons.broken_image, size: 40),
            ),
          );
        } else if (mediaType == 'video') {
          final thumb = (thumbnail.isNotEmpty) ? thumbnail : null;
          return SimpleVideoPlayer(
            videoUrl: media,
            autoPlay: true,
            height: imageHeight,
            thumbnailUrl: thumb,
            onTap: () {
              final videoPosts = widget.allPosts
                  .where((p) => (p['mediaType']?.toString() ?? '') == 'video' && (p['media']?.toString() ?? '').isNotEmpty)
                  .map((p) => Reel(
                      videoUrl: (p['media']?.toString() ?? ''),
                      movieTitle: (p['title']?.toString() ?? 'Video'),
                      movieDescription: (p['post']?.toString() ?? '')))
                  .toList();
              final idx = videoPosts.indexWhere((r) => r.videoUrl == media);
              if (idx != -1) {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => FeedReelPlayerScreen(reels: videoPosts, initialIndex: idx)));
              } else {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => FeedReelPlayerScreen(reels: [
                              Reel(videoUrl: media, movieTitle: title, movieDescription: message)
                            ], initialIndex: 0)));
              }
            },
          );
        }
      }
      return Container(
        height: imageHeight,
        color: Colors.grey[850],
        child: const Center(child: Icon(Icons.image, size: 40)),
      );
    }

    Widget bottomOverlay() {
      return Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.black.withOpacity(0.6), Colors.black.withOpacity(0.12)],
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: widget.accentColor,
                backgroundImage: _avatarUrl.isNotEmpty ? CachedNetworkImageProvider(_avatarUrl) : null,
                child: _avatarUrl.isEmpty ? Text(_username.isNotEmpty ? _username[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white)) : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_username, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 5),
                    Text(message, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 6),
                    Row(children: [
                      if (title.isNotEmpty) Flexible(child: Text('Movie: $title', style: const TextStyle(color: Colors.white54, fontStyle: FontStyle.italic, fontSize: 12), overflow: TextOverflow.ellipsis)),
                      if (season.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 6.0), child: Text('S:$season', style: const TextStyle(color: Colors.white54, fontSize: 12))),
                      if (episode.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 6.0), child: Text('E:$episode', style: const TextStyle(color: Colors.white54, fontSize: 12))),
                    ]),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.favorite, color: isLiked ? Colors.redAccent : Colors.white70, size: 18),
                  const SizedBox(height: 6),
                  Text(likedBy.length.toString(), style: const TextStyle(color: Colors.white70)),
                ],
              ),
            ],
          ),
        ),
      );
    }

    Widget inlineCommentsPanel() {
      final commentsStream = FirebaseFirestore.instance
          .collection('users')
          .doc(post['userId']?.toString())
          .collection('posts')
          .doc(post['id']?.toString())
          .collection('comments')
          .orderBy('timestamp', descending: true)
          .snapshots();

      final panelHeight = (imageHeight * 0.5).clamp(180.0, 420.0);

      return Positioned(
        left: 12,
        right: 12,
        bottom: 12,
        child: Container(
          height: panelHeight,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.55),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: widget.accentColor.withOpacity(0.08)),
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            children: [
              Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    const Icon(Icons.chat_bubble_outline, color: Colors.white70, size: 18),
                    const SizedBox(width: 8),
                    Text('Comments', style: TextStyle(color: widget.accentColor, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                      onPressed: () => setState(() => _showInlineComments = false),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white10, height: 1),
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: commentsStream,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      debugPrint('inline comments stream error: ${snap.error}');
                      return const Center(child: Text('Failed to load comments', style: TextStyle(color: Colors.white70)));
                    }
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final docs = snap.data!.docs;
                    if (docs.isEmpty) {
                      return const Center(child: Text('No comments yet', style: TextStyle(color: Colors.white70)));
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const Divider(color: Colors.white10),
                      itemBuilder: (context, i) {
                        final d = docs[i].data() as Map<String, dynamic>;
                        final avatar = (d['userAvatar'] ?? '').toString();
                        final username = (d['username'] ?? 'Unknown').toString();
                        final text = (d['text'] ?? '').toString();
                        final timestamp = (d['timestamp'] ?? '').toString();
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                          leading: CircleAvatar(
                            radius: 18,
                            backgroundImage: avatar.isNotEmpty && avatar.startsWith('http') ? CachedNetworkImageProvider(avatar) : null,
                            backgroundColor: widget.accentColor,
                            child: avatar.isEmpty ? Text(username.isNotEmpty ? username[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white)) : null,
                          ),
                          title: Text(username, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(text, style: const TextStyle(color: Colors.white70)),
                              const SizedBox(height: 4),
                              Text(friendlyTimeFromIso(timestamp), style: const TextStyle(color: Colors.white38, fontSize: 11)),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _commentController,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _postCommentInline(),
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Add a comment',
                            hintStyle: const TextStyle(color: Colors.white54),
                            filled: true,
                            fillColor: Colors.white12,
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: widget.accentColor, minimumSize: const Size(64, 44)),
                        onPressed: _postCommentInline,
                        child: const Text('Post'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.02),
              borderRadius: borderRadius,
              border: Border.all(color: widget.accentColor.withOpacity(0.06)),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.28), blurRadius: 10, offset: const Offset(0, 6))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (media.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(color: widget.accentColor.withOpacity(0.18), blurRadius: 10, spreadRadius: 1)
                            ],
                          ),
                          child: CircleAvatar(
                            radius: 18,
                            backgroundColor: widget.accentColor,
                            backgroundImage: _avatarUrl.isNotEmpty ? CachedNetworkImageProvider(_avatarUrl) : null,
                            child: _avatarUrl.isEmpty ? Text(_username.isNotEmpty ? _username[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white)) : null,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_username, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(friendlyTimeFromDateTime(timestampDt), style: TextStyle(color: Colors.white70, fontSize: 12)),
                        ])),
                        IconButton(icon: const Icon(Icons.more_horiz, color: Colors.white70), onPressed: () {
                          showModalBottomSheet(context: context, backgroundColor: Colors.grey[900], builder: (ctx) {
                            return SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
                              ListTile(leading: const Icon(Icons.person_add, color: Colors.white), title: const Text('Follow/Unfollow', style: TextStyle(color: Colors.white)), onTap: () {
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Toggled follow for $_username')));
                              }),
                              ListTile(leading: Icon(_muted ? Icons.volume_off : Icons.volume_up, color: Colors.white), title: Text(_muted ? 'Unmute user' : 'Mute user', style: const TextStyle(color: Colors.white)), onTap: () {
                                Navigator.pop(ctx);
                                _toggleMuteLocal();
                              }),
                              ListTile(leading: const Icon(Icons.report, color: Colors.white), title: const Text('Report', style: TextStyle(color: Colors.white)), onTap: () {
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reported')));
                              }),
                            ]));
                          });
                        }),
                      ],
                    ),
                  ),
                if (media.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        children: [
                          SizedBox(
                            height: imageHeight,
                            width: double.infinity,
                            child: mediaWidget(),
                          ),
                          bottomOverlay(),
                          if (_showInlineComments) inlineCommentsPanel(),
                        ],
                      ),
                    ),
                  ),

                if (media.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text(message, style: const TextStyle(color: Colors.white70)),
                  ),

                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6),
                  child: Row(children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          _FrostedIconButton(
                            onTap: _onLikePressed,
                            child: Row(children: [
                              Icon(isLiked ? Icons.favorite : Icons.favorite_border, color: isLiked ? Colors.redAccent : Colors.white70, size: 20),
                              const SizedBox(width: 6),
                              Text(likedBy.length.toString(), style: const TextStyle(color: Colors.white70)),
                            ]),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onLongPress: () => widget.onComment(widget.post),
                            child: _FrostedIconButton(
                              onTap: () => setState(() => _showInlineComments = !_showInlineComments),
                              child: Row(children: const [
                                Icon(Icons.comment, color: Colors.white70, size: 20),
                                SizedBox(width: 6),
                                Text('Comment', style: TextStyle(color: Colors.white70))
                              ]),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _FrostedIconButton(onTap: () => widget.onWatchParty(widget.post), child: Row(children: const [
                            Icon(Icons.connected_tv, color: Colors.white70, size: 20),
                            SizedBox(width: 6),
                            Text('Watch', style: TextStyle(color: Colors.white70))
                          ])),
                        ]),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      _FrostedIconButton(onTap: () => widget.onRetweet(widget.post), child: Row(children: [
                        const Icon(Icons.repeat, color: Colors.white70, size: 20),
                        const SizedBox(width: 6),
                        Text(retweetCount.toString(), style: const TextStyle(color: Colors.white70))
                      ])),
                      const SizedBox(width: 8),
                      _FrostedIconButton(onTap: () => widget.onShare(widget.post), child: const Icon(Icons.share, color: Colors.white70, size: 20)),
                      const SizedBox(width: 8),
                      _FrostedIconButton(onTap: _onSavePressed, child: _saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.bookmark_border, color: Colors.white70, size: 20)),
                      if (userId == currentUserId) ...[
                        const SizedBox(width: 8),
                        _FrostedIconButton(onTap: () => widget.onDelete(id), child: const Icon(Icons.delete, color: Colors.redAccent, size: 20)),
                      ],
                    ]),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FrostedIconButton extends StatelessWidget {
  final VoidCallback onTap;
  final Widget child;
  const _FrostedIconButton({required this.onTap, required this.child});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(0.02),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: DefaultTextStyle(
            style: const TextStyle(fontSize: 13),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// ----------------- SocialReactionsScreen wrapper -----------------
class SocialReactionsScreen extends StatelessWidget {
  final Color accentColor;
  const SocialReactionsScreen({super.key, required this.accentColor});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => FeedProvider(),
      child: _SocialReactionsScreen(accentColor: accentColor),
    );
  }
}

class _SocialReactionsScreen extends StatefulWidget {
  final Color accentColor;
  const _SocialReactionsScreen({required this.accentColor});

  @override
  State<_SocialReactionsScreen> createState() => _SocialReactionsScreenState();
}

class _SocialReactionsScreenState extends State<_SocialReactionsScreen>
    with WidgetsBindingObserver {
  // UI-only controllers
  final ScrollController _mainScrollController = ScrollController();
  final ScrollController _storiesScrollController = ScrollController();
  final PageStorageKey _feedKey = const PageStorageKey('feed-list');
  static const double _storyHeight = 110.0;

  // Light UI state
  int _selectedIndex = 0;
  bool _showStories = true;
  double _lastScrollOffset = 0.0;
  bool _initialized = false;
  final List<String> _notifications = [];

  // Controller (logic + data)
  late SocialReactionsController controller;

  // error handlers backup
  bool Function(Object, StackTrace)? _prevPlatformOnError;
  FlutterExceptionHandler? _prevFlutterOnError;

  @override
  void initState() {
    super.initState();

    // cap image cache
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.maximumSize = 50;
      PaintingBinding.instance.imageCache.maximumSizeBytes = 100 << 20; // ~100MB
    } catch (e) {
      debugPrint('Failed to tune imageCache: $e');
    }

    // create controller
    controller = SocialReactionsController(
      supabase: Supabase.instance.client,
      onChange: () {
        if (mounted) setState(() {});
      },
    );

    WidgetsBinding.instance.addObserver(this);
    _mainScrollController.addListener(_onScrollThrottled);

    // lightweight global error capture
    _prevPlatformOnError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('Uncaught platform error: $error\n$stack');
      if (mounted) {
        try {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Internal error: ${error.toString()}')));
          });
        } catch (_) {}
      }
      return _prevPlatformOnError?.call(error, stack) ?? false;
    };

    _prevFlutterOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      debugPrint('FlutterError caught: ${details.exception}\n${details.stack}');
      _prevFlutterOnError?.call(details);
    };

    _initializeData();
  }

  void _onScrollThrottled() {
    if (!_mainScrollController.hasClients) return;
    final offset = _mainScrollController.position.pixels;
    final delta = offset - _lastScrollOffset;
    if (delta > 30 && _showStories) {
      setState(() => _showStories = false);
    } else if (delta < -30 && !_showStories) {
      setState(() => _showStories = true);
    }
    _lastScrollOffset = offset.clamp(0.0, double.infinity);

    final feed = Provider.of<FeedProvider>(context, listen: false);
    if (_mainScrollController.position.pixels >=
            _mainScrollController.position.maxScrollExtent - 120 &&
        !feed.isLoading &&
        feed.hasMorePosts) {
      feed.fetchPosts();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mainScrollController.dispose();
    _storiesScrollController.dispose();

    // restore error handlers
    try {
      PlatformDispatcher.instance.onError = _prevPlatformOnError;
      FlutterError.onError = _prevFlutterOnError;
    } catch (_) {}

    super.dispose();
  }

  Future<void> _initializeData() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await controller.initialize();
      await Provider.of<FeedProvider>(context, listen: false).fetchPosts(isRefresh: true);
      controller.refreshRankedCache(Provider.of<FeedProvider>(context, listen: false).feedPosts);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollStoriesToEnd());
    } catch (e, st) {
      debugPrint('Screen init error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to initialize: $e')));
      }
    }
  }

  void _scrollStoriesToEnd() {
    try {
      if (!_storiesScrollController.hasClients) return;
      final max = _storiesScrollController.position.maxScrollExtent;
      _storiesScrollController.animateTo(max,
          duration: const Duration(milliseconds: 420), curve: Curves.easeOut);
    } catch (e) {
      debugPrint('scroll stories failed: $e');
    }
  }

  void _onTabTapped(int index) => setState(() => _selectedIndex = index);

  void _showFabActions() {
    showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (context) => Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: const BorderRadius.all(Radius.circular(12))),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
               ListTile(
  leading: const Icon(Icons.message, color: Colors.white),
  title: const Text('New Message', style: TextStyle(color: Colors.white)),
  onTap: () {
    Navigator.pop(context);
    if (controller.currentUser != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MessagesScreen(
            currentUser: controller.currentUser!,
            accentColor: widget.accentColor,
          ),
        ),
      );
    } else {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User data not loaded')));
    }
  },
),
                if (!_showStories)
                  ListTile(
                      leading: const Icon(Icons.expand, color: Colors.white),
                      title: const Text('Expand Recommendations',
                          style: TextStyle(color: Colors.white)),
                      onTap: () {
                        Navigator.pop(context);
                        setState(() => _showStories = true);
                      }),
              ]),
            ));
  }

  // UI builders: mostly unchanged but they reference `controller` for data + operations.
  Widget _buildStoriesScroller() {
    return SizedBox(
      height: _storyHeight,
      child: StoriesRow(
        stories: controller.stories,
        height: _storyHeight,
        currentUserAvatar: controller.currentUser?['avatar']?.toString(),
        currentUser: controller.currentUser,
        accentColor: widget.accentColor,
        forceNavigateOnAdd: false,
        onAddStory: () async {
          // simplified: pick -> call controller.postStory -> update UI
          final choice = await showModalBottomSheet<String>(
            context: context,
            builder: (context) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                  leading: const Icon(Icons.photo, color: Colors.white),
                  title: const Text("Upload Photo", style: TextStyle(color: Colors.white)),
                  onTap: () => Navigator.pop(context, 'photo')),
              ListTile(
                  leading: const Icon(Icons.videocam, color: Colors.white),
                  title: const Text("Upload Video", style: TextStyle(color: Colors.white)),
                  onTap: () => Navigator.pop(context, 'video')),
            ])),
          );
          if (choice == null) return;
          final picked = await controller.pickFile(choice);
          if (picked == null) return;

          showDialog(
              context: context,
              barrierDismissible: false,
              builder: (_) => const AlertDialog(
                      content: Row(children: [
                    CircularProgressIndicator(),
                    SizedBox(width: 12),
                    Text('Uploading...')
                  ])));

          try {
            await controller.postStory(picked, choice, context);
            WidgetsBinding.instance.addPostFrameCallback((_) => _scrollStoriesToEnd());
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Story posted')));
          } catch (e) {
            debugPrint('post story error: $e');
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to post story: $e')));
          } finally {
            if (mounted) Navigator.pop(context);
          }
        },
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }

  Widget _buildFeedTab() {
    return Consumer<FeedProvider>(builder: (context, feedProvider, child) {
      final rankedPosts = controller.getCachedRanked(feedProvider.feedPosts);

      return LayoutBuilder(builder: (context, constraints) {
        final double estimatedTabBarHeight = 56.0;
        final double otherFixed = _storyHeight + 48.0 + estimatedTabBarHeight + 32.0;
        final bool hasBounded = constraints.hasBoundedHeight && constraints.maxHeight.isFinite;

        final double tabViewHeight = hasBounded
            ? (constraints.maxHeight - otherFixed).clamp(240.0, constraints.maxHeight)
            : (MediaQuery.of(context).size.height * 0.62);

        return Column(children: [
          SizedBox(
            height: _storyHeight,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: _showStories ? 1.0 : 0.0,
              curve: Curves.easeInOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                transform: Matrix4.translationValues(0, _showStories ? 0 : -18, 0),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 0),
                  child: _buildStoriesScroller(),
                ),
              ),
            ),
          ),

          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: widget.accentColor,
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 6),
                onPressed: () {
                  if (controller.currentUser == null) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User data not loaded')));
                    return;
                  }
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => PostReviewScreen(
                              accentColor: widget.accentColor,
                              currentUser: controller.currentUser)));
                },
                icon: const Icon(Icons.rate_review, size: 20),
                label: const Text('Post Movie Review', style: TextStyle(fontSize: 16)),
              )),

          DefaultTabController(
            length: 4,
            child: Column(
              children: [
                Material(
                  color: Colors.transparent,
                  child: TabBar(
                    isScrollable: true,
                    labelColor: widget.accentColor,
                    unselectedLabelColor: Colors.white70,
                    indicator: UnderlineTabIndicator(
                      borderSide: BorderSide(width: 3.0, color: widget.accentColor),
                      insets: const EdgeInsets.symmetric(horizontal: 12.0),
                    ),
                    tabs: const [
                      Tab(text: 'Feed'),
                      Tab(text: 'Recommended'),
                      Tab(text: 'Live'),
                      Tab(text: 'Movie Match'),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                SizedBox(
                  height: tabViewHeight,
                  child: TabBarView(
                    children: [
                      RefreshIndicator(
                        onRefresh: () async {
                          await feedProvider.fetchPosts(isRefresh: true);
                          controller.refreshRankedCache(feedProvider.feedPosts);
                        },
                        child: CustomScrollView(
                          key: _feedKey,
                          controller: _mainScrollController,
                          slivers: [
                            SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  if (index >= rankedPosts.length) {
                                    return feedProvider.hasMorePosts
                                        ? const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: Center(child: CircularProgressIndicator()))
                                        : const SizedBox.shrink();
                                  }
                                  final item = rankedPosts[index];

                                  final isMuted = controller.mutedUsers.contains((item['userId'] ?? '').toString());
                                  if (isMuted) {
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12),
                                      child: Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: Colors.white10,
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Expanded(
                                              child: Text('Muted content', style: TextStyle(color: Colors.white.withOpacity(0.8))),
                                            ),
                                            TextButton(
                                              onPressed: () async {
                                                await controller.toggleMuteForUser((item['userId'] ?? '').toString());
                                              },
                                              child: const Text('Unmute'),
                                            )
                                          ],
                                        ),
                                      ),
                                    );
                                  }

                                  return PostCardWidget(
                                    key: ValueKey(item['id']),
                                    post: item,
                                    allPosts: rankedPosts,
                                    currentUser: controller.currentUser,
                                    users: controller.users,
                                    accentColor: widget.accentColor,
                                    muted: isMuted,
                                    onToggleMute: (userId) async {
                                      await controller.toggleMuteForUser(userId);
                                    },
                                    onDelete: (id) async {
                                      try {
                                        await FirebaseFirestore.instance.collection('feeds').doc(id).delete();
                                        feedProvider.removePost(id);
                                        controller.refreshRankedCache(feedProvider.feedPosts);
                                      } catch (e) {
                                        debugPrint('delete post error: $e');
                                        if (mounted)
                                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete post: $e')));
                                      }
                                    },
                                    onLike: (id, wasLiked) async {
                                      try {
                                        final ref = FirebaseFirestore.instance.collection('feeds').doc(id);
                                        if (wasLiked) {
                                          await ref.update({
                                            'likedBy': FieldValue.arrayRemove([controller.currentUser?['id'] ?? ''])
                                          });
                                        } else {
                                          await ref.update({
                                            'likedBy': FieldValue.arrayUnion([controller.currentUser?['id'] ?? ''])
                                          });
                                        }
                                      } catch (e) {
                                        debugPrint('like error: $e');
                                        if (mounted)
                                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to like post: $e')));
                                      }
                                    },
                                    onComment: _showComments,
                                    onWatchParty: (post) {
                                      Navigator.push(context, MaterialPageRoute(builder: (_) => WatchPartyScreen(post: post)));
                                    },
                                    onSend: (post) {
                                      final code = (100000 + Random().nextInt(900000)).toString();
                                      if (mounted)
                                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Started Watch Party: Code $code')));
                                      setState(() {
                                        _notifications.add('${controller.currentUser?['username'] ?? 'User'} started a watch party with code $code');
                                      });
                                    },
                                    onShare: (post) async {
                                      try {
                                        final shareText = '${post['post']}\n\nShared from MovieFlix';
                                        if (post['media'] != null && (post['media'] as String).isNotEmpty) {
                                          await Share.share('${post['post']}\n${post['media']}\n\nShared from MovieFlix');
                                        } else {
                                          await Share.share(shareText);
                                        }
                                      } catch (e) {
                                        debugPrint('share error: $e');
                                        if (mounted)
                                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to share: $e')));
                                      }
                                    },
                                    onRetweet: (post) async {
                                      if (controller.currentUser == null) {
                                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User data not loaded')));
                                        return;
                                      }
                                      try {
                                        final originalId = post['id']?.toString() ?? '';
                                        final newPost = {
                                          'user': controller.currentUser?['username'] ?? 'User',
                                          'userId': controller.currentUser?['id']?.toString() ?? '',
                                          'post': 'Retweeted: ${post['post'] ?? ''}',
                                          'type': 'retweet',
                                          'likedBy': [],
                                          'title': post['title'] ?? '',
                                          'season': post['season'] ?? '',
                                          'episode': post['episode'] ?? '',
                                          'media': post['media'] ?? '',
                                          'mediaType': post['mediaType'] ?? '',
                                          'thumbnail': post['thumbnail'] ?? '',
                                          'timestamp': DateTime.now().toIso8601String(),
                                          'timestampDt': DateTime.now(),
                                          'originalPostId': originalId,
                                        };

                                        final docRef = await FirebaseFirestore.instance.collection('feeds').add(newPost);
                                        newPost['id'] = docRef.id;
                                        if (originalId.isNotEmpty) {
                                          final originalRef = FirebaseFirestore.instance.collection('feeds').doc(originalId);
                                          await originalRef.update({'retweetCount': FieldValue.increment(1)});
                                        }

                                        Provider.of<FeedProvider>(context, listen: false).addPost(newPost);
                                        controller.refreshRankedCache(Provider.of<FeedProvider>(context, listen: false).feedPosts);
                                      } catch (e) {
                                        debugPrint('retweet error: $e');
                                        if (mounted)
                                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to repost: $e')));
                                      }
                                    },
                                    onSave: (post) async {
                                      try {
                                        final id = (post['id']?.toString() ?? '');
                                        if (id.isEmpty) throw Exception('Invalid id');
                                        controller.savedPosts.add(id);
                                        await controller.saveLocalData();
                                      } catch (e) {
                                        debugPrint('save post error: $e');
                                        rethrow;
                                      }
                                    },
                                  );
                                },
                                childCount: rankedPosts.length + (feedProvider.hasMorePosts ? 1 : 0),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Recommended Tab
                      SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Recommended Movies', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                              const SizedBox(height: 12),
                              SizedBox(
                                height: 320,
                                child: TrendingMoviesWidget(),
                              ),
                              const SizedBox(height: 20),
                            ],
                          ),
                        ),
                      ),

                      // Live Tab
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20.0),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.wifi_tethering, size: 56, color: widget.accentColor),
                            const SizedBox(height: 12),
                            const Text('Live events will appear here', style: TextStyle(color: Colors.white70)),
                            const SizedBox(height: 6),
                            ElevatedButton(onPressed: () {
                              if (controller.currentUser == null) {
                                if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User not loaded')));
                                return;
                              }
                              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No live events currently')));
                            }, child: const Text('Check Live')),
                          ]),
                        ),
                      ),

                      // Movie Match Tab
                      SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('Movie Match', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                            const SizedBox(height: 12),
                            const Text('Find movies that match your taste. Coming soon.', style: TextStyle(color: Colors.white70)),
                            const SizedBox(height: 20),
                            ElevatedButton(onPressed: () {
                              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Movie Match coming soon')));
                            }, child: const Text('Try Match')),
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ]);
      });
    });
  }

  Widget _buildStoriesTab() {
    Widget _buildTileCard(String title, IconData icon, {VoidCallback? onTap}) {
      return GestureDetector(
        onTap: onTap ??
            () {
              if (mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('Tapped $title')));
              }
            },
        child: Container(
          margin: const EdgeInsets.all(8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: widget.accentColor.withOpacity(0.06)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 6, offset: const Offset(0, 4))],
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.accentColor.withOpacity(0.12),
                ),
                child: Icon(icon, color: widget.accentColor, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.white54),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 120,
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('stories').snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                debugPrint('stories stream error: ${snapshot.error}');
                return const Center(
                  child: Text('Failed to load stories.', style: TextStyle(color: Colors.white)),
                );
              }

              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final stories = snapshot.data!.docs.map((doc) {
                final map = (doc.data() as Map<String, dynamic>?) ?? {};
                return {...map, 'id': doc.id};
              }).where((s) {
                try {
                  final ts = s['timestamp']?.toString() ?? '';
                  if (ts.isEmpty) return false;
                  final parsed = DateTime.parse(ts);
                  return DateTime.now().difference(parsed) < const Duration(hours: 24);
                } catch (_) {
                  return false;
                }
              }).toList();

              if (stories.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      _buildYourStoryTile(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text('No stories available right now', style: TextStyle(color: Colors.white70)),
                      ),
                    ],
                  ),
                );
              }

              return StoriesRow(
                stories: stories,
                height: 120,
                currentUserAvatar: controller.currentUser?['avatar']?.toString(),
                currentUser: controller.currentUser,
                accentColor: widget.accentColor,
                forceNavigateOnAdd: true,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              );
            },
          ),
        ),

        const SizedBox(height: 12),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.accentColor,
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 4,
            ),
            onPressed: () {
              if (controller.currentUser != null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PostStoryScreen(accentColor: widget.accentColor, currentUser: controller.currentUser!),
                  ),
                );
              } else {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User data not loaded')));
              }
            },
            icon: const Icon(Icons.add_a_photo, size: 20),
            label: const Text('Post Story', style: TextStyle(fontSize: 16)),
          ),
        ),

        const SizedBox(height: 12),

        DefaultTabController(
          length: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Material(
                  color: Colors.transparent,
                  child: TabBar(
                    isScrollable: true,
                    labelColor: widget.accentColor,
                    unselectedLabelColor: Colors.white70,
                    indicator: UnderlineTabIndicator(
                      borderSide: BorderSide(width: 3.0, color: widget.accentColor),
                      insets: const EdgeInsets.symmetric(horizontal: 12.0),
                    ),
                    tabs: const [
                      Tab(text: 'All'),
                      Tab(text: 'Weekly'),
                      Tab(text: 'Movies'),
                      Tab(text: 'Users'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),

              SizedBox(
                height: 320,
                child: TabBarView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                      child: PollsSection(accentColor: widget.accentColor, currentUser: controller.currentUser, categoryFilterKey: 'all'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                      child: PollsSection(accentColor: widget.accentColor, currentUser: controller.currentUser, categoryFilterKey: 'weekly'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                      child: PollsSection(accentColor: widget.accentColor, currentUser: controller.currentUser, categoryFilterKey: 'movies'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                      child: PollsSection(accentColor: widget.accentColor, currentUser: controller.currentUser, categoryFilterKey: 'users'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildYourStoryTile() {
    final avatarUrl =
        (controller.currentUser?['avatar'] ?? controller.currentUser?['photoUrl'] ?? '')
                ?.toString() ??
            '';
    final username = (controller.currentUser?['username'] ?? 'You')?.toString() ?? 'You';

    return GestureDetector(
      onTap: () {
        if (controller.currentUser != null) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PostStoryScreen(
                  accentColor: widget.accentColor, currentUser: controller.currentUser!),
            ),
          );
        } else {
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('User data not loaded')));
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.grey.shade800,
              border: Border.all(
                  color: widget.accentColor.withOpacity(0.95), width: 2),
              boxShadow: [
                BoxShadow(
                    color: widget.accentColor.withOpacity(0.22),
                    blurRadius: 8,
                    spreadRadius: 1)
              ],
              image: avatarUrl.isNotEmpty && avatarUrl.startsWith('http')
                  ? DecorationImage(
                      image: CachedNetworkImageProvider(avatarUrl),
                      fit: BoxFit.cover)
                  : null,
            ),
            child: avatarUrl.isEmpty
                ? Center(
                    child: Text(
                        (username.isNotEmpty ? username[0].toUpperCase() : 'U'),
                        style:
                            const TextStyle(color: Colors.white, fontSize: 22)))
                : null,
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 80,
            child: Text(
              'Your story',
              style: const TextStyle(color: Colors.white, fontSize: 12),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  void _promptCreateWatchParty(Map<String, dynamic> post) {
    showDialog(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Create Watch Party'),
                content: const Text(
                    'Do you want to create a watch party for this post?'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('No')),
                  TextButton(
                      onPressed: () {
                        final code =
                            (100000 + Random().nextInt(900000)).toString();
                        Navigator.pop(context);
                        if (mounted)
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(
                                  'Watch Party created with code: $code')));
                        setState(() {
                          _notifications.add(
                              '${controller.currentUser?['username'] ?? 'User'} created a watch party with code $code');
                        });
                      },
                      child: const Text('Yes')),
                ]));
  }

  void _showComments(Map<String, dynamic> post) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final TextEditingController controllerText = TextEditingController();
        return AnimatedPadding(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: DraggableScrollableSheet(
            initialChildSize: 0.80,
            minChildSize: 0.35,
            maxChildSize: 0.95,
            expand: false,
            builder: (context, scrollController) {
              return Container(
                margin:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                clipBehavior: Clip.hardEdge,
                child: Column(
                  children: [
                    Container(
                      height: 10,
                      alignment: Alignment.center,
                      child: Container(
                        width: 48,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),

                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16.0, vertical: 8),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text('Comments',
                                style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white)),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                    ),

                    const Divider(color: Color.fromARGB(31, 255, 255, 255), height: 1),

                    Expanded(
                      child: MediaQuery(
                        data: MediaQuery.of(context)
                            .copyWith(viewInsets: EdgeInsets.zero),
                        child: StreamBuilder<QuerySnapshot>(
                          stream: FirebaseFirestore.instance
                              .collection('users')
                              .doc(post['userId']?.toString())
                              .collection('posts')
                              .doc(post['id']?.toString())
                              .collection('comments')
                              .orderBy('timestamp', descending: true)
                              .snapshots(),
                          builder: (context, snap) {
                            if (snap.hasError) {
                              debugPrint(
                                  'comments stream error: ${snap.error}');
                              return const Center(
                                  child: Text('Failed to load comments.',
                                      style: TextStyle(color: Colors.white)));
                            }
                            if (!snap.hasData) {
                              return const Center(
                                  child: CircularProgressIndicator());
                            }

                            final docs = snap.data!.docs;

                            if (docs.isEmpty) {
                              return const Center(
                                  child: Text('No comments yet',
                                      style: TextStyle(color: Colors.white70)));
                            }

                            return ListView.separated(
                              controller: scrollController,
                              padding: const EdgeInsets.symmetric(
                                  vertical: 8, horizontal: 8),
                              itemCount: docs.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(color: Colors.white10),
                              itemBuilder: (context, i) {
                                final d =
                                    docs[i].data() as Map<String, dynamic>;
                                final avatar =
                                    (d['userAvatar'] ?? '').toString();
                                final username =
                                    (d['username'] ?? 'Unknown').toString();
                                final text = (d['text'] ?? '').toString();
                                final timestamp =
                                    (d['timestamp'] ?? '').toString();

                                return RepaintBoundary(
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                        vertical: 6, horizontal: 12),
                                    leading: CircleAvatar(
                                      radius: 20,
                                      backgroundImage: avatar.isNotEmpty &&
                                              avatar.startsWith('http')
                                          ? CachedNetworkImageProvider(avatar)
                                          : null,
                                      backgroundColor: widget.accentColor,
                                      child: avatar.isEmpty
                                          ? Text(
                                              username.isNotEmpty
                                                  ? username[0].toUpperCase()
                                                  : '?',
                                              style: const TextStyle(
                                                  color: Colors.white))
                                          : null,
                                    ),
                                    title: Text(username,
                                        style: TextStyle(
                                            color: widget.accentColor,
                                            fontWeight: FontWeight.w600)),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(text,
                                            style: const TextStyle(
                                                color: Colors.white70)),
                                        const SizedBox(height: 6),
                                        Text(
                                          friendlyTimeFromIso(timestamp),
                                          style: const TextStyle(
                                              color: Colors.white38,
                                              fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),

                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12.0, vertical: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: controllerText,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) =>
                                    controller.postCommentInline(controllerText.text, post, context),
                                style: const TextStyle(color: Colors.white),
                                decoration: InputDecoration(
                                  hintText: 'Add a comment',
                                  hintStyle:
                                      const TextStyle(color: Colors.white54),
                                  filled: true,
                                  fillColor: Colors.white12,
                                  border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide: BorderSide.none),
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 12),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: widget.accentColor,
                                  minimumSize: const Size(64, 44)),
                              onPressed: () =>
                                  controller.postCommentInline(controllerText.text, post, context),
                              child: const Text('Post'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      _buildFeedTab(),
      _buildStoriesTab(),
      NotificationsSection(notifications: _notifications),
      StreakSection(
          movieStreak: controller.movieStreak,
          onStreakUpdated: (newStreak) => setState(() => controller.movieStreak = newStreak)),
      controller.currentUser != null
          ? UserProfileScreen(
              key: ValueKey(controller.currentUser!['id']),
              user: controller.currentUser!,
              showAppBar: false,
              accentColor: widget.accentColor)
          : const Center(child: CircularProgressIndicator()),
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Social Section',
            style: TextStyle(color: Colors.white, fontSize: 20)),
        actions: [
          IconButton(
              icon: const Icon(Icons.message, color: Colors.white, size: 22),
              onPressed: () {
                if (controller.currentUser != null)
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => MessagesScreen(
                              currentUser: controller.currentUser!,
                              accentColor: widget.accentColor)));
                else if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('User data not loaded')));
              }),
          IconButton(
              icon: const Icon(Icons.search, color: Colors.white, size: 22),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SearchScreen()))),
          PopupMenuButton<String>(
            icon: const Icon(Icons.filter_list, color: Colors.white),
            onSelected: (s) {
              setState(() {
                controller.feedMode = s;
                // refresh ranking with current posts
                controller.refreshRankedCache(Provider.of<FeedProvider>(context, listen: false).feedPosts);
              });
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'for_everyone',
                  child: Text('For Everyone (fair)',
                      style: TextStyle(
                          color: controller.feedMode == 'for_everyone'
                              ? widget.accentColor
                              : Colors.white))),
              PopupMenuItem(
                  value: 'trending',
                  child: Text('Trending',
                      style: TextStyle(
                          color: controller.feedMode == 'trending'
                              ? widget.accentColor
                              : Colors.white))),
              PopupMenuItem(
                  value: 'fresh',
                  child: Text('Fresh / Newest',
                      style: TextStyle(
                          color: controller.feedMode == 'fresh'
                              ? widget.accentColor
                              : Colors.white))),
              PopupMenuItem(
                  value: 'personalized',
                  child: Text('Personalized',
                      style: TextStyle(
                          color: controller.feedMode == 'personalized'
                              ? widget.accentColor
                              : Colors.white))),
            ],
          ),
          if (controller.currentUser != null)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                    child: Text('Hey, ${controller.currentUser!['username']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                            fontSize: 16)))),
        ],
      ),
      body: Stack(children: [
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  widget.accentColor.withOpacity(0.18),
                  const Color(0xFF0B1220),
                ],
                stops: const [0.0, 1.0],
              ),
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
                      widget.accentColor.withAlpha((0.12 * 255).round()),
                      Colors.transparent
                    ],
                    stops: const [0.0, 1.0]),
                borderRadius: const BorderRadius.all(Radius.circular(18)),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.6),
                      blurRadius: 16,
                      spreadRadius: 2,
                      offset: const Offset(0, 8))
                ],
              ),
              child: Container(
  decoration: BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withOpacity(0.015),
        Colors.white.withOpacity(0.01),
      ],
    ),
    borderRadius: const BorderRadius.all(Radius.circular(18)),
    border: Border.all(color: widget.accentColor.withOpacity(0.07)),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.42),
        blurRadius: 18,
        spreadRadius: 0,
        offset: const Offset(0, 10),
      ),
      BoxShadow(
        color: widget.accentColor.withOpacity(0.03),
        blurRadius: 28,
        spreadRadius: 1,
        offset: const Offset(0, 6),
      ),
    ],
  ),
  child: Theme(
    data: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        textTheme: ThemeData.dark().textTheme),
    child: IndexedStack(index: _selectedIndex, children: tabs),
  ),
),

            ),
          ),
        ),
      ]),
      floatingActionButton: FloatingActionButton(
          backgroundColor: widget.accentColor,
          onPressed: _showFabActions,
          child: const Icon(Icons.add, color: Colors.white, size: 22)),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onTabTapped,
        backgroundColor: Colors.black87,
        selectedItemColor: const Color(0xffffeb00),
        unselectedItemColor: widget.accentColor,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.home, size: 22), label: "Feeds"),
          BottomNavigationBarItem(
              icon: Icon(Icons.history, size: 22), label: "Stories"),
          BottomNavigationBarItem(
              icon: Icon(Icons.notifications, size: 22),
              label: "Notifications"),
          BottomNavigationBarItem(
              icon: Icon(Icons.whatshot, size: 22), label: "Streaks"),
          BottomNavigationBarItem(
              icon: Icon(Icons.person, size: 22), label: "Profile"),
        ],
      ),
    );
  }
}
