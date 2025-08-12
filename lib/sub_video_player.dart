import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_pip/fl_pip.dart' show FlPiP;
import 'package:flutter/foundation.dart' show kIsWeb;

class SubVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final VideoPlayerController controller;
  final bool enableSkipIntro;
  final List<Chapter>? chapters;
  final bool enablePiP;
  final bool enableOffline;
  final List<AudioTrack>? audioTracks;
  final List<SubtitleTrack>? subtitleTracks;

  const SubVideoPlayer({
    super.key,
    required this.videoUrl,
    required this.controller,
    this.enableSkipIntro = false,
    this.chapters,
    this.enablePiP = false,
    this.enableOffline = false,
    this.audioTracks,
    this.subtitleTracks,
  });

  @override
  SubVideoPlayerState createState() => SubVideoPlayerState();
}

class SubVideoPlayerState extends State<SubVideoPlayer> with WidgetsBindingObserver {
  bool _isInitialized = false;
  bool _showSkipButton = false;
  Duration? _skipStart;
  Duration? _skipEnd;
  Duration? _resumePosition;
  bool _isDownloaded = false;
  Timer? _controlsTimer;
  bool _showControls = false;
  final Color _controlColor = Colors.white;
  final double _iconSize = 30;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupController();
    _loadResumePosition();
    _loadDownloadState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      widget.controller.pause();
      _savePosition();
    } else if (state == AppLifecycleState.resumed) {
      if (_isInitialized && !widget.controller.value.isPlaying) {
        widget.controller.play();
      }
    }
  }

  Future<void> _setupController() async {
    try {
      await widget.controller.initialize(); // Initialize controller
      if (widget.enableSkipIntro && widget.chapters != null) {
        _prepareSkip();
        widget.controller.addListener(_checkSkipIntro);
      }
      widget.controller.addListener(_savePosition);
      setState(() => _isInitialized = true);
      if (_resumePosition != null) {
        await widget.controller.seekTo(_resumePosition!);
      }
      await widget.controller.play();
    } catch (e) {
      if (mounted) {
        setState(() => _isInitialized = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to initialize video: $e')),
        );
      }
    }
  }

  void _prepareSkip() {
    final intro = widget.chapters!.firstWhere(
      (c) => c.title.toLowerCase() == 'intro',
      orElse: () => Chapter(title: 'Intro', start: Duration.zero, end: Duration.zero),
    );
    _skipStart = intro.start;
    _skipEnd = intro.end;
  }

  void _checkSkipIntro() {
    if (!widget.controller.value.isInitialized || _skipStart == null || _skipEnd == null) return;
    final position = widget.controller.value.position;
    setState(() {
      _showSkipButton = position >= _skipStart! && position < _skipEnd!;
    });
  }

  void _skipIntro() {
    if (_skipEnd != null) {
      widget.controller.seekTo(_skipEnd!);
      setState(() => _showSkipButton = false);
    }
  }

  void _resume() {
    if (_resumePosition != null) {
      widget.controller.seekTo(_resumePosition!);
      widget.controller.play();
    }
  }

  Future<void> _savePosition() async {
    if (!widget.controller.value.isInitialized) return;
    final prefs = await SharedPreferences.getInstance();
    final position = widget.controller.value.position;
    await prefs.setInt('${widget.videoUrl}_resume', position.inSeconds);
  }

  Future<void> _loadResumePosition() async {
    final prefs = await SharedPreferences.getInstance();
    final seconds = prefs.getInt('${widget.videoUrl}_resume');
    if (seconds != null) {
      setState(() {
        _resumePosition = Duration(seconds: seconds);
      });
    }
  }

  Future<void> _loadDownloadState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isDownloaded = prefs.getBool('${widget.videoUrl}_downloaded') ?? false;
    });
  }

  Future<void> _toggleDownload() async {
    final prefs = await SharedPreferences.getInstance();
    final newState = !_isDownloaded;
    await prefs.setBool('${widget.videoUrl}_downloaded', newState);
    setState(() {
      _isDownloaded = newState;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(newState ? 'Download started' : 'Download removed')),
      );
    }
  }

  void _selectAudioTrack(String? label) {
    if (label == null || widget.audioTracks == null) return;
    final track = widget.audioTracks!.firstWhere(
      (t) => t.label == label,
      orElse: () => widget.audioTracks!.first,
    );
  }

  void _selectSubtitleTrack(String? label) {
    if (label == null || widget.subtitleTracks == null) return;
    final track = widget.subtitleTracks!.firstWhere(
      (t) => t.label == label,
      orElse: () => widget.subtitleTracks!.first,
    );
  }

  void _showAudioTrackMenu() async {
    if (widget.audioTracks == null || widget.audioTracks!.isEmpty) return;
    final selected = await showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(100, 100, 100, 100),
      items: widget.audioTracks!.map((track) => PopupMenuItem<String>(
        value: track.label,
        child: Text(track.label, style: const TextStyle(color: Colors.white)),
      )).toList(),
      color: Colors.black87,
    );
    if (selected != null) {
      _selectAudioTrack(selected);
      _startHideTimer();
    }
  }

  void _showSubtitleTrackMenu() async {
    if (widget.subtitleTracks == null || widget.subtitleTracks!.isEmpty) return;
    final selected = await showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(100, 100, 100, 100),
      items: widget.subtitleTracks!.map((track) => PopupMenuItem<String>(
        value: track.label,
        child: Text(track.label, style: const TextStyle(color: Colors.white)),
      )).toList(),
      color: Colors.black87,
    );
    if (selected != null) {
      _selectSubtitleTrack(selected);
      _startHideTimer();
    }
  }

  Future<void> _enterPiP() async {
    if (!widget.enablePiP) return;

    if (kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PiP not supported on web')),
        );
      }
      return;
    }

    try {
      final pip = FlPiP();
      await pip.enable();
      widget.controller.pause();
    } catch (e) {
      debugPrint('Failed to enter PiP: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to enter PiP')),
        );
      }
    }
  }

  void _startHideTimer() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_showSkipButton) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls) {
      _startHideTimer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_savePosition);
    widget.controller.removeListener(_checkSkipIntro);
    _controlsTimer?.cancel();
    super.dispose();
  }

  Widget _buildControls() {
    return AnimatedOpacity(
      opacity: _showControls || _showSkipButton ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: Container(
          color: Colors.black54,
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Focus(
                child: IconButton(
                  icon: Icon(
                    widget.controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: _controlColor,
                    size: _iconSize,
                  ),
                  onPressed: () {
                    setState(() {
                      widget.controller.value.isPlaying ? widget.controller.pause() : widget.controller.play();
                    });
                    _startHideTimer();
                  },
                ),
                onFocusChange: (hasFocus) {
                  if (hasFocus) {
                    _startHideTimer();
                  }
                },
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                    setState(() {
                      widget.controller.value.isPlaying ? widget.controller.pause() : widget.controller.play();
                    });
                    _startHideTimer();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
              ),
              if (_showSkipButton && widget.enableSkipIntro && _skipStart != null)
                Focus(
                  child: TextButton(
                    onPressed: _skipIntro,
                    child: const Text('Skip Intro', style: TextStyle(color: Colors.white)),
                  ),
                  onFocusChange: (hasFocus) {
                    if (hasFocus) {
                      _startHideTimer();
                    }
                  },
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                      _skipIntro();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                ),
              if (_resumePosition != null)
                Focus(
                  child: TextButton(
                    onPressed: _resume,
                    child: const Text('Resume', style: TextStyle(color: Colors.white)),
                  ),
                  onFocusChange: (hasFocus) {
                    if (hasFocus) {
                      _startHideTimer();
                    }
                  },
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                      _resume();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                ),
              if (widget.audioTracks != null && widget.audioTracks!.isNotEmpty)
                Focus(
                  child: IconButton(
                    icon: Icon(Icons.audiotrack, color: _controlColor, size: _iconSize),
                    onPressed: _showAudioTrackMenu,
                  ),
                  onFocusChange: (hasFocus) {
                    if (hasFocus) {
                      _startHideTimer();
                    }
                  },
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                      _showAudioTrackMenu();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                ),
              if (widget.subtitleTracks != null && widget.subtitleTracks!.isNotEmpty)
                Focus(
                  child: IconButton(
                    icon: Icon(Icons.subtitles, color: _controlColor, size: _iconSize),
                    onPressed: _showSubtitleTrackMenu,
                  ),
                  onFocusChange: (hasFocus) {
                    if (hasFocus) {
                      _startHideTimer();
                    }
                  },
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                      _showSubtitleTrackMenu();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                ),
              const Spacer(),
              if (widget.enableOffline)
                Focus(
                  child: IconButton(
                    icon: Icon(
                      _isDownloaded ? Icons.download_done : Icons.download,
                      color: _controlColor,
                      size: _iconSize,
                    ),
                    onPressed: _toggleDownload,
                  ),
                  onFocusChange: (hasFocus) {
                    if (hasFocus) {
                      _startHideTimer();
                    }
                  },
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                      _toggleDownload();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                ),
              if (widget.enablePiP)
                Focus(
                  child: IconButton(
                    icon: Icon(Icons.picture_in_picture, color: _controlColor, size: _iconSize),
                    onPressed: _enterPiP,
                  ),
                  onFocusChange: (hasFocus) {
                    if (hasFocus) {
                      _startHideTimer();
                    }
                  },
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                      _enterPiP();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return GestureDetector(
      onTap: _toggleControls,
      child: Stack(
        children: [
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: widget.controller.value.size.width,
                height: widget.controller.value.size.height,
                child: VideoPlayer(widget.controller),
              ),
            ),
          ),
          if (_showControls || _showSkipButton) _buildControls(),
        ],
      ),
    );
  }
}

class Chapter {
  final String title;
  final Duration start;
  final Duration end;
  Chapter({required this.title, required this.start, required this.end});
}

class AudioTrack {
  final String label;
  final String url;
  AudioTrack({required this.label, required this.url});
}

class SubtitleTrack {
  final String label;
  final String url;
  SubtitleTrack({required this.label, required this.url});
}