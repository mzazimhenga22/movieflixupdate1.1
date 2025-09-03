// feed_reel_player_screen_with_ads.dart
// Updated: adds in-feed ads (AdMob native/banner, Facebook native, Unity interstitial) shown randomly within the vertical PageView.
// NOTE: Replace all placeholder ad unit ids and game ids with your real ids. See comments for pubspec + native setup.

import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';

// Ad packages
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:facebook_audience_network/facebook_audience_network.dart';

// Unity Ads plugin: package name may vary depending on the plugin you choose.
// If you use a package with a different import, replace this import and the Unity calls below.
import 'package:unity_ads_plugin/unity_ads_plugin.dart';

import '../../models/reel.dart';

/// ---------------------------
/// PUBSPEC / PLATFORM NOTES
/// ---------------------------
/// Add to pubspec.yaml:
///   google_mobile_ads: ^2.3.0
///   facebook_audience_network: ^0.8.0
///   unity_ads_plugin: ^1.0.0   // adjust to the actual package you pick
///
/// Android:
///  - Add AdMob app id to AndroidManifest.xml (application tag):
///      <meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" android:value="ca-app-pub-3940256099942544~3347511713"/>
///  - FAN and Unity require additional setup (placement ids, initialization).
///
/// iOS:
///  - Add AdMob App ID to Info.plist.
///  - Follow FAN and Unity docs for iOS setup.
///
/// Replace the placeholder/test ids below with your production ids.
/// ---------------------------

enum FeedItemType { reel, ad }

class FeedItem {
  final FeedItemType type;
  final Reel? reel;
  final String? provider; // 'admob', 'facebook', 'unity'
  final bool isVideoAd;
  final String? adUnitId; // provider ad unit id or placement id

  FeedItem.reel(this.reel)
      : type = FeedItemType.reel,
        provider = null,
        isVideoAd = false,
        adUnitId = null;

  FeedItem.ad({required this.provider, this.adUnitId, this.isVideoAd = false})
      : type = FeedItemType.ad,
        reel = null;
}

class FeedReelPlayerScreen extends StatefulWidget {
  final List<Reel> reels;
  final int initialIndex;
  final String feedMode;

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

  /// Video controllers keyed by combined feed index (items may be ad or reel)
  final Map<int, VideoPlayerController> _controllers = {};

  /// Active loaded AdMob Native/Banner/Interstitial objects keyed by combined feed index
  final Map<int, NativeAd> _admobNativeByIndex = {};
  final Map<int, BannerAd> _admobBannerByIndex = {};
  final Map<int, InterstitialAd> _admobInterstitialByIndex = {};

  /// Facebook native widget state doesn't need a heavy object; we track loaded flags
  final Map<int, bool> _facebookNativeLoaded = {};

  /// Unity: we'll preload/show interstitials when encountering a Unity ad item
  final Set<int> _unityPreloadedSet = {};

  /// Firestore realtime metadata for each feed doc id
  final Map<String, Map<String, dynamic>> _liveMetaById = {};
  final Map<String, StreamSubscription<DocumentSnapshot>> _metaSubs = {};
  final Set<String> _viewedThisSession = {};

  late List<Reel> _orderedReels;
  late List<FeedItem> _combinedItems; // reels + ads interleaved

  String _feedMode = 'for_everyone';
  int _seed = DateTime.now().millisecondsSinceEpoch % 100000;
  final FirebaseFirestore _fire = FirebaseFirestore.instance;
  final User? _authUser = FirebaseAuth.instance.currentUser;
  final Random _rng = Random();

  // AD UNIT IDS (replace with real IDs)
  // AdMob test native: ca-app-pub-3940256099942544/2247696110
  // AdMob test banner: ca-app-pub-3940256099942544/6300978111
  // AdMob interstitial test: ca-app-pub-3940256099942544/1033173712
  static const String admobNativeTestId = 'ca-app-pub-3940256099942544/2247696110';
  static const String admobBannerTestId = 'ca-app-pub-3940256099942544/6300978111';
  static const String admobInterstitialTestId = 'ca-app-pub-3940256099942544/1033173712';

  // Facebook Audience Network test placement id (example)
  static const String fanPlacementTestId = 'IMG_16_9_APP_INSTALL#YOUR_PLACEMENT_ID';

  // Unity Ads: game id and placement (replace with your ids)
  static const String unityGameIdAndroid = '1234567';
  static const String unityGameIdIos = '7654321';
  static const String unityInFeedPlacement = 'video'; // example

  // Controls how often ads appear (min,max distance between ads)
  final int adSpacingMin = 3;
  final int adSpacingMax = 7;

  bool _adsInitialized = false;

  @override
  void initState() {
    super.initState();
    _feedMode = widget.feedMode;
    _seed = DateTime.now().millisecondsSinceEpoch % 100000;
    _orderedReels = List<Reel>.from(widget.reels);
    _applyRankingAndShuffle();

    _currentIndex = widget.initialIndex.clamp(0, max(0, _orderedReels.length - 1));

    // Build combined list with ads inserted
    _combinedItems = _buildCombinedListWithAds(_orderedReels, seed: _seed);

    _pageController = PageController(initialPage: _currentIndex);

    // initialize controllers around current index
    _initializeControllersAroundIndex(_currentIndex);

    // subscribe to live metadata for reel items near current index
    _subscribeMetaForCombinedIndices(_currentIndex - 6, _currentIndex + 6);

    // initialize ad SDKs (non-blocking)
    _initializeAdSdks();
  }

  // Initialize ad SDKs (AdMob, FAN, Unity)
  void _initializeAdSdks() async {
    try {
      // AdMob
      await MobileAds.instance.initialize();
      // Facebook Audience Network
      FacebookAudienceNetwork.init();
      // Unity - choose testMode true for dev
      await UnityAds.init(
        gameId: Theme.of(context).platform == TargetPlatform.iOS ? unityGameIdIos : unityGameIdAndroid,
        testMode: true,
      );

      setState(() {
        _adsInitialized = true;
      });
    } catch (e) {
      debugPrint('Ad SDK init error: $e');
      // don't rethrow; allow app to function with placeholders
    }
  }

  // Create combined list: interleave ad items randomly among reels.
  List<FeedItem> _buildCombinedListWithAds(List<Reel> reels, {required int seed}) {
    final rng = Random(seed);
    final List<FeedItem> out = [];
    int i = 0;
    int nextAdDistance = adSpacingMin + rng.nextInt(max(1, adSpacingMax - adSpacingMin + 1));
    int reelsSinceLastAd = 0;

    while (i < reels.length) {
      out.add(FeedItem.reel(reels[i]));
      i++;
      reelsSinceLastAd++;

      if (i < reels.length && reelsSinceLastAd >= nextAdDistance) {
        // choose provider randomly with weighted choice
        final choice = rng.nextDouble();
        if (choice < 0.5) {
          out.add(FeedItem.ad(provider: 'admob', adUnitId: admobNativeTestId, isVideoAd: true));
        } else if (choice < 0.85) {
          out.add(FeedItem.ad(provider: 'facebook', adUnitId: fanPlacementTestId, isVideoAd: true));
        } else {
          out.add(FeedItem.ad(provider: 'unity', adUnitId: unityInFeedPlacement, isVideoAd: true));
        }
        // reset counters
        reelsSinceLastAd = 0;
        nextAdDistance = adSpacingMin + rng.nextInt(max(1, adSpacingMax - adSpacingMin + 1));
      }
    }

    // Optionally add an ad at the end
    if (rng.nextDouble() < 0.25) {
      out.add(FeedItem.ad(provider: 'admob', adUnitId: admobBannerTestId, isVideoAd: false));
    }

    return out;
  }

  @override
  void didUpdateWidget(covariant FeedReelPlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reels != widget.reels) {
      _orderedReels = List<Reel>.from(widget.reels);
      _applyRankingAndShuffle();
      _combinedItems = _buildCombinedListWithAds(_orderedReels, seed: _seed);
      _currentIndex = _currentIndex.clamp(0, max(0, _combinedItems.length - 1));
      _initializeControllersAroundIndex(_currentIndex);
      _subscribeMetaForCombinedIndices(_currentIndex - 6, _currentIndex + 6);
      setState(() {});
    }
  }

  String? _getReelId(Reel r) {
    try {
      final dyn = r as dynamic;
      final id = dyn.id;
      if (id == null) return null;
      return id.toString();
    } catch (e) {
      return null;
    }
  }

  void _applyRankingAndShuffle() {
    if (_orderedReels.isEmpty) return;
    final now = DateTime.now();
    final metaForReel = (Reel r) {
      final id = _getReelId(r);
      if (id != null && _liveMetaById.containsKey(id)) return _liveMetaById[id]!;
      return <String, dynamic>{};
    };

    final scored = <MapEntry<Reel, double>>[];
    for (var r in _orderedReels) {
      final m = metaForReel(r);
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

      final ageHours = max(1, now.difference(ts).inHours);
      final recencyFactor = 1 / ageHours;
      final engagement = (log(1 + likes) * 1.4) + (log(1 + comments) * 1.2) + (log(1 + views) * 1.0);
      final newBoost = now.difference(ts).inHours < 24 ? 2.0 : 1.0;

      final rng = Random(_seed + (r.videoUrl.hashCode & 0xffff));
      final noise = (rng.nextDouble() - 0.5) * 0.2;

      double score;
      switch (_feedMode) {
        case 'trending':
          score = engagement * 1.8 * newBoost + recencyFactor * 0.5 + noise;
          break;
        case 'fresh':
          score = recencyFactor * 2.8 * newBoost + engagement * 0.6 + noise;
          break;
        case 'personalized':
          score = engagement * 1.3 + recencyFactor * 1.2 + noise;
          break;
        case 'for_everyone':
        default:
          score = engagement * 1.0 + recencyFactor * 1.0 + noise;
          break;
      }

      scored.add(MapEntry(r, score));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    _orderedReels = scored.map((e) => e.key).toList();
  }

  // Initialize controllers for reel items around combined index
  void _initializeControllersAroundIndex(int combinedIndex) {
    final start = combinedIndex - 5;
    final end = combinedIndex + 5;
    for (int i = start; i <= end; i++) {
      if (i >= 0 && i < _combinedItems.length) {
        final item = _combinedItems[i];
        if (item.type == FeedItemType.reel && !_controllers.containsKey(i)) {
          final url = item.reel!.videoUrl;
          try {
            final controller = VideoPlayerController.network(url, videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
            _controllers[i] = controller;
            controller.setLooping(true);
            controller.initialize().then((_) {
              if (!mounted) return;
              if (i == _currentIndex) {
                controller.play();
                _maybeIncrementViewForCombinedIndex(i);
              }
              setState(() {});
            }).catchError((e) {
              debugPrint('video initialize error for combined index $i: $e');
            });
          } catch (e) {
            debugPrint('failed to create controller for combined index $i -> $e');
          }
        }

        // Preload ads for ad items
        if (item.type == FeedItemType.ad) {
          _prepareAdForCombinedIndex(i, item);
        }
      }
    }

    // dispose controllers outside range
    final active = List.generate(11, (k) => combinedIndex - 5 + k).where((k) => k >= 0 && k < _combinedItems.length).toSet();
    final toRemove = _controllers.keys.where((k) => !active.contains(k)).toList();
    for (var k in toRemove) {
      try {
        _controllers[k]?.dispose();
      } catch (_) {}
      _controllers.remove(k);
    }
  }

  // Subscribe to feed doc metadata but mapping to reel ids contained in combined items
  void _subscribeMetaForCombinedIndices(int start, int end) {
    for (int i = start; i <= end; i++) {
      if (i >= 0 && i < _combinedItems.length) {
        final item = _combinedItems[i];
        if (item.type == FeedItemType.reel) {
          final id = _getReelId(item.reel!);
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

    // Unsubscribe ones outside range
    final activeIds = <String>{};
    for (int i = max(0, start); i <= min(_combinedItems.length - 1, end); i++) {
      final it = _combinedItems[i];
      if (it.type == FeedItemType.reel) {
        final id = _getReelId(it.reel!);
        if (id != null) activeIds.add(id);
      }
    }
    final subsKeys = _metaSubs.keys.toList();
    for (var id in subsKeys) {
      if (!activeIds.contains(id)) _unsubscribeMetaById(id);
    }
  }

  void _unsubscribeMetaById(String id) {
    try {
      _metaSubs[id]?.cancel();
    } catch (_) {}
    _metaSubs.remove(id);
    _liveMetaById.remove(id);
  }

  void _onPageChanged(int index) {
    if (!mounted) return;
    // pause previous if it was a reel
    _controllers[_currentIndex]?.pause();

    setState(() {
      _currentIndex = index;
    });

    _initializeControllersAroundIndex(index);
    _subscribeMetaForCombinedIndices(index - 6, index + 6);

    final newController = _controllers[index];
    if (newController != null && newController.value.isInitialized) {
      newController.play();
      _maybeIncrementViewForCombinedIndex(index);
    }

    // If current item is an ad and provider==unity, consider showing a Unity interstitial here
    final item = _combinedItems[index];
    if (item.type == FeedItemType.ad && item.provider == 'unity') {
      _showUnityAdIfReady(index, item);
    }
  }

  Future<void> _maybeIncrementViewForCombinedIndex(int combinedIndex) async {
    if (combinedIndex < 0 || combinedIndex >= _combinedItems.length) return;
    final item = _combinedItems[combinedIndex];
    if (item.type != FeedItemType.reel) return;
    final reel = item.reel!;
    final String? id = _getReelId(reel);
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

  Future<void> _toggleLikeForCombinedIndex(int combinedIndex) async {
    if (combinedIndex < 0 || combinedIndex >= _combinedItems.length) return;
    final item = _combinedItems[combinedIndex];
    if (item.type != FeedItemType.reel) return;
    final reel = item.reel!;
    final String? id = _getReelId(reel);
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

  void _openCommentsSheetForCombinedIndex(int combinedIndex) {
    if (combinedIndex < 0 || combinedIndex >= _combinedItems.length) return;
    final item = _combinedItems[combinedIndex];
    if (item.type != FeedItemType.reel) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Comments only available for reels')));
      return;
    }
    final reel = item.reel!;
    final String? id = _getReelId(reel);
    if (id == null || id.isEmpty) {
      _showLocalCommentsSheet(reel, id: null);
      return;
    }
    _showCommentsBottomSheet(feedId: id, reel: reel);
  }

  void _showLocalCommentsSheet(Reel reel, {String? id}) {
    // same as your original sheet — kept minimal for brevity
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

  void _showCommentsBottomSheet({required String feedId, required Reel reel}) {
    // identical to your original Firestore-powered bottom sheet. For brevity reuse earlier code or keep as-is.
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
                decoration: const BoxDecoration(color: Color(0xFF111214), borderRadius: BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16))),
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
                      child: StreamBuilder<DocumentSnapshot>(
                        stream: _fire.collection('feeds').doc(feedId).snapshots(),
                        builder: (context, feedSnap) {
                          if (feedSnap.hasError) {
                            return Center(child: Text('Failed to load comments', style: TextStyle(color: Colors.white70)));
                          }
                          // show nested comments collection stream
                          return StreamBuilder<QuerySnapshot>(
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

  // Prepare ads for combined index (preload AdMob native/banner/interstitial or mark FAN as loading)
  void _prepareAdForCombinedIndex(int combinedIndex, FeedItem item) {
    if (!_adsInitialized) return;
    if (item.provider == 'admob') {
      // For AdMob: choose native if isVideoAd else banner
      if (item.isVideoAd) {
        if (_admobNativeByIndex.containsKey(combinedIndex)) return;
        try {
          final native = NativeAd(
            adUnitId: item.adUnitId ?? admobNativeTestId,
            factoryId: 'listTile', // you must register a native factory on the platform side for complex templates OR use a simple template factory id you register
            listener: NativeAdListener(
              onAdLoaded: (ad) {
                debugPrint('AdMob native loaded for index $combinedIndex');
                if (mounted) setState(() {});
              },
              onAdFailedToLoad: (ad, err) {
                debugPrint('AdMob native failed to load index $combinedIndex: $err');
                try {
                  ad.dispose();
                } catch (_) {}
                _admobNativeByIndex.remove(combinedIndex);
                if (mounted) setState(() {});
              },
            ),
            request: AdRequest(),
          );
          _admobNativeByIndex[combinedIndex] = native;
          native.load();
        } catch (e) {
          debugPrint('failed to create admob native: $e');
        }
      } else {
        if (_admobBannerByIndex.containsKey(combinedIndex)) return;
        try {
          final banner = BannerAd(
            adUnitId: item.adUnitId ?? admobBannerTestId,
            size: AdSize.mediumRectangle,
            request: AdRequest(),
            listener: BannerAdListener(
              onAdLoaded: (ad) {
                debugPrint('AdMob banner loaded for index $combinedIndex');
                if (mounted) setState(() {});
              },
              onAdFailedToLoad: (ad, err) {
                debugPrint('AdMob banner failed for index $combinedIndex: $err');
                try {
                  ad.dispose();
                } catch (_) {}
                _admobBannerByIndex.remove(combinedIndex);
                if (mounted) setState(() {});
              },
            ),
          );
          _admobBannerByIndex[combinedIndex] = banner;
          banner.load();
        } catch (e) {
          debugPrint('failed to create admob banner: $e');
        }
      }

      // Preload an interstitial optionally for AdMob video ad display (if desired)
      if (item.isVideoAd && !_admobInterstitialByIndex.containsKey(combinedIndex)) {
        InterstitialAd.load(
          adUnitId: admobInterstitialTestId,
          request: AdRequest(),
          adLoadCallback: InterstitialAdLoadCallback(
            onAdLoaded: (ad) {
              _admobInterstitialByIndex[combinedIndex] = ad;
              debugPrint('AdMob interstitial loaded for index $combinedIndex');
            },
            onAdFailedToLoad: (err) {
              debugPrint('AdMob interstitial failed to load: $err');
            },
          ),
        );
      }
    } else if (item.provider == 'facebook') {
      // For FAN we rely on the widget to load itself; mark as false initially
      _facebookNativeLoaded[combinedIndex] = false;
      // The actual Facebook widget will set loaded callback when mounted.
      if (item.isVideoAd) {
        // nothing extra to preload here with the package; platform will fetch when widget is built
      }
    } else if (item.provider == 'unity') {
      // Preload Unity interstitial for that placement (optional)
      if (_unityPreloadedSet.contains(combinedIndex)) return;
      try {
        UnityAds.load(placementId: item.adUnitId ?? unityInFeedPlacement, onComplete: (placementId) {
          debugPrint('Unity ad preloaded for placement $placementId at combined index $combinedIndex');
          _unityPreloadedSet.add(combinedIndex);
        }, onFailed: (placementId, error, msg) {
          debugPrint('Unity failed to preload $placementId: $error / $msg');
        });
      } catch (e) {
        debugPrint('unity preload error: $e');
      }
    }
  }

void _showUnityAdIfReady(int combinedIndex, FeedItem item) {
  if (!_adsInitialized) return;

  final placementId = item.adUnitId ?? unityInFeedPlacement;

  if (!_unityPreloadedSet.contains(combinedIndex)) {
    // Attempt to show anyway; Unity will handle fallback.
    try {
      UnityAds.showVideoAd(
        placementId: placementId,
        onComplete: (placementId) {
          debugPrint('Unity Ad completed: $placementId');
        },
        onFailed: (placementId, error, message) {
          debugPrint('Unity Ad failed: $placementId - $error $message');
        },
        onStart: (placementId) {
          debugPrint('Unity Ad started: $placementId');
        },
        onClick: (placementId) {
          debugPrint('Unity Ad clicked: $placementId');
        },
      );
    } catch (e) {
      debugPrint('unity show error (not preloaded): $e');
    }
    return;
  }

  try {
    UnityAds.showVideoAd(
      placementId: placementId,
      onComplete: (placementId) {
        debugPrint('Unity Ad completed: $placementId');
      },
      onFailed: (placementId, error, message) {
        debugPrint('Unity Ad failed: $placementId - $error $message');
      },
      onStart: (placementId) {
        debugPrint('Unity Ad started: $placementId');
      },
      onClick: (placementId) {
        debugPrint('Unity Ad clicked: $placementId');
      },
    );
  } catch (e) {
    debugPrint('unity show error: $e');
  }
}


  // Build Ad Widget based on provider
  Widget _buildAdWidget(int combinedIndex, FeedItem item) {
    // Fallback placeholder if ad not ready
    Widget placeholder = Container(
      color: Colors.black87,
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(height: 180, color: Colors.grey[900], child: Center(child: Text('Sponsored', style: TextStyle(color: Colors.white70)))),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: Text('Sponsored content — buy now', style: TextStyle(color: Colors.white70))),
              TextButton(onPressed: () {}, child: Text('Learn', style: TextStyle(color: Colors.white))),
            ],
          ),
        ],
      ),
    );

    if (!_adsInitialized) {
      return placeholder;
    }

    if (item.provider == 'admob') {
      if (item.isVideoAd) {
        // Try AdMob native first
        final native = _admobNativeByIndex[combinedIndex];
        if (native != null) {
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            color: Colors.black,
            child: SizedBox(
              height: 250,
              child: AdWidget(ad: native),
            ),
          );
        } else {
          // fallback to banner if native not available
          final banner = _admobBannerByIndex[combinedIndex];
          if (banner != null) {
            return Container(
              color: Colors.black,
              height: banner.size.height.toDouble(),
              child: AdWidget(ad: banner),
            );
          }
        }
      } else {
        final banner = _admobBannerByIndex[combinedIndex];
        if (banner != null) {
          return Container(
            color: Colors.black,
            height: banner.size.height.toDouble(),
            child: AdWidget(ad: banner),
          );
        }
      }
      return placeholder;
    } else if (item.provider == 'facebook') {
      // Facebook Audience Network native widget
      return Container(
        color: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: FacebookNativeAd(
          placementId: item.adUnitId ?? fanPlacementTestId,
          adType: NativeAdType.NATIVE_AD,
          width: MediaQuery.of(context).size.width,
          height: 250,
          backgroundColor: Colors.transparent,
          titleColor: Colors.white,
          descriptionColor: Colors.white70,
          buttonColor: Colors.blue,
          buttonTitleColor: Colors.white,
          keepExpandedWhileLoading: false,
          listener: (result, value) {
            // value returns a map for events like loaded, clicked etc.
            debugPrint("FB Ad listener $result -> $value");
            if (result == NativeAdResult.LOADED) {
              _facebookNativeLoaded[combinedIndex] = true;
            } else if (result == NativeAdResult.ERROR) {
              _facebookNativeLoaded[combinedIndex] = false;
            }
            // update UI
            if (mounted) setState(() {});
          },
        ),
      );
    } else if (item.provider == 'unity') {
      // Unity ad we show as a placeholder (Unity doesn't embed into widget tree usually).
      // Show a sponsored card prompting the app to show an interstitial when tapped or auto-showed via _onPageChanged.
      return GestureDetector(
        onTap: () => _showUnityAdIfReady(combinedIndex, item),
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: Colors.black,
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(height: 220, color: Colors.grey[900], child: Center(child: Text('Sponsored video (Unity Ad)', style: TextStyle(color: Colors.white70)))),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Text('Sponsored content', style: TextStyle(color: Colors.white70))),
                  TextButton(onPressed: () => _showUnityAdIfReady(combinedIndex, item), child: Text('Watch', style: TextStyle(color: Colors.white))),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return placeholder;
  }

  // share reel
  Future<void> _shareReelCombinedIndex(int combinedIndex) async {
    if (combinedIndex < 0 || combinedIndex >= _combinedItems.length) return;
    final item = _combinedItems[combinedIndex];
    if (item.type != FeedItemType.reel) return;
    final reel = item.reel!;
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

  @override
  void dispose() {
    _pageController.dispose();
    for (var c in _controllers.values) {
      try {
        c.dispose();
      } catch (_) {}
    }
    _controllers.clear();

    for (var ad in _admobNativeByIndex.values) {
      try {
        ad.dispose();
      } catch (_) {}
    }
    _admobNativeByIndex.clear();

    for (var ad in _admobBannerByIndex.values) {
      try {
        ad.dispose();
      } catch (_) {}
    }
    _admobBannerByIndex.clear();

    for (var ad in _admobInterstitialByIndex.values) {
      try {
        ad.dispose();
      } catch (_) {}
    }
    _admobInterstitialByIndex.clear();

    for (var s in _metaSubs.values) {
      try {
        s.cancel();
      } catch (_) {}
    }
    _metaSubs.clear();
    _liveMetaById.clear();

    super.dispose();
  }

  // Right-side action column adapted for combined feed index
  Widget _buildRightActionColumnForCombinedIndex(int combinedIndex) {
    final item = _combinedItems[combinedIndex];
    if (item.type != FeedItemType.reel) {
      // show small sponsored badge when ad: e.g., "Sponsored"
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
            child: const Text('Sponsored', style: TextStyle(color: Colors.white70, fontSize: 12)),
          )
        ],
      );
    }

    final reel = item.reel!;
    final id = _getReelId(reel);
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
          onTap: () {},
          child: CircleAvatar(radius: 22, backgroundColor: Colors.white12, child: Icon(Icons.person, color: Colors.white70)),
        ),
        const SizedBox(height: 20),
        _ActionIconWithCount(
          icon: isLiked ? Icons.favorite : Icons.favorite_border,
          color: isLiked ? Colors.redAccent : Colors.white,
          count: likesCount,
          onTap: () => _toggleLikeForCombinedIndex(combinedIndex),
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
          onTap: () => _openCommentsSheetForCombinedIndex(combinedIndex),
          label: 'Comments',
        ),
        const SizedBox(height: 16),
        _ActionIconWithCount(
          icon: Icons.share,
          color: Colors.white,
          count: 0,
          onTap: () => _shareReelCombinedIndex(combinedIndex),
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

  Widget _buildFeedModeSelector() {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.filter_list, color: Colors.white),
      onSelected: (s) {
        setState(() {
          _feedMode = s;
          _applyRankingAndShuffle();
          _combinedItems = _buildCombinedListWithAds(_orderedReels, seed: _seed);
          // dispose and reinit controllers/ads
          for (var c in _controllers.values) {
            try {
              c.dispose();
            } catch (_) {}
          }
          _controllers.clear();
          _prepareAdsForAllIndices();
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

  void _prepareAdsForAllIndices() {
    for (int i = 0; i < _combinedItems.length; i++) {
      final item = _combinedItems[i];
      if (item.type == FeedItemType.ad) {
        _prepareAdForCombinedIndex(i, item);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_combinedItems.isEmpty) {
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
            itemCount: _combinedItems.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, index) {
              final item = _combinedItems[index];
              if (item.type == FeedItemType.ad) {
                // ad UI
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    // Tapping may open ad or show interstitial for Unity
                    if (item.provider == 'admob' && _admobInterstitialByIndex.containsKey(index)) {
                      final inter = _admobInterstitialByIndex[index]!;
                      inter.fullScreenContentCallback = FullScreenContentCallback(onAdDismissedFullScreenContent: (ad) {
                        ad.dispose();
                      });
                      inter.show();
                      _admobInterstitialByIndex.remove(index);
                    } else if (item.provider == 'unity') {
                      _showUnityAdIfReady(index, item);
                    } else {
                      // nothing
                    }
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // background
                      Container(color: Colors.black),
                      Align(alignment: Alignment.center, child: _buildAdWidget(index, item)),
                      Positioned(
                        right: 12,
                        top: MediaQuery.of(context).size.height * 0.2,
                        child: _buildRightActionColumnForCombinedIndex(index),
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
              } else {
                // reel UI
                final controller = _controllers[index];
                final reel = item.reel!;
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
                    _toggleLikeForCombinedIndex(index);
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
                                    onPressed: () => _shareReelCombinedIndex(index),
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
                        child: _buildRightActionColumnForCombinedIndex(index),
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
              }
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
