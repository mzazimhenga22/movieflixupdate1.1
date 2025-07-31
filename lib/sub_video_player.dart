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
  // ignore: unused_field
  String? _selectedAudioTrack; // Retained for future track display
  // ignore: unused_field
  String? _selectedSubtitleTrack; // Retained for future track display

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupController();
    _loadResumePosition();
    _loadDownloadState();
  }

  Future<void> _setupController() async {
    if (!widget.controller.value.isInitialized) {
      await widget.controller.initialize();
    }

    if (widget.enableSkipIntro && widget.chapters != null) {
      _prepareSkip();
      widget.controller.addListener(_checkSkipIntro);
    }

    if (widget.audioTracks != null && widget.audioTracks!.isNotEmpty) {
      _selectedAudioTrack = widget.audioTracks!.first.label;
    }
    if (widget.subtitleTracks != null && widget.subtitleTracks!.isNotEmpty) {
      _selectedSubtitleTrack = widget.subtitleTracks!.first.label;
    }

    widget.controller.addListener(_savePosition);

    setState(() => _isInitialized = true);
    if (_resumePosition != null) {
      await widget.controller.seekTo(_resumePosition!);
    }
    await widget.controller.play();
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
    }
  }

  void _savePosition() async {
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
    // TODO: Implement actual download logic (e.g., save video file locally)
    await prefs.setBool('${widget.videoUrl}_downloaded', newState);
    setState(() {
      _isDownloaded = newState;
    });
  }

  void _selectAudioTrack(String? label) {
    if (label == null || widget.audioTracks == null) return;
    final track = widget.audioTracks!.firstWhere(
      (t) => t.label == label,
      orElse: () => widget.audioTracks!.first,
    );
    // TODO: Implement platform-specific audio track switching
    setState(() {
      _selectedAudioTrack = track.label;
    });
  }

  void _selectSubtitleTrack(String? label) {
    if (label == null || widget.subtitleTracks == null) return;
    final track = widget.subtitleTracks!.firstWhere(
      (t) => t.label == label,
      orElse: () => widget.subtitleTracks!.first,
    );
    // TODO: Implement subtitle track switching
    setState(() {
      _selectedSubtitleTrack = track.label;
    });
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_savePosition);
    widget.controller.removeListener(_checkSkipIntro);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) return const Center(child: CircularProgressIndicator());

    return Stack(
      children: [
        AspectRatio(
          aspectRatio: widget.controller.value.aspectRatio,
          child: VideoPlayer(widget.controller),
        ),
        _buildControls(),
      ],
    );
  }

  Widget _buildControls() {
    return Positioned(
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
                  color: Colors.white,
                ),
                onPressed: () {
                  setState(() {
                    widget.controller.value.isPlaying ? widget.controller.pause() : widget.controller.play();
                  });
                },
              ),
              onFocusChange: (hasFocus) {
                if (hasFocus) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() {});
                    }
                  });
                }
              },
              onKeyEvent: (node, event) {
                if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                  setState(() {
                    widget.controller.value.isPlaying ? widget.controller.pause() : widget.controller.play();
                  });
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
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        setState(() {});
                      }
                    });
                  }
                },
                onKeyEvent: (node, event) {
                  if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
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
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        setState(() {});
                      }
                    });
                  }
                },
                onKeyEvent: (node, event) {
                  if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                    _resume();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
              ),
            if (widget.audioTracks != null && widget.audioTracks!.isNotEmpty)
              Focus(
                child: IconButton(
                  icon: const Icon(Icons.audiotrack, color: Colors.white),
                  onPressed: _showAudioTrackMenu,
                ),
                onFocusChange: (hasFocus) {
                  if (hasFocus) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        setState(() {});
                      }
                    });
                  }
                },
                onKeyEvent: (node, event) {
                  if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                    _showAudioTrackMenu();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
              ),
            if (widget.subtitleTracks != null && widget.subtitleTracks!.isNotEmpty)
              Focus(
                child: IconButton(
                  icon: const Icon(Icons.subtitles, color: Colors.white),
                  onPressed: _showSubtitleTrackMenu,
                ),
                onFocusChange: (hasFocus) {
                  if (hasFocus) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        setState(() {});
                      }
                    });
                  }
                },
                onKeyEvent: (node, event) {
                  if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
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
                    color: Colors.white,
                  ),
                  onPressed: _toggleDownload,
                ),
                onFocusChange: (hasFocus) {
                  if (hasFocus) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        setState(() {});
                      }
                    });
                  }
                },
                onKeyEvent: (node, event) {
                  if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                    _toggleDownload();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
              ),
            if (widget.enablePiP)
              Focus(
                child: IconButton(
                  icon: const Icon(Icons.picture_in_picture, color: Colors.white),
                  onPressed: _enterPiP,
                ),
                onFocusChange: (hasFocus) {
                  if (hasFocus) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        setState(() {});
                      }
                    });
                  }
                },
                onKeyEvent: (node, event) {
                  if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                    _enterPiP();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
              ),
          ],
        ),
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