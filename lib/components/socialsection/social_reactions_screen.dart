// social_section.dart (updated & optimized)
// Replace your existing social section file with this.
// Note: I preserved your external dependencies (Supabase, TMDB helpers, etc).
// Review places marked TODO if you want deeper integration (video pooling, better offline).

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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

/// Lightweight video widget — keeps same API but guarded initialization.
class SimpleVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final bool autoPlay;
  final VoidCallback? onTap;

  const SimpleVideoPlayer({
    super.key,
    required this.videoUrl,
    this.autoPlay = false,
    this.onTap,
  });

  @override
  State<SimpleVideoPlayer> createState() => _SimpleVideoPlayerState();
}

class _SimpleVideoPlayerState extends State<SimpleVideoPlayer> with AutomaticKeepAliveClientMixin {
  late vp.VideoPlayerController _controller;
  bool _isPlaying = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = vp.VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl))
      ..setLooping(true)
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() {
          _initialized = true;
          if (widget.autoPlay) {
            _controller.play();
            _isPlaying = true;
          }
        });
      }).catchError((e) {
        debugPrint('Video init error: $e');
      });
  }

  @override
  void dispose() {
    try {
      _controller.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return GestureDetector(
      onTap: widget.onTap ??
          () {
            if (!_initialized) return;
            setState(() {
              if (_isPlaying) {
                _controller.pause();
                _isPlaying = false;
              } else {
                _controller.play();
                _isPlaying = true;
              }
            });
          },
      child: RepaintBoundary(
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_initialized)
              AspectRatio(aspectRatio: _controller.value.aspectRatio, child: vp.VideoPlayer(_controller))
            else
              Container(
                color: Colors.grey[300],
                constraints: const BoxConstraints(minHeight: 120),
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

/// Feed provider with simple pagination and fetch guard
class FeedProvider with ChangeNotifier {
  final List<Map<String, dynamic>> _feedPosts = [];
  bool _isLoading = false;
  bool _hasMorePosts = true;
  final int _postsPerPage = 10;
  DocumentSnapshot? _lastDocument;

  List<Map<String, dynamic>> get feedPosts => _feedPosts;
  bool get isLoading => _isLoading;
  bool get hasMorePosts => _hasMorePosts;

  Future<void> fetchPosts({bool isRefresh = false}) async {
    if (_isLoading) return;
    _isLoading = true;
    notifyListeners();

    try {
      Query query = FirebaseFirestore.instance.collection('feeds').orderBy('timestamp', descending: true).limit(_postsPerPage);

      if (!isRefresh && _lastDocument != null) {
        query = query.startAfterDocument(_lastDocument!);
      }

      final snapshot = await query.get();
      final newPosts = snapshot.docs.map((doc) {
        final data = (doc.data() as Map<String, dynamic>? ) ?? {};
        return {
          'id': doc.id,
          'user': (data['user'] ?? '') as String,
          'post': (data['post'] ?? '') as String,
          'type': (data['type'] ?? '') as String,
          'likedBy': (data['likedBy'] as List?)?.where((item) => item != null).map((item) => item.toString()).toList() ?? <String>[],
          'title': (data['title'] ?? '') as String,
          'season': (data['season'] ?? '') as String,
          'episode': (data['episode'] ?? '') as String,
          'media': (data['media'] ?? '') as String,
          'mediaType': (data['mediaType'] ?? '') as String,
          'timestamp': data['timestamp']?.toString() ?? DateTime.now().toIso8601String(),
          'userId': (data['userId'] ?? '') as String,
        };
      }).toList();

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
  }

  void addPost(Map<String, dynamic> post) {
    _feedPosts.insert(0, post);
    notifyListeners();
  }

  void removePost(String id) {
    _feedPosts.removeWhere((p) => p['id'] == id);
    notifyListeners();
  }
}

/// Post card — optimized to avoid fixed huge heights and heavy rebuilds.
class PostCardWidget extends StatelessWidget {
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
  });

  @override
  Widget build(BuildContext context) {
    final id = (post['id'] as String?) ?? '';
    final userName = (post['user'] as String?) ?? 'Unknown';
    final message = (post['post'] as String?) ?? '';
    final likedBy = (post['likedBy'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
    final title = (post['title'] as String?) ?? '';
    final season = (post['season'] as String?) ?? '';
    final episode = (post['episode'] as String?) ?? '';
    final media = (post['media'] as String?) ?? '';
    final mediaType = (post['mediaType'] as String?) ?? '';
    final userId = (post['userId'] as String?) ?? '';
    final userRecord = users.firstWhere((u) => (u['id'] as String?) == userId, orElse: () => {'username': userName, 'avatar': ''});
    final username = (userRecord['username'] as String?) ?? 'Unknown';
    final initial = username.isNotEmpty ? username[0].toUpperCase() : '?';
    final avatarUrl = (userRecord['avatar'] as String?) ?? '';
    final currentUserId = (currentUser?['id'] as String?) ?? '';
    final isLiked = likedBy.contains(currentUserId);

    bool isValidImageUrl(String url) =>
        url.startsWith('http') && (url.endsWith('.jpg') || url.endsWith('.jpeg') || url.endsWith('.png'));

    // Compute a reasonable display height based on device width
    final screenWidth = MediaQuery.of(context).size.width;
    final imageHeight = (screenWidth * 9 / 16).clamp(180.0, 480.0);

    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [accentColor.withAlpha((0.1 * 255).round()), accentColor.withAlpha((0.3 * 255).round())],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accentColor.withAlpha((0.3 * 255).round())),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: CircleAvatar(
                radius: 20,
                backgroundImage: avatarUrl.isNotEmpty ? CachedNetworkImageProvider(avatarUrl) : null,
                child: avatarUrl.isEmpty ? Text(initial, style: const TextStyle(color: Colors.white)) : null,
              ),
              title: Text(username, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              subtitle: null,
              trailing: PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'report') {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reported')));
                  } else if (value == 'share') {
                    onSend(post);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'share', child: Text('Share')),
                  PopupMenuItem(value: 'report', child: Text('Report')),
                ],
              ),
            ),

            // Media
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
                            color: Colors.grey[800],
                            alignment: Alignment.center,
                            height: imageHeight,
                            child: const CircularProgressIndicator(),
                          ),
                          errorWidget: (c, url, err) => Container(
                            color: Colors.grey[300],
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
                              final videoPosts = allPosts
                                  .where((p) => (p['mediaType'] as String?) == 'video' && (p['media'] as String?)?.isNotEmpty == true)
                                  .map((p) => Reel(
                                        videoUrl: (p['media'] as String?) ?? '',
                                        movieTitle: (p['title'] as String?) ?? 'Video',
                                        movieDescription: (p['post'] as String?) ?? '',
                                      ))
                                  .toList();
                              final idx = videoPosts.indexWhere((r) => r.videoUrl == media);
                              if (idx != -1) {
                                Navigator.push(context, MaterialPageRoute(builder: (_) => FeedReelPlayerScreen(reels: videoPosts, initialIndex: idx)));
                              } else {
                                Navigator.push(context, MaterialPageRoute(builder: (_) => FeedReelPlayerScreen(reels: [Reel(videoUrl: media, movieTitle: title, movieDescription: message)], initialIndex: 0)));
                              }
                            },
                          ),
                        );
                      } else {
                        return Container(
                          height: imageHeight,
                          color: Colors.grey[300],
                          child: const Center(child: Icon(Icons.image, size: 40)),
                        );
                      }
                    }),
                  ),
                ),
              ),

            // Text content
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(message, style: const TextStyle(fontSize: 15, color: Colors.white70)),
                if (season.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Season: $season, Episode: ${episode.isNotEmpty ? episode : 'N/A'}', style: const TextStyle(color: Colors.white70, fontStyle: FontStyle.italic)),
                  ),
                if (title.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Movie: $title', style: const TextStyle(color: Colors.white70, fontStyle: FontStyle.italic)),
                  ),
              ]),
            ),

            const Divider(color: Colors.white54, height: 1),

            // Actions row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  InkWell(
                    onTap: () => onLike(id, isLiked),
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Row(children: [
                        Icon(isLiked ? Icons.favorite : Icons.favorite_border, color: isLiked ? Colors.red : Colors.white70, size: 22),
                        const SizedBox(width: 6),
                        Text(likedBy.length.toString(), style: const TextStyle(color: Colors.white70, fontSize: 14)),
                      ]),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.comment, color: Colors.white70, size: 22), onPressed: () => onComment(post)),
                  IconButton(icon: const Icon(Icons.connected_tv, color: Colors.white70, size: 22), onPressed: () => onWatchParty(post)),
                  IconButton(icon: const Icon(Icons.send, color: Colors.white70, size: 22), onPressed: () => onSend(post)),
                  if (userId == currentUserId)
                    IconButton(icon: const Icon(Icons.delete, color: Colors.red, size: 22), onPressed: () => onDelete(id)),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }
}

/// Main Social Reactions Screen (top-level)
class SocialReactionsScreen extends StatelessWidget {
  final Color accentColor;

  const SocialReactionsScreen({super.key, required this.accentColor});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(create: (_) => FeedProvider(), child: _SocialReactionsScreen(accentColor: accentColor));
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeData();
    _mainScrollController.addListener(_onScroll);
  }

  void _onScroll() {
    final feed = Provider.of<FeedProvider>(context, listen: false);
    if (_mainScrollController.position.pixels >= _mainScrollController.position.maxScrollExtent - 100 && !feed.isLoading && feed.hasMorePosts) {
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
    try {
      await Future.wait([_checkMovieAccount(), _loadLocalData(), _loadUsers(), _loadUserData()]);
      await Provider.of<FeedProvider>(context, listen: false).fetchPosts(isRefresh: true);
    } catch (e) {
      debugPrint('Error initializing social screen: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to initialize data: $e')));
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
      _stories = List<Map<String, dynamic>>.from(jsonDecode(storiesString));
      _movieStreak = movieStreak;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Error loading local data: $e');
    }
  }

  Future<void> _saveLocalData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('stories', jsonEncode(_stories));
    await prefs.setInt('movieStreak', _movieStreak);
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
      // you can add other fields as needed
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
    final choice = await showModalBottomSheet<String>(context: context, builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.photo, color: Colors.white), title: const Text("Upload Photo", style: TextStyle(color: Colors.white)), onTap: () => Navigator.pop(context, 'photo')),
      ListTile(leading: const Icon(Icons.videocam, color: Colors.white), title: const Text("Upload Video", style: TextStyle(color: Colors.white)), onTap: () => Navigator.pop(context, 'video')),
    ])));
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

      setState(() { _stories.add(story); });
      await _saveLocalData();
    } catch (e) {
      debugPrint('postStory error: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to post story: $e')));
    } finally {
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _postMovieReview() async {
    final movieController = TextEditingController();
    final reviewController = TextEditingController();
    final episodeController = TextEditingController();
    final seasonController = TextEditingController();
    dynamic mediaFile;
    String? mediaType;
    bool isTVShow = false;

    final result = await showDialog<Map<String, dynamic>>(context: context, builder: (context) {
      return StatefulBuilder(builder: (context, setDialogState) {
        return AlertDialog(
          backgroundColor: const Color.fromARGB(255, 17, 25, 40),
          title: const Text('Write a Review', style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: !isTVShow ? widget.accentColor : Colors.grey), onPressed: () => setDialogState(() => isTVShow = false), child: const Text('Movie')),
                const SizedBox(width: 8),
                ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: isTVShow ? widget.accentColor : Colors.grey), onPressed: () => setDialogState(() => isTVShow = true), child: const Text('TV Show')),
              ]),
              const SizedBox(height: 12),
              TextField(controller: movieController, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: 'Movie/TV Show Name', hintStyle: TextStyle(color: Colors.white54))),
              if (isTVShow) ...[
                const SizedBox(height: 8),
                TextField(controller: seasonController, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: 'Season Name', hintStyle: TextStyle(color: Colors.white54))),
                const SizedBox(height: 8),
                TextField(controller: episodeController, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: 'Episode Name/Number', hintStyle: TextStyle(color: Colors.white54))),
              ],
              const SizedBox(height: 8),
              TextField(controller: reviewController, style: const TextStyle(color: Colors.white), maxLines: 4, decoration: const InputDecoration(hintText: 'Enter your review...', hintStyle: TextStyle(color: Colors.white54))),
              const SizedBox(height: 8),
              TextButton.icon(icon: const Icon(Icons.image, color: Colors.white70), label: const Text('Pick Media', style: TextStyle(color: Colors.white70)), onPressed: () async {
                final choice = await showModalBottomSheet<String>(context: context, builder: (context) => Container(color: Colors.black87, child: SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  ListTile(leading: const Icon(Icons.photo, color: Colors.white), title: const Text('Upload Photo', style: TextStyle(color: Colors.white)), onTap: () => Navigator.pop(context, 'photo')),
                  ListTile(leading: const Icon(Icons.videocam, color: Colors.white), title: const Text('Upload Video', style: TextStyle(color: Colors.white)), onTap: () => Navigator.pop(context, 'video')),
                ]))));
                if (choice != null) {
                  final picked = await pickFile(choice);
                  if (picked != null) {
                    setDialogState(() { mediaFile = picked; mediaType = choice; });
                  }
                }
              }),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: widget.accentColor), onPressed: () {
              if (movieController.text.trim().isEmpty || reviewController.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill in all fields')));
                return;
              }
              Navigator.pop(context, {
                'title': movieController.text.trim(),
                'review': reviewController.text.trim(),
                'season': seasonController.text.trim(),
                'episode': episodeController.text.trim(),
                'media': mediaFile,
                'mediaType': mediaType,
                'isTVShow': isTVShow,
              });
            }, child: const Text('Post')),
          ],
        );
      });
    });

    if (result == null || !mounted) return;
    String? mediaUrl;
    try {
      if (result['media'] != null) {
        showDialog(context: context, barrierDismissible: false, builder: (_) => const AlertDialog(content: Row(children: [CircularProgressIndicator(), SizedBox(width: 12), Text('Uploading Review...')])));
        mediaUrl = await uploadMedia(result['media'], result['mediaType'] ?? 'photo', context);
        if (mediaUrl == 'https://via.placeholder.com/150') throw Exception('Failed to upload review media');
      }
      final newPost = {
        'user': _currentUser?['username'] ?? 'User',
        'userId': _currentUser?['id']?.toString() ?? '',
        'post': result['isTVShow'] ? 'Reviewed ${result['title']} S${result['season']}: E${result['episode']} - ${result['review']}' : 'Reviewed ${result['title']}: ${result['review']}',
        'type': 'review',
        'likedBy': [],
        'title': result['title'],
        'season': result['season'],
        'episode': result['episode'],
        'media': mediaUrl,
        'mediaType': mediaUrl != null ? (result['mediaType'] ?? '') : '',
        'timestamp': DateTime.now().toIso8601String(),
      };
      final docRef = await FirebaseFirestore.instance.collection('users').doc(_currentUser?['id']?.toString()).collection('posts').add(newPost);
      newPost['id'] = docRef.id;
      await FirebaseFirestore.instance.collection('feeds').add(newPost);
      Provider.of<FeedProvider>(context, listen: false).addPost(newPost);
      setState(() { _notifications.add('${_currentUser?['username'] ?? 'User'} posted a review for ${result['title']}'); });
    } catch (e) {
      debugPrint('post review error: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to post review: $e')));
    } finally {
      if (mounted) Navigator.pop(context);
    }
  }

  Widget _buildFeedTab() {
    return Consumer<FeedProvider>(builder: (context, feedProvider, child) {
      return Column(children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: widget.accentColor, minimumSize: const Size(double.infinity, 48)),
          onPressed: _postMovieReview,
          icon: const Icon(Icons.rate_review, size: 20),
          label: const Text('Post Movie Review', style: TextStyle(fontSize: 16)),
        )),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => feedProvider.fetchPosts(isRefresh: true),
            child: CustomScrollView(
              key: _feedKey,
              controller: _mainScrollController,
              slivers: [
                SliverList(delegate: SliverChildBuilderDelegate((context, index) {
                  if (index >= feedProvider.feedPosts.length) {
                    return feedProvider.hasMorePosts ? const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())) : const SizedBox.shrink();
                  }
                  final item = feedProvider.feedPosts[index];
                  return RepaintBoundary(
                    child: PostCardWidget(
                      key: ValueKey(item['id']),
                      post: item,
                      allPosts: feedProvider.feedPosts,
                      currentUser: _currentUser,
                      users: _users,
                      accentColor: widget.accentColor,
                      onDelete: (id) async {
                        try {
                          await FirebaseFirestore.instance.collection('feeds').doc(id).delete();
                          feedProvider.removePost(id);
                        } catch (e) {
                          debugPrint('delete post error: $e');
                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete post: $e')));
                        }
                      },
                      onLike: (id, isLiked) async {
                        try {
                          final ref = FirebaseFirestore.instance.collection('feeds').doc(id);
                          if (isLiked) {
                            await ref.update({'likedBy': FieldValue.arrayRemove([_currentUser?['id'] ?? ''])});
                          } else {
                            await ref.update({'likedBy': FieldValue.arrayUnion([_currentUser?['id'] ?? ''])});
                          }
                          // local optimistic update
                        } catch (e) {
                          debugPrint('like error: $e');
                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to like post: $e')));
                        }
                      },
                      onComment: _showComments,
                      onWatchParty: (post) => _promptCreateWatchParty(post),
                      onSend: (post) {
                        final code = (100000 + Random().nextInt(900000)).toString();
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Started Watch Party: Code $code')));
                        setState(() { _notifications.add('${_currentUser?['username'] ?? 'User'} started a watch party with code $code'); });
                      },
                    ),
                  );
                }, childCount: feedProvider.feedPosts.length + (feedProvider.hasMorePosts ? 1 : 0))),
                SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      const Text('Recommended Movies', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                      IconButton(icon: Icon(_showRecommendations ? Icons.remove : Icons.add, color: Colors.white), onPressed: () => setState(() => _showRecommendations = !_showRecommendations)),
                    ]),
                    Visibility(visible: _showRecommendations, child: const SizedBox(height: 12)),
                    if (_showRecommendations) const TrendingMoviesWidget(),
                    const SizedBox(height: 20),
                  ],
                ))),
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
              final map = (doc.data() as Map<String, dynamic>? ) ?? {};
              return {...map, 'id': doc.id};
            }).where((s) {
              try {
                return DateTime.now().difference(DateTime.parse(s['timestamp'])) < const Duration(hours: 24);
              } catch (_) { return false; }
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
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          image: isPhoto ? DecorationImage(image: CachedNetworkImageProvider(mediaUrl), fit: BoxFit.cover) : null,
                          color: first['type'] == 'video' ? Colors.black : Colors.grey,
                          border: Border.all(color: Colors.yellow.withAlpha((0.8 * 255).round()), width: 2),
                          boxShadow: [BoxShadow(color: Colors.yellow.withAlpha((0.6 * 255).round()), blurRadius: 8, spreadRadius: 1)],
                        ),
                        child: first['type'] == 'video' ? const Icon(Icons.videocam, color: Colors.white, size: 20) : null,
                      ),
                      const SizedBox(height: 6),
                      SizedBox(width: 72, child: Text(first['user'] ?? 'Unknown', style: const TextStyle(color: Colors.white, fontSize: 12), overflow: TextOverflow.ellipsis)),
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
        setState(() { _notifications.add('${_currentUser?['username'] ?? 'User'} created a watch party with code $code'); });
      }, child: const Text('Yes')),
    ]));
  }

  void _showComments(Map<String, dynamic> post) {
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: const Color.fromARGB(255, 17, 25, 40), builder: (context) {
      final controller = TextEditingController();
      return FractionallySizedBox(
        heightFactor: 0.9,
        child: StreamBuilder<QuerySnapshot>(stream: FirebaseFirestore.instance.collection('users').doc(post['userId']).collection('posts').doc(post['id']).collection('comments').orderBy('timestamp', descending: true).snapshots(), builder: (context, snapshot) {
          if (snapshot.hasError) return const Center(child: Text('Failed to load comments.', style: TextStyle(color: Colors.white)));
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final comments = snapshot.data!.docs.map((d) => (d.data() as Map<String, dynamic>? ) ?? {}).toList();
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom + 16, left: 16, right: 16, top: 16),
            child: Column(children: [
              const Text('Comments', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
              Expanded(child: ListView.builder(itemCount: comments.length, itemBuilder: (_, i) => ListTile(
                leading: CircleAvatar(radius: 20, backgroundImage: CachedNetworkImageProvider(comments[i]['userAvatar'] ?? 'https://via.placeholder.com/50')),
                title: Text(comments[i]['username'] ?? 'Unknown', style: TextStyle(color: widget.accentColor)),
                subtitle: Text(comments[i]['text'] ?? '', style: const TextStyle(color: Colors.white70)),
              ))),
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
        }),
      );
    });
  }

  void _onTabTapped(int index) => setState(() => _selectedIndex = index);

  void _showFabActions() {
    showModalBottomSheet(context: context, backgroundColor: Colors.transparent, builder: (context) => Container(margin: const EdgeInsets.all(16), decoration: const BoxDecoration(color: Color.fromARGB(255, 17, 25, 40), borderRadius: BorderRadius.all(Radius.circular(12))), child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.message, color: Colors.white), title: const Text('New Message', style: TextStyle(color: Colors.white)), onTap: () {
        Navigator.pop(context);
        if (_currentUser != null) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => NewChatScreen(currentUser: _currentUser!, otherUsers: _users.where((u) => u['email'] != _currentUser!['email']).toList(), accentColor: widget.accentColor)));
        } else {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User data not loaded')));
        }
      }),
      if (!_showRecommendations) ListTile(leading: const Icon(Icons.expand, color: Colors.white), title: const Text('Expand Recommendations', style: TextStyle(color: Colors.white)), onTap: () { Navigator.pop(context); setState(() => _showRecommendations = true); }),
    ])));
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
          if (_currentUser != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Center(child: Text('Hey, ${_currentUser!['username']}', style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white, fontSize: 16)))),
        ],
      ),
      body: Stack(children: [
        // Static background layers (cheap to repaint) and single blur — don't rebuild on scroll
        Container(color: const Color(0xFF111927)),
        Container(decoration: BoxDecoration(gradient: RadialGradient(center: const Alignment(-0.1, -0.4), radius: 1.2, colors: [widget.accentColor.withAlpha((0.4 * 255).round()), Colors.black], stops: const [0.0, 0.6]))),
        Positioned.fill(top: kToolbarHeight + MediaQuery.of(context).padding.top, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Container(decoration: BoxDecoration(gradient: RadialGradient(center: Alignment.center, radius: 1.6, colors: [widget.accentColor.withAlpha((0.2 * 255).round()), Colors.transparent], stops: const [0.0, 1.0]), borderRadius: const BorderRadius.all(Radius.circular(16)), boxShadow: [BoxShadow(color: widget.accentColor.withAlpha((0.4 * 255).round()), blurRadius: 10, spreadRadius: 1, offset: const Offset(0, 4))]), child: ClipRRect(borderRadius: const BorderRadius.all(Radius.circular(16)), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12), child: Container(decoration: const BoxDecoration(color: Color.fromARGB(180, 17, 19, 40), borderRadius: BorderRadius.all(Radius.circular(16)), border: Border.fromBorderSide(BorderSide(color: Colors.white, width: 0.1))), child: Theme(data: ThemeData.dark(), child: IndexedStack(index: _selectedIndex, children: tabs))))))),
        )
      ]),
      floatingActionButton: FloatingActionButton(backgroundColor: widget.accentColor, onPressed: _showFabActions, child: const Icon(Icons.add, color: Colors.white, size: 22)),
      bottomNavigationBar: BottomNavigationBar(currentIndex: _selectedIndex, onTap: _onTabTapped, backgroundColor: Colors.black87, selectedItemColor: const Color(0xffffeb00), unselectedItemColor: widget.accentColor, type: BottomNavigationBarType.fixed, items: const [
        BottomNavigationBarItem(icon: Icon(Icons.home, size: 22), label: "Feeds"),
        BottomNavigationBarItem(icon: Icon(Icons.history, size: 22), label: "Stories"),
        BottomNavigationBarItem(icon: Icon(Icons.notifications, size: 22), label: "Notifications"),
        BottomNavigationBarItem(icon: Icon(Icons.whatshot, size: 22), label: "Streaks"),
        BottomNavigationBarItem(icon: Icon(Icons.person, size: 22), label: "Profile"),
      ]),
    );
  }
}

/// NewChatScreen — minor cleanup / reuse chatutils.getChatId
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
    return Scaffold(extendBodyBehindAppBar: true, appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: const Text('New Chat', style: TextStyle(color: Colors.white, fontSize: 20)), leading: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context))), body: Stack(children: [
      Container(color: const Color(0xFF111927)),
      Container(decoration: BoxDecoration(gradient: RadialGradient(center: const Alignment(-0.1, -0.4), radius: 1.2, colors: [widget.accentColor.withAlpha((0.4 * 255).round()), Colors.black], stops: const [0.0, 0.6]))),
      Positioned.fill(top: kToolbarHeight + MediaQuery.of(context).padding.top, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Container(decoration: BoxDecoration(gradient: RadialGradient(center: Alignment.center, radius: 1.6, colors: [widget.accentColor.withAlpha((0.2 * 255).round()), Colors.transparent], stops: const [0.0, 1.0]), borderRadius: const BorderRadius.all(Radius.circular(16)), boxShadow: [BoxShadow(color: widget.accentColor.withAlpha((0.4 * 255).round()), blurRadius: 10, spreadRadius: 1, offset: const Offset(0, 4))]), child: ClipRRect(borderRadius: const BorderRadius.all(Radius.circular(16)), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6), child: Container(decoration: BoxDecoration(color: Colors.black.withAlpha((0.3 * 255).round()), borderRadius: const BorderRadius.all(Radius.circular(16)), border: Border.all(color: Colors.white.withAlpha((0.5 * 255).round()))), child: ListView.separated(padding: const EdgeInsets.all(16), itemCount: widget.otherUsers.length, separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white54), itemBuilder: (context, index) {
        final user = widget.otherUsers[index];
        return ListTile(leading: CircleAvatar(backgroundColor: widget.accentColor, child: Text(user['username'] != null && user['username'].isNotEmpty ? user['username'][0].toUpperCase() : '?', style: const TextStyle(color: Colors.white))), title: Text(user['username'] ?? 'Unknown', style: const TextStyle(color: Colors.white, fontSize: 14)), onTap: () => _startChat(user));
      })))))),
      )
    ]));
  }
}
