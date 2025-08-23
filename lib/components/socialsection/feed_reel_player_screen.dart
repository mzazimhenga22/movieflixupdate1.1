// feed_reel_player_screen.dart
// Updated: live likes/comments/views, comments bottom sheet, ranking algo, preloading.

import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/reel.dart';

/// FeedReelPlayerScreen
/// Accepts an initial list of `Reel` objects. Each Reel is expected to have:
/// - videoUrl (public Supabase link or any public url)
/// - movieTitle
/// - movieDescription
/// - id (optional but required for syncing likes/comments/views with Firestore)
///
/// If you pass feed docs as Reels without `id`, the screen will still play videos,
/// but counts won't be live-updated (recommended to include feed doc IDs).
class FeedReelPlayerScreen extends StatefulWidget {
  final List<Reel> reels;
  final int initialIndex;
  final String feedMode; // optional starting feed mode

  const FeedReelPlayerScreen({
    super.key,
    required this.reels,
    this.initialIndex = 0,
    this.feedMode = 'for_everyone',
  });

  @override
  _FeedReelPlayerScreenState createState() => _FeedReelPlayerScreenState();
}

class _FeedReelPlayerScreenState extends State<FeedReelPlayerScreen> {
  late PageController _pageController;
  int _currentIndex = 0;

  /// video controllers keyed by reel index in the _orderedReels list
  final Map<int, VideoPlayerController> _controllers = {};

  /// Firestore realtime metadata for each feed doc id
  final Map<String, Map<String, dynamic>> _liveMetaById = {};

  /// Firestore subscriptions keyed by feed doc id
  final Map<String, StreamSubscription<DocumentSnapshot>> _metaSubs = {};

  /// keep track of which indices we've incremented views for (avoid double-count)
  final Set<String> _viewedThisSession = {};

  /// ordered list of reels after algorithmic ranking
  late List<Reel> _orderedReels;

  /// feed mode state
  String _feedMode = 'for_everyone';

  /// small random seed for shuffle/entropy
  int _seed = DateTime.now().millisecondsSinceEpoch % 100000;

  /// Firestore instance
  final FirebaseFirestore _fire = FirebaseFirestore.instance;

  /// Auth
  final User? _authUser = FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    _feedMode = widget.feedMode;
    _seed = DateTime.now().millisecondsSinceEpoch % 100000;
    // copy provided reels and order them using ranking algorithm
    _orderedReels = List<Reel>.from(widget.reels);
    _applyRankingAndShuffle();

    _currentIndex = widget.initialIndex.clamp(0, max(0, _orderedReels.length - 1));
    _pageController = PageController(initialPage: _currentIndex);

    // initialize controllers for current, prev/next 5
    _initializeControllersAroundIndex(_currentIndex);

    // subscribe to live metadata for initial visible reels (if they have ids)
    _subscribeMetaForIndices(_currentIndex - 5, _currentIndex + 5);
  }

  @override
  void didUpdateWidget(covariant FeedReelPlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // if the provided reels changed, update ordering and controllers
    if (oldWidget.reels != widget.reels) {
      _orderedReels = List<Reel>.from(widget.reels);
      _applyRankingAndShuffle();
      // ensure currentIndex in range
      _currentIndex = _currentIndex.clamp(0, max(0, _orderedReels.length - 1));
      _initializeControllersAroundIndex(_currentIndex);
    }
  }

  // Ranking algorithm: combine recency, likes, comments, views and a small random seed.
  // Promotes new videos (ageBoost window) and trending videos; supports feed modes.
  void _applyRankingAndShuffle() {
    if (_orderedReels.isEmpty) return;
    final now = DateTime.now();

    // Extract metadata if available (some reels may not have id or live meta)
    final metaForReel = (Reel r) {
      final id = (r as dynamic).id?.toString();
      if (id != null && _liveMetaById.containsKey(id)) return _liveMetaById[id]!;
      return <String, dynamic>{};
    };

    // compute scores
    final scored = <MapEntry<Reel, double>>[];
    for (var r in _orderedReels) {
      final m = metaForReel(r);

      // counts fallback
      final likes = (m['likedBy'] is List) ? (m['likedBy'] as List).length : (m['likes'] is int ? m['likes'] as int : 0);
      final comments = (m['commentsCount'] is int) ? m['commentsCount'] as int : (m['comments'] is int ? m['comments'] as int : 0);
      final views = (m['views'] is int) ? m['views'] as int : 0;
      DateTime ts;
      try {
        if (m['timestamp'] is Timestamp) ts = (m['timestamp'] as Timestamp).toDate();
        else if (m['timestamp'] is String) ts = DateTime.parse(m['timestamp'] as String);
        else ts = DateTime.now();
      } catch (_) {
        ts = DateTime.now();
      }

      // base scoring factors
      final ageHours = max(1, now.difference(ts).inHours);
      final recencyFactor = 1 / ageHours; // newer => higher
      final engagement = (log(1 + likes) * 1.4) + (log(1 + comments) * 1.2) + (log(1 + views) * 1.0);
      // promote very new content strongly (e.g. first 24 hours)
      final newBoost = now.difference(ts).inHours < 24 ? 2.0 : 1.0;

      // small randomness to help circulate videos across users
      final rng = Random(_seed + (r.videoUrl.hashCode & 0xffff));
      final noise = (rng.nextDouble() - 0.5) * 0.2; // -0.1 .. 0.1

      double score;
      switch (_feedMode) {
        case 'trending':
          score = engagement * 1.8 * newBoost + recencyFactor * 0.5 + noise;
          break;
        case 'fresh':
          score = recencyFactor * 2.8 * newBoost + engagement * 0.6 + noise;
          break;
        case 'personalized':
          // placeholder: for personalization you'd look at user tags/seen tags;
          // we simulate by slightly favoring engagement but keeping some recency.
          score = engagement * 1.3 + recencyFactor * 1.2 + noise;
          break;
        case 'for_everyone':
        default:
          score = engagement * 1.0 + recencyFactor * 1.0 + noise;
          break;
      }

      scored.add(MapEntry(r, score));
    }

    // sort descending by score
    scored.sort((a, b) => b.value.compareTo(a.value));
    _orderedReels = scored.map((e) => e.key).toList();
  }

  // Initialize video controllers for a range around the given index
  void _initializeControllersAroundIndex(int index) {
    final start = index - 5;
    final end = index + 5;
    for (int i = start; i <= end; i++) {
      if (i >= 0 && i < _orderedReels.length && !_controllers.containsKey(i)) {
        final url = _orderedReels[i].videoUrl;
        try {
          final controller = VideoPlayerController.network(url, videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
          _controllers[i] = controller;
          controller.setLooping(true);
          controller.initialize().then((_) {
            if (!mounted) return;
            if (i == _currentIndex) {
              controller.play();
              _maybeIncrementViewForIndex(i);
            }
            setState(() {});
          }).catchError((e) {
            debugPrint('video initialize error for index $i: $e');
          });
        } catch (e) {
          debugPrint('failed to create controller for index $i -> $e');
        }
      }
    }
  }

  // Subscribe to feed doc metadata for a range of indices
  void _subscribeMetaForIndices(int start, int end) {
    for (int i = start; i <= end; i++) {
      if (i >= 0 && i < _orderedReels.length) {
        final reel = _orderedReels[i];
        final String? id = (reel as dynamic).id?.toString();
        if (id == null || id.isEmpty) continue;
        if (_metaSubs.containsKey(id)) continue;

        final sub = _fire.collection('feeds').doc(id).snapshots().listen((snap) {
          if (snap.exists) {
            final data = snap.data() ?? {};
            final normalized = Map<String, dynamic>.from(data);
            if (normalized['likedBy'] is! List) normalized['likedBy'] = (normalized['likedBy'] ?? []) as List;
            _liveMetaById[id] = normalized;
            if (mounted) setState(() {});
          }
        }, onError: (e) {
          debugPrint('meta subscription error for $id: $e');
        });

        _metaSubs[id] = sub;
      }
    }
  }

  // Cancel subscriptions that are no longer needed
  void _unsubscribeMetaById(String id) {
    try {
      _metaSubs[id]?.cancel();
    } catch (_) {}
    _metaSubs.remove(id);
    _liveMetaById.remove(id);
  }

  // Called when the PageView changes index
  void _onPageChanged(int index) {
    if (!mounted) return;
    _controllers[_currentIndex]?.pause();

    setState(() {
      _currentIndex = index;
    });

    _initializeControllersAroundIndex(index);

    // dispose controllers outside the preloaded range (keep -5 to +5)
    final active = List.generate(11, (i) => index - 5 + i).where((i) => i >= 0 && i < _orderedReels.length).toSet();
    final toRemove = _controllers.keys.where((k) => !active.contains(k)).toList();
    for (var k in toRemove) {
      try {
        _controllers[k]?.dispose();
      } catch (_) {}
      _controllers.remove(k);
    }

    // subscribe/unsubscribe meta streams
    final activeIds = <String>{};
    for (var idx in active) {
      final id = (_orderedReels[idx] as dynamic).id?.toString();
      if (id != null) activeIds.add(id);
    }
    final subsKeys = _metaSubs.keys.toList();
    for (var id in subsKeys) {
      if (!activeIds.contains(id)) _unsubscribeMetaById(id);
    }
    _subscribeMetaForIndices(index - 5, index + 5);

    final newController = _controllers[index];
    if (newController != null && newController.value.isInitialized) {
      newController.play();
      _maybeIncrementViewForIndex(index);
    }
  }

  // increment view count on Firestore for a reel once per session per user
  Future<void> _maybeIncrementViewForIndex(int index) async {
    if (index < 0 || index >= _orderedReels.length) return;
    final reel = _orderedReels[index];
    final String? id = (reel as dynamic).id?.toString();
    if (id == null || id.isEmpty) return;
    if (_authUser == null) return;
    final key = '${_authUser!.uid}::$id';
    if (_viewedThisSession.contains(key)) return;
    _viewedThisSession.add(key);
    try {
      await _fire.collection('feeds').doc(id).update({'views': FieldValue.increment(1)});
    } catch (e) {
      debugPrint('failed to increment view for $id: $e');
    }
  }

  // toggle like for current reel
  Future<void> _toggleLikeForIndex(int index) async {
    if (index < 0 || index >= _orderedReels.length) return;
    final reel = _orderedReels[index];
    final String? id = (reel as dynamic).id?.toString();
    if (id == null || id.isEmpty) return;
    final uid = _authUser?.uid;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please log in to like')));
      return;
    }
    final meta = _liveMetaById[id];
    final likedBy = (meta != null && meta['likedBy'] is List) ? List<String>.from(meta['likedBy']) : <String>[];

    try {
      final docRef = _fire.collection('feeds').doc(id);
      if (likedBy.contains(uid)) {
        await docRef.update({'likedBy': FieldValue.arrayRemove([uid])});
      } else {
        await docRef.update({'likedBy': FieldValue.arrayUnion([uid])});
      }
    } catch (e) {
      debugPrint('like toggle failed for $id: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to like: $e')));
    }
  }

  // open comments bottom sheet for current index
  void _openCommentsSheet(int index) {
    if (index < 0 || index >= _orderedReels.length) return;
    final reel = _orderedReels[index];
    final String? id = (reel as dynamic).id?.toString();
    if (id == null || id.isEmpty) {
      _showLocalCommentsSheet(reel, id: null);
      return;
    }
    _showCommentsBottomSheet(feedId: id, reel: reel);
  }

  // Show a generic local comments sheet (no Firestore)
  void _showLocalCommentsSheet(Reel reel, {String? id}) {
    showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.black87,
        builder: (context) {
          final controller = TextEditingController();
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.7,
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Container(width: 40, height: 5, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(6))),
                  const SizedBox(height: 12),
                  Text('Comments (offline)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Center(child: Text('No comments available for this reel.', style: TextStyle(color: Colors.white54))),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(hintText: 'Add a comment', hintStyle: TextStyle(color: Colors.white54), filled: true, fillColor: Colors.white12, border: InputBorder.none),
                          ),
                        ),
                        IconButton(
                            onPressed: () {
                              controller.clear();
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Comment posted (local)')));
                            },
                            icon: const Icon(Icons.send, color: Colors.white))
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        });
  }

  // Show bottom sheet for comments connected to Firestore
  void _showCommentsBottomSheet({required String feedId, required Reel reel}) {
    showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) {
          final TextEditingController _commentController = TextEditingController();
          final FocusNode _focusNode = FocusNode();
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.7,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            builder: (context, scrollController) {
              return Container(
                decoration: const BoxDecoration(
                    color: Color(0xFF111214),
                    borderRadius: BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16))),
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    Container(width: 40, height: 5, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(6))),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Row(
                        children: [
                          Expanded(child: Text('Comments', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600))),
                          TextButton(
                            onPressed: () {
                              scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
                            },
                            child: const Text('Latest', style: TextStyle(color: Colors.white70)),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: StreamBuilder<QuerySnapshot>(
                        stream: _fire.collection('feeds').doc(feedId).collection('comments').orderBy('timestamp', descending: true).snapshots(),
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return Center(child: Text('Failed to load comments', style: TextStyle(color: Colors.white70)));
                          }
                          if (!snapshot.hasData) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          final docs = snapshot.data!.docs;
                          if (docs.isEmpty) {
                            return Center(child: Text('No comments yet — be the first!', style: TextStyle(color: Colors.white54)));
                          }
                          return ListView.separated(
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            itemCount: docs.length,
                            separatorBuilder: (_, __) => const Divider(color: Colors.white10),
                            itemBuilder: (context, i) {
                              final d = docs[i];
                              final data = d.data() as Map<String, dynamic>? ?? {};
                              final username = data['username'] ?? 'User';
                              final text = data['text'] ?? '';
                              final avatar = data['userAvatar'] ?? '';
                              final ts = data['timestamp'];
                              String timeText = '';
                              try {
                                DateTime t;
                                if (ts is Timestamp) t = ts.toDate();
                                else if (ts is String) t = DateTime.parse(ts);
                                else t = DateTime.now();
                                final diff = DateTime.now().difference(t);
                                if (diff.inMinutes < 1) timeText = 'just now';
                                else if (diff.inHours < 1) timeText = '${diff.inMinutes}m';
                                else if (diff.inDays < 1) timeText = '${diff.inHours}h';
                                else timeText = '${diff.inDays}d';
                              } catch (_) {
                                timeText = '';
                              }
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Colors.grey[800],
                                  backgroundImage: avatar != null && avatar.toString().isNotEmpty ? NetworkImage(avatar) : null,
                                  child: (avatar == null || avatar.toString().isEmpty) ? Text(username.isNotEmpty ? username[0].toUpperCase() : 'U') : null,
                                ),
                                title: Text(username, style: const TextStyle(color: Colors.white)),
                                subtitle: Text(text, style: const TextStyle(color: Colors.white70)),
                                trailing: Text(timeText, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                              );
                            },
                          );
                        },
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.only(left: 12, right: 8, bottom: MediaQuery.of(context).viewInsets.bottom == 0 ? 12 : MediaQuery.of(context).viewInsets.bottom),
                      color: Colors.transparent,
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _commentController,
                              focusNode: _focusNode,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                  hintText: 'Add a comment...',
                                  hintStyle: const TextStyle(color: Colors.white54),
                                  filled: true,
                                  fillColor: Colors.white12,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                  border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.circular(24))),
                            ),
                          ),
                          IconButton(
                              onPressed: () async {
                                final text = _commentController.text.trim();
                                if (text.isEmpty) return;
                                final uid = _authUser?.uid ?? 'anonymous';
                                final username = _authUser?.displayName ?? (_authUser?.email ?? 'User');
                                final avatar = ''; // optionally load from profile
                                try {
                                  await _fire.collection('feeds').doc(feedId).collection('comments').add({
                                    'text': text,
                                    'userId': uid,
                                    'username': username,
                                    'userAvatar': avatar,
                                    'timestamp': DateTime.now().toIso8601String(),
                                  });
                                  await _fire.collection('feeds').doc(feedId).update({'commentsCount': FieldValue.increment(1)});
                                  _commentController.clear();
                                  _focusNode.requestFocus();
                                } catch (e) {
                                  debugPrint('failed to post comment: $e');
                                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to post comment: $e')));
                                }
                              },
                              icon: const Icon(Icons.send, color: Colors.white))
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        });
  }

  // share reel (uses share_plus)
  Future<void> _shareReel(int index) async {
    if (index < 0 || index >= _orderedReels.length) return;
    final reel = _orderedReels[index];
    final url = reel.videoUrl;
    final title = reel.movieTitle ?? '';
    try {
      final text = '$title\n\nWatch: $url';
      await Share.share(text);
    } catch (e) {
      debugPrint('share failed: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to share: $e')));
    }
  }

  // Dispose controllers and subscriptions
  @override
  void dispose() {
    _pageController.dispose();
    for (var c in _controllers.values) {
      try {
        c.dispose();
      } catch (_) {}
    }
    for (var s in _metaSubs.values) {
      try {
        s.cancel();
      } catch (_) {}
    }
    _controllers.clear();
    _metaSubs.clear();
    _liveMetaById.clear();
    super.dispose();
  }

  // build right-side icon column with live counts
  Widget _buildRightActionColumn(int index) {
    final reel = _orderedReels[index];
    final id = (reel as dynamic).id?.toString();
    final meta = id != null ? _liveMetaById[id] : null;
    final likedBy = meta != null && meta['likedBy'] is List ? List<String>.from(meta['likedBy']) : <String>[];
    final likesCount = likedBy.length;
    final commentsCount = meta != null && meta['commentsCount'] is int ? meta['commentsCount'] as int : (meta != null && meta['comments'] is int ? meta['comments'] as int : 0);
    final views = meta != null && meta['views'] is int ? meta['views'] as int : 0;
    final uid = _authUser?.uid;

    final isLiked = uid != null && likedBy.contains(uid);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () {
            // open profile if you want
          },
          child: CircleAvatar(
            radius: 22,
            backgroundColor: Colors.white12,
            child: Icon(Icons.person, color: Colors.white70),
          ),
        ),
        const SizedBox(height: 20),
        _ActionIconWithCount(
          icon: isLiked ? Icons.favorite : Icons.favorite_border,
          color: isLiked ? Colors.redAccent : Colors.white,
          count: likesCount,
          onTap: () => _toggleLikeForIndex(index),
          label: 'Like',
        ),
        const SizedBox(height: 16),
        _ActionIconWithCount(
          icon: Icons.thumb_down_outlined,
          color: Colors.white,
          count: 0,
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not implemented')));
          },
          label: 'Down',
        ),
        const SizedBox(height: 16),
        _ActionIconWithCount(
          icon: Icons.comment,
          color: Colors.white,
          count: commentsCount,
          onTap: () => _openCommentsSheet(index),
          label: 'Comments',
        ),
        const SizedBox(height: 16),
        _ActionIconWithCount(
          icon: Icons.share,
          color: Colors.white,
          count: 0,
          onTap: () => _shareReel(index),
          label: 'Share',
        ),
        const SizedBox(height: 16),
        Column(
          children: [
            const Icon(Icons.visibility, color: Colors.white70, size: 28),
            const SizedBox(height: 6),
            Text(views.toString(), style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      ],
    );
  }

  // top-right popup to change feed mode (applies ranking and reshuffles)
  Widget _buildFeedModeSelector() {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.filter_list, color: Colors.white),
      onSelected: (s) {
        setState(() {
          _feedMode = s;
          _applyRankingAndShuffle();
          _controllers.forEach((k, c) {
            try {
              c.dispose();
            } catch (_) {}
          });
          _controllers.clear();
          _initializeControllersAroundIndex(_currentIndex);
        });
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'for_everyone', child: Text('For everyone', style: TextStyle(color: _feedMode == 'for_everyone' ? Colors.amber : Colors.black))),
        PopupMenuItem(value: 'trending', child: Text('Trending', style: TextStyle(color: _feedMode == 'trending' ? Colors.amber : Colors.black))),
        PopupMenuItem(value: 'fresh', child: Text('Fresh / Newest', style: TextStyle(color: _feedMode == 'fresh' ? Colors.amber : Colors.black))),
        PopupMenuItem(value: 'personalized', child: Text('Personalized', style: TextStyle(color: _feedMode == 'personalized' ? Colors.amber : Colors.black))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_orderedReels.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context))),
        body: const Center(child: Text('No videos available', style: TextStyle(color: Colors.white70))),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            itemCount: _orderedReels.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, index) {
              final reel = _orderedReels[index];
              final controller = _controllers[index];

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (controller != null && controller.value.isInitialized) {
                    if (controller.value.isPlaying) {
                      controller.pause();
                    } else {
                      controller.play();
                    }
                    setState(() {});
                  }
                },
                onDoubleTap: () {
                  _toggleLikeForIndex(index);
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (controller == null || !controller.value.isInitialized)
                      const Center(child: CircularProgressIndicator())
                    else
                      FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: controller.value.size.width,
                          height: controller.value.size.height,
                          child: VideoPlayer(controller),
                        ),
                      ),
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: Container(
                        width: MediaQuery.of(context).size.width * 0.6,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(colors: [Colors.transparent, Colors.black54], begin: Alignment.topCenter, end: Alignment.bottomCenter),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              reel.movieTitle ?? '',
                              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              reel.movieDescription ?? '',
                              style: const TextStyle(color: Colors.white70, fontSize: 14),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.white12, elevation: 0),
                                  onPressed: () {
                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Start Watch Party (not implemented)')));
                                  },
                                  icon: const Icon(Icons.connected_tv, color: Colors.white, size: 18),
                                  label: const Text('Watch Party', style: TextStyle(color: Colors.white)),
                                ),
                                const SizedBox(width: 8),
                                TextButton.icon(
                                  onPressed: () => _shareReel(index),
                                  icon: const Icon(Icons.share, color: Colors.white70),
                                  label: const Text('Share', style: TextStyle(color: Colors.white70)),
                                )
                              ],
                            )
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      right: 12,
                      top: MediaQuery.of(context).size.height * 0.2,
                      child: _buildRightActionColumn(index),
                    ),
                    Positioned(
                      top: 36,
                      left: 12,
                      child: SafeArea(
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28),
                          onPressed: () {
                            Navigator.pop(context);
                          },
                        ),
                      ),
                    ),
                    Positioned(
                      top: 36,
                      right: 12,
                      child: SafeArea(child: _buildFeedModeSelector()),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// small widget: icon plus count stacked vertically with onTap
class _ActionIconWithCount extends StatelessWidget {
  final IconData icon;
  final Color color;
  final int count;
  final VoidCallback onTap;
  final String label;

  const _ActionIconWithCount({required this.icon, required this.color, required this.count, required this.onTap, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        IconButton(onPressed: onTap, icon: Icon(icon, color: color, size: 30)),
        const SizedBox(height: 6),
        Text(count.toString(), style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}