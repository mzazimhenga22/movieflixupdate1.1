// social_reactions_controller.dart
// Controller: holds helpers, stateful data and logic used by the UI screen.
// Also contains FeedProvider and SimpleVideoPlayer (previously in controller file).

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart' as vp;
import 'package:visibility_detector/visibility_detector.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:universal_html/html.dart' as html;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:movie_app/helpers/movie_account_helper.dart';
import 'algo.dart';

/// ----------------- Utility / Constants -----------------
const _kPostsPerPage = 10;
const _kPrefMutedUsers = 'muted_users';
const _kPrefSavedPosts = 'saved_posts';

/// ----------------- Helper: frosted panel (polished) -----------------
BoxDecoration frostedPanelDecoration(Color accentColor, {double radius = 18}) {
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withOpacity(0.015),
        Colors.white.withOpacity(0.01),
      ],
    ),
    borderRadius: BorderRadius.all(Radius.circular(radius)),
    border: Border.all(color: accentColor.withOpacity(0.07)),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.42),
        blurRadius: 18,
        spreadRadius: 0,
        offset: const Offset(0, 10),
      ),
      BoxShadow(
        color: accentColor.withOpacity(0.03),
        blurRadius: 28,
        spreadRadius: 1,
        offset: const Offset(0, 6),
      ),
    ],
  );
}

/// ----------------- Friendly time helper -----------------
String friendlyTimeFromDateTime(DateTime dt) {
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return '${dt.day}/${dt.month}/${dt.year}';
}

String friendlyTimeFromIso(String iso) {
  try {
    final dt = DateTime.parse(iso).toLocal();
    return friendlyTimeFromDateTime(dt);
  } catch (_) {
    return '';
  }
}

/// ----------------- SimpleVideoPlayer -----------------
/// (unchanged, lightweight Instagram-like autoplay behaviour)
class SimpleVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final bool autoPlay;
  final VoidCallback? onTap;
  final double? height;
  final String? thumbnailUrl;

  const SimpleVideoPlayer({
    super.key,
    required this.videoUrl,
    this.autoPlay = false,
    this.onTap,
    this.height,
    this.thumbnailUrl,
  });

  @override
  State<SimpleVideoPlayer> createState() => _SimpleVideoPlayerState();
}

class _SimpleVideoPlayerState extends State<SimpleVideoPlayer> {
  static int _activeControllers = 0;
  static const int _maxActiveControllers = 2;
  static String? _currentlyPlayingUrl;

  vp.VideoPlayerController? _controller;
  bool _isPlaying = false;
  bool _initialized = false;
  bool _initRequested = false;
  bool _isMuted = true;

  static const double _kAutoPlayThreshold = 0.55;
  static const double _kDisposeThreshold = 0.15;

  double _lastVisibility = 0.0;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _initController({bool autoplay = false}) async {
    if (_initRequested) return;
    _initRequested = true;

    var attempts = 0;
    while (_activeControllers >= _maxActiveControllers && attempts < 6) {
      await Future.delayed(const Duration(milliseconds: 200));
      attempts++;
    }

    if (_activeControllers >= _maxActiveControllers) {
      debugPrint('Skipping init - active controllers limit reached for ${widget.videoUrl}');
      _initRequested = false;
      return;
    }

    try {
      _activeControllers++;
      _controller = vp.VideoPlayerController.network(widget.videoUrl);
      _controller!
        ..setLooping(true)
        ..setVolume(_isMuted ? 0.0 : 1.0);

      await _controller!.initialize().timeout(const Duration(seconds: 12));

      if (!mounted) return;
      setState(() {
        _initialized = true;
        if (autoplay) {
          _pauseOtherPlayers();
          _controller!.play();
          _isPlaying = true;
          _currentlyPlayingUrl = widget.videoUrl;
        }
      });
    } catch (e, st) {
      debugPrint('Video init error for ${widget.videoUrl}: $e\n$st');
      if (mounted) setState(() {});
    } finally {
      _initRequested = false;
      if (!_initialized) {
        if (_activeControllers > 0) _activeControllers--;
      }
    }
  }

  Future<void> _disposeController() async {
    try {
      await _controller?.pause();
      _controller?.dispose();
    } catch (_) {}
    _controller = null;
    _initialized = false;
    _isPlaying = false;
    _initRequested = false;
    if (_activeControllers > 0) _activeControllers--;
    if (_currentlyPlayingUrl == widget.videoUrl) _currentlyPlayingUrl = null;
  }

  void _pauseOtherPlayers() {
    _currentlyPlayingUrl = widget.videoUrl;
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  void _togglePlayOrInit() async {
    try {
      if (!_initialized && !_initRequested) {
        await _initController(autoplay: true);
        if (!mounted || _controller == null) return;
      }
      if (!_initialized || _controller == null) return;
      setState(() {
        if (_isPlaying) {
          _controller!.pause();
          _isPlaying = false;
          if (_currentlyPlayingUrl == widget.videoUrl) _currentlyPlayingUrl = null;
        } else {
          _pauseOtherPlayers();
          _controller!.play();
          _isPlaying = true;
          _currentlyPlayingUrl = widget.videoUrl;
        }
      });
    } catch (e, st) {
      debugPrint('togglePlay error for ${widget.videoUrl}: $e\n$st');
    }
  }

  void _toggleMute() {
    if (_controller == null) {
      setState(() => _isMuted = !_isMuted);
      return;
    }
    _isMuted = !_isMuted;
    try {
      _controller!.setVolume(_isMuted ? 0.0 : 1.0);
    } catch (_) {}
    setState(() {});
  }

  Widget _buildPlaceholder(double height) {
    return Container(
      height: height,
      width: double.infinity,
      color: Colors.grey[900],
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty)
            Positioned.fill(
              child: CachedNetworkImage(
                imageUrl: widget.thumbnailUrl!,
                fit: BoxFit.cover,
                placeholder: (c, u) => Container(color: Colors.grey[850]),
                errorWidget: (c, u, e) => Container(color: Colors.grey[850]),
              ),
            ),
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withOpacity(0.36),
            ),
            child: const Padding(
              padding: EdgeInsets.all(6.0),
              child: Icon(Icons.play_circle_outline, color: Colors.white70, size: 56),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rawHeight = (widget.height ?? (MediaQuery.of(context).size.width * 9 / 16));
    final height = (rawHeight is num ? rawHeight.toDouble() : double.tryParse(rawHeight.toString()) ?? 200.0).clamp(160.0, 480.0);

    return VisibilityDetector(
      key: Key('simple_video_${widget.videoUrl.hashCode}'),
      onVisibilityChanged: (info) async {
        final visible = info.visibleFraction;
        if ((visible - _lastVisibility).abs() < 0.02) {
          _lastVisibility = visible;
          return;
        }
        _lastVisibility = visible;

        try {
          if (_currentlyPlayingUrl != null && _currentlyPlayingUrl != widget.videoUrl) {
            if (_initialized && _controller != null && _isPlaying) {
              _controller!.pause();
              if (mounted) setState(() => _isPlaying = false);
            }
            return;
          }

          if (visible >= _kAutoPlayThreshold) {
            if (!_initialized && !_initRequested) {
              await _initController(autoplay: widget.autoPlay);
            } else if (_initialized && _controller != null) {
              if (!_isPlaying) {
                _pauseOtherPlayers();
                _controller!.play();
                if (mounted) setState(() => _isPlaying = true);
              }
            }
          } else if (visible <= _kDisposeThreshold) {
            if (_initialized || _initRequested) {
              await _disposeController();
              if (mounted) setState(() {});
            }
          } else {
            if (_initialized && _controller != null) {
              _controller!.pause();
              if (mounted) setState(() => _isPlaying = false);
            }
          }
        } catch (e, st) {
          debugPrint('Visibility handler error for ${widget.videoUrl}: $e\n$st');
        }
      },
      child: GestureDetector(
        onTap: widget.onTap ?? _togglePlayOrInit,
        child: ClipRect(
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (!_initialized || _controller == null)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: height,
                  child: _buildPlaceholder(height),
                )
              else
                SizedBox(
                  height: height,
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: _controller!.value.size.width == 0 ? MediaQuery.of(context).size.width : _controller!.value.size.width,
                      height: _controller!.value.size.height == 0 ? height : _controller!.value.size.height,
                      child: vp.VideoPlayer(_controller!),
                    ),
                  ),
                ),

              if (_initialized && !_isPlaying)
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withOpacity(0.36),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(6.0),
                    child: Icon(Icons.play_circle_outline, color: Colors.white70, size: 56),
                  ),
                ),

              Positioned(
                right: 10,
                bottom: 10,
                child: GestureDetector(
                  onTap: _toggleMute,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.36),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Icon(_isMuted ? Icons.volume_off : Icons.volume_up, color: Colors.white70, size: 18),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ----------------- FeedProvider -----------------
class FeedProvider with ChangeNotifier {
  final List<Map<String, dynamic>> _feedPosts = [];
  bool _isLoading = false;
  bool _hasMorePosts = true;
  final int _postsPerPage;
  DocumentSnapshot? _lastDocument;
  final Map<String, Map<String, dynamic>> _postCache = {};
  FeedProvider({int postsPerPage = _kPostsPerPage}) : _postsPerPage = postsPerPage;

  List<Map<String, dynamic>> get feedPosts => _feedPosts;
  bool get isLoading => _isLoading;
  bool get hasMorePosts => _hasMorePosts;
  Timer? _debounceTimer;
  Completer<void>? _debounceCompleter;

  Future<void> fetchPosts({bool isRefresh = false}) async {
    if (_isLoading) return;
    _debounceTimer?.cancel();
    if (_debounceCompleter == null || (_debounceCompleter?.isCompleted ?? true)) {
      _debounceCompleter = Completer<void>();
    }

    _debounceTimer = Timer(const Duration(milliseconds: 250), () async {
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

          final typeValue = (data['type'] ?? '').toString();
          if (typeValue.toLowerCase() == 'story') {
            continue;
          }

          final timestampStr = data['timestamp']?.toString() ?? DateTime.now().toIso8601String();
          DateTime timestampDt;
          try {
            timestampDt = DateTime.parse(timestampStr).toLocal();
          } catch (_) {
            timestampDt = DateTime.now();
          }

          final likedByList = (data['likedBy'] is List) ? (data['likedBy'] as List).where((i) => i != null).map((i) => i.toString()).toList() : <String>[];

          int safeInt(dynamic v) {
            if (v is int) return v;
            if (v is double) return v.toInt();
            return int.tryParse(v?.toString() ?? '') ?? 0;
          }

          final item = {
            'id': doc.id,
            'user': (data['user'] ?? '').toString(),
            'post': (data['post'] ?? '').toString(),
            'type': typeValue,
            'likedBy': likedByList,
            'title': (data['title'] ?? '').toString(),
            'season': (data['season'] ?? '').toString(),
            'episode': (data['episode'] ?? '').toString(),
            'media': (data['media'] ?? '').toString(),
            'mediaType': (data['mediaType'] ?? '').toString(),
            'thumbnail': (data['thumbnail'] ?? '').toString(),
            'timestamp': timestampStr,
            'timestampDt': timestampDt,
            'userId': (data['userId'] ?? '').toString(),
            'retweetCount': safeInt(data['retweetCount']),
            'commentsCount': safeInt(data['commentsCount']),
            'views': safeInt(data['views']),
            'tags': data['tags'] ?? [],
            'followerCount': safeInt(data['followerCount']),
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
      } catch (e, st) {
        debugPrint('Error fetching posts: $e\n$st');
      } finally {
        _isLoading = false;
        notifyListeners();
        if (!(_debounceCompleter?.isCompleted ?? true)) {
          _debounceCompleter?.complete();
        }
      }
    });

    return _debounceCompleter!.future;
  }

  void addPost(Map<String, dynamic> post) {
    if ((post['type'] ?? '').toString().toLowerCase() == 'story') return;

    if (post['timestampDt'] == null) {
      if (post['timestamp'] != null) {
        try {
          post['timestampDt'] = DateTime.parse(post['timestamp'].toString()).toLocal();
        } catch (_) {
          post['timestampDt'] = DateTime.now();
        }
      } else {
        post['timestampDt'] = DateTime.now();
        post['timestamp'] = DateTime.now().toIso8601String();
      }
    }

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

/// ----------------- SocialReactionsController -----------------
/// Holds screen state data + operations so UI can be slimmer.
/// UI will call `controller.attach(setState)` (or pass an onChange callback)
/// and invoke methods; controller updates its own fields and calls onChange.
class SocialReactionsController {
  final SupabaseClient supabase;
  final void Function()? onChange; // call this after internal state changes so UI can setState
  SocialReactionsController({required this.supabase, this.onChange});

  // Mutable public fields that the UI reads
  Map<String, dynamic>? currentUser;
  List<Map<String, dynamic>> users = [];
  List<Map<String, dynamic>> stories = [];
  int movieStreak = 0;
  Set<String> savedPosts = {};
  Set<String> mutedUsers = {};
  List<String> recentlySeenTags = [];
  String feedMode = 'for_everyone';
  List<Map<String, dynamic>>? cachedRankedPosts;
  int? cachedForSourceId;

  // Helpers: attach UI updater (optional)
  void notify() {
    try {
      if (onChange != null) onChange!();
    } catch (_) {}
  }

  /// Initialize sequence (non-UI heavy)
  Future<void> initialize() async {
    try {
      await Future.wait([
        _checkMovieAccount(),
        _loadLocalData(),
        _loadUsers(),
        _loadUserData(),
      ]);
    } catch (e, st) {
      debugPrint('Controller initialize error: $e\n$st');
    } finally {
      notify();
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
      final movieStreakLocal = prefs.getInt('movieStreak') ?? 0;
      final saved = prefs.getStringList(_kPrefSavedPosts) ?? <String>[];
      final muted = prefs.getStringList(_kPrefMutedUsers) ?? <String>[];
      stories = List<Map<String, dynamic>>.from(jsonDecode(storiesString));
      movieStreak = movieStreakLocal;
      savedPosts = saved.toSet();
      mutedUsers = muted.toSet();
    } catch (e) {
      debugPrint('Error loading local data: $e');
    } finally {
      notify();
    }
  }

  Future<void> saveLocalData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('stories', jsonEncode(stories));
      await prefs.setInt('movieStreak', movieStreak);
      await prefs.setStringList(_kPrefSavedPosts, savedPosts.toList());
      await prefs.setStringList(_kPrefMutedUsers, mutedUsers.toList());
    } catch (e) {
      debugPrint('Error saving local data: $e');
    }
  }

  Future<void> _loadUserData() async {
    try {
      final current = FirebaseAuth.instance.currentUser;
      if (current == null) throw Exception('No current user');
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(current.uid)
          .get();
      if (!doc.exists) throw Exception('No user document');
      final data = Map<String, dynamic>.from(doc.data() ?? {});
      data['id'] = doc.id;
      currentUser = _normalizeUserData(data);
    } catch (e) {
      debugPrint('Error loading user data: $e');
      currentUser = null;
    } finally {
      notify();
    }
  }

  Future<void> _loadUsers() async {
    try {
      final snapshot =
          await FirebaseFirestore.instance.collection('users').get();
      final rawUsers = snapshot.docs.map((d) {
        final m = Map<String, dynamic>.from(d.data());
        m['id'] = d.id;
        return m;
      }).toList();
      users = rawUsers
          .map((u) => _normalizeUserData(Map<String, dynamic>.from(u)))
          .toList();
    } catch (e) {
      debugPrint('Error loading users: $e');
    } finally {
      notify();
    }
  }

  Map<String, dynamic> _normalizeUserData(Map<String, dynamic> user) {
    return {
      'id': user['id']?.toString() ?? '',
      'username': user['username']?.toString() ?? 'Unknown',
      'email': user['email']?.toString() ?? '',
      'bio': user['bio']?.toString() ?? '',
      'avatar': user['avatar']?.toString() ?? '',
    };
  }

  /// File picker abstraction (web + mobile)
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
      if (type == 'photo')
        return await picker.pickImage(source: ImageSource.gallery);
      return await picker.pickVideo(source: ImageSource.gallery);
    }
    return null;
  }

  Future<String> uploadMedia(dynamic mediaFile, String type, BuildContext ctx) async {
    try {
      final mediaId = const Uuid().v4();
      String filePath;
      String contentType;
      if (kIsWeb) {
        if (mediaFile is html.File) {
          final fileSizeInBytes = mediaFile.size;
          if (type == 'photo' && fileSizeInBytes > 5 * 1024 * 1024)
            throw Exception('Image too large, max 5MB');
          if (type == 'video' && fileSizeInBytes > 20 * 1024 * 1024)
            throw Exception('Video too large, max 20MB');
          final extension = mediaFile.name.split('.').last.toLowerCase();
          filePath = 'media/$mediaId.$extension';
          contentType = mediaFile.type;
          final reader = html.FileReader();
          reader.readAsArrayBuffer(mediaFile);
          await reader.onLoad.first;
          final bytes = reader.result as Uint8List;
          await supabase.storage.from('feeds').uploadBinary(filePath, bytes,
              fileOptions: FileOptions(contentType: contentType));
        } else {
          throw Exception('Invalid web file');
        }
      } else {
        if (mediaFile is XFile) {
          final file = File(mediaFile.path);
          final fileSizeInBytes = await file.length();
          if (type == 'photo' && fileSizeInBytes > 5 * 1024 * 1024)
            throw Exception('Image too large, max 5MB');
          if (type == 'video' && fileSizeInBytes > 20 * 1024 * 1024)
            throw Exception('Video too large, max 20MB');
          final extension = p.extension(mediaFile.path).replaceFirst('.', '');
          filePath = 'media/$mediaId.$extension';
          contentType = _getMimeType(extension);
          await supabase.storage.from('feeds').upload(filePath, file,
              fileOptions: FileOptions(contentType: contentType));
        } else {
          throw Exception('Invalid file type');
        }
      }

      final url = supabase.storage.from('feeds').getPublicUrl(filePath);
      return url.isNotEmpty ? url : '';
    } catch (e) {
      debugPrint('upload error: $e');
      try {
        if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Error uploading media: $e')));
      } catch (_) {}
      return '';
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

  /// Post a story (returns uploaded story map or throws)
  Future<Map<String, dynamic>> postStory(dynamic pickedFile, String choice, BuildContext ctx) async {
    final uploadedUrl = await uploadMedia(pickedFile, choice, ctx);
    if (uploadedUrl.isEmpty) throw Exception('Upload failed');

    final story = {
      'user': currentUser?['username'] ?? 'User',
      'userId': currentUser?['id']?.toString() ?? '',
      'media': uploadedUrl,
      'type': choice,
      'timestamp': DateTime.now().toIso8601String(),
    };

    final docRef = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser?['id']?.toString())
        .collection('stories')
        .add(story);
    story['id'] = docRef.id;
    await FirebaseFirestore.instance.collection('stories').add(story);

    // local add
    stories.add(story);
    await saveLocalData();
    notify();
    return story;
  }

  Future<void> postMovieReviewNavigate(BuildContext ctx, Color accentColor) async {
    // keep behavior simple: the UI calls Navigator; controller only validates
    if (currentUser == null) {
      if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('User data not loaded')));
      return;
    }
    // UI will navigate; controller does not perform navigation
  }

  // Ranking helpers (pure)
  List<Map<String, dynamic>> rankAndApply(List<Map<String, dynamic>> posts) {
    try {
      final ranked = Algo.rankPosts(posts,
          currentUser: currentUser,
          recentlySeenTags: recentlySeenTags,
          mode: feedMode,
          seed: DateTime.now().millisecondsSinceEpoch % 100000);
      return ranked;
    } catch (e) {
      debugPrint('Ranking error: $e');
      return posts;
    }
  }

  List<Map<String, dynamic>> getCachedRanked(List<Map<String, dynamic>> source) {
    try {
      final sourceId =
          source.map((p) => (p['id'] ?? '').toString()).join('|').hashCode ^
              feedMode.hashCode;
      if (cachedRankedPosts == null || cachedForSourceId != sourceId) {
        final newRanked = rankAndApply(source);
        cachedRankedPosts = newRanked;
        cachedForSourceId = sourceId;
      }
      return cachedRankedPosts ?? source;
    } catch (e) {
      debugPrint('Cache rank error: $e');
      return source;
    }
  }

  void refreshRankedCache(List<Map<String, dynamic>> source) {
    cachedRankedPosts = rankAndApply(source);
    cachedForSourceId = source
            .map((p) => (p['id'] ?? '').toString())
            .join('|')
            .hashCode ^
        feedMode.hashCode;
    notify();
  }

  Future<void> toggleMuteForUser(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final muted = prefs.getStringList(_kPrefMutedUsers) ?? <String>[];
      if (mutedUsers.contains(userId)) {
        muted.remove(userId);
        mutedUsers.remove(userId);
      } else {
        muted.add(userId);
        mutedUsers.add(userId);
      }
      await prefs.setStringList(_kPrefMutedUsers, muted);
      notify();
    } catch (e) {
      debugPrint('toggle mute central error: $e');
      rethrow;
    }
  }

  Future<void> postCommentInline(String text, Map<String, dynamic> post, BuildContext ctx) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(post['userId']?.toString())
          .collection('posts')
          .doc(post['id']?.toString())
          .collection('comments')
          .add({
        'text': trimmed,
        'userId': currentUser?['id'],
        'username': currentUser?['username'],
        'userAvatar': currentUser?['avatar'],
        'timestamp': DateTime.now().toIso8601String(),
      });
      if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Comment posted')));
    } catch (e) {
      debugPrint('comment error: $e');
      if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed to post comment: $e')));
    }
  }
}
