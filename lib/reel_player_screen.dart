// reel_player_screen.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'models/reel.dart';

/// Optimizations:
/// - Heavy URL parsing (extracting YouTube IDs) is performed off the UI isolate
///   using compute() which significantly reduces main-thread work when opening
///   a player with many reels.
/// - Controller creation remains lazy and limited to a small window.
/// - If compute hasn't finished yet, we fall back to the safe runtime parser.

class ReelPlayerScreen extends StatefulWidget {
  final List<Reel> reels;
  final int initialIndex;

  const ReelPlayerScreen({
    super.key,
    required this.reels,
    this.initialIndex = 0,
  });

  @override
  _ReelPlayerScreenState createState() => _ReelPlayerScreenState();
}

class _ReelPlayerScreenState extends State<ReelPlayerScreen> {
  late final PageController _pageController;
  int currentIndex = 0;

  // Keep only a small window of controllers in memory
  final Map<int, YoutubePlayerController> _controllers = {};
  static const int _preloadRange = 1; // current ±1 — keep low for smoothness

  // Heavy parsing result: video IDs extracted off the UI isolate
  List<String> _videoIds = [];
  bool _videoIdsReady = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    currentIndex = widget.initialIndex.clamp(0, widget.reels.length - 1);
    _pageController = PageController(initialPage: currentIndex, viewportFraction: 1.0);

    // Start background parsing of video IDs (heavy work) as soon as possible.
    _prepareVideoIdsInBackground();

    // Ensure controllers for initial window (creation is cheap since it only uses IDs)
    // If video IDs aren't ready yet, _ensureControllersFor will fall back to runtime parsing.
    _ensureControllersFor(currentIndex);

    // After first frame, attempt to play the focused item if controller is ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _playIndex(currentIndex);
    });
  }

  /// Serialize reels to primitive maps and run compute to extract YouTube IDs off the UI thread.
  Future<void> _prepareVideoIdsInBackground() async {
    if (widget.reels.isEmpty) {
      _videoIds = [];
      _videoIdsReady = true;
      return;
    }

    try {
      // Convert Reels to primitive-only maps so compute can transfer them to the isolate.
      final serialized = widget.reels
          .map<Map<String, String>>((r) => {'videoUrl': r.videoUrl ?? ''})
          .toList();

      final result = await compute(_extractVideoIds, serialized);
      if (_disposed) return;

      // result is List<String> (video ids or empty string for invalid)
      setState(() {
        _videoIds = result;
        _videoIdsReady = true;
      });

      // Now that IDs exist, ensure controllers for the current window are created with those IDs.
      _ensureControllersFor(currentIndex);

      // If the focused controller exists, try to play it (in case previous attempt couldn't).
      Future.delayed(const Duration(milliseconds: 80), () {
        if (!_disposed) _playIndex(currentIndex);
      });
    } catch (e) {
      // Parsing failed in background; we fall back to runtime parsing for each controller creation.
      debugPrint('Video ID extraction failed in background: $e');
      if (!_disposed) {
        setState(() {
          _videoIdsReady = false; // we'll fallback to runtime parsing as needed
        });
      }
    }
  }

  /// Ensure controllers exist for indices in [index - _preloadRange .. index + _preloadRange].
  /// Controllers outside that window are disposed.
  void _ensureControllersFor(int index) {
    final minIndex = (index - _preloadRange).clamp(0, widget.reels.length - 1);
    final maxIndex = (index + _preloadRange).clamp(0, widget.reels.length - 1);
    final active = <int>{for (var i = minIndex; i <= maxIndex; i++) i};

    // Dispose controllers outside the active window
    final toRemove = _controllers.keys.where((k) => !active.contains(k)).toList();
    for (var k in toRemove) {
      try {
        _controllers[k]?.pause();
        _controllers[k]?.dispose();
      } catch (_) {}
      _controllers.remove(k);
    }

    // Create controllers for indices in the active window if missing
    for (var i in active) {
      if (_controllers.containsKey(i)) continue;

      final reel = widget.reels[i];
      String? videoId;

      // Prefer background-extracted IDs if available and valid
      if (_videoIdsReady && i < _videoIds.length && _videoIds[i].isNotEmpty) {
        videoId = _videoIds[i];
      } else {
        // fallback: try runtime parsing (cheap for a small number of controllers)
        videoId = YoutubePlayer.convertUrlToId(reel.videoUrl) ?? "";
      }

      if (videoId.isEmpty) continue;

      final controller = YoutubePlayerController(
        initialVideoId: videoId,
        flags: const YoutubePlayerFlags(
          autoPlay: false, // do not auto-play until focused
          mute: true, // start muted
          hideControls: true,
          controlsVisibleAtStart: false,
          enableCaption: false,
        ),
      );

      _controllers[i] = controller;
    }
  }

  /// Pause & mute other controllers, unmute & play the focused controller.
  void _playIndex(int index) {
    // If controllers for index are not created yet, create the window and return.
    if (!_controllers.containsKey(index)) {
      _ensureControllersFor(index);
      // playing will be attempted after controller is initialized or when user lands on it
      return;
    }

    // Pause and mute other controllers
    _controllers.forEach((k, c) {
      if (k == index) return;
      try {
        c.pause();
        c.mute(); // youtube_player_flutter: mute()
      } catch (_) {}
    });

    final currentController = _controllers[index]!;
    try {
      currentController.unMute();
      currentController.play();
    } catch (_) {
      // timing errors can occur; ignore safely
    }
  }

  void _onPageChanged(int index) {
    if (index == currentIndex) return;

    // Pause previously playing controller (if any)
    try {
      _controllers[currentIndex]?.pause();
    } catch (_) {}

    setState(() {
      currentIndex = index;
      _ensureControllersFor(currentIndex);
    });

    // small delay so the PageView settling doesn't fight playback
    Future.delayed(const Duration(milliseconds: 120), () {
      _playIndex(currentIndex);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _pageController.dispose();
    for (var controller in _controllers.values) {
      try {
        controller.dispose();
      } catch (_) {}
    }
    _controllers.clear();
    super.dispose();
  }

  Widget _buildPage(BuildContext context, int index) {
    final reel = widget.reels[index];
    var controller = _controllers[index];

    // Create lazily if still missing (safe guard); keep creation cheap.
    if (controller == null) {
      String? videoId;

      if (_videoIdsReady && index < _videoIds.length && _videoIds[index].isNotEmpty) {
        videoId = _videoIds[index];
      } else {
        videoId = YoutubePlayer.convertUrlToId(reel.videoUrl);
      }

      if (videoId != null && videoId.isNotEmpty) {
        controller = YoutubePlayerController(
          initialVideoId: videoId,
          flags: const YoutubePlayerFlags(
            autoPlay: false,
            mute: true,
            hideControls: true,
            controlsVisibleAtStart: false,
            enableCaption: false,
          ),
        );
        _controllers[index] = controller;
      } else {
        return const Center(
          child: Text('Invalid video', style: TextStyle(color: Colors.white70)),
        );
      }
    }

    // Show a very cheap UI — YoutubePlayer will render and show its own loader while buffer happens.
    return ReelVideoPage(
      key: ValueKey('reel_video_$index'),
      reel: reel,
      controller: controller,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: NotificationListener<OverscrollIndicatorNotification>(
        onNotification: (overscroll) {
          overscroll.disallowIndicator();
          return true;
        },
        child: Stack(
          children: [
            PageView.builder(
              scrollDirection: Axis.vertical,
              controller: _pageController,
              itemCount: widget.reels.length,
              onPageChanged: _onPageChanged,
              physics: const PageScrollPhysics(),
              itemBuilder: (context, index) {
                return _buildPage(context, index);
              },
            ),
            // simple, cheap page indicator
            Positioned(
              bottom: 18,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(widget.reels.length, (i) {
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: currentIndex == i ? 12 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: currentIndex == i ? Colors.redAccent : Colors.white24,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single reel page that uses YoutubePlayer and very simple overlays (no blur/shadow).
class ReelVideoPage extends StatefulWidget {
  final Reel reel;
  final YoutubePlayerController controller;

  const ReelVideoPage({
    super.key,
    required this.reel,
    required this.controller,
  });

  @override
  _ReelVideoPageState createState() => _ReelVideoPageState();
}

class _ReelVideoPageState extends State<ReelVideoPage> with AutomaticKeepAliveClientMixin {
  bool isLiked = false;
  int likeCount = 42;
  List<String> comments = [
    "Amazing trailer!",
    "Can’t wait to watch this!",
    "Epic scenes!"
  ];
  final TextEditingController commentController = TextEditingController();
  bool _showControls = false;
  Timer? _hideControlTimer;

  @override
  bool get wantKeepAlive => true;

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls) {
      _hideControlTimer?.cancel();
      _hideControlTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _showControls = false;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    commentController.dispose();
    _hideControlTimer?.cancel();
    super.dispose();
  }

  void _toggleLike() {
    setState(() {
      isLiked = !isLiked;
      likeCount += isLiked ? 1 : -1;
    });
  }

  void _addComment() {
    if (commentController.text.trim().isNotEmpty) {
      setState(() {
        comments.add(commentController.text.trim());
      });
      commentController.clear();
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) {
          setState(() {
            comments.removeLast();
          });
        }
      });
    }
  }

  void _showComments() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: 400,
              decoration: BoxDecoration(
                color: const Color.fromARGB(230, 17, 19, 40),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Text(
                      "Comments (${comments.length})",
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: comments.length,
                      itemBuilder: (context, index) {
                        return ListTile(
                          title: Text(comments[index], style: const TextStyle(color: Colors.white70)),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: commentController,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: "Add a comment...",
                              hintStyle: TextStyle(color: Colors.white54),
                              filled: true,
                              fillColor: Colors.white10,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.send, color: Colors.deepPurpleAccent),
                          onPressed: () {
                            _addComment();
                            setModalState(() {});
                          },
                        )
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // YoutubePlayer shows its own buffering UI. We keep overlays simple and cheap.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      child: Stack(
        fit: StackFit.expand,
        children: [
          YoutubePlayer(
            controller: widget.controller,
            showVideoProgressIndicator: true,
            progressIndicatorColor: Colors.redAccent,
            aspectRatio: 9 / 16,
          ),
          if (_showControls)
            Center(
              child: IconButton(
                iconSize: 64,
                icon: Icon(
                  widget.controller.value.isPlaying ? Icons.pause_circle : Icons.play_circle,
                  color: Colors.white70,
                ),
                onPressed: () {
                  setState(() {
                    if (widget.controller.value.isPlaying) {
                      widget.controller.pause();
                    } else {
                      widget.controller.play();
                    }
                    _showControls = false;
                    _hideControlTimer?.cancel();
                  });
                },
              ),
            ),
          // Top bar (lightweight)
          Positioned(
            top: 20,
            left: 8,
            right: 8,
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.reel.movieTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ],
            ),
          ),
          // Right side actions (cheap)
          Positioned(
            bottom: 70,
            right: 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: _toggleLike,
                  icon: Icon(isLiked ? Icons.favorite : Icons.favorite_border, color: isLiked ? Colors.redAccent : Colors.white),
                ),
                const SizedBox(height: 8),
                IconButton(onPressed: _showComments, icon: const Icon(Icons.comment, color: Colors.white)),
                const SizedBox(height: 8),
                IconButton(
                  onPressed: () {
                    // simple share action
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Shared: ${widget.reel.movieTitle}')));
                  },
                  icon: const Icon(Icons.share, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Top-level function used by compute() to extract YouTube IDs.
/// Input: List<dynamic> where each item is a Map with key 'videoUrl' -> String.
/// Output: List<String> of videoIds (empty string for invalid/missing).
List<String> _extractVideoIds(List<dynamic> serialized) {
  final List<String> ids = <String>[];
  final RegExp ytIdReg = RegExp(
    r'(?:v=|\/)([0-9A-Za-z_-]{11})(?:\b|&|$)',
    caseSensitive: false,
  );

  for (var item in serialized) {
    try {
      final url = (item is Map && item['videoUrl'] != null) ? item['videoUrl'].toString() : '';
      if (url.isEmpty) {
        ids.add('');
        continue;
      }
      final m = ytIdReg.firstMatch(url);
      if (m != null && m.groupCount >= 1) {
        ids.add(m.group(1) ?? '');
      } else {
        // Try a few common URL forms fallback parsing
        // e.g., youtu.be/<id>
        final shortMatch = RegExp(r'youtu\.be\/([0-9A-Za-z_-]{11})').firstMatch(url);
        if (shortMatch != null && shortMatch.groupCount >= 1) {
          ids.add(shortMatch.group(1) ?? '');
        } else {
          ids.add('');
        }
      }
    } catch (_) {
      ids.add('');
    }
  }
  return ids;
}