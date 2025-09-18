// story_player_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

class StoryPlayerScreen extends StatefulWidget {
  final String videoUrl;
  final String storyTitle;
  final String storyDescription;
  final int durationSeconds;
  final List<Map<String, dynamic>>? stories;
  final int currentIndex;

  const StoryPlayerScreen({
    super.key,
    required this.videoUrl,
    required this.storyTitle,
    required this.storyDescription,
    this.durationSeconds = 30,
    this.stories,
    this.currentIndex = 0,
  });

  @override
  _StoryPlayerScreenState createState() => _StoryPlayerScreenState();
}

class _StoryPlayerScreenState extends State<StoryPlayerScreen> {
  late final YoutubePlayerController _controller;
  Timer? _timer;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0.0);
  late final int _storyDuration;
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  bool _isPlaying = true;
  bool _showControls = false;
  Timer? _hideControlsTimer;

  @override
  void initState() {
    super.initState();
    _storyDuration = widget.durationSeconds;
    final videoId = YoutubePlayer.convertUrlToId(widget.videoUrl) ?? "";
    _controller = YoutubePlayerController(
      initialVideoId: videoId,
      flags: const YoutubePlayerFlags(
        autoPlay: true,
        mute: false,
        hideControls: true,
        controlsVisibleAtStart: false,
      ),
    );

    // Start progress when player ready & playing
    _controller.addListener(_youtubeListener);
  }

  void _youtubeListener() {
    if (_controller.value.isReady && _controller.value.isPlaying && _timer == null) {
      _startProgressTimer();
      _isPlaying = true;
    }
  }

  void _startProgressTimer() {
    _timer?.cancel();
    _progress.value = 0.0;
    final int totalTicks = _storyDuration * 10; // updates every 100ms
    int ticks = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      ticks++;
      _progress.value = (ticks / totalTicks).clamp(0.0, 1.0);
      if (_progress.value >= 1.0) {
        _timer?.cancel();
        _goToNextStory();
      }
    });
  }

  void _stopProgressTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _togglePlayPause() {
    if (_controller.value.isPlaying) {
      _controller.pause();
      _stopProgressTimer();
      _isPlaying = false;
    } else {
      _controller.play();
      _startProgressTimer();
      _isPlaying = true;
    }
    setState(() {}); // small UI change (play/pause icon)
  }

  void _goToNextStory() {
    if (widget.stories != null && widget.stories!.isNotEmpty) {
      final nextIndex = widget.currentIndex + 1;
      if (nextIndex < widget.stories!.length &&
          (widget.stories![nextIndex]['videoUrl'] ?? '').isNotEmpty) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => StoryPlayerScreen(
              videoUrl: widget.stories![nextIndex]['videoUrl'] ?? '',
              storyTitle: widget.stories![nextIndex]['title'] ?? '',
              storyDescription: widget.stories![nextIndex]['description'] ?? '',
              durationSeconds: widget.durationSeconds,
              stories: widget.stories,
              currentIndex: nextIndex,
            ),
          ),
        );
        return;
      }
    }
    Navigator.pop(context);
  }

  void _goToPreviousStory() {
    if (widget.stories != null && widget.stories!.isNotEmpty) {
      final prevIndex = widget.currentIndex - 1;
      if (prevIndex >= 0 &&
          (widget.stories![prevIndex]['videoUrl'] ?? '').isNotEmpty) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => StoryPlayerScreen(
              videoUrl: widget.stories![prevIndex]['videoUrl'] ?? '',
              storyTitle: widget.stories![prevIndex]['title'] ?? '',
              storyDescription: widget.stories![prevIndex]['description'] ?? '',
              durationSeconds: widget.durationSeconds,
              stories: widget.stories,
              currentIndex: prevIndex,
            ),
          ),
        );
        return;
      }
    }
    // if already first -> restart
    _progress.value = 0.0;
    _startProgressTimer();
  }

  // segmented handling preserved, but only active when input not focused
  void _onTapDown(TapDownDetails details) {
    final width = MediaQuery.of(context).size.width;
    final dx = details.localPosition.dx; // local to the video area
    if (_inputFocus.hasFocus) {
      // if typing, tapping video area unfocuses (hides keyboard) but doesn't navigate
      FocusScope.of(context).unfocus();
      return;
    }

    if (dx < width / 3) {
      _goToPreviousStory();
    } else if (dx > 2 * width / 3) {
      _goToNextStory();
    } else {
      _togglePlayPause();
    }
  }

  void _showControlsTemporarily() {
    setState(() {
      _showControls = true;
    });
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _hideControlsTimer?.cancel();
    _controller.removeListener(_youtubeListener);
    _controller.pause();
    _controller.dispose();
    _progress.dispose();
    _messageController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Widget _topBar(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // progress bar (small rebuild scope)
            ValueListenableBuilder<double>(
              valueListenable: _progress,
              builder: (context, value, child) {
                return LinearProgressIndicator(
                  value: value,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                  minHeight: 3,
                );
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                InkWell(
                  onTap: () => Navigator.pop(context),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close, color: Colors.white, size: 18),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.storyTitle,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.storyDescription,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<double>(
                  valueListenable: _progress,
                  builder: (context, value, child) {
                    final elapsed = (value * _storyDuration).round();
                    return Text(
                      '$elapsed/${_storyDuration}s',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _rightActions() {
    return Positioned(
      right: 12,
      bottom: 110,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _actionButton(icon: Icons.favorite_border, onTap: () {/* handle like */}),
          const SizedBox(height: 12),
          _actionButton(
            icon: Icons.comment,
            onTap: () {
              FocusScope.of(context).requestFocus(_inputFocus);
            },
          ),
          const SizedBox(height: 12),
          _actionButton(icon: Icons.share, onTap: () {/* share */}),
        ],
      ),
    );
  }

  Widget _actionButton({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Prevent scaffold from resizing when keyboard opens; input will slide over player
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Player (fills background) + video-area gesture detector (below overlays)
          Positioned.fill(
            child: Stack(
              fit: StackFit.expand,
              children: [
                YoutubePlayer(
                  controller: _controller,
                  showVideoProgressIndicator: false,
                  onReady: () {
                    if (_controller.value.isPlaying && _timer == null) {
                      _startProgressTimer();
                      _isPlaying = true;
                    }
                  },
                  bottomActions: const [],
                ),

                // Gesture detector over the video area only (under top/bottom overlays)
                // It captures taps for prev/next/pause but doesn't block the controls placed above.
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _showControlsTemporarily,
                    onDoubleTap: _togglePlayPause,
                    onTapDown: _onTapDown,
                    child: Container(), // transparent capture area
                  ),
                ),
              ],
            ),
          ),

          // Top bar and small progress - on top of video
          Positioned(top: 0, left: 0, right: 0, child: _topBar(context)),

          // Right side actions (on top)
          _rightActions(),

          // center play/pause big icon when controls shown
          if (_showControls)
            Center(
              child: GestureDetector(
                onTap: _togglePlayPause,
                child: Container(
                  decoration: BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                  padding: const EdgeInsets.all(12),
                  child: Icon(
                    _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                    color: Colors.white,
                    size: 56,
                  ),
                ),
              ),
            ),

          // Bottom input bar anchored over player — slides with keyboard without pushing layout
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedPadding(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
              child: SafeArea(
                top: false,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 44,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.white12,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _messageController,
                                  focusNode: _inputFocus,
                                  style: const TextStyle(color: Colors.white),
                                  textInputAction: TextInputAction.send,
                                  onSubmitted: (text) {
                                    if (text.trim().isEmpty) return;
                                    // send message action
                                    _messageController.clear();
                                  },
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    hintText: 'Send a message',
                                    hintStyle: TextStyle(color: Colors.white54),
                                  ),
                                ),
                              ),
                              GestureDetector(
                                onTap: () {
                                  final text = _messageController.text.trim();
                                  if (text.isEmpty) return;
                                  // handle send
                                  _messageController.clear();
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  child: const Icon(Icons.send, color: Colors.white70, size: 20),
                                ),
                              )
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: () {
                          // like action (quick animation could be added)
                        },
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(color: Colors.pinkAccent, borderRadius: BorderRadius.circular(12)),
                          child: const Icon(Icons.favorite, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
