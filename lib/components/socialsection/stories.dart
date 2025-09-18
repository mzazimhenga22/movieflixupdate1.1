// story_screen.dart
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart'; // Clipboard
import 'package:url_launcher/url_launcher.dart'; // open url

class StoryScreen extends StatefulWidget {
  final List<Map<String, dynamic>> stories;
  final int initialIndex;
  final void Function(String type, Map<String, dynamic> data)?
      onStoryInteraction;
  final String currentUserId;

  const StoryScreen({
    super.key,
    required this.stories,
    required this.currentUserId,
    this.initialIndex = 0,
    this.onStoryInteraction,
  });

  @override
  _StoryScreenState createState() => _StoryScreenState();
}

class _StoryScreenState extends State<StoryScreen>
    with SingleTickerProviderStateMixin {
  late PageController _pageController;
  late AnimationController _animationController;
  VideoPlayerController? _videoController;
  int _currentIndex = 0;
  final TextEditingController _replyController = TextEditingController();
  late List<Map<String, dynamic>> _activeStories;
  final FocusNode _replyFocusNode = FocusNode();

  // If true, play through all stories from Firestore (global) rather than only widget.stories
  bool _playAll = false;
  bool _isPaused = false;
  bool _isLoadingAll = false;

  @override
  void initState() {
    super.initState();
    _activeStories = List<Map<String, dynamic>>.from(widget.stories);
    _currentIndex = widget.initialIndex.clamp(0, _activeStories.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )
      ..addListener(() => setState(() {}))
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && !_isPaused) _nextStory();
      });
    _loadStory(_currentIndex);

    _replyFocusNode.addListener(() {
      if (_replyFocusNode.hasFocus) {
        _pause();
      } else {
        _resume();
      }
    });
  }

  /// Try to extract Firebase Console index creation URL from Firestore error message.
  /// Typical errors include a link like:
  /// https://console.firebase.google.com/project/PROJECT_ID/firestore/indexes?create_composite=...
  String? _extractIndexUrlFromError(Object? error) {
    if (error == null) return null;
    final s = error.toString();
    final match = RegExp(r'https://console\.firebase\.google\.com[^\s\)\]]+').firstMatch(s);
    return match?.group(0);
  }

  Future<void> _handleFirestoreIndexError(Object error) async {
    final url = _extractIndexUrlFromError(error);
    if (url == null) {
      // No index URL found; show a generic message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Firestore error: ${error.toString()}')),
        );
      }
      return;
    }

    // Show dialog with actions: open or copy
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Missing Firestore Index'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'A required Firestore index is missing for this query. '
                'You can create it in the Firebase Console with the link below.',
              ),
              const SizedBox(height: 12),
              SelectableText(
                url,
                style: const TextStyle(fontSize: 12),
                maxLines: 5,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url));
                Navigator.of(ctx).pop();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Index link copied to clipboard')));
                }
              },
              child: const Text('Copy link'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _launchUrl(url);
              },
              child: const Text('Open Console'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Dismiss'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _launchUrl(String urlString) async {
    try {
      final uri = Uri.parse(urlString);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open link')));
        }
      }
    } catch (e) {
      debugPrint('launchUrl error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open link')));
      }
    }
  }

  Future<void> _fetchAllActiveStories() async {
    setState(() {
      _isLoadingAll = true;
    });
    try {
      final now = DateTime.now();
      final snapshot = await FirebaseFirestore.instance.collection('stories').get();
      final docs = snapshot.docs.map((d) {
        final m = Map<String, dynamic>.from(d.data() as Map<String, dynamic>);
        m['id'] = d.id;
        return m;
      }).where((m) {
        try {
          final ts = DateTime.parse(m['timestamp'] ?? DateTime.now().toIso8601String());
          return now.difference(ts) < const Duration(hours: 24);
        } catch (_) {
          return false;
        }
      }).toList();

      docs.sort((a, b) {
        try {
          return DateTime.parse(a['timestamp']).compareTo(DateTime.parse(b['timestamp']));
        } catch (_) {
          return 0;
        }
      });

      if (!mounted) return;
      setState(() {
        _activeStories = docs;
        _currentIndex = 0;
        _pageController.jumpToPage(0);
      });
      _loadStory(0);
    } catch (e) {
      debugPrint('Failed to fetch all stories: $e');
      // If Firestore returned a missing-index error, help the developer create it.
      await _handleFirestoreIndexError(e);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load all stories: ${e.toString()}')));
    } finally {
      if (mounted) setState(() { _isLoadingAll = false; });
    }
  }

  void _loadStory(int index) {
    // dispose previous video
    _animationController.reset();
    try {
      _videoController?.removeListener(_videoListenerSafe);
    } catch (_) {}
    try {
      _videoController?.dispose();
    } catch (_) {}
    _videoController = null;
    _isPaused = false;

    if (_activeStories.isEmpty) return;
    if (index < 0 || index >= _activeStories.length) return;
    final story = _activeStories[index];
    DateTime? storyTime;
    try {
      storyTime = DateTime.parse(story['timestamp'] ?? DateTime.now().toIso8601String());
    } catch (_) {
      storyTime = DateTime.now();
    }

    // auto-delete expired story if it's ours
    if (DateTime.now().difference(storyTime) >= const Duration(hours: 24)) {
      if (story['userId'] == widget.currentUserId) {
        FirebaseFirestore.instance.collection('stories').doc(story['id']).delete().catchError((e) {
          debugPrint('Failed to delete expired story: $e');
        });
      }
      if (mounted) {
        setState(() {
          _activeStories.removeAt(index);
          if (_activeStories.isEmpty) {
            Navigator.pop(context);
            return;
          }
          _currentIndex = index.clamp(0, _activeStories.length - 1);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _loadStory(_currentIndex);
        });
      }
      return;
    }

    if (story['type'] == 'video') {
      try {
        final url = story['media'] ?? '';
        if (url.toString().isNotEmpty) {
          _videoController = VideoPlayerController.network(url);
          _videoController!.initialize().then((_) {
            if (!mounted) return;
            _videoController!.addListener(_videoListenerSafe);
            final dur = _videoController!.value.duration;
            _animationController.duration = (dur.inMilliseconds > 0) ? dur : const Duration(seconds: 5);
            _videoController!.play();
            _animationController.forward(from: 0.0);
            setState(() {});
          }).catchError((err) {
            debugPrint('Video init error: $err');
            _animationController.duration = const Duration(seconds: 5);
            _animationController.forward();
          });
        } else {
          // invalid URL - play as image fallback
          _animationController.duration = const Duration(seconds: 5);
          _animationController.forward();
        }
      } catch (e) {
        debugPrint('Video load error: $e');
        _animationController.duration = const Duration(seconds: 5);
        _animationController.forward();
      }
    } else {
      _animationController.duration = const Duration(seconds: 5);
      _animationController.forward();
    }
  }

  void _videoListenerSafe() {
    if (!mounted) return;
    setState(() {});
  }

  void _nextStory() {
    if (_activeStories.isEmpty) {
      Navigator.pop(context);
      return;
    }
    if (_currentIndex < _activeStories.length - 1) {
      _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeIn);
    } else {
      Navigator.pop(context);
    }
  }

  void _previousStory() {
    if (_currentIndex > 0) {
      _pageController.previousPage(duration: const Duration(milliseconds: 300), curve: Curves.easeIn);
    }
  }

  void _pause() {
    if (_isPaused) return;
    _isPaused = true;
    _animationController.stop();
    if (_videoController != null && _videoController!.value.isPlaying) _videoController!.pause();
    setState(() {});
  }

  void _resume() {
    if (!_isPaused) return;
    _isPaused = false;
    if (_videoController != null && _videoController!.value.isInitialized) {
      _videoController!.play();
      final pos = _videoController!.value.position;
      final dur = _videoController!.value.duration;
      if (dur.inMilliseconds > 0) {
        _animationController.duration = dur;
        final double value = pos.inMilliseconds / dur.inMilliseconds;
        _animationController.forward(from: value.clamp(0.0, 1.0));
      } else {
        _animationController.forward();
      }
    } else {
      _animationController.forward();
    }
    setState(() {});
  }

  void _deleteStory(int index) {
    if (index < 0 || index >= _activeStories.length) return;
    final story = _activeStories[index];
    if (story['userId'] == widget.currentUserId) {
      FirebaseFirestore.instance.collection('stories').doc(story['id']).delete();
      setState(() {
        _activeStories.removeAt(index);
        if (_activeStories.isEmpty) {
          Navigator.pop(context);
          return;
        }
        _currentIndex = index.clamp(0, _activeStories.length - 1);
        _pageController.jumpToPage(_currentIndex);
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Story deleted")));
      _loadStory(_currentIndex);
    }
  }

  void _updateChatWithInteraction(String type, Map<String, dynamic> data) {
    if (widget.onStoryInteraction != null && _activeStories.isNotEmpty) {
      widget.onStoryInteraction!(type, {
        'storyUser': _activeStories[_currentIndex]['user'],
        'storyUserId': _activeStories[_currentIndex]['userId'],
        'content': data['content'],
        'timestamp': DateTime.now().toIso8601String(),
        'storyId': _activeStories[_currentIndex]['id'],
      });
    }
  }

  Future<void> _openCommentsSheet() async {
    if (_activeStories.isEmpty) return;
    final story = _activeStories[_currentIndex];
    final storyId = story['id'] as String? ?? '';
    final caption = (story['caption'] ?? '').toString();

    _pause();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (context) {
        final commentController = TextEditingController();
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: FractionallySizedBox(
            heightFactor: 0.75,
            child: Column(
              children: [
                Container(height: 6, width: 48, margin: const EdgeInsets.symmetric(vertical: 10), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: Row(
                    children: [
                      Expanded(child: Text(caption.isEmpty ? 'No caption' : caption, style: const TextStyle(color: Colors.white70))),
                      if (story['userId'] == widget.currentUserId)
                        TextButton(onPressed: () {
                          Navigator.of(context).pop();
                          _showEditCaptionDialog(storyId, story);
                        }, child: const Text('Edit', style: TextStyle(color: Colors.white70))),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: (storyId.isNotEmpty)
                        ? FirebaseFirestore.instance.collection('stories').doc(storyId).collection('comments').orderBy('timestamp', descending: true).snapshots()
                        : const Stream.empty(),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        debugPrint('comments stream error: ${snap.error}');
                        // try to extract an index link from the error and show a helpful button
                        final indexUrl = _extractIndexUrlFromError(snap.error);
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20.0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('Failed to load comments', style: TextStyle(color: Colors.white)),
                                const SizedBox(height: 12),
                                if (indexUrl != null) ...[
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.link),
                                    label: const Text('Open index in Firebase Console'),
                                    onPressed: () async {
                                      await _launchUrl(indexUrl);
                                    },
                                  ),
                                  const SizedBox(height: 8),
                                  TextButton(
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(text: indexUrl));
                                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Index link copied to clipboard')));
                                    },
                                    child: const Text('Copy link'),
                                  ),
                                ] else
                                  Text(snap.error.toString(), style: const TextStyle(color: Colors.white70)),
                              ],
                            ),
                          ),
                        );
                      }
                      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                      final docs = snap.data!.docs;
                      if (docs.isEmpty) return const Center(child: Text('No comments', style: TextStyle(color: Colors.white70)));
                      return ListView.separated(
                        itemCount: docs.length,
                        separatorBuilder: (_, __) => const Divider(color: Colors.white10),
                        itemBuilder: (context, i) {
                          final d = docs[i].data() as Map<String, dynamic>;
                          return ListTile(
                            leading: CircleAvatar(backgroundImage: NetworkImage(d['userAvatar'] ?? 'https://via.placeholder.com/100')),
                            title: Text(d['username'] ?? 'Unknown', style: const TextStyle(color: Colors.white)),
                            subtitle: Text(d['text'] ?? '', style: const TextStyle(color: Colors.white70)),
                            trailing: Text(
                              (() {
                                try {
                                  final t = DateTime.parse(d['timestamp'] ?? DateTime.now().toIso8601String());
                                  final diff = DateTime.now().difference(t);
                                  if (diff.inHours < 1) return '${diff.inMinutes}m';
                                  if (diff.inDays < 1) return '${diff.inHours}h';
                                  return '${diff.inDays}d';
                                } catch (_) {
                                  return '';
                                }
                              })(),
                              style: const TextStyle(color: Colors.white38, fontSize: 12),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        controller: commentController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(hintText: 'Write a comment', hintStyle: const TextStyle(color: Colors.white54), filled: true, fillColor: Colors.white12, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none)),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send, color: Colors.white),
                      onPressed: () async {
                        final text = commentController.text.trim();
                        if (text.isEmpty) return;
                        if (storyId.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Unable to post comment')));
                          return;
                        }
                        try {
                          await FirebaseFirestore.instance.collection('stories').doc(storyId).collection('comments').add({
                            'text': text,
                            'username': widget.currentUserId, // consider storing username instead
                            'userAvatar': '', // optionally pass avatar url
                            'timestamp': DateTime.now().toIso8601String(),
                          });
                          commentController.clear();
                        } catch (e) {
                          debugPrint('comment post error: $e');
                          // If posting fails due to missing index rules (rare for add), still attempt to show helpful link
                          await _handleFirestoreIndexError(e);
                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to post comment')));
                        }
                      },
                    )
                  ]),
                )
              ],
            ),
          ),
        );
      },
    );
    _resume();
  }

  Future<void> _showEditCaptionDialog(String storyId, Map<String, dynamic> story) async {
    final editController = TextEditingController(text: (story['caption'] ?? '').toString());
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit caption'),
        content: TextField(controller: editController, decoration: const InputDecoration(hintText: 'Caption')),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(editController.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (result != null) {
      try {
        await FirebaseFirestore.instance.collection('stories').doc(storyId).update({'caption': result});
        setState(() {
          final idx = _activeStories.indexWhere((s) => (s['id'] as String?) == storyId);
          if (idx != -1) _activeStories[idx]['caption'] = result;
        });
      } catch (e) {
        debugPrint('Failed to update caption: $e');
        // If update fails with index error (unlikely), help the user
        await _handleFirestoreIndexError(e);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to update caption')));
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _animationController.dispose();
    try {
      _videoController?.removeListener(_videoListenerSafe);
    } catch (_) {}
    try {
      _videoController?.dispose();
    } catch (_) {}
    _replyController.dispose();
    _replyFocusNode.dispose();
    super.dispose();
  }

  /// Prefer profile avatar for a user. If missing, fall back to the first available story thumbnail for that user.
  String? _getAvatarForIndex(int index) {
    if (_activeStories.isEmpty) return null;
    final userId = (_activeStories[index]['userId'] ?? '').toString();
    if (userId.isEmpty) return _activeStories[index]['userAvatar']?.toString();
    // search for any story of same user that has a userAvatar set
    for (var s in _activeStories) {
      if ((s['userId'] ?? '').toString() == userId) {
        final ua = (s['userAvatar'] ?? '').toString();
        if (ua.isNotEmpty) return ua;
      }
    }
    // fallback: use current story's media as a visual if it's an image
    final cur = _activeStories[index];
    final media = (cur['media'] ?? '').toString();
    final type = (cur['type'] ?? '').toString().toLowerCase();
    if (media.isNotEmpty && type == 'photo') return media;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_activeStories.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: Text("No active stories", style: TextStyle(color: Colors.white))),
      );
    }
    final story = _activeStories[_currentIndex];
    final isOwner = story['userId'] == widget.currentUserId;

    // avatar URL resolution: prefer user's profile avatar; fallback to image thumbnail if available
    final avatarUrl = _getAvatarForIndex(_currentIndex) ?? '';

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: (details) {
          if (details.primaryVelocity != null) {
            if (details.primaryVelocity! > 0) {
              _previousStory();
            } else if (details.primaryVelocity! < 0) {
              _nextStory();
            }
          }
        },
        onVerticalDragEnd: (details) {
          if (details.primaryVelocity != null && details.primaryVelocity! < -200) {
            _openCommentsSheet();
          }
        },
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: _activeStories.length,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (index) {
                setState(() => _currentIndex = index);
                _loadStory(index);
              },
              itemBuilder: (context, index) {
                final s = _activeStories[index];
                final type = (s['type'] ?? '').toString().toLowerCase();
                final media = (s['media'] ?? '').toString();
                final isVideoThisIndex = type == 'video' && index == _currentIndex && _videoController != null && _videoController!.value.isInitialized;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    // video (when initialized & active) else image
                    Center(
                      child: isVideoThisIndex
                          ? AspectRatio(aspectRatio: _videoController!.value.aspectRatio, child: VideoPlayer(_videoController!))
                          : (media.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: media,
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
                                  errorWidget: (context, url, error) => const Center(child: Icon(Icons.broken_image, size: 40, color: Colors.white)),
                                )
                              : Container(color: Colors.black)),
                    ),

                    // dark gradient top/bottom so captions are readable
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black.withOpacity(0.35), Colors.transparent, Colors.black.withOpacity(0.45)],
                          stops: const [0.0, 0.55, 1.0],
                        ),
                      ),
                    ),

                    // caption (compact) - tap to expand via comments sheet
                    if ((s['caption'] ?? '').toString().isNotEmpty)
                      Positioned(
                        bottom: 90,
                        left: 16,
                        right: 16,
                        child: GestureDetector(
                          onTap: _openCommentsSheet,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                            child: Text(
                              s['caption'],
                              style: const TextStyle(color: Colors.white, fontSize: 15),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),

            // top controls + progress bars
            Positioned(
              top: 36,
              left: 12,
              right: 12,
              child: Column(
                children: [
                  // progress indicators across the activeStories list
                  Row(
                    children: List.generate(_activeStories.length, (i) {
                      double progress;
                      if (i < _currentIndex) {
                        progress = 1.0;
                      } else if (i == _currentIndex) {
                        progress = _animationController.value;
                      } else {
                        progress = 0.0;
                      }
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2.0),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: progress,
                              backgroundColor: Colors.white12,
                              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                              minHeight: 3,
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      // avatar (profile pic preferred)
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: Colors.grey[800],
                        backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
                        child: avatarUrl.isEmpty ? Text((story['user'] ?? 'U').toString()[0].toUpperCase()) : null,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          story['user'] ?? 'Unknown',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),

                      // Play All toggle & loading indicator
                      if (!_playAll)
                        TextButton(
                          onPressed: () async {
                            setState(() => _playAll = true);
                            await _fetchAllActiveStories();
                          },
                          child: _isLoadingAll ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Play all', style: TextStyle(color: Colors.white70)),
                        )
                      else
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _playAll = false;
                              _activeStories = List<Map<String, dynamic>>.from(widget.stories);
                              _currentIndex = 0;
                              _pageController.jumpToPage(0);
                              _loadStory(0);
                            });
                          },
                          child: const Text('Stop all', style: TextStyle(color: Colors.white70)),
                        ),

                      // Owner actions & overflow menu
                      PopupMenuButton<String>(
                        color: Colors.grey[900],
                        icon: const Icon(Icons.more_vert, color: Colors.white),
                        onSelected: (v) {
                          if (v == 'delete') _deleteStory(_currentIndex);
                          if (v == 'edit' && story['userId'] == widget.currentUserId) _showEditCaptionDialog(story['id']?.toString() ?? '', story);
                        },
                        itemBuilder: (_) {
                          final items = <PopupMenuEntry<String>>[];
                          if (story['userId'] == widget.currentUserId) {
                            items.add(const PopupMenuItem(value: 'edit', child: Text('Edit caption', style: TextStyle(color: Colors.white))));
                            items.add(const PopupMenuItem(value: 'delete', child: Text('Delete story', style: TextStyle(color: Colors.redAccent))));
                          } else {
                            items.add(const PopupMenuItem(value: 'report', child: Text('Report', style: TextStyle(color: Colors.white))));
                          }
                          return items;
                        },
                      ),

                      // always show close button
                      IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
                    ],
                  ),
                ],
              ),
            ),

            // bottom quick actions: like, comment, share OR reply input for non-owner
            Positioned(
              bottom: 24,
              left: 16,
              right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isOwner) ...[
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      IconButton(
                        icon: const Icon(Icons.favorite_border, color: Colors.white),
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Liked story by ${story['user']}')));
                          _updateChatWithInteraction('like', {'content': ''});
                        },
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        icon: const Icon(Icons.comment, color: Colors.white),
                        onPressed: _openCommentsSheet,
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        icon: const Icon(Icons.share, color: Colors.white),
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Shared story')));
                          _updateChatWithInteraction('share', {'content': ''});
                        },
                      ),
                    ]),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _replyController,
                      focusNode: _replyFocusNode,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      decoration: InputDecoration(
                        hintText: 'Reply',
                        hintStyle: const TextStyle(color: Colors.white70),
                        filled: true,
                        fillColor: Colors.black54,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.send, color: Colors.white70),
                          onPressed: () {
                            final text = _replyController.text.trim();
                            if (text.isEmpty) return;
                            _updateChatWithInteraction('reply', {'content': text});
                            _replyController.clear();
                            FocusScope.of(context).unfocus();
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Replied to ${story['user']}')));
                          },
                        ),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (value) {
                        final text = value.trim();
                        if (text.isEmpty) return;
                        _updateChatWithInteraction('reply', {'content': text});
                        _replyController.clear();
                        FocusScope.of(context).unfocus();
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Replied to ${story['user']}')));
                      },
                    ),
                  ] else
                    GestureDetector(
                      onTap: _openCommentsSheet,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(10)),
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
                          Icon(Icons.info_outline, color: Colors.white70, size: 18),
                          SizedBox(width: 8),
                          Text('Tap to view comments & edit caption', style: TextStyle(color: Colors.white70)),
                        ]),
                      ),
                    ),
                ],
              ),
            ),

            // Long-press to pause overlay
            Positioned.fill(
              child: GestureDetector(
                onLongPress: () => _pause(),
                onLongPressUp: () => _resume(),
                behavior: HitTestBehavior.translucent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
