// feed_reel_player_screen_with_ads.dart
// Updated: Full Reel player with social features (owner metadata, comments, likes, views),
// double-tap big heart, floating hearts, Twitch-style chat overlay, mirrored writes to user posts,
// and in-feed ads (AdMob native/banner, Unity interstitial).
//
// NOTE: Replace placeholder ad unit ids and game ids with your real ids. See comments for pubspec + native setup.

import 'dart:async';
import 'dart:math' show Random, max, min, log;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';

// Ad packages
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:unity_ads_plugin/unity_ads_plugin.dart';

import '../../models/reel.dart';

enum FeedItemType { reel, ad }

class FeedItem {
  final FeedItemType type;
  final Reel? reel;
  final String? provider; // 'admob', 'unity'
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

class _FloatingHeart {
  final String id;
  final double leftFraction;
  final Color color;
  final String? label;
  final double size;
  _FloatingHeart({required this.id, required this.leftFraction, required this.color, this.label, this.size = 28});
}

class _FeedReelPlayerScreenState extends State<FeedReelPlayerScreen> {
  late PageController _pageController;
  int _currentIndex = 0;

  /// Video controllers keyed by combined feed index (items may be ad or reel)
  final Map<int, VideoPlayerController> _controllers = {};

  /// Ad objects keyed by combined feed index
  final Map<int, NativeAd> _admobNativeByIndex = {};
  final Map<int, BannerAd> _admobBannerByIndex = {};
  final Map<int, InterstitialAd> _admobInterstitialByIndex = {};

  final Set<int> _unityPreloadedSet = {};

  /// Firestore realtime metadata & subscriptions
  final Map<String, Map<String, dynamic>> _liveMetaById = {};
  final Map<String, StreamSubscription<DocumentSnapshot>> _metaSubs = {};
  final Set<String> _viewedThisSession = {};

  /// user cache & mapping for mirroring writes
  final Map<String, Map<String, dynamic>> _userById = {};
  final Map<String, Map<String, String>> _feedToOwnerAndPost = {};

  late List<Reel> _orderedReels;
  late List<FeedItem> _combinedItems;

  String _feedMode = 'for_everyone';
  int _seed = DateTime.now().millisecondsSinceEpoch % 100000;
  final FirebaseFirestore _fire = FirebaseFirestore.instance;
  final User? _authUser = FirebaseAuth.instance.currentUser;
  final Random _rng = Random();

  // Floating hearts / chat overlays state
  final Map<int, List<_FloatingHeart>> _floatingHeartsByIndex = {};
  final Map<int, bool> _chatVisibleByIndex = {};
  int? _bigHeartIndex; // index currently showing the large center heart
  Timer? _bigHeartTimer;

  // AD UNIT IDS (replace with real IDs)
  static const String admobNativeTestId = 'ca-app-pub-3940256099942544/2247696110';
  static const String admobBannerTestId = 'ca-app-pub-3940256099942544/6300978111';
  static const String admobInterstitialTestId = 'ca-app-pub-3940256099942544/1033173712';

  static const String unityGameIdAndroid = '1234567';
  static const String unityGameIdIos = '7654321';
  static const String unityInFeedPlacement = 'video';

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
    _combinedItems = _buildCombinedListWithAds(_orderedReels, seed: _seed);

    _pageController = PageController(initialPage: _currentIndex);

    _initializeControllersAroundIndex(_currentIndex);
    _subscribeMetaForCombinedIndices(_currentIndex - 6, _currentIndex + 6);

    // initialize ad SDKs (non-blocking)
    _initializeAdSdks();
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

    _bigHeartTimer?.cancel();

    super.dispose();
  }

  // ----------------- Ranking & list building -----------------
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
        final choice = rng.nextDouble();
        if (choice < 0.7) {
          out.add(FeedItem.ad(provider: 'admob', adUnitId: admobNativeTestId, isVideoAd: true));
        } else {
          out.add(FeedItem.ad(provider: 'unity', adUnitId: unityInFeedPlacement, isVideoAd: true));
        }
        reelsSinceLastAd = 0;
        nextAdDistance = adSpacingMin + rng.nextInt(max(1, adSpacingMax - adSpacingMin + 1));
      }
    }

    if (rng.nextDouble() < 0.25) {
      out.add(FeedItem.ad(provider: 'admob', adUnitId: admobBannerTestId, isVideoAd: false));
    }

    return out;
  }

  // ----------------- Ad SDK init -----------------
  void _initializeAdSdks() async {
    try {
      await MobileAds.instance.initialize();
      await UnityAds.init(
        gameId: Theme.of(context).platform == TargetPlatform.iOS ? unityGameIdIos : unityGameIdAndroid,
        testMode: true,
      );
      setState(() {
        _adsInitialized = true;
      });
    } catch (e) {
      debugPrint('Ad SDK init error: $e');
    }
  }

  // ----------------- Controllers & preloads -----------------
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

  // ----------------- Firestore meta subscriptions (and owner mapping) -----------------
  void _subscribeMetaForCombinedIndices(int start, int end) {
    for (int i = start; i <= end; i++) {
      if (i >= 0 && i < _combinedItems.length) {
        final item = _combinedItems[i];
        if (item.type == FeedItemType.reel) {
          final id = _getReelId(item.reel!);
          if (id == null || id.isEmpty) continue;
          if (_metaSubs.containsKey(id)) continue;

          final sub = _fire.collection('feeds').doc(id).snapshots().listen((snap) async {
            if (snap.exists) {
              final data = snap.data() ?? {};
              final normalized = Map<String, dynamic>.from(data);
              if (normalized['likedBy'] is! List) normalized['likedBy'] = (normalized['likedBy'] ?? []) as List;

              // --- store feed -> owner/post mapping if available
              try {
                final ownerId = (normalized['userId'] ?? normalized['ownerId'])?.toString();
                final postId = (normalized['postId'] ?? normalized['originalPostId'])?.toString();
                if (ownerId != null && ownerId.isNotEmpty) {
                  _feedToOwnerAndPost[id] = {
                    'ownerId': ownerId,
                    if (postId != null && postId.isNotEmpty) 'postId': postId
                  };

                  // fetch owner doc if not cached
                  if (!_userById.containsKey(ownerId)) {
                    try {
                      final userSnap = await _fire.collection('users').doc(ownerId).get();
                      if (userSnap.exists) {
                        final udata = Map<String, dynamic>.from(userSnap.data() ?? {});
                        _userById[ownerId] = {
                          'username': udata['username']?.toString() ?? (udata['displayName']?.toString() ?? 'User'),
                          'avatar': udata['avatar']?.toString() ?? (udata['photoUrl']?.toString() ?? ''),
                          'email': udata['email']?.toString() ?? '',
                        };
                        if (mounted) setState(() {});
                      }
                    } catch (e) {
                      debugPrint('failed to load owner $ownerId: $e');
                    }
                  }
                }
              } catch (e) {
                debugPrint('owner extraction error: $e');
              }

              // Detect like increases to spawn floating hearts
              final old = _liveMetaById[id];
              final oldLiked = (old != null && old['likedBy'] is List) ? List<String>.from(old['likedBy']) : <String>[];
              final newLiked = (normalized['likedBy'] is List) ? List<String>.from(normalized['likedBy']) : <String>[];

              try {
                final added = newLiked.where((x) => !oldLiked.contains(x)).toList();
                if (added.isNotEmpty) {
                  // find combined indices with this reel id and spawn hearts there
                  final combinedIndices = <int>[];
                  for (int j = 0; j < _combinedItems.length; j++) {
                    final it = _combinedItems[j];
                    if (it.type == FeedItemType.reel) {
                      final rid = _getReelId(it.reel!);
                      if (rid == id) combinedIndices.add(j);
                    }
                  }
                  // spawn up to 4 hearts per new like event (cap)
                  final spawnCount = min(4, added.length);
                  for (var ci in combinedIndices) {
                    for (int k = 0; k < spawnCount; k++) {
                      _spawnFloatingHeart(ci, label: (added.length == 1 ? (added.first == _authUser?.uid ? 'You' : null) : null));
                    }
                  }
                }
              } catch (e) {
                debugPrint('like-detection error: $e');
              }

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
    _feedToOwnerAndPost.remove(id);
  }

  // ----------------- Views / Likes / Comments (mirrored writes) -----------------

  Future<void> _maybeIncrementViewForCombinedIndex(int combinedIndex) async {
    if (combinedIndex < 0 || combinedIndex >= _combinedItems.length) return;
    final item = _combinedItems[combinedIndex];
    if (item.type != FeedItemType.reel) return;
    final reel = item.reel!;
    final String? feedId = _getReelId(reel);
    if (feedId == null || feedId.isEmpty) return;
    if (_authUser == null) return;
    final key = '${_authUser!.uid}::$feedId';
    if (_viewedThisSession.contains(key)) return;
    _viewedThisSession.add(key);
    try {
      await _fire.collection('feeds').doc(feedId).update({'views': FieldValue.increment(1)});
    } catch (e) {
      debugPrint('failed to increment view on feed $feedId: $e');
    }

    // mirror to user's post doc if mapping exists
    final mapping = _feedToOwnerAndPost[feedId];
    if (mapping != null && mapping.containsKey('ownerId') && mapping.containsKey('postId')) {
      final ownerId = mapping['ownerId']!;
      final postId = mapping['postId']!;
      try {
        await _fire.collection('users').doc(ownerId).collection('posts').doc(postId).update({'views': FieldValue.increment(1)});
      } catch (e) {
        debugPrint('failed to increment view on user post $ownerId/$postId: $e');
      }
    }
  }

  Future<void> _toggleLikeForCombinedIndex(int combinedIndex) async {
    if (combinedIndex < 0 || combinedIndex >= _combinedItems.length) return;
    final item = _combinedItems[combinedIndex];
    if (item.type != FeedItemType.reel) return;
    final reel = item.reel!;
    final String? feedId = _getReelId(reel);
    if (feedId == null || feedId.isEmpty) return;
    final uid = _authUser?.uid;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please log in to like')));
      return;
    }

    final meta = _liveMetaById[feedId];
    final likedBy = (meta != null && meta['likedBy'] is List) ? List<String>.from(meta['likedBy']) : <String>[];

    // immediate UX: spawn heart + big center heart
    _spawnFloatingHeart(combinedIndex, label: 'You');
    _triggerBigCenterHeart(combinedIndex);

    try {
      final docRef = _fire.collection('feeds').doc(feedId);
      if (likedBy.contains(uid)) {
        await docRef.update({'likedBy': FieldValue.arrayRemove([uid])});
      } else {
        await docRef.update({'likedBy': FieldValue.arrayUnion([uid])});
      }

      // Mirror to user post doc if mapping exists
      final mapping = _feedToOwnerAndPost[feedId];
      if (mapping != null && mapping.containsKey('ownerId') && mapping.containsKey('postId')) {
        final ownerId = mapping['ownerId']!;
        final postId = mapping['postId']!;
        final userPostRef = _fire.collection('users').doc(ownerId).collection('posts').doc(postId);
        try {
          if (likedBy.contains(uid)) {
            await userPostRef.update({'likedBy': FieldValue.arrayRemove([uid])});
          } else {
            await userPostRef.update({'likedBy': FieldValue.arrayUnion([uid])});
          }
        } catch (e) {
          debugPrint('failed to mirror like to user post: $e');
        }
      }
    } catch (e) {
      debugPrint('like toggle failed for $feedId: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to like: $e')));
    }
  }

  Future<void> _postCommentToFeedAndUser({required String feedId, required String text}) async {
    if (text.trim().isEmpty) return;
    final uid = _authUser?.uid ?? 'anonymous';
    final username = _authUser?.displayName ?? (_authUser?.email ?? 'User');
    final avatar = _authUser?.photoURL ?? '';

    final commentDoc = {
      'text': text,
      'userId': uid,
      'username': username,
      'userAvatar': avatar,
      'timestamp': DateTime.now().toIso8601String(),
    };

    try {
      // write to feeds/<feedId>/comments
      await _fire.collection('feeds').doc(feedId).collection('comments').add(commentDoc);

      // increment commentsCount on feeds doc
      await _fire.collection('feeds').doc(feedId).update({'commentsCount': FieldValue.increment(1)});

      // if mapping exists, write to user's post comments too
      final mapping = _feedToOwnerAndPost[feedId];
      if (mapping != null && mapping.containsKey('ownerId') && mapping.containsKey('postId')) {
        final ownerId = mapping['ownerId']!;
        final postId = mapping['postId']!;
        try {
          await _fire.collection('users').doc(ownerId).collection('posts').doc(postId).collection('comments').add(commentDoc);
          await _fire.collection('users').doc(ownerId).collection('posts').doc(postId).update({'commentsCount': FieldValue.increment(1)});
        } catch (e) {
          debugPrint('failed to write comment to owner post path: $e');
        }
      }
    } catch (e) {
      debugPrint('failed to post comment: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to post comment: $e')));
    }
  }

  // ----------------- Ad preparation -----------------
  void _prepareAdForCombinedIndex(int combinedIndex, FeedItem item) {
    if (!_adsInitialized) return;
    if (item.provider == 'admob') {
      // For AdMob: choose native if isVideoAd else banner
      if (item.isVideoAd) {
        if (_admobNativeByIndex.containsKey(combinedIndex)) return;
        try {
          final native = NativeAd(
            adUnitId: item.adUnitId ?? admobNativeTestId,
            factoryId: 'listTile', // register factory on native side
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
    } else if (item.provider == 'unity') {
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

  // ----------------- Floating hearts & big heart UI -----------------
  void _spawnFloatingHeart(int combinedIndex, {String? label}) {
    final id = DateTime.now().millisecondsSinceEpoch.toString() + '-' + (_rng.nextInt(10000)).toString();
    final left = 0.12 + _rng.nextDouble() * 0.76;
    final colorOptions = [Colors.pinkAccent, Colors.redAccent, Colors.amberAccent, Colors.white];
    final color = colorOptions[_rng.nextInt(colorOptions.length)];
    final size = 20.0 + _rng.nextDouble() * 22.0;
    final heart = _FloatingHeart(id: id, leftFraction: left, color: color, label: label, size: size);
    _floatingHeartsByIndex.putIfAbsent(combinedIndex, () => []);
    _floatingHeartsByIndex[combinedIndex]!.add(heart);
    setState(() {});

    Future.delayed(const Duration(milliseconds: 1200), () {
      final list = _floatingHeartsByIndex[combinedIndex];
      if (list == null) return;
      list.removeWhere((h) => h.id == id);
      if (mounted) setState(() {});
    });
  }

  void _triggerBigCenterHeart(int combinedIndex) {
    _bigHeartTimer?.cancel();
    setState(() {
      _bigHeartIndex = combinedIndex;
    });
    _bigHeartTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() {
        _bigHeartIndex = null;
      });
    });
  }

  // ----------------- Helpers -----------------
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

  // ----------------- Share -----------------
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

  // ----------------- Widgets building -----------------

  Widget _buildAdWidget(int combinedIndex, FeedItem item) {
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
    } else if (item.provider == 'unity') {
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

  // Build chat overlay: Twitch-like show comments
  Widget _buildChatOverlayForIndex(int combinedIndex, Reel reel) {
    final id = _getReelId(reel);
    if (id == null || id.isEmpty) return const SizedBox.shrink();

    final width = MediaQuery.of(context).size.width * 0.46;
    final height = MediaQuery.of(context).size.height * 0.55;

    final TextEditingController _chatController = TextEditingController();

    return Positioned(
      left: 12,
      bottom: 80,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.46),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          children: [
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Text('Live chat', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Expanded(child: Container()),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                    onPressed: () => setState(() => _chatVisibleByIndex[combinedIndex] = false),
                  )
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: _fire.collection('feeds').doc(id).collection('comments').orderBy('timestamp', descending: false).snapshots(),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Center(child: Text('Chat error', style: TextStyle(color: Colors.white70)));
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snap.data!.docs;
                  if (docs.isEmpty) {
                    return Center(child: Text('Be the first to comment', style: TextStyle(color: Colors.white54)));
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final d = docs[i].data() as Map<String, dynamic>;
                      final username = (d['username'] ?? 'User').toString();
                      final text = (d['text'] ?? '').toString();
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CircleAvatar(radius: 12, backgroundColor: Colors.white12, child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white, fontSize: 12))),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(username, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, fontSize: 12)),
                                  const SizedBox(height: 4),
                                  Text(text, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              color: Colors.black.withOpacity(0.28),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _chatController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Write a message...',
                        hintStyle: const TextStyle(color: Colors.white54, fontSize: 13),
                        filled: true,
                        fillColor: Colors.white12,
                        border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.circular(26)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onSubmitted: (_) async {
                        final text = _chatController.text.trim();
                        if (text.isEmpty) return;
                        _chatController.clear();
                        await _postCommentToFeedAndUser(feedId: id, text: text);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.transparent, elevation: 0, side: BorderSide(color: Colors.white12)),
                    onPressed: () async {
                      final text = _chatController.text.trim();
                      if (text.isEmpty) return;
                      _chatController.clear();
                      await _postCommentToFeedAndUser(feedId: id, text: text);
                    },
                    child: const Icon(Icons.send, color: Colors.white70),
                  )
                ],
              ),
            )
          ],
        ),
      ),
    );
  }

  // Build floating hearts widgets for index
  List<Widget> _buildFloatingHeartsWidgets(int combinedIndex) {
    final hearts = _floatingHeartsByIndex[combinedIndex] ?? [];
    final widgets = <Widget>[];
    final screenW = MediaQuery.of(context).size.width;
    for (var h in hearts) {
      final left = h.leftFraction * screenW;
      widgets.add(
        Positioned(
          left: left,
          bottom: 140 + (_rng.nextDouble() * 40),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: -90.0),
            duration: const Duration(milliseconds: 1100),
            curve: Curves.easeOutCubic,
            builder: (context, val, child) {
              return Opacity(
                opacity: (1.0 - (val.abs() / 120.0)).clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(0, val),
                  child: child,
                ),
              );
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.45),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [BoxShadow(color: h.color.withOpacity(0.16), blurRadius: 6)],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.favorite, color: h.color, size: h.size * 0.8),
                      if (h.label != null) ...[
                        const SizedBox(width: 6),
                        Text(h.label!, style: TextStyle(color: Colors.white70, fontSize: 12)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _buildRightActionColumnForCombinedIndex(int combinedIndex) {
    final item = _combinedItems[combinedIndex];
    if (item.type != FeedItemType.reel) {
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

    // owner display attempts
    final reelOwnerId = (() {
      if (id != null && _liveMetaById.containsKey(id)) {
        return (_liveMetaById[id]?['userId'] ?? _feedToOwnerAndPost[id]?['ownerId'])?.toString();
      }
      try {
        final dyn = reel as dynamic;
        final owner = dyn.userId ?? dyn.ownerId;
        return owner?.toString();
      } catch (_) {
        return null;
      }
    })();

    final ownerMeta = (reelOwnerId != null && _userById.containsKey(reelOwnerId)) ? _userById[reelOwnerId] : null;
    final ownerAvatar = ownerMeta != null ? ownerMeta['avatar']?.toString() ?? '' : '';
    final ownerName = ownerMeta != null ? ownerMeta['username']?.toString() ?? 'User' : 'User';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () {
            // navigate to profile if present - keep placeholder
            if (reelOwnerId != null) {
              // implement navigation to user profile screen if available
            }
          },
          child: CircleAvatar(
            radius: 22,
            backgroundColor: Colors.white12,
            backgroundImage: ownerAvatar.isNotEmpty && ownerAvatar.startsWith('http') ? NetworkImage(ownerAvatar) : null,
            child: ownerAvatar.isEmpty ? Text(ownerName.isNotEmpty ? ownerName[0].toUpperCase() : 'U', style: const TextStyle(color: Colors.white70)) : null,
          ),
        ),
        const SizedBox(height: 20),
        _ActionIconWithCount(
          icon: isLiked ? Icons.favorite : Icons.favorite_border,
          color: isLiked ? Colors.redAccent : Colors.white,
          count: likesCount,
          onTap: () => _toggleLikeForCombinedIndex(combinedIndex),
          label: 'Like',
        ),
        const SizedBox(height: 12),
        _ActionIconWithCount(
          icon: Icons.thumb_down_outlined,
          color: Colors.white,
          count: 0,
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not implemented')));
          },
          label: 'Down',
        ),
        const SizedBox(height: 12),
        _ActionIconWithCount(
          icon: Icons.comment,
          color: Colors.white,
          count: commentsCount,
          onTap: () => setState(() => _chatVisibleByIndex[combinedIndex] = !(_chatVisibleByIndex[combinedIndex] ?? false)),
          label: 'Comments',
        ),
        const SizedBox(height: 12),
        _ActionIconWithCount(
          icon: Icons.share,
          color: Colors.white,
          count: 0,
          onTap: () => _shareReelCombinedIndex(combinedIndex),
          label: 'Share',
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: () {
            _spawnFloatingHeart(combinedIndex, label: 'You');
          },
          child: Column(
            children: [
              const Icon(Icons.favorite_border, color: Colors.white70, size: 26),
              const SizedBox(height: 6),
              const Text('React', style: TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
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

  // ----------------- Main build -----------------
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
            onPageChanged: (idx) {
              if (!mounted) return;
              _controllers[_currentIndex]?.pause();
              setState(() {
                _currentIndex = idx;
                // hide chat overlays on nav
                _chatVisibleByIndex.removeWhere((k, v) => k != idx);
              });
              _initializeControllersAroundIndex(idx);
              _subscribeMetaForCombinedIndices(idx - 6, idx + 6);
              final newController = _controllers[idx];
              if (newController != null && newController.value.isInitialized) {
                newController.play();
                _maybeIncrementViewForCombinedIndex(idx);
              }

              final item = _combinedItems[idx];
              if (item.type == FeedItemType.ad && item.provider == 'unity') {
                _showUnityAdIfReady(idx, item);
              }
            },
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

                // owner metadata attempt
                final reelOwnerId = (() {
                  final id = _getReelId(reel);
                  if (id != null && _liveMetaById.containsKey(id)) {
                    return (_liveMetaById[id]?['userId'] ?? _feedToOwnerAndPost[id]?['ownerId'])?.toString();
                  }
                  try {
                    final dyn = reel as dynamic;
                    final owner = dyn.userId ?? dyn.ownerId;
                    return owner?.toString();
                  } catch (_) {
                    return null;
                  }
                })();

                final ownerMeta = (reelOwnerId != null && _userById.containsKey(reelOwnerId)) ? _userById[reelOwnerId] : null;
                final ownerAvatar = ownerMeta != null ? ownerMeta['avatar']?.toString() ?? '' : '';
                final ownerName = ownerMeta != null ? ownerMeta['username']?.toString() ?? 'User' : 'User';

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

                      // bottom-left info
                      Align(
                        alignment: Alignment.bottomLeft,
                        child: Container(
                          width: MediaQuery.of(context).size.width * 0.62,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(colors: [Colors.transparent, Colors.black54], begin: Alignment.topCenter, end: Alignment.bottomCenter),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // owner row
                              Row(
                                children: [
                                  GestureDetector(
                                    onTap: () {
                                      if (reelOwnerId != null) {
                                        // navigate to profile if you have screen
                                      }
                                    },
                                    child: CircleAvatar(
                                      radius: 16,
                                      backgroundColor: Colors.white12,
                                      backgroundImage: ownerAvatar.isNotEmpty && ownerAvatar.startsWith('http') ? NetworkImage(ownerAvatar) : null,
                                      child: ownerAvatar.isEmpty ? Text(ownerName.isNotEmpty ? ownerName[0].toUpperCase() : 'U', style: const TextStyle(color: Colors.white70)) : null,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(ownerName, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600))),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                reel.movieTitle ?? '',
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 6),
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

                      // right action column (like/comment/etc)
                      Positioned(
                        right: 12,
                        top: MediaQuery.of(context).size.height * 0.18,
                        child: _buildRightActionColumnForCombinedIndex(index),
                      ),

                      // top-left back
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

                      // top-right feed mode
                      Positioned(
                        top: 36,
                        right: 12,
                        child: SafeArea(child: _buildFeedModeSelector()),
                      ),

                      // floating hearts (small) overlay
                      ..._buildFloatingHeartsWidgets(index),

                      // big center heart on double tap
                      if (_bigHeartIndex == index)
                        Center(
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0.0, end: 1.0),
                            duration: const Duration(milliseconds: 700),
                            builder: (context, v, child) {
                              final scale = 0.8 + (v * 1.6);
                              final opacity = (1.0 - v).clamp(0.0, 1.0);
                              return Opacity(
                                opacity: opacity,
                                child: Transform.scale(scale: scale, child: child),
                              );
                            },
                            child: Container(
                              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withOpacity(0.28)),
                              padding: const EdgeInsets.all(18),
                              child: Icon(Icons.favorite, color: Colors.redAccent.withOpacity(0.95), size: 110),
                            ),
                          ),
                        ),

                      // chat overlay (Twitch-like) when toggled
                      if ((_chatVisibleByIndex[index] ?? false)) _buildChatOverlayForIndex(index, reel),
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
