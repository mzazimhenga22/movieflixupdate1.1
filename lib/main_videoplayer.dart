import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:video_player/video_player.dart';
import 'package:http/http.dart' as http;
import 'package:movie_app/streaming_service.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:system_info/system_info.dart';
import 'sub_video_player.dart';
import 'package:fl_pip/fl_pip.dart' show FlPiP;

class Subtitle {
  final Duration start;
  final Duration end;
  final String text;

  Subtitle({required this.start, required this.end, required this.text});
}

class EpisodeSelectorDialog extends StatefulWidget {
  final List<Map<String, dynamic>> seasons;
  final int currentSeasonNumber;
  final int currentEpisodeNumber;
  final void Function(int seasonNumber, int episodeNumber) onEpisodeSelected;

  const EpisodeSelectorDialog({
    super.key,
    required this.seasons,
    required this.currentSeasonNumber,
    required this.currentEpisodeNumber,
    required this.onEpisodeSelected,
  });

  @override
  EpisodeSelectorDialogState createState() => EpisodeSelectorDialogState();
}

class EpisodeSelectorDialogState extends State<EpisodeSelectorDialog> {
  late int _selectedSeasonNumber;

  @override
  void initState() {
    super.initState();
    _selectedSeasonNumber = widget.currentSeasonNumber;
  }

  @override
  Widget build(BuildContext context) {
    final selectedSeason = widget.seasons.firstWhere(
      (season) => season['season_number'] == _selectedSeasonNumber,
      orElse: () => widget.seasons.first,
    );
    final episodes = selectedSeason['episodes'] as List<dynamic>? ?? [];

    return AlertDialog(
      backgroundColor: Colors.black87,
      title: const Text('Select Episode', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButton<int>(
              value: _selectedSeasonNumber,
              dropdownColor: Colors.black87,
              style: const TextStyle(color: Colors.white),
              items: widget.seasons.map((season) {
                return DropdownMenuItem<int>(
                  value: season['season_number'] as int,
                  child: Text('Season ${season['season_number']}'),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _selectedSeasonNumber = value;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: episodes.length,
                itemBuilder: (context, index) {
                  final episode = episodes[index];
                  final episodeNumber = episode['episode_number'] as int;
                  final isCurrent = _selectedSeasonNumber == widget.currentSeasonNumber &&
                      episodeNumber == widget.currentEpisodeNumber;
                  return ListTile(
                    title: Text(
                      'Episode $episodeNumber: ${episode['name'] ?? 'Episode $episodeNumber'}',
                      style: TextStyle(
                        color: isCurrent ? Colors.grey : Colors.white,
                      ),
                    ),
                    enabled: !isCurrent,
                    onTap: () {
                      if (!isCurrent) {
                        Navigator.pop(context);
                        widget.onEpisodeSelected(_selectedSeasonNumber, episodeNumber);
                      }
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MainVideoPlayer extends StatefulWidget {
  final String videoPath;
  final String title;
  final int releaseYear;
  final bool isFullSeason;
  final List<String> episodeFiles;
  final List<Map<String, dynamic>> similarMovies;
  final String? subtitleUrl;
  final String? localSubtitlePath;
  final bool isHls;
  final bool isLocal;
  final Duration? initialPosition;
  final List<Map<String, dynamic>>? seasons;
  final int? initialSeasonNumber;
  final int? initialEpisodeNumber;
  final bool enableSkipIntro;
  final List<Chapter>? chapters;
  final bool enablePiP;
  final bool enableOffline;
  final List<AudioTrack>? audioTracks;
  final List<SubtitleTrack>? subtitleTracks;

  const MainVideoPlayer({
    super.key,
    required this.videoPath,
    required this.title,
    required this.releaseYear,
    this.isFullSeason = false,
    this.episodeFiles = const [],
    this.similarMovies = const [],
    this.subtitleUrl,
    this.localSubtitlePath,
    required this.isHls,
    this.isLocal = false,
    this.initialPosition,
    this.seasons,
    this.initialSeasonNumber,
    this.initialEpisodeNumber,
    this.enableSkipIntro = false,
    this.chapters,
    this.enablePiP = false,
    this.enableOffline = false,
    this.audioTracks,
    this.subtitleTracks,
  });

  @override
  MainVideoPlayerState createState() => MainVideoPlayerState();
}

class MainVideoPlayerState extends State<MainVideoPlayer> with WidgetsBindingObserver {
  late VideoPlayerController _controller;
  Map<String, dynamic>? _streamingInfo;
  bool _isInitialized = false;
  String? _errorMessage;
  bool _isBuffering = false;
  bool _showControls = false;
  Timer? _hideTimer;
  double _volume = 1.0;
  bool _isMuted = false;
  double _brightness = 0.5;
  bool _isLocked = false;
  bool _isAdjustingBrightness = false;
  bool _isAdjustingVolume = false;
  double? _startX;
  double _playbackSpeed = 1.0;
  List<Subtitle> _subtitles = [];
  String _currentSubtitle = "";
  final List<String> _qualities = ["Auto", "360p", "480p", "720p", "1080p"];
  String _selectedQuality = "Auto";
  Color _controlColor = Colors.white;
  double _iconSize = 30;
  final Map<String, double> _iconSizePresets = {
    'Small': 30,
    'Medium': 44,
    'Large': 63,
  };
  String _iconSizeKey = 'Small';
  String _currentVideoPath = "";
  String _title = "";
  int? _currentEpisodeNumber;
  int? _currentSeasonNumber;
  bool _showNextEpisodeBar = false;
  Map<String, String>? _nextEpisodeData;
  bool _showRecommendationsBar = false;
  Map<String, dynamic>? _recommendationData;
  Timer? _recommendationTimer;
  bool _showSubtitles = true;
  Offset? _lastTapPosition;
  String? _seekFeedback;
  Duration? _seekTargetDuration;
  double? _dragStartX;
  Duration? _dragStartPosition;
  bool _showSkipButton = false;
  Duration? _skipStart;
  Duration? _skipEnd;
  String? _selectedAudioTrack;
  String? _selectedSubtitleTrack;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _title = widget.title;
    _enforceLandscape();
    _initializeVideoPath().then((_) => _initializeVideo());
    _initializeBrightness();
    _loadSubtitles();
    if (widget.enableSkipIntro && widget.chapters != null) {
      _prepareSkip();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      _controller.pause();
      _saveWatchHistory();
    } else if (state == AppLifecycleState.resumed) {
      _enforceLandscape();
      if (_controller.value.isInitialized && !_controller.value.isPlaying) {
        _controller.play();
      }
    }
  }

  Future<void> _saveWatchHistory() async {
    if (!_controller.value.isInitialized) return;
    final prefs = await SharedPreferences.getInstance();
    List<String> jsonList = prefs.getStringList('watchHistory') ?? [];
    final currentPosition = _controller.value.position.inSeconds;
    final duration = _controller.value.duration.inSeconds;

    final historyEntry = {
      'id': widget.title.hashCode.toString(),
      'title': widget.title,
      'releaseYear': widget.releaseYear,
      'media_type': widget.isFullSeason ? 'tv' : 'movie',
      'position': currentPosition,
      'duration': duration,
      'resolution': _selectedQuality,
      'subtitles': _showSubtitles,
      'episodeFiles': widget.isFullSeason ? widget.episodeFiles : [],
      'similarMovies': widget.similarMovies,
      if (widget.isFullSeason) 'season': _currentSeasonNumber ?? 1,
      if (widget.isFullSeason) 'episode': _currentEpisodeNumber ?? 1,
    };

    jsonList.removeWhere((jsonStr) {
      final map = json.decode(jsonStr);
      return map['id'].toString() == historyEntry['id'];
    });

    jsonList.insert(0, json.encode(historyEntry));
    await prefs.setStringList('watchHistory', jsonList);
  }

  Future<void> _enforceLandscape() async {
    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (e) {
      debugPrint('Error setting landscape mode: $e');
    }
  }

  Future<void> _initializeVideoPath() async {
    if (!mounted) return;
    setState(() {
      _errorMessage = null;
      _currentVideoPath = widget.videoPath;
      _currentSeasonNumber = widget.initialSeasonNumber ?? 1;
      _currentEpisodeNumber = widget.initialEpisodeNumber ?? (widget.isFullSeason ? _extractEpisodeNumber(widget.videoPath) : null) ?? 1;
    });
  }

  Future<void> _initializeVideo() async {
    if (_currentVideoPath.isEmpty) {
      if (mounted) {
        setState(() {
          _errorMessage = "No valid video URL or path provided.";
        });
      }
      return;
    }

    try {
      if (widget.isLocal) {
        final file = File(_currentVideoPath);
        if (!await file.exists()) {
          if (mounted) {
            setState(() {
              _errorMessage = "Local file not found: $_currentVideoPath";
            });
          }
          return;
        }
        _controller = VideoPlayerController.file(file);
        _streamingInfo = {'creditsStartTime': null};
      } else {
        final streamingInfo = await StreamingService.getStreamingLink(
          tmdbId: widget.title.hashCode.toString(),
          title: widget.title,
          releaseYear: widget.releaseYear,
          season: _currentSeasonNumber,
          episode: _currentEpisodeNumber,
          resolution: _selectedQuality,
          enableSubtitles: _showSubtitles,
        );
        _streamingInfo = streamingInfo;
        _controller = VideoPlayerController.networkUrl(
          Uri.parse(_currentVideoPath),
          formatHint: widget.isHls ? VideoFormat.hls : VideoFormat.other,
          httpHeaders: {
            'Accept': '*/*',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
          videoPlayerOptions: VideoPlayerOptions(
            allowBackgroundPlayback: false,
            mixWithOthers: false,
          ),
        );
      }

      _controller.addListener(_videoListener);

      await _controller.initialize();
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _volume = _controller.value.volume;
        });
        if (widget.initialPosition != null) {
          await _controller.seekTo(widget.initialPosition!);
        }
        await _controller.play();
        await _controller.setPlaybackSpeed(_playbackSpeed);
        _adjustQualityBasedOnHardware();
        if (widget.audioTracks != null && widget.audioTracks!.isNotEmpty) {
          _selectedAudioTrack = widget.audioTracks!.first.label;
        }
        if (widget.subtitleTracks != null && widget.subtitleTracks!.isNotEmpty) {
          _selectedSubtitleTrack = widget.subtitleTracks!.first.label;
        }
      }
    } catch (error) {
      if (mounted) {
        if (_selectedQuality == "Auto") {
          _selectedQuality = "360p";
          await _fetchNewQualityStream("360p");
        } else {
          final nextQuality = _getNextLowerQuality(_selectedQuality);
          if (nextQuality != null) {
            setState(() {
              _selectedQuality = nextQuality;
            });
            await _fetchNewQualityStream(nextQuality);
          } else {
            setState(() {
              _errorMessage = "Failed to load video: $error";
            });
          }
        }
      }
    }
  }

  Future<void> _adjustQualityBasedOnHardware() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      bool isHighEndTV = false;

      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        final sdkInt = androidInfo.version.sdkInt;
        final cpuCores = SysInfo.processors.length;
        final totalRam = SysInfo.getTotalPhysicalMemory();
        isHighEndTV = sdkInt >= 30 && cpuCores >= 4 && totalRam >= (2 * 1024 * 1024 * 1024);
      } else {
        isHighEndTV = true;
      }

      if (isHighEndTV && _selectedQuality != "1080p") {
        setState(() => _selectedQuality = "1080p");
        await _fetchNewQualityStream("1080p");
      } else if (!isHighEndTV && _selectedQuality != "720p" && _selectedQuality != "480p") {
        setState(() => _selectedQuality = "720p");
        await _fetchNewQualityStream("720p");
      }
    } catch (e) {
      debugPrint('Error adjusting quality: $e');
    }
  }

  String? _getNextLowerQuality(String currentQuality) {
    switch (currentQuality) {
      case "1080p":
        return "720p";
      case "720p":
        return "480p";
      case "480p":
        return "360p";
      default:
        return null;
    }
  }

  void _videoListener() {
    if (mounted) {
      setState(() {
        _isBuffering = _controller.value.isBuffering;
        _updateSubtitle();
        _checkForEndOfContent();
        _checkSkipIntro();
      });
    }
  }

  Future<void> _initializeBrightness() async {
    if (kIsWeb) {
      _brightness = 0.5;
      if (mounted) setState(() {});
      return;
    }
    try {
      _brightness = await ScreenBrightness().application;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Failed to get brightness: $e');
      _brightness = 0.5;
      if (mounted) setState(() {});
    }
  }

  Future<void> _setBrightness(double value) async {
    if (kIsWeb) return;
    try {
      await ScreenBrightness().setApplicationScreenBrightness(value);
    } catch (e) {
      debugPrint('Failed to set brightness: $e');
    }
  }

  Future<void> _loadSubtitles() async {
    String? content;
    if (widget.isLocal && widget.localSubtitlePath != null) {
      try {
        final file = File(widget.localSubtitlePath!);
        if (await file.exists()) {
          content = await file.readAsString();
        } else {
          debugPrint('Local subtitle file not found');
        }
      } catch (e) {
        debugPrint('Failed to load local subtitles: $e');
      }
    } else if (widget.subtitleUrl != null && widget.subtitleUrl!.isNotEmpty) {
      try {
        final response = await http.get(Uri.parse(widget.subtitleUrl!));
        if (response.statusCode == 200) {
          content = utf8.decode(response.bodyBytes);
        } else {
          debugPrint('Failed to fetch network subtitles: ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('Failed to load network subtitles: $e');
      }
    }
    if (content != null && mounted) {
      final subtitleText = content;
      setState(() {
        _subtitles = subtitleText.startsWith('WEBVTT')
            ? _parseVtt(subtitleText)
            : _parseSrt(subtitleText);
      });
    }
  }

  List<Subtitle> _parseSrt(String srt) {
    final List<Subtitle> subtitles = [];
    final regex = RegExp(
        r'(\d+)\s+(\d{2}:\d{2}:\d{2},\d{3})\s+-->\s+(\d{2}:\d{2}:\d{2},\d{3})\s+([\s\S]*?)(?=\n\n|\$)');
    final matches = regex.allMatches(srt);
    for (final match in matches) {
      final start = _parseDuration(match.group(2)!);
      final end = _parseDuration(match.group(3)!);
      final text = match.group(4)!.trim().replaceAll('\n', ' ');
      subtitles.add(Subtitle(start: start, end: end, text: text));
    }
    return subtitles;
  }

  List<Subtitle> _parseVtt(String vtt) {
    final List<Subtitle> subtitles = [];
    final regex = RegExp(
        r'(\d{2}:\d{2}:\d{2}\.\d{3})\s+-->\s+(\d{2}:\d{2}:\d{2}\.\d{3})\s+([\s\S]*?)(?=\n\n|\$)');
    final matches = regex.allMatches(vtt);
    for (final match in matches) {
      final start = _parseDuration(match.group(1)!);
      final end = _parseDuration(match.group(2)!);
      final text = match.group(3)!.trim().replaceAll('\n', ' ');
      subtitles.add(Subtitle(start: start, end: end, text: text));
    }
    return subtitles;
  }

  Duration _parseDuration(String timeString) {
    final parts = timeString.split(RegExp(r'[:,]'));
    return Duration(
      hours: int.parse(parts[0]),
      minutes: int.parse(parts[1]),
      seconds: int.parse(parts[2]),
      milliseconds: int.parse(parts[3]),
    );
  }

  void _updateSubtitle() {
    if (!_showSubtitles || _subtitles.isEmpty || !_controller.value.isInitialized) {
      return;
    }
    final position = _controller.value.position;
    final current = _subtitles.firstWhere(
        (sub) => position >= sub.start && position <= sub.end,
        orElse: () => Subtitle(start: Duration.zero, end: Duration.zero, text: ""));
    if (mounted) {
      setState(() {
        _currentSubtitle = current.text;
      });
    }
  }

  void _prepareSkip() {
    final intro = widget.chapters!.firstWhere(
      (c) => c.title.toLowerCase() == 'intro',
      orElse: () => Chapter(title: 'Intro', start: Duration.zero, end: Duration.zero),
    );
    _skipStart = intro.start;
    _skipEnd = intro.end;
    _controller.addListener(_checkSkipIntro);
  }

  void _checkSkipIntro() {
    if (!widget.enableSkipIntro || !_controller.value.isInitialized || _skipStart == null || _skipEnd == null) return;
    final position = _controller.value.position;
    setState(() {
      _showSkipButton = position >= _skipStart! && position < _skipEnd!;
    });
  }

  void _skipIntro() {
    if (_skipEnd != null) {
      _controller.seekTo(_skipEnd!);
      setState(() => _showSkipButton = false);
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_isLocked) {
        setState(() {
          _showControls = false;
          if (_showNextEpisodeBar || _showRecommendationsBar) {
            _showControls = true;
          }
        });
      }
    });
  }

  void _toggleControls() {
    if (!mounted || _isLocked) return;
    setState(() {
      _showControls = true;
      if (_recommendationTimer != null) {
        _recommendationTimer!.cancel();
        _showRecommendationsBar = false;
      }
    });
    _startHideTimer();
  }

  Future<void> _retryLoad() async {
    if (!mounted) return;
    setState(() {
      _errorMessage = null;
      _isInitialized = false;
    });
    await _initializeVideoPath();
    await _initializeVideo();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _recommendationTimer?.cancel();
    _controller.removeListener(_videoListener);
    _controller.removeListener(_checkSkipIntro);
    _controller.pause().then((_) => _controller.dispose());
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = duration.inSeconds % 60;
    return hours > 0
        ? '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}'
        : '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _dragStartX = details.globalPosition.dx;
    _dragStartPosition = _controller.value.position;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_controller.value.isInitialized || _dragStartX == null || _dragStartPosition == null) {
      return;
    }
    final screenWidth = MediaQuery.of(context).size.width;
    final dx = details.globalPosition.dx - _dragStartX!;
    final offset = dx / screenWidth * _controller.value.duration.inSeconds;
    final newPosition = (_dragStartPosition!.inSeconds + offset).clamp(0, _controller.value.duration.inSeconds);
    setState(() {
      _seekTargetDuration = Duration(seconds: newPosition.round());
      _showControls = true;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_seekTargetDuration != null) {
      _controller.seekTo(_seekTargetDuration!);
      setState(() {
        _seekTargetDuration = null;
      });
      _dragStartX = null;
      _dragStartPosition = null;
      _startHideTimer();
    }
  }

  void _onVerticalDragStart(DragStartDetails details) {
    _startX = details.globalPosition.dx;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;
    final delta = -details.delta.dy / screenHeight;
    if (_startX == null) return;
    if (_startX! < screenWidth / 2 && !kIsWeb) {
      setState(() {
        _brightness = (_brightness + delta).clamp(0.0, 1.0);
        _isAdjustingBrightness = true;
        _showControls = true;
      });
      _setBrightness(_brightness);
    } else {
      setState(() {
        _volume = (_volume + delta).clamp(0.0, 1.0);
        _controller.setVolume(_volume);
        _isMuted = _volume == 0;
        _isAdjustingVolume = true;
        _showControls = true;
      });
    }
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    setState(() {
      _isAdjustingBrightness = false;
      _isAdjustingVolume = false;
    });
    _startHideTimer();
  }

  void _showQualityMenu() async {
    final quality = await showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(100, 100, 100, 100),
      items: _qualities.map((q) => PopupMenuItem<String>(value: q, child: Text(q))).toList(),
    );
    if (quality != null && quality != _selectedQuality) {
      setState(() {
        _selectedQuality = quality;
      });
      await _fetchNewQualityStream(quality);
      _startHideTimer();
    }
  }

  Future<void> _fetchNewQualityStream(String quality) async {
    try {
      final streamingInfo = await StreamingService.getStreamingLink(
        tmdbId: widget.title.hashCode.toString(),
        title: widget.title,
        releaseYear: widget.releaseYear,
        season: _currentSeasonNumber,
        episode: _currentEpisodeNumber,
        resolution: quality == "Auto" ? "auto" : quality,
        enableSubtitles: _showSubtitles,
      );
      _streamingInfo = streamingInfo;
      final newUrl = streamingInfo['url'] ?? _currentVideoPath;
      final newSubtitleUrl = streamingInfo['subtitleUrl'];
      final isHls = streamingInfo['type'] == 'm3u8';
      await _switchVideo(newUrl, widget.title, newSubtitleUrl: newSubtitleUrl, isHls: isHls);
    } catch (e) {
      debugPrint('Failed to fetch new quality stream: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to switch quality: $e")),
        );
      }
    }
  }

  void _showSpeedMenu() async {
    final speed = await showMenu<double>(
      context: context,
      position: const RelativeRect.fromLTRB(100, 100, 100, 100),
      items: [
        const PopupMenuItem(value: 0.5, child: Text('0.5x')),
        const PopupMenuItem(value: 1.0, child: Text('1.0x')),
        const PopupMenuItem(value: 1.25, child: Text('1.25x')),
        const PopupMenuItem(value: 1.5, child: Text('1.5x')),
        const PopupMenuItem(value: 1.75, child: Text('1.75x')),
        const PopupMenuItem(value: 2.0, child: Text('2.0x')),
      ],
    );
    if (speed != null) {
      setState(() {
        _playbackSpeed = speed;
      });
      await _controller.setPlaybackSpeed(speed);
      _startHideTimer();
    }
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
      _controller.pause();
    } catch (e) {
      debugPrint('Failed to enter PiP: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to enter PiP')),
        );
      }
    }
  }

  void _showSettingsMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Customize Player', style: TextStyle(color: Colors.white, fontSize: 18)),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Control Color:', style: TextStyle(color: Colors.white)),
                  const SizedBox(width: 8),
                  DropdownButton<Color>(
                    value: _controlColor,
                    dropdownColor: Colors.black87,
                    items: const [
                      DropdownMenuItem(
                          value: Colors.white, child: Text('White', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(
                          value: Colors.yellow, child: Text('Yellow', style: TextStyle(color: Colors.yellow))),
                      DropdownMenuItem(value: Colors.red, child: Text('Red', style: TextStyle(color: Colors.red))),
                    ],
                    onChanged: (color) {
                      if (mounted) {
                        setState(() {
                          _controlColor = color!;
                        });
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Icon Size:', style: TextStyle(color: Colors.white)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: CupertinoSegmentedControl<String>(
                      groupValue: _iconSizeKey,
                      children: _iconSizePresets.map((label, size) {
                        return MapEntry(
                          label,
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                            child: Text(label, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
                          ),
                        );
                      }),
                      onValueChanged: (value) {
                        if (mounted) {
                          setState(() {
                            _iconSizeKey = value;
                            _iconSize = _iconSizePresets[value]!;
                          });
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Focus(
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close Settings'),
                ),
                onFocusChange: (hasFocus) {
                  if (hasFocus) {
                    _startHideTimer();
                  }
                },
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                    Navigator.pop(context);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
              ),
            ],
          ),
        );
      },
    ).whenComplete(_startHideTimer);
  }

  int? _extractEpisodeNumber(String videoPath) {
    final match = RegExp(r'[sS]\d+[eE](\d+)').firstMatch(videoPath);
    return match != null ? int.tryParse(match.group(1)!) : null;
  }

  void _checkForEndOfContent() {
    if (!_controller.value.isInitialized) return;
    final position = _controller.value.position;
    final duration = _controller.value.duration;
    final remaining = duration - position;

    final creditsStartTime = _streamingInfo?['creditsStartTime'] != null
        ? Duration(seconds: _streamingInfo!['creditsStartTime'] as int)
        : duration * 0.93;

    if (position >= creditsStartTime && !_showNextEpisodeBar && widget.isFullSeason) {
      setState(() {
        _showNextEpisodeBar = true;
        _showControls = true;
      });
      _fetchNextEpisode();
    } else if (remaining <= Duration.zero) {
      if (widget.isFullSeason && _nextEpisodeData != null) {
        _playNextEpisode();
      } else if (!widget.isFullSeason && _recommendationData != null) {
        _playRecommendedMovie();
      }
    }
  }

  void _fetchNextEpisode() async {
    if (_currentSeasonNumber == null || _currentEpisodeNumber == null || !widget.isFullSeason || widget.seasons == null) {
      return;
    }
    final currentSeason = widget.seasons!.firstWhere(
      (season) => season['season_number'] == _currentSeasonNumber,
      orElse: () => {},
    );
    final episodes = currentSeason['episodes'] as List<dynamic>? ?? [];
    final currentIndex = episodes.indexWhere((e) => e['episode_number'] == _currentEpisodeNumber);
    if (currentIndex != -1 && currentIndex < episodes.length - 1) {
      final nextEpisode = episodes[currentIndex + 1];
      final nextEpisodeNumber = nextEpisode['episode_number'] as int;
      try {
        final streamingInfo = await StreamingService.getStreamingLink(
          tmdbId: widget.title.hashCode.toString(),
          title: widget.title,
          releaseYear: widget.releaseYear,
          season: _currentSeasonNumber!,
          episode: nextEpisodeNumber,
          resolution: _selectedQuality,
          enableSubtitles: _showSubtitles,
        );
        final nextVideoPath = streamingInfo['url'] ?? '';
        final synopsis = nextEpisode['overview'] ?? 'No synopsis available';
        if (nextVideoPath.isNotEmpty && mounted) {
          setState(() {
            _nextEpisodeData = {
              'videoPath': nextVideoPath,
              'title': '${widget.title} - S${_currentSeasonNumber!.toString().padLeft(2, '0')}E${nextEpisodeNumber.toString().padLeft(2, '0')}',
              'episodeNumber': nextEpisodeNumber.toString(),
              'synopsis': synopsis,
            };
          });
        } else {
          final fallbackVideoPath = 'S${_currentSeasonNumber}E${nextEpisodeNumber}';
          if (mounted) {
            setState(() {
              _nextEpisodeData = {
                'videoPath': fallbackVideoPath,
                'title': '${widget.title} - S${_currentSeasonNumber}E${nextEpisodeNumber}',
                'episodeNumber': nextEpisodeNumber.toString(),
                'synopsis': synopsis,
              };
            });
          }
        }
      } catch (e) {
        debugPrint('Failed to fetch next episode: $e');
        final fallbackVideoPath = 'S${_currentSeasonNumber}E${nextEpisodeNumber}';
        final synopsis = nextEpisode['overview'] ?? 'No synopsis available';
        if (mounted) {
          setState(() {
            _nextEpisodeData = {
              'videoPath': fallbackVideoPath,
              'title': '${widget.title} - S${_currentSeasonNumber}E${nextEpisodeNumber}',
              'episodeNumber': nextEpisodeNumber.toString(),
              'synopsis': synopsis,
            };
          });
        }
      }
    }
  }

  void _showNextEpisodePreview() {
    if (_nextEpisodeData == null) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.black87,
        title: Text(
          _nextEpisodeData!['title'] ?? 'Next Episode',
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          _nextEpisodeData!['synopsis'] ?? 'No synopsis available',
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          Focus(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close', style: TextStyle(color: Colors.white)),
            ),
            onFocusChange: (hasFocus) {
              if (hasFocus) {
                _startHideTimer();
              }
            },
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                Navigator.pop(context);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
          ),
          Focus(
            child: TextButton(
              onPressed: () {
                Navigator.pop(context);
                _playNextEpisode();
              },
              child: const Text('Play Now', style: TextStyle(color: Colors.white)),
            ),
            onFocusChange: (hasFocus) {
              if (hasFocus) {
                _startHideTimer();
              }
            },
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                Navigator.pop(context);
                _playNextEpisode();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
          ),
        ],
      ),
    ).then((_) => _startHideTimer());
  }

  Future<void> _fetchRecommendations() async {
    if (widget.similarMovies.isEmpty) return;
    final recommendation = widget.similarMovies.first;
    try {
      final releaseDate = recommendation['release_date'] as String? ?? recommendation['first_air_date'] as String? ?? '1970-01-01';
      final releaseYear = int.parse(releaseDate.split('-')[0]);
      final streamingInfo = await StreamingService.getStreamingLink(
        tmdbId: recommendation['id'].toString(),
        title: recommendation['title']?.toString() ?? recommendation['name']?.toString() ?? 'Untitled',
        releaseYear: releaseYear,
        resolution: _selectedQuality,
        enableSubtitles: _showSubtitles,
      );
      if (mounted) {
        setState(() {
          _recommendationData = {
            'title': streamingInfo['title'] ?? recommendation['title'] ?? recommendation['name'] ?? 'Untitled',
            'videoPath': streamingInfo['url'] ?? '',
          };
        });
        if (streamingInfo['url'] != null && streamingInfo['url']!.isNotEmpty) {
          _recommendationTimer?.cancel();
          _recommendationTimer = Timer(const Duration(seconds: 10), () {
            if (mounted && _recommendationData != null) {
              _playRecommendedMovie();
            }
          });
        }
      }
    } catch (e) {
      debugPrint('Failed to fetch streaming URL for recommendation: $e');
    }
  }

  void _playRecommendedMovie() {
    if (_recommendationData == null || _recommendationData!['videoPath'].isEmpty) {
      return;
    }
    final nextVideoPath = _recommendationData!['videoPath'];
    final nextTitle = _recommendationData!['title'];
    if (nextVideoPath != null) {
      _switchVideo(nextVideoPath, nextTitle);
    }
  }

  Future<void> _switchVideo(String videoPath, String title, {String? newSubtitleUrl, bool isHls = false}) async {
    if (!mounted) return;
    setState(() {
      _currentVideoPath = videoPath;
      _title = title;
      _showRecommendationsBar = false;
      _recommendationData = null;
      _isInitialized = false;
    });
    await _controller.pause();
    await _controller.dispose();
    final newWidget = MainVideoPlayer(
      videoPath: videoPath,
      title: title,
      releaseYear: widget.releaseYear,
      isFullSeason: widget.isFullSeason,
      episodeFiles: widget.episodeFiles,
      similarMovies: widget.similarMovies,
      subtitleUrl: newSubtitleUrl ?? widget.subtitleUrl,
      localSubtitlePath: widget.localSubtitlePath,
      isHls: isHls,
      isLocal: widget.isLocal,
      seasons: widget.seasons,
      initialSeasonNumber: _currentSeasonNumber,
      initialEpisodeNumber: _currentEpisodeNumber,
      enableSkipIntro: widget.enableSkipIntro,
      chapters: widget.chapters,
      enablePiP: widget.enablePiP,
      enableOffline: widget.enableOffline,
      audioTracks: widget.audioTracks,
      subtitleTracks: widget.subtitleTracks,
    );
    setState(() {
      _currentVideoPath = newWidget.videoPath;
      _title = newWidget.title;
    });
    await _initializeVideo();
    await _loadSubtitles();
  }

  Future<void> _switchToEpisode(int seasonNumber, int episodeNumber) async {
    try {
      final streamingInfo = await StreamingService.getStreamingLink(
        tmdbId: widget.title.hashCode.toString(),
        title: widget.title,
        releaseYear: widget.releaseYear,
        season: seasonNumber,
        episode: episodeNumber,
        resolution: _selectedQuality,
        enableSubtitles: _showSubtitles,
      );
      _streamingInfo = streamingInfo;
      final newUrl = streamingInfo['url'] ?? '';
      final newSubtitleUrl = streamingInfo['subtitleUrl'];
      final isHls = streamingInfo['type'] == 'm3u8';
      final newTitle = '${widget.title} - S${seasonNumber.toString().padLeft(2, '0')}E${episodeNumber.toString().padLeft(2, '0')}';

      if (newUrl.isNotEmpty) {
        await _switchVideo(
          newUrl,
          newTitle,
          newSubtitleUrl: newSubtitleUrl,
          isHls: isHls,
        );
        setState(() {
          _currentSeasonNumber = seasonNumber;
          _currentEpisodeNumber = episodeNumber;
        });
      } else {
        throw Exception('No streaming URL found');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to load episode: $e")),
        );
      }
    }
  }

  void _showEpisodeMenu() {
    if (!widget.isFullSeason || widget.seasons == null || widget.seasons!.isEmpty) return;
    showDialog(
      context: context,
      builder: (context) => EpisodeSelectorDialog(
        seasons: widget.seasons!,
        currentSeasonNumber: _currentSeasonNumber ?? 1,
        currentEpisodeNumber: _currentEpisodeNumber ?? 1,
        onEpisodeSelected: _switchToEpisode,
      ),
    ).then((_) => _startHideTimer());
  }

  void _playNextEpisode() {
    if (_nextEpisodeData == null || _nextEpisodeData!['videoPath'] == null || _nextEpisodeData!['episodeNumber'] == null) {
      return;
    }
    final nextEpisodeNumber = int.parse(_nextEpisodeData!['episodeNumber']!);
    _switchToEpisode(_currentSeasonNumber!, nextEpisodeNumber);
  }

  Widget _buildControls() {
    if (!_controller.value.isInitialized) return const SizedBox.shrink();
    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                    colors: [Colors.black87, Colors.transparent],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter),
              ),
              child: SafeArea(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Focus(
                      child: IconButton(
                        icon: Icon(Icons.arrow_back, color: _controlColor, size: _iconSize),
                        onPressed: () {
                          if (mounted) Navigator.pop(context);
                        },
                      ),
                      onFocusChange: (hasFocus) {
                        if (hasFocus) {
                          _startHideTimer();
                        }
                      },
                      onKeyEvent: (node, event) {
                        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                          if (mounted) Navigator.pop(context);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                    ),
                    Expanded(
                      child: Text(
                        _title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: _controlColor, fontSize: 18, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Row(
                      children: [
                        Focus(
                          child: IconButton(
                            icon: Icon(Icons.high_quality, color: _controlColor, size: _iconSize),
                            onPressed: _showQualityMenu,
                          ),
                          onFocusChange: (hasFocus) {
                            if (hasFocus) {
                              _startHideTimer();
                            }
                          },
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                              _showQualityMenu();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                        ),
                        Focus(
                          child: IconButton(
                            icon: Icon(Icons.speed, color: _controlColor, size: _iconSize),
                            onPressed: _showSpeedMenu,
                          ),
                          onFocusChange: (hasFocus) {
                            if (hasFocus) {
                              _startHideTimer();
                            }
                          },
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                              _showSpeedMenu();
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
                        Focus(
                          child: IconButton(
                            icon: Icon(Icons.settings, color: _controlColor, size: _iconSize),
                            onPressed: _showSettingsMenu,
                          ),
                          onFocusChange: (hasFocus) {
                            if (hasFocus) {
                              _startHideTimer();
                            }
                          },
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                              _showSettingsMenu();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                        ),
                        Focus(
                          child: IconButton(
                            icon: Icon(
                                _showSubtitles ? Icons.closed_caption : Icons.closed_caption_off,
                                color: _controlColor,
                                size: _iconSize),
                            onPressed: () {
                              setState(() {
                                _showSubtitles = !_showSubtitles;
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
                                _showSubtitles = !_showSubtitles;
                              });
                              _startHideTimer();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                        ),
                        if (widget.isFullSeason)
                          Focus(
                            child: IconButton(
                              icon: Icon(Icons.list, color: _controlColor, size: _iconSize),
                              onPressed: _showEpisodeMenu,
                            ),
                            onFocusChange: (hasFocus) {
                              if (hasFocus) {
                                _startHideTimer();
                              }
                            },
                            onKeyEvent: (node, event) {
                              if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                                _showEpisodeMenu();
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
                  ],
                ),
              ),
            ),
          ),
          if (_showSubtitles && _currentSubtitle.isNotEmpty)
            Positioned(
              bottom: 80,
              left: 20,
              right: 20,
              child: Text(
                _currentSubtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    shadows: [
                      Shadow(offset: Offset(1, 1), color: Colors.black, blurRadius: 2)
                    ]),
              ),
            ),
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Focus(
                  child: IconButton(
                    iconSize: _iconSize,
                    icon: Icon(Icons.replay_10, color: _controlColor),
                    onPressed: () {
                      final newPos = _controller.value.position - const Duration(seconds: 10);
                      _controller.seekTo(newPos > Duration.zero ? newPos : Duration.zero);
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
                      final newPos = _controller.value.position - const Duration(seconds: 10);
                      _controller.seekTo(newPos > Duration.zero ? newPos : Duration.zero);
                      _startHideTimer();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                ),
                Focus(
                  child: IconButton(
                    iconSize: _iconSize + 24,
                    icon: Icon(
                        _controller.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                        color: _controlColor),
                    onPressed: () {
                      setState(() {
                        if (_controller.value.isPlaying) {
                          _controller.pause();
                        } else {
                          _controller.play();
                        }
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
                        if (_controller.value.isPlaying) {
                          _controller.pause();
                        } else {
                          _controller.play();
                        }
                      });
                      _startHideTimer();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                ),
                Focus(
                  child: IconButton(
                    iconSize: _iconSize,
                    icon: Icon(Icons.forward_10, color: _controlColor),
                    onPressed: () {
                      final newPos = _controller.value.position + const Duration(seconds: 10);
                      if (newPos < _controller.value.duration) {
                        _controller.seekTo(newPos);
                      }
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
                      final newPos = _controller.value.position + const Duration(seconds: 10);
                      if (newPos < _controller.value.duration) {
                        _controller.seekTo(newPos);
                      }
                      _startHideTimer();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                ),
              ],
            ),
          ),
          if (_seekTargetDuration != null)
            Center(
                child: Text(_formatDuration(_seekTargetDuration!), style: const TextStyle(color: Colors.white, fontSize: 24))),
          if (_seekFeedback != null)
            Center(child: Text(_seekFeedback!, style: const TextStyle(color: Colors.white, fontSize: 24))),
          if (_showSkipButton && widget.enableSkipIntro && _skipStart != null)
            Positioned(
              top: 20,
              right: 20,
              child: Focus(
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
            ),
          if (_showNextEpisodeBar)
            Positioned(
              bottom: 100,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        _nextEpisodeData != null
                            ? 'Next: ${_nextEpisodeData!['title']}'
                            : 'Loading next episode...',
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Row(
                      children: [
                        Focus(
                          child: ElevatedButton(
                            onPressed: _nextEpisodeData != null ? _showNextEpisodePreview : null,
                            child: const Text('Now'),
                          ),
                          onFocusChange: (hasFocus) {
                            if (hasFocus) {
                              _startHideTimer();
                            }
                          },
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select && _nextEpisodeData != null) {
                              _showNextEpisodePreview();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                        ),
                        const SizedBox(width: 8),
                        Focus(
                          child: ElevatedButton(
                            onPressed: _nextEpisodeData != null ? _playNextEpisode : null,
                            child: const Text('Play Now'),
                          ),
                          onFocusChange: (hasFocus) {
                            if (hasFocus) {
                              _startHideTimer();
                            }
                          },
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select && _nextEpisodeData != null) {
                              _playNextEpisode();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (_showRecommendationsBar && _recommendationData != null)
            Positioned(
              bottom: 100,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Up Next: ${_recommendationData!['title']}', style: const TextStyle(color: Colors.white, fontSize: 16)),
                    Focus(
                      child: ElevatedButton(
                        onPressed: _playRecommendedMovie,
                        child: const Text('Play Now'),
                      ),
                      onFocusChange: (hasFocus) {
                        if (hasFocus) {
                          _startHideTimer();
                        }
                      },
                      onKeyEvent: (node, event) {
                        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                          _playRecommendedMovie();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                    ),
                  ],
                ),
              ),
            ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                  gradient: LinearGradient(
                      colors: [Colors.transparent, Colors.black87],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter)),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    VideoProgressIndicator(
                      _controller,
                      allowScrubbing: true,
                      colors: const VideoProgressColors(
                          playedColor: Colors.deepPurpleAccent, backgroundColor: Colors.grey, bufferedColor: Colors.white30),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(_formatDuration(_controller.value.position), style: TextStyle(color: _controlColor, fontSize: 14)),
                        const Spacer(),
                        Focus(
                          child: IconButton(
                            icon: Icon(_isMuted ? Icons.volume_off : Icons.volume_up, color: _controlColor, size: _iconSize),
                            onPressed: () {
                              showDialog(
                                context: context,
                                builder: (context) => AlertDialog(
                                  backgroundColor: Colors.black87,
                                  title: const Text('Volume', style: TextStyle(color: Colors.white)),
                                  content: Slider(
                                    value: _volume,
                                    onChanged: (value) {
                                      setState(() {
                                        _volume = value;
                                        _controller.setVolume(value);
                                        _isMuted = value == 0;
                                      });
                                    },
                                    min: 0,
                                    max: 1,
                                    divisions: 20,
                                    activeColor: Colors.deepPurpleAccent,
                                  ),
                                  actions: [
                                    Focus(
                                      child: TextButton(
                                          onPressed: () => Navigator.pop(context),
                                          child: const Text('Close', style: TextStyle(color: Colors.white))),
                                      onFocusChange: (hasFocus) {
                                        if (hasFocus) {
                                          _startHideTimer();
                                        }
                                      },
                                      onKeyEvent: (node, event) {
                                        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                                          Navigator.pop(context);
                                          return KeyEventResult.handled;
                                        }
                                        return KeyEventResult.ignored;
                                      },
                                    ),
                                  ],
                                ),
                              ).whenComplete(_startHideTimer);
                            },
                          ),
                          onFocusChange: (hasFocus) {
                            if (hasFocus) {
                              _startHideTimer();
                            }
                          },
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                              showDialog(
                                context: context,
                                builder: (context) => AlertDialog(
                                  backgroundColor: Colors.black87,
                                  title: const Text('Volume', style: TextStyle(color: Colors.white)),
                                  content: Slider(
                                    value: _volume,
                                    onChanged: (value) {
                                      setState(() {
                                        _volume = value;
                                        _controller.setVolume(value);
                                        _isMuted = value == 0;
                                      });
                                    },
                                    min: 0,
                                    max: 1,
                                    divisions: 20,
                                    activeColor: Colors.deepPurpleAccent,
                                  ),
                                  actions: [
                                    Focus(
                                      child: TextButton(
                                          onPressed: () => Navigator.pop(context),
                                          child: const Text('Close', style: TextStyle(color: Colors.white))),
                                      onFocusChange: (hasFocus) {
                                        if (hasFocus) {
                                          _startHideTimer();
                                        }
                                      },
                                      onKeyEvent: (node, event) {
                                        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                                          Navigator.pop(context);
                                          return KeyEventResult.handled;
                                        }
                                        return KeyEventResult.ignored;
                                      },
                                    ),
                                  ],
                                ),
                              ).whenComplete(_startHideTimer);
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                        ),
                        Focus(
                          child: IconButton(
                            icon: Icon(Icons.lock, color: _controlColor, size: _iconSize),
                            onPressed: () {
                              setState(() {
                                _isLocked = true;
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
                                _isLocked = true;
                              });
                              _startHideTimer();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                        ),
                        Focus(
                          child: IconButton(
                            icon: Icon(Icons.fullscreen, color: _controlColor, size: _iconSize),
                            onPressed: () {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text("Fullscreen toggled")));
                              }
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
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text("Fullscreen toggled")));
                              }
                              _startHideTimer();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                        ),
                        const SizedBox(width: 8),
                        Text(_formatDuration(_controller.value.duration), style: TextStyle(color: _controlColor, fontSize: 14)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _errorMessage != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_errorMessage!, style: const TextStyle(color: Colors.red, fontSize: 16), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  Focus(
                    child: ElevatedButton(
                      onPressed: _retryLoad,
                      child: const Text('Retry'),
                    ),
                    onFocusChange: (hasFocus) {
                      if (hasFocus) {
                        _startHideTimer();
                      }
                    },
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
                        _retryLoad();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                  ),
                ],
              ),
            )
          : _isInitialized
              ? FocusScope(
                  child: Stack(
                    children: [
                      SubVideoPlayer(
                        videoUrl: _currentVideoPath,
                        controller: _controller,
                        enableSkipIntro: widget.enableSkipIntro,
                        chapters: widget.chapters,
                        enablePiP: widget.enablePiP,
                        enableOffline: widget.enableOffline,
                        audioTracks: widget.audioTracks,
                        subtitleTracks: widget.subtitleTracks,
                      ),
                      if (_isLocked)
                        Center(
                          child: Focus(
                            child: IconButton(
                              icon: Icon(Icons.lock, color: _controlColor, size: _iconSize + 10),
                              onPressed: () {
                                setState(() {
                                  _isLocked = false;
                                });
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
                                  _isLocked = false;
                                });
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                          ),
                        )
                      else
                        GestureDetector(
                          onTap: _toggleControls,
                          onDoubleTap: () {
                            if (_lastTapPosition == null) return;
                            final screenWidth = MediaQuery.of(context).size.width;
                            final tapX = _lastTapPosition!.dx;
                            if (tapX < screenWidth / 3) {
                              final newPos = _controller.value.position - const Duration(seconds: 10);
                              _controller.seekTo(newPos > Duration.zero ? newPos : Duration.zero);
                              setState(() {
                                _seekFeedback = "-10s";
                              });
                            } else if (tapX > screenWidth * 2 / 3) {
                              final newPos = _controller.value.position + const Duration(seconds: 10);
                              if (newPos < _controller.value.duration) {
                                _controller.seekTo(newPos);
                              }
                              setState(() {
                                _seekFeedback = "+10s";
                              });
                            }
                            _lastTapPosition = null;
                            Timer(const Duration(seconds: 1), () {
                              if (mounted) {
                                setState(() {
                                  _seekFeedback = null;
                                });
                              }
                            });
                          },
                          onTapDown: (details) => _lastTapPosition = details.globalPosition,
                          onHorizontalDragStart: _onHorizontalDragStart,
                          onHorizontalDragUpdate: _onHorizontalDragUpdate,
                          onHorizontalDragEnd: _onHorizontalDragEnd,
                          child: _buildControls(),
                        ),
                      if (_isAdjustingBrightness && !kIsWeb)
                        Positioned(
                          left: 16,
                          top: MediaQuery.of(context).size.height / 2 - 50,
                          child: Column(
                            children: [
                              const Icon(Icons.brightness_6, color: Colors.white, size: 32),
                              Text('${(_brightness * 100).round()}%', style: const TextStyle(color: Colors.white)),
                            ],
                          ),
                        ),
                      if (_isAdjustingVolume)
                        Positioned(
                          right: 16,
                          top: MediaQuery.of(context).size.height / 2 - 50,
                          child: Column(
                            children: [
                              const Icon(Icons.volume_up, color: Colors.white, size: 32),
                              Text('${(_volume * 100).round()}%', style: const TextStyle(color: Colors.white)),
                            ],
                          ),
                        ),
                    ],
                  ),
                )
              : const Center(child: CircularProgressIndicator()),
    );
  }
}