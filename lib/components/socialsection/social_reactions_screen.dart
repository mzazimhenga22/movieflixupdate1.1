// social_reactions_screen.dart
// Optimized & feature-enhanced version (no BackdropFilter/ImageFilter.blur)
// - Reduced rebuilds by splitting widgets and using local state/value notifiers
// - Debounced pagination and guarded async calls
// - Save post / Follow / Mute features
// - Image precaching & fade-in placeholders
// - Minor UI polish and animations

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'feed_reel_player_screen.dart';
import '../../models/reel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:movie_app/helpers/movie_account_helper.dart';
import 'package:movie_app/components/trending_movies_widget.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io' show File;
import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'dart:async';
import 'dart:typed_data';
import 'package:universal_html/html.dart' as html;
import 'stories.dart';
import 'messages_screen.dart';
import 'search_screen.dart';
import 'user_profile_screen.dart';
import 'realtime_feed_service.dart';
import 'streak_section.dart';
import 'notifications_section.dart';
import 'chat_screen.dart';
import 'package:video_player/video_player.dart' as vp;
import 'package:path/path.dart' as p;
import 'PostStoryScreen.dart';
import 'chatutils.dart' as chatUtils;
import 'package:share_plus/share_plus.dart';
import 'package:movie_app/components/watch_party_screen.dart';
import 'post_review_screen.dart';
import 'algo.dart';

// Import the stories components you asked for
import 'storiecomponents.dart';

/// ----------------- Utility / Constants -----------------
const _kPostsPerPage = 10;
const _kPrefMutedUsers = 'muted_users';
const _kPrefSavedPosts = 'saved_posts';

/// ----------------- Reusable frosted decoration helper -----------------
/// Use this wherever you previously used a semi-opaque black panel.
/// Keeps a subtle "glass" look on dark backgrounds without using BackdropFilter.
BoxDecoration frostedPanelDecoration(Color accentColor, {double radius = 18}) {
  return BoxDecoration(
    // faint white tint reads like glass over a dark background
    color: Colors.white.withOpacity(0.03),
    borderRadius: BorderRadius.all(Radius.circular(radius)),
    border: Border.all(color: accentColor.withOpacity(0.06)),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.32),
        blurRadius: 14,
        spreadRadius: 0,
        offset: const Offset(0, 8),
      ),
    ],
  );
}

/// ----------------- SimpleVideoPlayer (lazy init, guarded) -----------------
class SimpleVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final bool autoPlay;
  final VoidCallback? onTap;
  final double? height;

  const SimpleVideoPlayer({
    super.key,
    required this.videoUrl,
    this.autoPlay = false,
    this.onTap,
    this.height,
  });

  @override
  State<SimpleVideoPlayer> createState() => _SimpleVideoPlayerState();
}

class _SimpleVideoPlayerState extends State<SimpleVideoPlayer>
    with AutomaticKeepAliveClientMixin {
  vp.VideoPlayerController? _controller;
  bool _isPlaying = false;
  bool _initialized = false;
  bool _initRequested = false;

  @override
  void initState() {
    super.initState();
    // Do NOT initialize controllers for every instance by default.
    // Initialize only when autoPlay is true (rare) to avoid mass allocation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_initRequested && widget.autoPlay) {
        _initController();
      }
    });
  }

  Future<void> _initController() async {
    if (_initRequested) return;
    _initRequested = true;
    try {
      _controller = vp.VideoPlayerController.network(widget.videoUrl)
        ..setLooping(true);
      await _controller!.initialize();
      if (!mounted) return;
      setState(() {
        _initialized = true;
        if (widget.autoPlay) {
          _controller!.play();
          _isPlaying = true;
        }
      });
    } catch (e) {
      debugPrint('Video init error: $e');
    }
  }

  @override
  void dispose() {
    try {
      _controller?.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  void _togglePlay() async {
    if (!_initialized && !_initRequested) {
      // lazy-init on first user interaction if needed (rare path)
      await _initController();
      if (!mounted || _controller == null) return;
    }
    if (!_initialized || _controller == null) return;
    setState(() {
      if (_isPlaying) {
        _controller!.pause();
        _isPlaying = false;
      } else {
        _controller!.play();
        _isPlaying = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final height =
        (widget.height ?? (MediaQuery.of(context).size.width * 9 / 16)).clamp(160.0, 420.0);
    return GestureDetector(
      onTap: widget.onTap ?? _togglePlay,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        height: height,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_initialized && _controller != null)
              AspectRatio(
                aspectRatio: _controller!.value.aspectRatio,
                child: vp.VideoPlayer(_controller!),
              )
            else
              Container(
                height: height,
                color: Colors.grey[900],
                child: const Center(child: CircularProgressIndicator()),
              ),
            if (!_isPlaying && _initialized)
              const Icon(Icons.play_circle_outline, color: Colors.white70, size: 48),
          ],
        ),
      ),
    );
  }
}

/// ----------------- FeedProvider (debounced pagination + caching) -----------------
class FeedProvider with ChangeNotifier {
  final List<Map<String, dynamic>> _feedPosts = [];
  bool _isLoading = false;
  bool _hasMorePosts = true;
  final int _postsPerPage;
  DocumentSnapshot? _lastDocument;

  // local cache for quick UI access
  final Map<String, Map<String, dynamic>> _postCache = {};

  FeedProvider({int postsPerPage = _kPostsPerPage}) : _postsPerPage = postsPerPage;

  List<Map<String, dynamic>> get feedPosts => _feedPosts;
  bool get isLoading => _isLoading;
  bool get hasMorePosts => _hasMorePosts;

  // simple debounce
  Timer? _debounce;

  Future<void> fetchPosts({bool isRefresh = false}) async {
    if (_isLoading) return;
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      _isLoading = true;
      notifyListeners();
      try {
        Query query = FirebaseFirestore.instance
            .collection('feeds')
            .orderBy('timestamp', descending: true)
            .limit(_postsPerPage);

        if (!isRefresh && _lastDocument != null) {
          query = query.startAfterDocument(_lastDocument!);
        }

        final snapshot = await query.get();
        final newPosts = <Map<String, dynamic>>[];
        for (var doc in snapshot.docs) {
          final data = (doc.data() as Map<String, dynamic>?) ?? {};
          final item = {
            'id': doc.id,
            'user': (data['user'] ?? '').toString(),
            'post': (data['post'] ?? '').toString(),
            'type': (data['type'] ?? '').toString(),
            'likedBy': (data['likedBy'] as List?)?.where((i) => i != null).map((i) => i.toString()).toList() ?? <String>[],
            'title': (data['title'] ?? '').toString(),
            'season': (data['season'] ?? '').toString(),
            'episode': (data['episode'] ?? '').toString(),
            'media': (data['media'] ?? '').toString(),
            'mediaType': (data['mediaType'] ?? '').toString(),
            'timestamp': data['timestamp']?.toString() ?? DateTime.now().toIso8601String(),
            'userId': (data['userId'] ?? '').toString(),
            'retweetCount': (data['retweetCount'] is int) ? data['retweetCount'] as int : 0,
            'commentsCount': (data['commentsCount'] is int) ? data['commentsCount'] as int : 0,
            'views': (data['views'] is int) ? data['views'] as int : 0,
            'tags': data['tags'] ?? [],
            'followerCount': (data['followerCount'] is int) ? data['followerCount'] as int : 0,
            'originalPostId': (data['originalPostId'] ?? '').toString(),
          };
          _postCache[doc.id] = item;
          newPosts.add(item);
        }

        if (isRefresh) {
          _feedPosts.clear();
          _lastDocument = snapshot.docs.isNotEmpty ? snapshot.docs.last : null;
        } else {
          _lastDocument = snapshot.docs.isNotEmpty ? snapshot.docs.last : _lastDocument;
        }

        _feedPosts.addAll(newPosts);
        _hasMorePosts = newPosts.length == _postsPerPage;
      } catch (e) {
        debugPrint('Error fetching posts: $e');
      } finally {
        _isLoading = false;
        notifyListeners();
      }
    });
  }

  void addPost(Map<String, dynamic> post) {
    _postCache[post['id'] ?? const Uuid().v4()] = post;
    _feedPosts.insert(0, post);
    notifyListeners();
  }

  void removePost(String id) {
    _postCache.remove(id);
    _feedPosts.removeWhere((p) => p['id'] == id);
    notifyListeners();
  }

  Map<String, dynamic>? getCached(String id) => _postCache[id];
}

/// ----------------- PostCard (split & local stateful to reduce rebuilds) -----------------
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

  // performance: receive muted state + toggle callback from parent (no per-item prefs)
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

  @override
  void initState() {
    super.initState();
    likedBy = (widget.post['likedBy'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
    final currentUserId = (widget.currentUser?['id'] as String?) ?? '';
    isLiked = likedBy.contains(currentUserId);
    final userId = (widget.post['userId'] as String?) ?? '';
    final userRecord = widget.users.firstWhere((u) => (u['id'] as String?) == userId,
        orElse: () => {'username': widget.post['user'] ?? 'Unknown', 'avatar': ''});
    _username = (userRecord['username'] as String?) ?? 'Unknown';
    _avatarUrl = (userRecord['avatar'] as String?) ?? '';
    _muted = widget.muted;
  }

  Future<void> _toggleMuteLocal() async {
    setState(() => _muted = !_muted);
    try {
      await widget.onToggleMute(widget.post['userId']?.toString() ?? '');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_muted ? 'User muted' : 'User unmuted')));
    } catch (e) {
      debugPrint('mute error: $e');
      setState(() => _muted = !_muted); // revert on failure
    }
  }

  Future<void> _onLikePressed() async {
    final id = (widget.post['id'] as String?) ?? '';
    final wasLiked = isLiked;
    // optimistic update
    setState(() {
      isLiked = !isLiked;
      if (isLiked)
        likedBy.add(widget.currentUser?['id'] ?? '');
      else
        likedBy.remove(widget.currentUser?['id'] ?? '');
    });
    try {
      await widget.onLike(id, wasLiked);
    } catch (e) {
      debugPrint('like action failed: $e');
      // revert
      setState(() {
        isLiked = wasLiked;
        if (wasLiked)
          likedBy.add(widget.currentUser?['id'] ?? '');
        else
          likedBy.remove(widget.currentUser?['id'] ?? '');
      });
    }
  }

  Future<void> _onSavePressed() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(widget.post);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      debugPrint('save failed: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool isValidImageUrl(String url) =>
      url.startsWith('http') &&
      (url.endsWith('.jpg') || url.endsWith('.jpeg') || url.endsWith('.png'));

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final id = (post['id'] as String?) ?? '';
    final message = (post['post'] as String?) ?? '';
    final title = (post['title'] as String?) ?? '';
    final season = (post['season'] as String?) ?? '';
    final episode = (post['episode'] as String?) ?? '';
    final media = (post['media'] as String?) ?? '';
    final mediaType = (post['mediaType'] as String?) ?? '';
    final userId = (post['userId'] as String?) ?? '';
    final retweetCount = (post['retweetCount'] as int?) ?? 0;
    final currentUserId = (widget.currentUser?['id'] as String?) ?? '';

    // Precache image for better UX (non-blocking)
    if (mediaType == 'photo' && isValidImageUrl(media)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          precacheImage(CachedNetworkImageProvider(media), context);
        } catch (_) {}
      });
    }

    // display height based on screen height: make feed media occupy ~70% of screen height
    final screenHeight = MediaQuery.of(context).size.height;
    final imageHeight = ((screenHeight * 0.70).clamp(160.0, screenHeight * 0.85));

    final borderRadius = BorderRadius.circular(14.0);

    // Build a frosted gradient background that respects accent color.
    final gradientDecoration = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          widget.accentColor.withOpacity(0.22),
          widget.accentColor.withOpacity(0.10),
        ],
        stops: const [0.0, 1.0],
      ),
    );

    final innerDecoration = BoxDecoration(
      color: Colors.white.withOpacity(0.03),
      borderRadius: borderRadius,
      border: Border.all(color: widget.accentColor.withOpacity(0.10)),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.28), blurRadius: 10, offset: const Offset(0, 6))],
    );

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            decoration: gradientDecoration,
            child: Container(
              decoration: innerDecoration,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // header
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: widget.accentColor,
                          backgroundImage: _avatarUrl.isNotEmpty ? CachedNetworkImageProvider(_avatarUrl) : null,
                          child: _avatarUrl.isEmpty
                              ? Text(_username.isNotEmpty ? _username[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white))
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(_username, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(_friendlyTimeString(post['timestamp']?.toString() ?? DateTime.now().toIso8601String()),
                                style: TextStyle(color: Colors.white70, fontSize: 12)),
                          ]),
                        ),
                        // Follow / mute small actions
                        IconButton(
                          icon: const Icon(Icons.more_horiz, color: Colors.white70),
                          onPressed: () async {
                            showModalBottomSheet(context: context, backgroundColor: Colors.grey[900], builder: (ctx) {
                              return SafeArea(
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  ListTile(
                                      leading: const Icon(Icons.person_add, color: Colors.white),
                                      title: const Text('Follow/Unfollow', style: TextStyle(color: Colors.white)),
                                      onTap: () {
                                        Navigator.pop(ctx);
                                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Toggled follow for $_username')));
                                      }),
                                  ListTile(
                                      leading: Icon(_muted ? Icons.volume_off : Icons.volume_up, color: Colors.white),
                                      title: Text(_muted ? 'Unmute user' : 'Mute user', style: const TextStyle(color: Colors.white)),
                                      onTap: () {
                                        Navigator.pop(ctx);
                                        _toggleMuteLocal();
                                      }),
                                  ListTile(
                                      leading: const Icon(Icons.report, color: Colors.white),
                                      title: const Text('Report', style: TextStyle(color: Colors.white)),
                                      onTap: () {
                                        Navigator.pop(ctx);
                                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reported')));
                                      }),
                                ]),
                              );
                            });
                          },
                        ),
                      ],
                    ),
                  ),

                  // media
                  if (media.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: imageHeight, minHeight: 120),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Builder(builder: (context) {
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
                              return SizedBox(
                                height: imageHeight,
                                width: double.infinity,
                                child: SimpleVideoPlayer(
                                  videoUrl: media,
                                  autoPlay: false,
                                  onTap: () {
                                    final videoPosts = widget.allPosts
                                        .where((p) => (p['mediaType'] as String?) == 'video' && (p['media'] as String?)!.isNotEmpty)
                                        .map((p) => Reel(videoUrl: (p['media'] as String?) ?? '', movieTitle: (p['title'] as String?) ?? 'Video', movieDescription: (p['post'] as String?) ?? ''))
                                        .toList();
                                    final idx = videoPosts.indexWhere((r) => r.videoUrl == media);
                                    if (idx != -1) {
                                      Navigator.push(context, MaterialPageRoute(builder: (_) => FeedReelPlayerScreen(reels: videoPosts, initialIndex: idx)));
                                    } else {
                                      Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) => FeedReelPlayerScreen(
                                                  reels: [Reel(videoUrl: media, movieTitle: title, movieDescription: message)],
                                                  initialIndex: 0)));
                                    }
                                  },
                                ),
                              );
                            } else {
                              return Container(
                                height: imageHeight,
                                color: Colors.grey[850],
                                child: const Center(child: Icon(Icons.image, size: 40)),
                              );
                            }
                          }),
                        ),
                      ),
                    ),

                  // text content
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(message, style: const TextStyle(fontSize: 15, color: Colors.white70)),
                      const SizedBox(height: 8),
                      Row(children: [
                        if (title.isNotEmpty)
                          Expanded(child: Text('Movie: $title', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontStyle: FontStyle.italic))),
                        if (season.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 6.0), child: Text('S:$season', style: const TextStyle(color: Colors.white60, fontStyle: FontStyle.italic))),
                        if (episode.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 6.0), child: Text('E:$episode', style: const TextStyle(color: Colors.white60, fontStyle: FontStyle.italic))),
                      ]),
                    ]),
                  ),

                  const Divider(color: Colors.white10, height: 1),

                  // actions
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6),
                    child: Row(children: [
                      Flexible(
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
                          _FrostedIconButton(onTap: () => widget.onComment(widget.post), child: Row(children: const [Icon(Icons.comment, color: Colors.white70, size: 20), SizedBox(width: 6), Text('Comment', style: TextStyle(color: Colors.white70))])),
                          const SizedBox(width: 8),
                          _FrostedIconButton(onTap: () => widget.onWatchParty(widget.post), child: Row(children: const [Icon(Icons.connected_tv, color: Colors.white70, size: 20), SizedBox(width: 6), Text('Watch', style: TextStyle(color: Colors.white70))])),
                        ]),
                      ),
                      const SizedBox(width: 8),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        _FrostedIconButton(onTap: () => widget.onRetweet(widget.post), child: Row(children: [const Icon(Icons.repeat, color: Colors.white70, size: 20), const SizedBox(width: 6), Text(retweetCount.toString(), style: const TextStyle(color: Colors.white70))])),
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
      ),
    );
  }

  // Helper: friendly time text
  static String _friendlyTimeString(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inSeconds < 60) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m';
      if (diff.inHours < 24) return '${diff.inHours}h';
      if (diff.inDays < 7) return '${diff.inDays}d';
      return '${dt.day}/${dt.month}/${dt.year}';
    } catch (_) {
      return '';
    }
  }
}

/// small frosted button used inside the card for consistent style
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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

class _SocialReactionsScreenState extends State<_SocialReactionsScreen> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  List<Map<String, dynamic>> _users = [];
  final List<String> _notifications = [];
  List<Map<String, dynamic>> _stories = [];
  int _movieStreak = 0;
  Map<String, dynamic>? _currentUser;
  final SupabaseClient _supabase = Supabase.instance.client;
  bool _showRecommendations = true;
  final ScrollController _mainScrollController = ScrollController();
  final PageStorageKey _feedKey = const PageStorageKey('feed-list');

  // hiding stories on scroll:
  bool _showStories = true;
  double _lastScrollOffset = 0.0;
  static const double _storyHeight = 110.0;

  // Algorithm / feed mode state
  List<String> _recentlySeenTags = [];
  String _feedMode = 'for_everyone';
  List<Map<String, dynamic>>? _cachedRankedPosts;
  int? _cachedForSourceId;

  // local saved posts cache
  Set<String> _savedPosts = {};

  // guard for init
  bool _initialized = false;

  // performance: cached muted users to avoid per-item prefs calls
  Set<String> _mutedUsers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mainScrollController.addListener(_onScrollThrottled);
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

    // pagination trigger (small threshold)
    final feed = Provider.of<FeedProvider>(context, listen: false);
    if (_mainScrollController.position.pixels >= _mainScrollController.position.maxScrollExtent - 120 && !feed.isLoading && feed.hasMorePosts) {
      feed.fetchPosts();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mainScrollController.dispose();
    super.dispose();
  }

  Future<void> _initializeData() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await Future.wait([
        _checkMovieAccount(),
        _loadLocalData(),
        _loadUsers(),
        _loadUserData(),
      ]);
      await Provider.of<FeedProvider>(context, listen: false).fetchPosts(isRefresh: true);
      _refreshRankedCache();
    } catch (e) {
      debugPrint('Error initializing social screen: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to initialize: $e')));
    }
  }

  Future<void> _checkMovieAccount() async {
    try {
      if (await MovieAccountHelper.doesMovieAccountExist()) {
        await MovieAccountHelper.getMovieAccountData();
      }
    } catch (e) {
      debugPrint('movie account check failed: $e');
    }
  }

  Future<void> _loadLocalData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storiesString = prefs.getString('stories') ?? '[]';
      final movieStreak = prefs.getInt('movieStreak') ?? 0;
      final saved = prefs.getStringList(_kPrefSavedPosts) ?? <String>[];
      final muted = prefs.getStringList(_kPrefMutedUsers) ?? <String>[];
      _stories = List<Map<String, dynamic>>.from(jsonDecode(storiesString));
      _movieStreak = movieStreak;
      _savedPosts = saved.toSet();
      _mutedUsers = muted.toSet();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Error loading local data: $e');
    }
  }

  Future<void> _saveLocalData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('stories', jsonEncode(_stories));
    await prefs.setInt('movieStreak', _movieStreak);
    await prefs.setStringList(_kPrefSavedPosts, _savedPosts.toList());
    await prefs.setStringList(_kPrefMutedUsers, _mutedUsers.toList());
  }

  Future<void> _loadUserData() async {
    try {
      final current = FirebaseAuth.instance.currentUser;
      if (current == null) throw Exception('No current user');
      final doc = await FirebaseFirestore.instance.collection('users').doc(current.uid).get();
      if (!doc.exists) throw Exception('No user document');
      final data = Map<String, dynamic>.from(doc.data() ?? {});
      data['id'] = doc.id;
      if (!mounted) return;
      setState(() {
        _currentUser = _normalizeUserData(data);
      });
    } catch (e) {
      debugPrint('Error loading user data: $e');
      if (mounted) {
        setState(() => _currentUser = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error loading profile: $e')));
      }
    }
  }

  Future<void> _loadUsers() async {
    try {
      final snapshot = await FirebaseFirestore.instance.collection('users').get();
      final rawUsers = snapshot.docs.map((d) {
        final m = Map<String, dynamic>.from(d.data());
        m['id'] = d.id;
        return m;
      }).toList();
      _users = rawUsers.map((u) => _normalizeUserData(Map<String, dynamic>.from(u))).toList();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Error loading users: $e');
    }
  }

  Map<String, dynamic> _normalizeUserData(Map<String, dynamic> user) {
    return {
      'id': user['id']?.toString() ?? '',
      'username': user['username']?.toString() ?? 'Unknown',
      'email': user['email']?.toString() ?? '',
      'bio': user['bio']?.toString() ?? '',
      'avatar': user['avatar']?.toString() ?? 'https://via.placeholder.com/200',
    };
  }

  Future<dynamic> pickFile(String type) async {
    if (kIsWeb) {
      final html.FileUploadInputElement input = html.FileUploadInputElement();
      input.accept = type == 'photo' ? 'image/jpeg,image/png' : 'video/mp4';
      input.click();
      await input.onChange.first;
      if (input.files!.isNotEmpty) {
        return input.files!.first;
      }
    } else {
      final picker = ImagePicker();
      if (type == 'photo') return await picker.pickImage(source: ImageSource.gallery);
      return await picker.pickVideo(source: ImageSource.gallery);
    }
    return null;
  }

  Future<String> uploadMedia(dynamic mediaFile, String type, BuildContext context) async {
    try {
      final mediaId = const Uuid().v4();
      String filePath;
      String contentType;
      if (kIsWeb) {
        if (mediaFile is html.File) {
          final fileSizeInBytes = mediaFile.size;
          if (type == 'photo' && fileSizeInBytes > 5 * 1024 * 1024) throw Exception('Image too large, max 5MB');
          if (type == 'video' && fileSizeInBytes > 20 * 1024 * 1024) throw Exception('Video too large, max 20MB');
          final extension = mediaFile.name.split('.').last.toLowerCase();
          filePath = 'media/$mediaId.$extension';
          contentType = mediaFile.type;
          final reader = html.FileReader();
          reader.readAsArrayBuffer(mediaFile);
          await reader.onLoad.first;
          final bytes = reader.result as Uint8List;
          await _supabase.storage.from('feeds').uploadBinary(filePath, bytes, fileOptions: FileOptions(contentType: contentType));
        } else {
          throw Exception('Invalid web file');
        }
      } else {
        if (mediaFile is XFile) {
          final file = File(mediaFile.path);
          final fileSizeInBytes = await file.length();
          if (type == 'photo' && fileSizeInBytes > 5 * 1024 * 1024) throw Exception('Image too large, max 5MB');
          if (type == 'video' && fileSizeInBytes > 20 * 1024 * 1024) throw Exception('Video too large, max 20MB');
          final extension = p.extension(mediaFile.path).replaceFirst('.', '');
          filePath = 'media/$mediaId.$extension';
          contentType = _getMimeType(extension);
          await _supabase.storage.from('feeds').upload(filePath, file, fileOptions: FileOptions(contentType: contentType));
        } else {
          throw Exception('Invalid file type');
        }
      }

      final url = _supabase.storage.from('feeds').getPublicUrl(filePath);
      return url.isNotEmpty ? url : 'https://via.placeholder.com/150';
    } catch (e) {
      debugPrint('upload error: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error uploading media: $e')));
      return 'https://via.placeholder.com/150';
    }
  }

  String _getMimeType(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'mp4':
        return 'video/mp4';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> _postStory() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.photo, color: Colors.white), title: const Text("Upload Photo", style: TextStyle(color: Colors.white)), onTap: () => Navigator.pop(context, 'photo')),
        ListTile(leading: const Icon(Icons.videocam, color: Colors.white), title: const Text("Upload Video", style: TextStyle(color: Colors.white)), onTap: () => Navigator.pop(context, 'video')),
      ])),
    );
    if (choice == null || !mounted) return;
    final pickedFile = await pickFile(choice);
    if (pickedFile == null) return;

    showDialog(context: context, barrierDismissible: false, builder: (_) => const AlertDialog(content: Row(children: [CircularProgressIndicator(), SizedBox(width: 12), Text('Uploading...')])));

    try {
      final uploadedUrl = await uploadMedia(pickedFile, choice, context);
      if (!mounted) return;
      if (uploadedUrl.isEmpty || uploadedUrl == 'https://via.placeholder.com/150') throw Exception('Upload failed');

      final story = {
        'user': _currentUser?['username'] ?? 'User',
        'userId': _currentUser?['id']?.toString() ?? '',
        'media': uploadedUrl,
        'type': choice,
        'timestamp': DateTime.now().toIso8601String(),
      };
      final docRef = await FirebaseFirestore.instance.collection('users').doc(_currentUser?['id']?.toString()).collection('stories').add(story);
      story['id'] = docRef.id;
      await FirebaseFirestore.instance.collection('stories').add(story);

      Provider.of<FeedProvider>(context, listen: false).addPost({
        'id': docRef.id,
        'user': story['user'],
        'userId': story['userId'],
        'post': '${story['user']} posted a story.',
        'type': 'story',
        'likedBy': [],
        'timestamp': story['timestamp'],
      });

      setState(() {
        _stories.add(story);
      });
      await _saveLocalData();
    } catch (e) {
      debugPrint('postStory error: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to post story: $e')));
    } finally {
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _postMovieReview() async {
    if (_currentUser == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User data not loaded')));
      return;
    }

    Navigator.push(context, MaterialPageRoute(builder: (_) => PostReviewScreen(accentColor: widget.accentColor, currentUser: _currentUser)));
  }

  // Ranking helpers (unchanged)
  List<Map<String, dynamic>> _rankAndApply(List<Map<String, dynamic>> posts) {
    try {
      final ranked = Algo.rankPosts(posts, currentUser: _currentUser, recentlySeenTags: _recentlySeenTags, mode: _feedMode, seed: DateTime.now().millisecondsSinceEpoch % 100000);
      return ranked;
    } catch (e) {
      debugPrint('Ranking error: $e');
      return posts;
    }
  }

  List<Map<String, dynamic>> _getCachedRanked(List<Map<String, dynamic>> source) {
    try {
      final sourceId = source.map((p) => (p['id'] ?? '').toString()).join('|').hashCode ^ _feedMode.hashCode;
      if (_cachedRankedPosts == null || _cachedForSourceId != sourceId) {
        final newRanked = _rankAndApply(source);
        _cachedRankedPosts = newRanked;
        _cachedForSourceId = sourceId;
      }
      return _cachedRankedPosts ?? source;
    } catch (e) {
      debugPrint('Cache rank error: $e');
      return source;
    }
  }

  void _refreshRankedCache() {
    final feed = Provider.of<FeedProvider>(context, listen: false);
    _cachedRankedPosts = _rankAndApply(feed.feedPosts);
    _cachedForSourceId = feed.feedPosts.map((p) => (p['id'] ?? '').toString()).join('|').hashCode ^ _feedMode.hashCode;
  }

  // Toggle mute helper (centralized)
  Future<void> _toggleMuteForUser(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final muted = prefs.getStringList(_kPrefMutedUsers) ?? <String>[];
      if (_mutedUsers.contains(userId)) {
        muted.remove(userId);
        _mutedUsers.remove(userId);
      } else {
        muted.add(userId);
        _mutedUsers.add(userId);
      }
      await prefs.setStringList(_kPrefMutedUsers, muted);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('toggle mute central error: $e');
      rethrow;
    }
  }

  Widget _buildFeedTab() {
    return Consumer<FeedProvider>(builder: (context, feedProvider, child) {
      final rankedPosts = _getCachedRanked(feedProvider.feedPosts);

      // Use the local _stories as source for the StoriesRow; stories are maps as loaded earlier.
      final storiesForRow = _stories;

      return Column(children: [
        // Animated stories area (hide on scroll down, show on scroll up)
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: SizedBox(
            height: _showStories ? _storyHeight : 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _showStories ? 1.0 : 0.0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 10),
                child:
                // Use StoriesRow's built-in navigation/grouping behavior:
                StoriesRow(
                  stories: storiesForRow,
                  currentUserAvatar: _currentUser?['avatar']?.toString(),
                  // Give the StoriesRow the full current user map so it can navigate to PostStoryScreen
                  currentUser: _currentUser,
                  // pass accent color so PostStoryScreen and gradient rings match your theme
                  accentColor: widget.accentColor,
                  // Add story navigation forced to PostStoryScreen by default
                  forceNavigateOnAdd: true,
                  height: 100,
                ),
              ),
            ),
          ),
        ),

        // Post Movie Review button (kept visible even when stories are hidden)
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: widget.accentColor, minimumSize: const Size(double.infinity, 48)),
          onPressed: _postMovieReview,
          icon: const Icon(Icons.rate_review, size: 20),
          label: const Text('Post Movie Review', style: TextStyle(fontSize: 16)),
        )),

        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              await feedProvider.fetchPosts(isRefresh: true);
              _refreshRankedCache();
            },
            child: CustomScrollView(
              key: _feedKey,
              controller: _mainScrollController,
              slivers: [
                SliverList(delegate: SliverChildBuilderDelegate((context, index) {
                  if (index >= rankedPosts.length) {
                    return feedProvider.hasMorePosts ? const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())) : const SizedBox.shrink();
                  }
                  final item = rankedPosts[index];

                  // QUICK check for muted users using cached set (no FutureBuilder)
                  final isMuted = _mutedUsers.contains((item['userId'] ?? '').toString());
                  if (isMuted) {
                    // show a placeholder for muted content with an unmute button
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12)),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: Text('Muted content', style: TextStyle(color: Colors.white.withOpacity(0.8)))),
                            TextButton(onPressed: () async {
                              await _toggleMuteForUser((item['userId'] ?? '').toString());
                            }, child: const Text('Unmute'))
                          ],
                        ),
                      ),
                    );
                  }

                  return PostCardWidget(
                    key: ValueKey(item['id']),
                    post: item,
                    allPosts: rankedPosts,
                    currentUser: _currentUser,
                    users: _users,
                    accentColor: widget.accentColor,
                    muted: isMuted,
                    onToggleMute: (userId) async {
                      await _toggleMuteForUser(userId);
                    },
                    onDelete: (id) async {
                      try {
                        await FirebaseFirestore.instance.collection('feeds').doc(id).delete();
                        feedProvider.removePost(id);
                        _refreshRankedCache();
                      } catch (e) {
                        debugPrint('delete post error: $e');
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete post: $e')));
                      }
                    },
                    onLike: (id, wasLiked) async {
                      try {
                        final ref = FirebaseFirestore.instance.collection('feeds').doc(id);
                        if (wasLiked) {
                          await ref.update({'likedBy': FieldValue.arrayRemove([_currentUser?['id'] ?? ''])});
                        } else {
                          await ref.update({'likedBy': FieldValue.arrayUnion([_currentUser?['id'] ?? ''])});
                        }
                      } catch (e) {
                        debugPrint('like error: $e');
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to like post: $e')));
                      }
                    },
                    onComment: _showComments,
                    onWatchParty: (post) {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => WatchPartyScreen(post: post)));
                    },
                    onSend: (post) {
                      final code = (100000 + Random().nextInt(900000)).toString();
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Started Watch Party: Code $code')));
                      setState(() {
                        _notifications.add('${_currentUser?['username'] ?? 'User'} started a watch party with code $code');
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
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to share: $e')));
                      }
                    },
                    onRetweet: (post) async {
                      if (_currentUser == null) {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User data not loaded')));
                        return;
                      }
                      try {
                        final originalId = post['id'] as String? ?? '';
                        final newPost = {
                          'user': _currentUser?['username'] ?? 'User',
                          'userId': _currentUser?['id']?.toString() ?? '',
                          'post': 'Retweeted: ${post['post'] ?? ''}',
                          'type': 'retweet',
                          'likedBy': [],
                          'title': post['title'] ?? '',
                          'season': post['season'] ?? '',
                          'episode': post['episode'] ?? '',
                          'media': post['media'] ?? '',
                          'mediaType': post['mediaType'] ?? '',
                          'timestamp': DateTime.now().toIso8601String(),
                          'originalPostId': originalId,
                        };

                        final docRef = await FirebaseFirestore.instance.collection('feeds').add(newPost);
                        newPost['id'] = docRef.id;
                        if (originalId.isNotEmpty) {
                          final originalRef = FirebaseFirestore.instance.collection('feeds').doc(originalId);
                          await originalRef.update({'retweetCount': FieldValue.increment(1)});
                        }

                        Provider.of<FeedProvider>(context, listen: false).addPost(newPost);
                        _refreshRankedCache();
                      } catch (e) {
                        debugPrint('retweet error: $e');
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to repost: $e')));
                      }
                    },
                    onSave: (post) async {
                      try {
                        final id = (post['id'] as String?) ?? '';
                        if (id.isEmpty) throw Exception('Invalid id');
                        _savedPosts.add(id);
                        await _saveLocalData();
                      } catch (e) {
                        debugPrint('save post error: $e');
                        rethrow;
                      }
                    },
                  );
                }, childCount: rankedPosts.length + (feedProvider.hasMorePosts ? 1 : 0))),
                SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    const Text('Recommended Movies', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                    IconButton(icon: Icon(_showRecommendations ? Icons.remove : Icons.add, color: Colors.white), onPressed: () => setState(() => _showRecommendations = !_showRecommendations)),
                  ]),
                  Visibility(visible: _showRecommendations, child: const SizedBox(height: 12)),
                  if (_showRecommendations) const TrendingMoviesWidget(),
                  const SizedBox(height: 20),
                ]))),
              ],
            ),
          ),
        ),
      ]);
    });
  }

  Widget _buildStoriesTab() {
    return Column(children: [
      SizedBox(
        height: 110,
        child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('stories').snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              debugPrint('stories stream error: ${snapshot.error}');
              return const Center(child: Text('Failed to load stories.', style: TextStyle(color: Colors.white)));
            }
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            final stories = snapshot.data!.docs.map((doc) {
              final map = (doc.data() as Map<String, dynamic>?) ?? {};
              return {...map, 'id': doc.id};
            }).where((s) {
              try {
                return DateTime.now().difference(DateTime.parse(s['timestamp'])) < const Duration(hours: 24);
              } catch (_) {
                return false;
              }
            }).toList();

            final Map<String, List<Map<String, dynamic>>> grouped = {};
            for (var s in stories) {
              final uid = (s['userId'] as String?) ?? '';
              grouped.putIfAbsent(uid, () => []).add(s);
            }

            if (grouped.isEmpty) return const Center(child: Text('No stories available.', style: TextStyle(color: Colors.white)));

            final keys = grouped.keys.toList();
            return ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: keys.length,
              itemBuilder: (context, index) {
                final userId = keys[index];
                final userStories = grouped[userId]!;
                final first = userStories.first;
                final mediaUrl = (first['media'] as String?) ?? '';
                final isPhoto = mediaUrl.startsWith('http') && (mediaUrl.endsWith('.jpg') || mediaUrl.endsWith('.png') || mediaUrl.endsWith('.jpeg'));
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: GestureDetector(
                    onTap: () {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => StoryScreen(stories: userStories, initialIndex: 0, currentUserId: (_currentUser?['id'] ?? '').toString())));
                    },
                    child: Column(children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          image: isPhoto ? DecorationImage(image: CachedNetworkImageProvider(mediaUrl), fit: BoxFit.cover) : null,
                          color: first['type'] == 'video' ? Colors.black : Colors.grey,
                          border: Border.all(color: widget.accentColor.withOpacity(0.85), width: 2),
                          boxShadow: [BoxShadow(color: widget.accentColor.withOpacity(0.25), blurRadius: 8, spreadRadius: 1)],
                        ),
                        child: first['type'] == 'video' ? const Icon(Icons.videocam, color: Colors.white, size: 20) : null,
                      ),
                      const SizedBox(height: 6),
                      SizedBox(width: 80, child: Text(first['user'] ?? 'Unknown', style: const TextStyle(color: Colors.white, fontSize: 12), overflow: TextOverflow.ellipsis)),
                    ]),
                  ),
                );
              },
            );
          },
        ),
      ),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: widget.accentColor, minimumSize: const Size(double.infinity, 48)),
          onPressed: () {
            if (_currentUser != null) {
              Navigator.push(context, MaterialPageRoute(builder: (_) => PostStoryScreen(accentColor: widget.accentColor, currentUser: _currentUser!)));
            } else {
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User data not loaded')));
            }
          },
          icon: const Icon(Icons.add_a_photo, size: 20),
          label: const Text('Post Story', style: TextStyle(fontSize: 16)),
        ),
      ),
    ]);
  }

  void _promptCreateWatchParty(Map<String, dynamic> post) {
    showDialog(context: context, builder: (context) => AlertDialog(title: const Text('Create Watch Party'), content: const Text('Do you want to create a watch party for this post?'), actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('No')),
      TextButton(onPressed: () {
        final code = (100000 + Random().nextInt(900000)).toString();
        Navigator.pop(context);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Watch Party created with code: $code')));
        setState(() {
          _notifications.add('${_currentUser?['username'] ?? 'User'} created a watch party with code $code');
        });
      }, child: const Text('Yes')),
    ]));
  }

  void _showComments(Map<String, dynamic> post) {
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: const Color.fromARGB(255, 17, 25, 40), builder: (context) {
      final controller = TextEditingController();
      return FractionallySizedBox(
        heightFactor: 0.9,
        child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('users').doc(post['userId']).collection('posts').doc(post['id']).collection('comments').orderBy('timestamp', descending: true).snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) return const Center(child: Text('Failed to load comments.', style: TextStyle(color: Colors.white)));
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            final comments = snapshot.data!.docs.map((d) => (d.data() as Map<String, dynamic>?) ?? {}).toList();
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom + 16, left: 16, right: 16, top: 16),
              child: Column(children: [
                const Text('Comments', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                Expanded(child: ListView.builder(itemCount: comments.length, itemBuilder: (_, i) => ListTile(leading: CircleAvatar(radius: 20, backgroundImage: CachedNetworkImageProvider(comments[i]['userAvatar'] ?? 'https://via.placeholder.com/50')), title: Text(comments[i]['username'] ?? 'Unknown', style: TextStyle(color: widget.accentColor)), subtitle: Text(comments[i]['text'] ?? '', style: const TextStyle(color: Colors.white70))))),
                TextField(controller: controller, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Add a comment', labelStyle: TextStyle(color: Colors.white54))),
                const SizedBox(height: 12),
                ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: widget.accentColor, minimumSize: const Size(double.infinity, 48)), onPressed: () async {
                  if (controller.text.isNotEmpty) {
                    try {
                      await FirebaseFirestore.instance.collection('users').doc(post['userId']).collection('posts').doc(post['id']).collection('comments').add({
                        'text': controller.text,
                        'userId': _currentUser?['id'],
                        'username': _currentUser?['username'],
                        'userAvatar': _currentUser?['avatar'],
                        'timestamp': DateTime.now().toIso8601String(),
                      });
                      controller.clear();
                    } catch (e) {
                      debugPrint('comment error: $e');
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to post comment: $e')));
                    }
                  }
                }, child: const Text('Post', style: TextStyle(fontSize: 16))),
              ]),
            );
          },
        ),
      );
    });
  }

  void _onTabTapped(int index) => setState(() => _selectedIndex = index);

  void _showFabActions() {
    showModalBottomSheet(context: context, backgroundColor: Colors.transparent, builder: (context) => Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: const BorderRadius.all(Radius.circular(12))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.message, color: Colors.white), title: const Text('New Message', style: TextStyle(color: Colors.white)), onTap: () {
          Navigator.pop(context);
          if (_currentUser != null) {
            Navigator.push(context, MaterialPageRoute(builder: (_) => NewChatScreen(currentUser: _currentUser!, otherUsers: _users.where((u) => u['email'] != _currentUser!['email']).toList(), accentColor: widget.accentColor)));
          } else {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User data not loaded')));
          }
        }),
        if (!_showRecommendations) ListTile(leading: const Icon(Icons.expand, color: Colors.white), title: const Text('Expand Recommendations', style: TextStyle(color: Colors.white)), onTap: () {
          Navigator.pop(context);
          setState(() => _showRecommendations = true);
        }),
      ]),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      _buildFeedTab(),
      _buildStoriesTab(),
      NotificationsSection(notifications: _notifications),
      StreakSection(movieStreak: _movieStreak, onStreakUpdated: (newStreak) => setState(() => _movieStreak = newStreak)),
      _currentUser != null ? UserProfileScreen(key: ValueKey(_currentUser!['id']), user: _currentUser!, showAppBar: false, accentColor: widget.accentColor) : const Center(child: CircularProgressIndicator()),
    ];

    return Scaffold(
      // make scaffold transparent so our gradient shows through everywhere (including behind appbar)
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Social Section', style: TextStyle(color: Colors.white, fontSize: 20)),
        actions: [
          IconButton(icon: const Icon(Icons.message, color: Colors.white, size: 22), onPressed: () {
            if (_currentUser != null) Navigator.push(context, MaterialPageRoute(builder: (_) => MessagesScreen(currentUser: _currentUser!, accentColor: widget.accentColor)));
            else if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User data not loaded')));
          }),
          IconButton(icon: const Icon(Icons.search, color: Colors.white, size: 22), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen()))),
          PopupMenuButton<String>(
            icon: const Icon(Icons.filter_list, color: Colors.white),
            onSelected: (s) {
              setState(() {
                _feedMode = s;
                _refreshRankedCache();
              });
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'for_everyone', child: Text('For Everyone (fair)', style: TextStyle(color: _feedMode == 'for_everyone' ? widget.accentColor : Colors.white))),
              PopupMenuItem(value: 'trending', child: Text('Trending', style: TextStyle(color: _feedMode == 'trending' ? widget.accentColor : Colors.white))),
              PopupMenuItem(value: 'fresh', child: Text('Fresh / Newest', style: TextStyle(color: _feedMode == 'fresh' ? widget.accentColor : Colors.white))),
              PopupMenuItem(value: 'personalized', child: Text('Personalized', style: TextStyle(color: _feedMode == 'personalized' ? widget.accentColor : Colors.white))),
            ],
          ),
          if (_currentUser != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Center(child: Text('Hey, ${_currentUser!['username']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white, fontSize: 16)))),
        ],
      ),
      body: Stack(children: [
        // FULL-SCREEN GRADIENT BACKGROUND (covers area behind AppBar too)
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

        // Main frosted panel (NO blur) - using frostedPanelDecoration
        Positioned.fill(
          top: kToolbarHeight + MediaQuery.of(context).padding.top,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(center: Alignment.center, radius: 1.6, colors: [widget.accentColor.withAlpha((0.12 * 255).round()), Colors.transparent], stops: const [0.0, 1.0]),
                borderRadius: const BorderRadius.all(Radius.circular(18)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 16, spreadRadius: 2, offset: const Offset(0, 8))],
              ),
              child: Container(
                decoration: frostedPanelDecoration(widget.accentColor, radius: 18),
                child: Theme(
                  data: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.transparent, textTheme: ThemeData.dark().textTheme),
                  child: IndexedStack(index: _selectedIndex, children: tabs),
                ),
              ),
            ),
          ),
        ),
      ]),
      floatingActionButton: FloatingActionButton(backgroundColor: widget.accentColor, onPressed: _showFabActions, child: const Icon(Icons.add, color: Colors.white, size: 22)),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onTabTapped,
        backgroundColor: Colors.black87,
        selectedItemColor: const Color(0xffffeb00),
        unselectedItemColor: widget.accentColor,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home, size: 22), label: "Feeds"),
          BottomNavigationBarItem(icon: Icon(Icons.history, size: 22), label: "Stories"),
          BottomNavigationBarItem(icon: Icon(Icons.notifications, size: 22), label: "Notifications"),
          BottomNavigationBarItem(icon: Icon(Icons.whatshot, size: 22), label: "Streaks"),
          BottomNavigationBarItem(icon: Icon(Icons.person, size: 22), label: "Profile"),
        ],
      ),
    );
  }
}

/// ----------------- NewChatScreen (unchanged except for small polish) -----------------
class NewChatScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  final List<Map<String, dynamic>> otherUsers;
  final Color accentColor;

  const NewChatScreen({super.key, required this.currentUser, required this.otherUsers, required this.accentColor});

  @override
  State<NewChatScreen> createState() => NewChatScreenState();
}

class NewChatScreenState extends State<NewChatScreen> {
  void _startChat(Map<String, dynamic> user) {
    final chatId = chatUtils.getChatId(widget.currentUser['id'], user['id']);
    Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId, currentUser: widget.currentUser, otherUser: {'id': user['id'], 'username': user['username'], 'photoUrl': user['photoUrl']}, authenticatedUser: widget.currentUser, storyInteractions: const [])));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: const Text('New Chat', style: TextStyle(color: Colors.white, fontSize: 20)), leading: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context))),
      body: Stack(children: [
        Container(color: const Color(0xFF0B1220)),
        Container(decoration: BoxDecoration(gradient: RadialGradient(center: const Alignment(-0.1, -0.4), radius: 1.2, colors: [widget.accentColor.withAlpha((0.35 * 255).round()), Colors.transparent], stops: const [0.0, 0.9]))),
        Positioned.fill(
          top: kToolbarHeight + MediaQuery.of(context).padding.top,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              decoration: BoxDecoration(gradient: RadialGradient(center: Alignment.center, radius: 1.6, colors: [widget.accentColor.withAlpha((0.12 * 255).round()), Colors.transparent], stops: const [0.0, 1.0]), borderRadius: const BorderRadius.all(Radius.circular(16)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 10, spreadRadius: 1, offset: const Offset(0, 4))]),
              child: ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(16)),
                child: Container(
                  decoration: frostedPanelDecoration(widget.accentColor, radius: 16),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: widget.otherUsers.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                    itemBuilder: (context, index) {
                      final user = widget.otherUsers[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: widget.accentColor,
                          child: Text(user['username'] != null && user['username'].isNotEmpty ? user['username'][0].toUpperCase() : '?', style: const TextStyle(color: Colors.white)),
                        ),
                        title: Text(user['username'] ?? 'Unknown', style: const TextStyle(color: Colors.white, fontSize: 14)),
                        onTap: () => _startChat(user),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        )
      ]),
    );
  }
}
