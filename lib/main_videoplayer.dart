// main_videoplayer.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:better_player/better_player.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:movie_app/streaming_service.dart';
import 'package:movie_app/components/movieflix_loader.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_info/system_info.dart';
import 'package:fl_pip/fl_pip.dart' show FlPiP;
import 'package:path/path.dart' as p;
import 'package:cached_network_image/cached_network_image.dart';

/// Simple data classes
class Subtitle {
  final Duration start;
  final Duration end;
  final String text;

  Subtitle({required this.start, required this.end, required this.text});
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

/// -----------------
/// Isolate helpers
/// -----------------
List<Map<String, dynamic>> _parseSrtIsolate(String srt) {
  final List<Map<String, dynamic>> subtitles = [];
  final regex = RegExp(
      r'(\d+)\s+(\d{2}:\d{2}:\d{2},\d{3})\s+-->\s+(\d{2}:\d{2}:\d{2},\d{3})\s+([\s\S]*?)(?=\n\n|\$)',
      dotAll: true);
  final matches = regex.allMatches(srt);
  for (final match in matches) {
    final start = _parseDurationIsolate(match.group(2)!);
    final end = _parseDurationIsolate(match.group(3)!);
    final text = match.group(4)!.trim().replaceAll('\r\n', '\n').replaceAll('\n', ' ');
    subtitles.add({
      'start_ms': start.inMilliseconds,
      'end_ms': end.inMilliseconds,
      'text': text,
    });
  }
  return subtitles;
}

List<Map<String, dynamic>> _parseVttIsolate(String vtt) {
  final List<Map<String, dynamic>> subtitles = [];
  final regex = RegExp(
      r'(\d{2}:\d{2}:\d{2}\.\d{3})\s+-->\s+(\d{2}:\d{2}:\d{2}\.\d{3})\s+([\s\S]*?)(?=\n\n|\$)',
      dotAll: true);
  final matches = regex.allMatches(vtt);
  for (final match in matches) {
    final start = _parseDurationIsolate(match.group(1)!);
    final end = _parseDurationIsolate(match.group(2)!);
    final text = match.group(3)!.trim().replaceAll('\r\n', '\n').replaceAll('\n', ' ');
    subtitles.add({
      'start_ms': start.inMilliseconds,
      'end_ms': end.inMilliseconds,
      'text': text,
    });
  }
  return subtitles;
}

Duration _parseDurationIsolate(String timeString) {
  final parts = timeString.split(RegExp(r'[:,.]'));
  final hours = int.parse(parts[0]);
  final minutes = int.parse(parts[1]);
  final seconds = int.parse(parts[2]);
  final milliseconds = int.parse(parts[3]);
  return Duration(hours: hours, minutes: minutes, seconds: seconds, milliseconds: milliseconds);
}

/// -----------------
/// Widget
/// -----------------
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

class MainVideoPlayerState extends State<MainVideoPlayer>
    with WidgetsBindingObserver {
  late BetterPlayerController _betterPlayerController;
  Map<String, dynamic>? _streamingInfo;

  // Keep previous streaming info so we can rollback on bad switches
  Map<String, dynamic>? _prevStreamingInfo;
  String? _prevSelectedQuality;
  String? _prevVideoPath;

  bool _isInitialized = false;
  String? _errorMessage;
  bool _isBuffering = false;
  bool _showSkipButton = false;
  Duration? _skipStart;
  Duration? _skipEnd;
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
  String _CurrentSubtitle = "";
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
  Map<String, dynamic>? _nextEpisodeData;
  bool _showRecommendationsBar = false;
  Map<String, dynamic>? _recommendationData;
  Timer? _recommendationTimer;
  bool _showSubtitles = true;
  Offset? _lastTapPosition;
  String? _seekFeedback;
  Duration? _seekTargetDuration;
  double? _dragStartX;
  Duration? _dragStartPosition;
  Duration? _resumePosition;
  String? _selectedAudioTrack;
  String? _selectedSubtitleTrack;
  bool _isDownloaded = false;
  late Future<void> _videoInitFuture;

  // store a current subtitle url locally
  String? _currentSubtitleUrl;

  // helper timer to poll underlying video state (position/update subtitles)
  Timer? _pollTimer;

  // shared buffering configuration for all data sources
  late final BetterPlayerBufferingConfiguration _bufferingConfig;

  // network timeout used for backend and HTTP calls (increased)
  final Duration _networkTimeout = const Duration(seconds: 25);

  // watchdog timeout after a switch (seconds)
  final int _playbackStartTimeoutSeconds = 8;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _title = widget.title;

    _bufferingConfig = BetterPlayerBufferingConfiguration(
      minBufferMs: 10000,
      maxBufferMs: 30000,
      bufferForPlaybackMs: 2500,
      bufferForPlaybackAfterRebufferMs: 5000,
    );

    _startHeavyBackgroundTasks();

    _enforceLandscape();
    _saveWatchHistory();
    _videoInitFuture = _setupStreamingAndController();
    _initializeBrightness();
    _currentSubtitleUrl = widget.subtitleUrl;
    _loadSubtitles();
    if (widget.enableSkipIntro && widget.chapters != null) {
      _prepareSkip();
    }
    _loadResumePosition();
    _loadDownloadState();
  }

  void _startHeavyBackgroundTasks() {
    // non-blocking: if you later add heavy compute, use compute() from Flutter.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    try {
      if (state == AppLifecycleState.paused) {
        _pauseInternal();
        _saveWatchHistory();
        _savePosition();
      } else if (state == AppLifecycleState.resumed) {
        _enforceLandscape();
        _playInternalIfNeeded();
      }
    } catch (e) {
      debugPrint("Lifecycle handling error: $e");
    }
  }

  Future<void> _pauseInternal() async {
    try {
      await _betterPlayerController.pause();
    } catch (_) {}
  }

  Future<void> _playInternalIfNeeded() async {
    final vp = _videoValue;
    if (vp != null && (vp.initialized ?? false) && !(vp.isPlaying ?? false)) {
      try {
        await _betterPlayerController.play();
      } catch (_) {}
    }
  }

  Future<void> _saveWatchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> jsonList = prefs.getStringList('watchHistory') ?? [];
      final currentPosition =
          (_videoValue?.position?.inSeconds) ?? _resumePosition?.inSeconds ?? 0;
      final duration = (_videoValue?.duration?.inSeconds) ?? 0;

      final historyEntry = {
        'id': widget.title.hashCode.toString(),
        'tmdbId': widget.title.hashCode.toString(),
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
        return map['tmdbId'] == historyEntry['tmdbId'] &&
            map['media_type'] == historyEntry['media_type'] &&
            (!widget.isFullSeason ||
                (map['season'] == _currentSeasonNumber &&
                    map['episode'] == _currentEpisodeNumber));
      });

      jsonList.insert(0, json.encode(historyEntry));
      await prefs.setStringList('watchHistory', jsonList);
    } catch (e) {
      debugPrint("Failed saving watch history: $e");
    }
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

  Future<void> _setupStreamingAndController() async {
    try {
      await _initializeVideoPath();
      await _initializeVideo();
    } catch (e) {
      debugPrint('setupStreamingAndController top-level error: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Playback initialization failed: $e';
        });
      }
    }
  }

  Future<void> _initializeVideoPath() async {
    if (!mounted) return;
    setState(() {
      _errorMessage = null;
      _currentVideoPath = widget.videoPath;
      _currentSeasonNumber = widget.initialSeasonNumber ?? 1;
      _currentEpisodeNumber = widget.initialEpisodeNumber ??
          (widget.isFullSeason ? _extractEpisodeNumber(widget.videoPath) : null) ??
          1;
    });

    final prefs = await SharedPreferences.getInstance();
    List<String> jsonList = prefs.getStringList('watchHistory') ?? [];
    final historyEntry = jsonList.firstWhere(
      (jsonStr) {
        final map = json.decode(jsonStr);
        if (widget.isFullSeason) {
          return map['id'] == widget.title.hashCode.toString() &&
              map['media_type'] == 'tv' &&
              map['season'] == _currentSeasonNumber &&
              map['episode'] == _currentEpisodeNumber;
        }
        return map['id'] == widget.title.hashCode.toString() &&
            map['media_type'] == 'movie';
      },
      orElse: () => '',
    );

    if (historyEntry.isNotEmpty) {
      final map = json.decode(historyEntry);
      setState(() {
        _resumePosition = Duration(seconds: map['position'] as int);
      });
    }
  }

  String _normalizeUrl(String url) {
    if (url.isEmpty) return url;
    var u = url.trim();
    if (u.startsWith('//')) return 'https:$u';
    return u;
  }

  String _mobileUserAgent() {
    return 'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116 Mobile Safari/537.36';
  }

  Future<Map<String, dynamic>> _preflightUrl(String url, {Map<String, String>? extraHeaders}) async {
    try {
      final normalized = _normalizeUrl(url);
      final uri = Uri.parse(normalized);
      final headers = <String, String>{
        'User-Agent': _mobileUserAgent(),
        'Accept': '*/*',
        if (extraHeaders != null) ...extraHeaders,
      };

      final response = await http.head(uri, headers: headers).timeout(_networkTimeout);
      final finalUrl = response.request?.url.toString() ?? normalized;
      return {
        'url': finalUrl,
        'statusCode': response.statusCode,
        'headers': response.headers,
      };
    } catch (e) {
      debugPrint('Preflight failed for $url: $e');
      return {'url': _normalizeUrl(url), 'statusCode': null, 'headers': {}};
    }
  }

  Map<String, String> _buildHeadersForUrl(String url, {bool forceReferer = false}) {
    final headers = <String, String>{
      'Accept': '*/*',
      'User-Agent': _mobileUserAgent(),
    };
    try {
      final uri = Uri.parse(url);
      if (forceReferer || uri.host.isNotEmpty) {
        final origin = '${uri.scheme}://${uri.host}';
        headers['Referer'] = origin;
        headers['Origin'] = origin;
      }
    } catch (_) {}
    return headers;
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
      if (!widget.isLocal) {
        try {
          debugPrint('Requesting streaming link for ${widget.title}');
          final streamingFuture = StreamingService.getStreamingLink(
            tmdbId: widget.title.hashCode.toString(),
            title: widget.title,
            releaseYear: widget.releaseYear,
            season: _currentSeasonNumber,
            episode: _currentEpisodeNumber,
            resolution: _selectedQuality,
            enableSubtitles: _showSubtitles,
          ).timeout(_networkTimeout);
          _streamingInfo = await streamingFuture;
        } on TimeoutException catch (te) {
          debugPrint('StreamingService.getStreamingLink timed out: $te');
          _streamingInfo = {'url': _currentVideoPath, 'creditsStartTime': null};
        } catch (e) {
          debugPrint('StreamingService.getStreamingLink failed: $e');
          _streamingInfo = {'url': _currentVideoPath, 'creditsStartTime': null};
        }
      } else {
        _streamingInfo = {'url': _currentVideoPath, 'creditsStartTime': null};
      }

      final rawUrl = (_streamingInfo?['url'] as String?) ?? _currentVideoPath;
      final preflight = await _preflightUrl(rawUrl);
      final actualUrl = (preflight['url'] as String?) ?? rawUrl;
      debugPrint('Resolved URL: $rawUrl -> $actualUrl ; status=${preflight['statusCode']}');

      if (actualUrl.isEmpty) {
        if (mounted) {
          setState(() {
            _errorMessage = "Invalid or empty streaming URL";
          });
        }
        return;
      }

      final streamingType = (_streamingInfo?['type'] as String?) ?? (widget.isHls ? 'm3u8' : '');
      final isHls = streamingType.toLowerCase() == 'm3u8' || widget.isHls;

      final List<BetterPlayerSubtitlesSource> subtitles = [];
      final subtitleCandidate = (_streamingInfo?['subtitleUrl'] as String?) ??
          widget.subtitleUrl ??
          _currentSubtitleUrl;
      if (subtitleCandidate != null && subtitleCandidate.isNotEmpty) {
        if (subtitleCandidate.startsWith('http') || subtitleCandidate.startsWith('https')) {
          subtitles.add(BetterPlayerSubtitlesSource(
            type: BetterPlayerSubtitlesSourceType.network,
            name: 'Subtitles',
            urls: [subtitleCandidate],
          ));
        } else if (!kIsWeb) {
          subtitles.add(BetterPlayerSubtitlesSource(
            type: BetterPlayerSubtitlesSourceType.file,
            name: 'Subtitles',
            urls: [subtitleCandidate],
          ));
        }
      }

      final headers = _buildHeadersForUrl(actualUrl);

      final isLocalFilePath = (!actualUrl.startsWith('http') && !actualUrl.startsWith('https'));

      BetterPlayerDataSource dataSource;
      if (isLocalFilePath) {
        dataSource = BetterPlayerDataSource(
          BetterPlayerDataSourceType.file,
          actualUrl,
          headers: headers,
          liveStream: isHls,
          useAsmsSubtitles: true,
          useAsmsTracks: true,
          useAsmsAudioTracks: true,
          subtitles: subtitles.isNotEmpty ? subtitles : null,
          bufferingConfiguration: _bufferingConfig,
        );
      } else {
        dataSource = BetterPlayerDataSource(
          BetterPlayerDataSourceType.network,
          actualUrl,
          headers: headers,
          liveStream: isHls,
          useAsmsSubtitles: true,
          useAsmsTracks: true,
          useAsmsAudioTracks: true,
          videoFormat: isHls ? BetterPlayerVideoFormat.hls : null,
          subtitles: subtitles.isNotEmpty ? subtitles : null,
          bufferingConfiguration: _bufferingConfig,
        );
      }

      final config = BetterPlayerConfiguration(
        autoPlay: false,
        fit: BoxFit.contain,
        allowedScreenSleep: false,
        handleLifecycle: false,
        controlsConfiguration: BetterPlayerControlsConfiguration(
          showControls: false,
        ),
      );

      try {
        _betterPlayerController.dispose();
      } catch (_) {}

      _betterPlayerController = BetterPlayerController(
        config,
        betterPlayerDataSource: dataSource,
      );

      _betterPlayerController.addEventsListener(_betterPlayerEventListener);

      final initializedOk = await _waitForInitialization(timeoutSeconds: 12);
      if (!initializedOk) {
        debugPrint('Initial BetterPlayer initialization FAILED or timed out — attempting fallback retry with alternative headers/data source');
        try {
          await _retryWithAlternativeHeaders();
        } catch (e) {
          debugPrint('Fallback retry also failed: $e');
          if (mounted) {
            setState(() {
              _errorMessage = "Playback initialization failed (initial + fallback).";
            });
          }
          return;
        }
      }

      await _applyAutoTrackSelection();

      if (!mounted) return;

      setState(() {
        _isInitialized = (_videoValue?.initialized ?? false);
        _volume = (_videoValue?.volume ?? 1.0);
      });

      if (_resumePosition != null && _videoValue?.duration != null) {
        try {
          await _betterPlayerController.seekTo(_resumePosition!);
        } catch (_) {}
      }

      try {
        await _betterPlayerController.setSpeed(_playbackSpeed);
      } catch (_) {}

      try {
        await _betterPlayerController.play();
      } catch (e) {
        debugPrint("Play after init failed: $e");
      }

      _startPolling();

      if (widget.audioTracks != null && widget.audioTracks!.isNotEmpty) {
        _selectedAudioTrack = widget.audioTracks!.first.label;
      }
      if (widget.subtitleTracks != null && widget.subtitleTracks!.isNotEmpty) {
        _selectedSubtitleTrack = widget.subtitleTracks!.first.label;
      }

      await _adjustQualityBasedOnHardware();
    } on PlatformException catch (e) {
      debugPrint("Platform exception initializing video: $e");
      if (mounted) {
        setState(() {
          _errorMessage = "Playback failed: ${e.message}";
        });
      }
    } catch (error, st) {
      debugPrint("Video initialization error (BetterPlayer): $error\n$st");
      if (mounted) {
        if (error.toString().toLowerCase().contains('exoplaybackexception') ||
            error.toString().toLowerCase().contains('source error')) {
          try {
            debugPrint('Attempting retry with additional headers (referer) ...');
            await _retryWithAlternativeHeaders();
            return;
          } catch (e) {
            debugPrint('Retry failed: $e');
          }
        }
        if (_selectedQuality == "Auto") {
          setState(() => _selectedQuality = "360p");
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Quality switching disabled; playing current stream')));
          }
        } else {
          final nextQuality = _getNextLowerQuality(_selectedQuality);
          if (nextQuality != null) {
            setState(() => _selectedQuality = nextQuality);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Quality switching disabled; playing current stream')));
            }
          } else {
            setState(() {
              _errorMessage = "Failed to load video: $error";
            });
          }
        }
      }
    }
  }

  Future<void> _retryWithAlternativeHeaders() async {
    final actualUrl = (_streamingInfo?['url'] as String?) ?? _currentVideoPath;
    final headers = _buildHeadersForUrl(actualUrl, forceReferer: true);

    final isHls = ( (_streamingInfo?['type'] as String?) ?? (widget.isHls ? 'm3u8' : '') )
        .toString()
        .toLowerCase()
        .contains('m3u8');

    BetterPlayerDataSource makeDataSource({required bool useAsms}) {
      return BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        actualUrl,
        headers: headers,
        liveStream: isHls,
        useAsmsSubtitles: useAsms,
        useAsmsTracks: useAsms,
        useAsmsAudioTracks: useAsms,
        videoFormat: isHls ? BetterPlayerVideoFormat.hls : null,
        bufferingConfiguration: _bufferingConfig,
      );
    }

    try {
      await _betterPlayerController.setupDataSource(makeDataSource(useAsms: true)).timeout(_networkTimeout);
      final initialized = await _waitForInitialization(timeoutSeconds: 10);
      if (!initialized) throw Exception('init timeout after ASMS-enabled setup');
      await _applyAutoTrackSelection();
      await _betterPlayerController.play();
      if (mounted) {
        setState(() {
          _errorMessage = null;
          _isInitialized = true;
        });
      }
      return;
    } catch (e) {
      debugPrint('Retry with ASMS=true failed: $e');
    }

    try {
      debugPrint('Retrying with ASMS disabled (fallback)...');
      await _betterPlayerController.setupDataSource(makeDataSource(useAsms: false)).timeout(_networkTimeout);
      final initialized = await _waitForInitialization(timeoutSeconds: 10);
      if (!initialized) throw Exception('init timeout after ASMS-disabled setup');
      try { await _betterPlayerController.play(); } catch (_) {}
      if (mounted) {
        setState(() {
          _errorMessage = null;
          _isInitialized = true;
        });
      }
      return;
    } catch (e) {
      debugPrint('Retry with ASMS=false also failed: $e');
      rethrow;
    }
  }

  Future<bool> _waitForInitialization({int timeoutSeconds = 10}) async {
    final completer = Completer<bool>();
    final int stepMs = 200;
    int elapsed = 0;
    Timer? t;
    t = Timer.periodic(Duration(milliseconds: stepMs), (_) {
      try {
        final vp = _videoValue;
        if (vp != null && (vp.initialized ?? false)) {
          t?.cancel();
          if (!completer.isCompleted) completer.complete(true);
        } else {
          elapsed += stepMs;
          if (elapsed >= timeoutSeconds * 1000) {
            t?.cancel();
            if (!completer.isCompleted) completer.complete(false);
          }
        }
      } catch (e) {
        t?.cancel();
        if (!completer.isCompleted) completer.complete(false);
      }
    });
    return completer.future;
  }

  Future<bool> _waitForPlaybackStart({int timeoutSeconds = 8}) async {
    final int stepMs = 300;
    int elapsed = 0;
    while (elapsed < timeoutSeconds * 1000) {
      await Future.delayed(Duration(milliseconds: stepMs));
      elapsed += stepMs;
      final vp = _videoValue;
      if (vp == null) continue;

      final initialized = vp.initialized ?? false;
      final buffering = vp.isBuffering ?? false;
      final isPlaying = vp.isPlaying ?? false;
      final pos = vp.position ?? Duration.zero;

      if (initialized && !buffering && (isPlaying || pos > Duration.zero)) {
        return true;
      }
    }
    return false;
  }

  dynamic get _videoValue =>
      _betterPlayerController.videoPlayerController?.value;

  Future<void> _applyAutoTrackSelection() async {
    return;
  }

  Future<void> _adjustQualityBasedOnHardware() async {
    return;
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

  void _betterPlayerEventListener(BetterPlayerEvent event) {
    if (!mounted) return;
    try {
      setState(() {
        _isBuffering =
            event.betterPlayerEventType == BetterPlayerEventType.bufferingStart;
      });

      final params = event.parameters;
      final paramsText = (params != null && params.toString().isNotEmpty) ? ' params: $params' : '';
      debugPrint('BetterPlayerEvent: ${event.betterPlayerEventType}$paramsText');

      if (event.betterPlayerEventType == BetterPlayerEventType.finished) {
        _checkForEndOfContent();
      }

      if (event.betterPlayerEventType == BetterPlayerEventType.changedTrack ||
          event.betterPlayerEventType == BetterPlayerEventType.initialized) {
        Future.delayed(const Duration(milliseconds: 700), () {
          _applyAutoTrackSelection();
        });
      }

      if (event.betterPlayerEventType == BetterPlayerEventType.exception) {
        debugPrint('BetterPlayer reported an exception: $params');
        try {
          final msg = (params != null && params is Map && params['exceptionMessage'] != null)
              ? params['exceptionMessage'].toString()
              : params.toString();
          if (mounted) {
            setState(() {
              _errorMessage = 'Playback error: $msg';
            });
          }
        } catch (e) {
          debugPrint('Error extracting exception params: $e');
        }
      }
    } catch (e) {
      debugPrint("BetterPlayer event listener error: $e");
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
    } else if (_currentSubtitleUrl != null && _currentSubtitleUrl!.isNotEmpty) {
      try {
        final response = await http.get(Uri.parse(_currentSubtitleUrl!)).timeout(_networkTimeout);
        if (response.statusCode == 200) {
          content = utf8.decode(response.bodyBytes);
        } else {
          debugPrint(
              'Failed to fetch network subtitles: ${response.statusCode}');
        }
      } on TimeoutException catch (te) {
        debugPrint('Subtitle fetch timed out: $te');
      } catch (e) {
        debugPrint('Failed to load network subtitles: $e');
      }
    }
    if (content != null && mounted) {
      try {
        final trimmed = content.trimLeft();
        List<Map<String, dynamic>> raw;
        if (trimmed.startsWith('WEBVTT')) {
          raw = await compute(_parseVttIsolate, content);
        } else {
          raw = await compute(_parseSrtIsolate, content);
        }
        final parsed = raw.map((m) => Subtitle(
          start: Duration(milliseconds: m['start_ms'] as int),
          end: Duration(milliseconds: m['end_ms'] as int),
          text: m['text'] as String,
        )).toList();
        setState(() {
          _subtitles = parsed;
        });
      } catch (e) {
        debugPrint('Error parsing subtitles in isolate: $e');
      }
    }
  }

  List<Subtitle> _parseSrt(String srt) {
    return _parseSrtIsolate(srt)
        .map((m) => Subtitle(
              start: Duration(milliseconds: m['start_ms'] as int),
              end: Duration(milliseconds: m['end_ms'] as int),
              text: m['text'] as String,
            ))
        .toList();
  }

  List<Subtitle> _parseVtt(String vtt) {
    return _parseVttIsolate(vtt)
        .map((m) => Subtitle(
              start: Duration(milliseconds: m['start_ms'] as int),
              end: Duration(milliseconds: m['end_ms'] as int),
              text: m['text'] as String,
            ))
        .toList();
  }

  Duration _parseDuration(String timeString) {
    final parts = timeString.split(RegExp(r'[:,.]'));
    return Duration(
      hours: int.parse(parts[0]),
      minutes: int.parse(parts[1]),
      seconds: int.parse(parts[2]),
      milliseconds: int.parse(parts[3]),
    );
  }

  void _updateSubtitle() {
    if (!_showSubtitles ||
        _subtitles.isEmpty ||
        _videoValue == null ||
        (_videoValue?.initialized ?? false) == false) {
      return;
    }
    final position = _videoValue!.position as Duration;
    final current = _subtitles.firstWhere(
        (sub) => position >= sub.start && position <= sub.end,
        orElse: () =>
            Subtitle(start: Duration.zero, end: Duration.zero, text: ""));
    if (mounted) {
      setState(() {
        _currentSubtitle = current.text;
      });
    }
  }

  void _prepareSkip() {
    if (widget.chapters == null) return;
    final intro = widget.chapters!.firstWhere(
      (c) => c.title.toLowerCase() == 'intro',
      orElse: () =>
          Chapter(title: 'Intro', start: Duration.zero, end: Duration.zero),
    );
    _skipStart = intro.start;
    _skipEnd = intro.end;
  }

  void _skipIntro() {
    if (_skipEnd != null) {
      try {
        _betterPlayerController.seekTo(_skipEnd!);
      } catch (_) {}
      setState(() => _showSkipButton = false);
    }
  }

  Future<void> _savePosition() async {
    final v = _videoValue;
    if (v == null || (v.initialized ?? false) == false) return;
    final prefs = await SharedPreferences.getInstance();
    final position = v.position as Duration;
    await prefs.setInt('${widget.videoPath}_resume', position.inSeconds);
  }

  Future<void> _loadResumePosition() async {
    final prefs = await SharedPreferences.getInstance();
    final seconds = prefs.getInt('${widget.videoPath}_resume');
    if (seconds != null) {
      setState(() {
        _resumePosition = Duration(seconds: seconds);
      });
    }
  }

  Future<void> _loadDownloadState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isDownloaded = prefs.getBool('${widget.videoPath}_downloaded') ?? false;
    });
  }

  Future<void> _toggleDownload() async {
    final prefs = await SharedPreferences.getInstance();
    final newState = !_isDownloaded;
    await prefs.setBool('${widget.videoPath}_downloaded', newState);
    setState(() {
      _isDownloaded = newState;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(newState ? 'Download started' : 'Download removed')),
      );
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
    _videoInitFuture = _setupStreamingAndController();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _recommendationTimer?.cancel();
    _pollTimer?.cancel();
    try {
      _betterPlayerController.removeEventsListener(_betterPlayerEventListener);
      _betterPlayerController.dispose();
    } catch (_) {}
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
    _dragStartPosition = _videoValue?.position as Duration?;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    final vp = _videoValue;
    if (vp == null || (vp.initialized ?? false) == false || _dragStartX == null || _dragStartPosition == null) {
      return;
    }
    final screenWidth = MediaQuery.of(context).size.width;
    final dx = details.globalPosition.dx - _dragStartX!;
    final offset = dx / screenWidth * (vp.duration as Duration).inSeconds;
    final newPosition = (_dragStartPosition!.inSeconds + offset)
        .clamp(0, (vp.duration as Duration).inSeconds);
    setState(() {
      _seekTargetDuration = Duration(seconds: newPosition.round());
      _showControls = true;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_seekTargetDuration != null) {
      try {
        _betterPlayerController.seekTo(_seekTargetDuration!);
      } catch (_) {}
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
        try {
          _betterPlayerController.setVolume(_volume);
        } catch (_) {}
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
      items: _qualities
          .map((q) => PopupMenuItem<String>(value: q, child: Text(q)))
          .toList(),
    );
    if (quality != null && quality != _selectedQuality) {
      setState(() {
        _selectedQuality = quality;
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Quality selection is disabled; playing current stream')));
      _startHideTimer();
    }
  }

  Future<void> _fetchNewQualityStream(String quality) async {
    try {
      setState(() {
        _selectedQuality = quality;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Quality selection is disabled; playing current stream')));
      }
    } catch (e) {
      debugPrint('Ignored error in _fetchNewQualityStream: $e');
    }
  }

  Future<bool> _trySwitchAndEnsurePlaying({
    required String videoPath,
    required String title,
    String? newSubtitleUrl,
    bool isHls = false,
    int timeoutSeconds = 8,
  }) async {
    try {
      await _switchVideo(videoPath, title, newSubtitleUrl: newSubtitleUrl, isHls: isHls);
    } catch (e) {
      debugPrint('Error during _switchVideo: $e');
      return false;
    }

    final started = await _waitForPlaybackStart(timeoutSeconds: timeoutSeconds);
    return started;
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
      try {
        await _betterPlayerController.setSpeed(speed);
      } catch (_) {}
      _startHideTimer();
    }
  }

  void _showAudioTrackMenu() async {
    if (widget.audioTracks == null || widget.audioTracks!.isEmpty) return;
    final selected = await showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(100, 100, 100, 100),
      items: widget.audioTracks!
          .map((track) => PopupMenuItem<String>(value: track.label, child: Text(track.label, style: const TextStyle(color: Colors.white))))
          .toList(),
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
      items: widget.subtitleTracks!
          .map((track) => PopupMenuItem<String>(value: track.label, child: Text(track.label, style: const TextStyle(color: Colors.white))))
          .toList(),
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
      await _betterPlayerController.pause();
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
                      DropdownMenuItem(value: Colors.white, child: Text('White', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: Colors.yellow, child: Text('Yellow', style: TextStyle(color: Colors.yellow))),
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
    final vp = _videoValue;
    if (vp == null || (vp.initialized ?? false) == false) return;
    final position = vp.position as Duration;
    final duration = vp.duration as Duration;
    final creditsStartTime = _streamingInfo?['creditsStartTime'] != null
        ? Duration(seconds: _streamingInfo!['creditsStartTime'] as int)
        : Duration(milliseconds: (duration.inMilliseconds * 0.98).round());

    if (position >= creditsStartTime &&
        !_showNextEpisodeBar &&
        widget.isFullSeason) {
      setState(() {
        _showNextEpisodeBar = true;
        _showControls = true;
      });
      _fetchNextEpisode();
    } else if (duration - position <= Duration.zero) {
      if (widget.isFullSeason && _nextEpisodeData != null) {
        _playNextEpisode();
      } else if (!widget.isFullSeason && _recommendationData != null) {
        _playRecommendedMovie();
      }
    }
  }

  void _fetchNextEpisode() async {
    if (_currentSeasonNumber == null ||
        _currentEpisodeNumber == null ||
        !widget.isFullSeason ||
        widget.seasons == null) {
      return;
    }
    final currentSeason = widget.seasons!.firstWhere(
      (season) => season['season_number'] == _currentSeasonNumber,
      orElse: () => {},
    );
    final episodes = currentSeason['episodes'] as List<dynamic>? ?? [];
    final currentIndex = episodes
        .indexWhere((e) => e['episode_number'] == _currentEpisodeNumber);
    if (currentIndex == -1 || currentIndex >= episodes.length - 1) {
      return;
    }

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
      ).timeout(_networkTimeout);
      if (mounted) {
        setState(() {
          _nextEpisodeData = {
            'videoPath': streamingInfo['url'] ?? '',
            'title':
                '${widget.title} - S${_currentSeasonNumber!.toString().padLeft(2, '0')}E${nextEpisodeNumber.toString().padLeft(2, '0')}',
            'episodeNumber': nextEpisodeNumber.toString(),
            'synopsis': nextEpisode['overview'] ?? 'No synopsis available',
          };
        });
      }
    } on TimeoutException catch (te) {
      debugPrint('fetchNextEpisode timed out: $te');
    } catch (e) {
      debugPrint('Failed to fetch next episode: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load next episode: $e')),
        );
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
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.select) {
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
              child:
                  const Text('Play Now', style: TextStyle(color: Colors.white)),
            ),
            onFocusChange: (hasFocus) {
              if (hasFocus) {
                _startHideTimer();
              }
            },
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.select) {
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
      final releaseDate = recommendation['release_date'] as String? ??
          recommendation['first_air_date'] as String? ??
          '1970-01-01';
      final releaseYear = int.parse(releaseDate.split('-')[0]);
      final streamingInfo = await StreamingService.getStreamingLink(
        tmdbId: recommendation['id'].toString(),
        title: recommendation['title']?.toString() ??
            recommendation['name']?.toString() ??
            'Untitled',
        releaseYear: releaseYear,
        resolution: _selectedQuality,
        enableSubtitles: _showSubtitles,
      ).timeout(_networkTimeout);
      if (mounted) {
        setState(() {
          _recommendationData = {
            'title': streamingInfo['title'] ??
                recommendation['title'] ??
                recommendation['name'] ??
                'Untitled',
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
    } on TimeoutException catch (te) {
      debugPrint('fetchRecommendations timed out: $te');
    } catch (e) {
      debugPrint('Failed to fetch streaming URL for recommendation: $e');
    }
  }

  void _playRecommendedMovie() {
    if (_recommendationData == null ||
        (_recommendationData!['videoPath'] ?? '').isEmpty) {
      return;
    }
    final nextVideoPath = _recommendationData!['videoPath'];
    final nextTitle = _recommendationData!['title'];
    if (nextVideoPath != null) {
      _switchVideo(nextVideoPath, nextTitle);
    }
  }

  Future<void> _switchVideo(String videoPath, String title,
      {String? newSubtitleUrl, bool isHls = false}) async {
    if (!mounted) return;
    setState(() {
      _currentVideoPath = videoPath;
      _title = title;
      _showRecommendationsBar = false;
      _recommendationData = null;
      _isInitialized = false;
      _resumePosition = null;
      _errorMessage = null;
    });

    try {
      try {
        await _betterPlayerController.pause();
      } catch (_) {}

      final List<BetterPlayerSubtitlesSource> subtitles = [];
      final subtitleCandidate = newSubtitleUrl ?? (_streamingInfo?['subtitleUrl'] as String?) ?? widget.subtitleUrl ?? _currentSubtitleUrl;
      if (subtitleCandidate != null && subtitleCandidate.isNotEmpty) {
        if (subtitleCandidate.startsWith('http') || subtitleCandidate.startsWith('https')) {
          subtitles.add(BetterPlayerSubtitlesSource(
            type: BetterPlayerSubtitlesSourceType.network,
            name: 'Subtitles',
            urls: [subtitleCandidate],
          ));
        } else if (!kIsWeb) {
          subtitles.add(BetterPlayerSubtitlesSource(
            type: BetterPlayerSubtitlesSourceType.file,
            name: 'Subtitles',
            urls: [subtitleCandidate],
          ));
        }
      }

      final pre = await _preflightUrl(videoPath);
      final resolvedPath = (pre['url'] as String?) ?? videoPath;
      debugPrint('Switch video preflight: $videoPath -> $resolvedPath (status=${pre['statusCode']})');

      final headers = _buildHeadersForUrl(resolvedPath, forceReferer: false);

      final isFile = (!resolvedPath.startsWith('http') && !resolvedPath.startsWith('https'));

      final dataSource = BetterPlayerDataSource(
        isFile ? BetterPlayerDataSourceType.file : BetterPlayerDataSourceType.network,
        resolvedPath,
        headers: headers,
        liveStream: isHls,
        useAsmsSubtitles: true,
        useAsmsTracks: true,
        useAsmsAudioTracks: true,
        videoFormat: isHls ? BetterPlayerVideoFormat.hls : null,
        subtitles: subtitles.isNotEmpty ? subtitles : null,
        bufferingConfiguration: _bufferingConfig,
      );

      try {
        await _betterPlayerController.setupDataSource(dataSource).timeout(_networkTimeout);
      } on TimeoutException catch (te) {
        debugPrint('setupDataSource timed out: $te');
        if (mounted) {
          setState(() {
            _errorMessage = 'Playback setup timed out';
          });
        }
        return;
      } on PlatformException catch (e) {
        debugPrint('PlatformException setting data source: $e');
        final altHeaders = _buildHeadersForUrl(resolvedPath, forceReferer: true);
        final altDataSource = dataSource.copyWith(
          headers: altHeaders,
          bufferingConfiguration: _bufferingConfig,
        );
        try {
          await _betterPlayerController.setupDataSource(altDataSource).timeout(_networkTimeout);
        } on TimeoutException catch (te) {
          debugPrint('alt setupDataSource timed out: $te');
          if (mounted) {
            setState(() {
              _errorMessage = 'Playback setup timed out (alt headers)';
            });
          }
          return;
        } catch (e) {
          debugPrint('Alt setupDataSource failed: $e');
          if (mounted) {
            setState(() {
              _errorMessage = 'Failed to setup data source: $e';
            });
          }
          return;
        }
      } catch (e) {
        debugPrint('setupDataSource failed: $e');
        if (mounted) {
          setState(() {
            _errorMessage = 'Failed to setup data source: $e';
          });
        }
        return;
      }

      final initializedOk = await _waitForInitialization(timeoutSeconds: 10);
      if (!initializedOk) {
        debugPrint('Switch data source failed to initialize within timeout.');
        if (mounted) {
          setState(() {
            _errorMessage = 'Playback setup failed (init timeout)';
            _isInitialized = false;
          });
        }
        throw Exception('Data source init failed');
      }

      setState(() {
        _isInitialized = (_videoValue?.initialized ?? false);
        _volume = (_videoValue?.volume ?? _volume);
      });

      if (!kIsWeb && subtitleCandidate != null && subtitleCandidate.isNotEmpty && (subtitleCandidate.startsWith('http') || subtitleCandidate.startsWith('https'))) {
        _currentSubtitleUrl = subtitleCandidate;
      }

      try {
        if (kIsWeb) {
          await _betterPlayerController.setVolume(0.0);
          await _betterPlayerController.play();
          setState(() {
            _isMuted = true;
            _volume = 0.0;
          });
        } else {
          await _betterPlayerController.play();
        }
      } catch (_) {}
    } catch (e) {
      debugPrint("Switch video error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to switch video: $e")),
        );
      }
      rethrow;
    }
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
      ).timeout(_networkTimeout);
      _streamingInfo = streamingInfo;
      final newUrl = streamingInfo['url'] ?? '';
      final newSubtitleUrl = streamingInfo['subtitleUrl'];
      final isHls = streamingInfo['type'] == 'm3u8';
      final newTitle =
          '${widget.title} - S${seasonNumber.toString().padLeft(2, '0')}E${episodeNumber.toString().padLeft(2, '0')}';

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
          _showNextEpisodeBar = false;
        });
      } else {
        throw Exception('No streaming URL found');
      }
    } on TimeoutException catch (te) {
      debugPrint('switchToEpisode getStreamingLink timed out: $te');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Request timed out while loading episode')));
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
    if (!widget.isFullSeason) return;
    if (widget.seasons == null || widget.seasons!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No seasons available for this TV show.')),
      );
      return;
    }
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
    if (_nextEpisodeData == null ||
        (_nextEpisodeData!['videoPath'] ?? '').isEmpty ||
        _nextEpisodeData!['episodeNumber'] == null) {
      return;
    }
    final nextEpisodeNumber = int.parse(_nextEpisodeData!['episodeNumber']!);
    _switchToEpisode(_currentSeasonNumber!, nextEpisodeNumber);
    setState(() {
      _currentEpisodeNumber = nextEpisodeNumber;
      _showNextEpisodeBar = false;
    });
  }

  Widget _buildControls() {
    final vp = _videoValue;
    if (!_isInitialized || vp == null || (vp.initialized ?? false) == false)
      return const SizedBox.shrink();
    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Stack(
        children: [
          // [existing top controls & center controls & bottom bar — unchanged]
          // Top controls bar
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
                        icon: Icon(Icons.arrow_back,
                            color: _controlColor, size: _iconSize),
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
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.select) {
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
                            color: _controlColor,
                            fontSize: 18,
                            fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Row(
                      children: [
                        Focus(
                          child: IconButton(
                            icon: Icon(Icons.high_quality,
                                color: _controlColor, size: _iconSize),
                            onPressed: _showQualityMenu,
                          ),
                          onFocusChange: (hasFocus) {
                            if (hasFocus) {
                              _startHideTimer();
                            }
                          },
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent &&
                                event.logicalKey ==
                                    LogicalKeyboardKey.select) {
                              _showQualityMenu();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                        ),
                        Focus(
                          child: IconButton(
                            icon: Icon(Icons.speed,
                                color: _controlColor, size: _iconSize),
                            onPressed: _showSpeedMenu,
                          ),
                          onFocusChange: (hasFocus) {
                            if (hasFocus) {
                              _startHideTimer();
                            }
                          },
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent &&
                                event.logicalKey ==
                                    LogicalKeyboardKey.select) {
                              _showSpeedMenu();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                        ),
                        if (widget.audioTracks != null &&
                            widget.audioTracks!.isNotEmpty)
                          Focus(
                            child: IconButton(
                              icon: Icon(Icons.audiotrack,
                                  color: _controlColor, size: _iconSize),
                              onPressed: _showAudioTrackMenu,
                            ),
                            onFocusChange: (hasFocus) {
                              if (hasFocus) {
                                _startHideTimer();
                              }
                            },
                            onKeyEvent: (node, event) {
                              if (event is KeyDownEvent &&
                                  event.logicalKey ==
                                      LogicalKeyboardKey.select) {
                                _showAudioTrackMenu();
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                          ),
                        if (widget.subtitleTracks != null &&
                            widget.subtitleTracks!.isNotEmpty)
                          Focus(
                            child: IconButton(
                              icon: Icon(Icons.subtitles,
                                  color: _controlColor, size: _iconSize),
                              onPressed: _showSubtitleTrackMenu,
                            ),
                            onFocusChange: (hasFocus) {
                              if (hasFocus) {
                                _startHideTimer();
                              }
                            },
                            onKeyEvent: (node, event) {
                              if (event is KeyDownEvent &&
                                  event.logicalKey ==
                                      LogicalKeyboardKey.select) {
                                _showSubtitleTrackMenu();
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                          ),
                        Focus(
                          child: IconButton(
                            icon: Icon(Icons.settings,
                                color: _controlColor, size: _iconSize),
                            onPressed: _showSettingsMenu,
                          ),
                          onFocusChange: (hasFocus) {
                            if (hasFocus) {
                              _startHideTimer();
                            }
                          },
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent &&
                                event.logicalKey ==
                                    LogicalKeyboardKey.select) {
                              _showSettingsMenu();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                        ),
                        Focus(
                          child: IconButton(
                            icon: Icon(
                                _showSubtitles
                                    ? Icons.closed_caption
                                    : Icons.closed_caption_off,
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
                            if (event is KeyDownEvent &&
                                event.logicalKey == LogicalKeyboardKey.select) {
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
                              icon: Icon(Icons.list,
                                  color: _controlColor, size: _iconSize),
                              onPressed: _showEpisodeMenu,
                            ),
                            onFocusChange: (hasFocus) {
                              if (hasFocus) {
                                _startHideTimer();
                              }
                            },
                            onKeyEvent: (node, event) {
                              if (event is KeyDownEvent &&
                                  event.logicalKey ==
                                      LogicalKeyboardKey.select) {
                                _showEpisodeMenu();
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                          ),
                        if (widget.enablePiP)
                          Focus(
                            child: IconButton(
                              icon: Icon(Icons.picture_in_picture,
                                  color: _controlColor, size: _iconSize),
                              onPressed: _enterPiP,
                            ),
                            onFocusChange: (hasFocus) {
                              if (hasFocus) {
                                _startHideTimer();
                              }
                            },
                            onKeyEvent: (node, event) {
                              if (event is KeyDownEvent &&
                                  event.logicalKey ==
                                      LogicalKeyboardKey.select) {
                                _enterPiP();
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                          ),
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
                              if (event is KeyDownEvent &&
                                  event.logicalKey ==
                                      LogicalKeyboardKey.select) {
                                _toggleDownload();
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
          // Subtitles
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
                    shadows: [Shadow(offset: Offset(1, 1), color: Colors.black, blurRadius: 2)]),
              ),
            ),
          // Center controls (rewind/play/forward)
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Focus(
                  child: IconButton(
                    iconSize: _iconSize,
                    icon: Icon(Icons.replay_10, color: _controlColor),
                    onPressed: () {
                      final newPos = (vp.position as Duration) - const Duration(seconds: 10);
                      _betterPlayerController.seekTo(newPos > Duration.zero ? newPos : Duration.zero);
                      _startHideTimer();
                    },
                  ),
                  onFocusChange: (hasFocus) {
                    if (hasFocus) {
                      _startHideTimer();
                    }
                  },
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.select) {
                      final newPos = (vp.position as Duration) - const Duration(seconds: 10);
                      _betterPlayerController.seekTo(newPos > Duration.zero ? newPos : Duration.zero);
                      _startHideTimer();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                ),
                Focus(
                  child: IconButton(
                    iconSize: _iconSize + 24,
                    icon: Icon((vp.isPlaying ?? false) ? Icons.pause_circle_filled : Icons.play_circle_filled,
                        color: _controlColor),
                    onPressed: () {
                      setState(() {
                        if (vp.isPlaying ?? false) {
                          _betterPlayerController.pause();
                        } else {
                          _betterPlayerController.play();
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
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.select) {
                      setState(() {
                        if (vp.isPlaying ?? false) {
                          _betterPlayerController.pause();
                        } else {
                          _betterPlayerController.play();
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
                      final newPos = (vp.position as Duration) + const Duration(seconds: 10);
                      if (newPos < (vp.duration as Duration)) {
                        _betterPlayerController.seekTo(newPos);
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
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.select) {
                      final newPos = (vp.position as Duration) + const Duration(seconds: 10);
                      if (newPos < (vp.duration as Duration)) {
                        _betterPlayerController.seekTo(newPos);
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
            Center(child: Text(_formatDuration(_seekTargetDuration!), style: const TextStyle(color: Colors.white, fontSize: 24))),
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
                        _nextEpisodeData != null ? 'Next: ${_nextEpisodeData!['title']}' : 'Loading next episode...',
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
          // Bottom bar with progress and controls
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [Colors.transparent, Colors.black87], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _builderProgressBar(),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(_formatDuration(vp.position as Duration), style: TextStyle(color: _controlColor, fontSize: 14)),
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
                                        try {
                                          _betterPlayerController.setVolume(value);
                                        } catch (_) {}
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
                                      child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close', style: TextStyle(color: Colors.white))),
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
                                        try {
                                          _betterPlayerController.setVolume(value);
                                        } catch (_) {}
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
                                      child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close', style: TextStyle(color: Colors.white))),
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
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Fullscreen toggled")));
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
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Fullscreen toggled")));
                              }
                              _startHideTimer();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                        ),
                        const SizedBox(width: 8),
                        Text(_formatDuration(vp.duration as Duration), style: TextStyle(color: _controlColor, fontSize: 14)),
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

  Widget _builderProgressBar() {
    final vp = _videoValue;
    if (vp == null || (vp.initialized ?? false) == false) {
      return const SizedBox.shrink();
    }

    final duration = (vp.duration as Duration);
    final position = (vp.position as Duration);
    final maxMs = duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;
    final posMs = position.inMilliseconds.toDouble().clamp(0.0, maxMs);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Slider(
          value: _seekTargetDuration != null
              ? _seekTargetDuration!.inMilliseconds.toDouble().clamp(0.0, maxMs)
              : posMs,
          min: 0,
          max: maxMs,
          divisions: duration.inSeconds > 0 ? duration.inSeconds : 1,
          onChanged: (value) {
            setState(() {
              _seekTargetDuration = Duration(milliseconds: value.round());
            });
          },
          onChangeEnd: (value) {
            try {
              final target = Duration(milliseconds: value.round());
              _betterPlayerController.seekTo(target);
            } catch (_) {}
            setState(() => _seekTargetDuration = null);
            _startHideTimer();
          },
        ),
      ],
    );
  }

  Widget _buildLoadingScreen() {
    return const MovieflixLoader();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final vp = _videoValue;
      if (!mounted || vp == null) return;
      final buffering = (vp.isBuffering ?? false);
      if (buffering != _isBuffering) {
        setState(() {
          _isBuffering = buffering;
        });
      }
      _updateSubtitle();
      _checkForEndOfContent();
    });
  }

  /// -------------------------
  /// NEW: Pause overlay (Netflix-like)
  /// -------------------------
  /// Lightweight overlay that appears when playback is paused.
  Widget _buildPauseOverlay(BuildContext context) {
    // Condition: show overlay when video is initialized and paused (not buffering)
    final vp = _videoValue;
    if (vp == null || (vp.initialized ?? false) == false) return const SizedBox.shrink();
    final isPlaying = vp.isPlaying ?? false;
    if (isPlaying || _isBuffering) return const SizedBox.shrink();

    final accent = Theme.of(context).colorScheme.secondary;
    final imageUrl = _getPauseImageUrl();
    final synopsis = (_streamingInfo?['overview'] as String?) ??
        (_streamingInfo?['synopsis'] as String?) ??
        ''; // fallback empty
    final panelWidth = 440.0;
    final panelHeight = MediaQuery.of(context).size.height * 0.55;

    return Positioned(
      right: 48,
      top: MediaQuery.of(context).size.height * 0.15,
      child: RepaintBoundary(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: panelWidth,
            height: panelHeight,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Banner/poster (left) - use simple poster image
                SizedBox(
                  height: panelHeight * 0.56,
                  width: double.infinity,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: Colors.grey[900]),
                      errorWidget: (_, __, ___) => Container(color: Colors.grey[800]),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: accent, fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  synopsis.isNotEmpty ? synopsis : 'No description available.',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: () async {
                        try {
                          await _betterPlayerController.play();
                        } catch (_) {}
                        _startHideTimer();
                        setState(() {
                          _showControls = false;
                        });
                      },
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Resume'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () {
                        try {
                          _betterPlayerController.seekTo(Duration.zero);
                          _betterPlayerController.play();
                        } catch (_) {}
                        _startHideTimer();
                        setState(() {
                          _showControls = false;
                        });
                      },
                      child: const Text('Restart'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () {
                        // show more info - route to detail screen (arguments provided)
                        Navigator.pushNamed(context, '/movie_detail', arguments: {
                          'title': widget.title,
                          'releaseYear': widget.releaseYear,
                          'streamingInfo': _streamingInfo,
                        });
                      },
                      child: const Text('More Info'),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Add to My List',
                      onPressed: () async {
                        // lightweight toggle: store a small flag in SharedPreferences
                        try {
                          final prefs = await SharedPreferences.getInstance();
                          final key = 'mylist_${widget.title.hashCode}';
                          final exists = prefs.getBool(key) ?? false;
                          await prefs.setBool(key, !exists);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(!exists ? 'Added to My List' : 'Removed from My List')));
                        } catch (e) {
                          debugPrint('MyList toggle failed: $e');
                        }
                      },
                      icon: Icon(Icons.add, color: Colors.white),
                    )
                  ],
                ),
                const SizedBox(height: 10),
                // compact similar items row — very lightweight (1-row thumbnails)
                if (widget.similarMovies.isNotEmpty) ...[
                  const Divider(color: Colors.white12),
                  SizedBox(
                    height: 72,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: widget.similarMovies.length > 8 ? 8 : widget.similarMovies.length,
                      itemBuilder: (context, i) {
                        final item = widget.similarMovies[i];
                        final poster = (item['poster_path'] as String?) ?? (item['backdrop_path'] as String?) ?? '';
                        final posterUrl = poster.isNotEmpty ? 'https://image.tmdb.org/t/p/w300$poster' : 'https://via.placeholder.com/300x170';
                        final title = (item['title'] ?? item['name'])?.toString() ?? 'Untitled';
                        return Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: GestureDetector(
                            onTap: () async {
                              // optimistic try-play for tapped recommendation
                              final releaseDate = item['release_date'] as String? ?? item['first_air_date'] as String? ?? '1970-01-01';
                              final releaseYear = int.tryParse(releaseDate.split('-').first) ?? widget.releaseYear;
                              try {
                                final streamingInfo = await StreamingService.getStreamingLink(
                                  tmdbId: (item['id'] ?? '').toString(),
                                  title: title,
                                  releaseYear: releaseYear,
                                  resolution: _selectedQuality,
                                  enableSubtitles: _showSubtitles,
                                ).timeout(_networkTimeout);
                                final nextUrl = streamingInfo['url'] ?? '';
                                if (nextUrl.isNotEmpty) {
                                  await _switchVideo(nextUrl, title, newSubtitleUrl: streamingInfo['subtitleUrl'], isHls: (streamingInfo['type'] == 'm3u8'));
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Unable to play selection')));
                                }
                              } catch (e) {
                                debugPrint('Failed to play recommendation: $e');
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to load selection')));
                              }
                            },
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: SizedBox(
                                width: 110,
                                child: CachedNetworkImage(
                                  imageUrl: posterUrl,
                                  height: 72,
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) => Container(color: Colors.grey[900]),
                                  errorWidget: (_, __, ___) => Container(color: Colors.grey[800]),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getPauseImageUrl() {
    // Prefer streamingInfo backdrop/poster, else fallback to first similar movie poster/backdrop, else placeholder.
    final backdrop = (_streamingInfo?['backdrop_path'] as String?) ?? (_streamingInfo?['poster_path'] as String?);
    if (backdrop != null && backdrop.isNotEmpty) {
      // choose a moderate size to reduce decode overhead
      return 'https://image.tmdb.org/t/p/w780$backdrop';
    }
    if (widget.similarMovies.isNotEmpty) {
      final first = widget.similarMovies.first;
      final fb = (first['backdrop_path'] as String?) ?? (first['poster_path'] as String?);
      if (fb != null && fb.isNotEmpty) {
        return 'https://image.tmdb.org/t/p/w780$fb';
      }
    }
    return 'https://via.placeholder.com/780x438';
  }

  void _startPollingIfNeeded() {
    if (_pollTimer == null || !_pollTimer!.isActive) _startPolling();
  }

  @override
  Widget build(BuildContext context) {
    debugPrint("enablePiP=${widget.enablePiP}, audio=${widget.audioTracks}, subtitles=${widget.subtitleTracks}");
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
          : FutureBuilder(
              future: _videoInitFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return _buildLoadingScreen();
                }
                _startPollingIfNeeded();
                return FocusScope(
                  child: Stack(
                    children: [
                      Container(color: Colors.black),
                      if (_videoValue != null && (_videoValue?.initialized ?? false))
                        Center(
                          child: AspectRatio(
                            aspectRatio: (_videoValue?.aspectRatio ?? 16.0 / 9.0),
                            child: BetterPlayer(controller: _betterPlayerController),
                          ),
                        )
                      else
                        const SizedBox.shrink(),
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
                            final vp = _videoValue;
                            if (vp == null || (vp.initialized ?? false) == false) return;
                            if (tapX < screenWidth / 3) {
                              final newPos = (vp.position as Duration) - const Duration(seconds: 10);
                              _betterPlayerController.seekTo(newPos > Duration.zero ? newPos : Duration.zero);
                              setState(() {
                                _seekFeedback = "-10s";
                              });
                            } else if (tapX > screenWidth * 2 / 3) {
                              final newPos = (vp.position as Duration) + const Duration(seconds: 10);
                              if (newPos < (vp.duration as Duration)) {
                                _betterPlayerController.seekTo(newPos);
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
                          onVerticalDragStart: _onVerticalDragStart,
                          onVerticalDragUpdate: _onVerticalDragUpdate,
                          onVerticalDragEnd: _onVerticalDragEnd,
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

                      // NEW: Pause overlay (Netflix-like)
                      _buildPauseOverlay(context),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

/// AnimatedText preserved
class AnimatedText extends StatefulWidget {
  const AnimatedText({super.key});

  @override
  AnimatedTextState createState() => AnimatedTextState();
}

class AnimatedTextState extends State<AnimatedText> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(seconds: 2), vsync: this)..repeat(reverse: true);
    _animation = CurvedAnimation(parent: _controller, curve: Curves.bounceInOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _animation,
      child: const Text(
        'Movieflix Loading...',
        style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// Episode selector unchanged aside from minor null-safety usage
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
      orElse: () => widget.seasons.isNotEmpty ? widget.seasons.first : {'season_number': 1, 'episodes': []},
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
                  return DropdownMenuItem<int>(value: season['season_number'] as int, child: Text('Season ${season['season_number']}'));
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
              if (episodes.isEmpty)
                const Text('No episodes available', style: TextStyle(color: Colors.white70))
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: episodes.length,
                    itemBuilder: (context, index) {
                      final episode = episodes[index];
                      final episodeNumber = episode['episode_number'] as int;
                      final isCurrent = _selectedSeasonNumber == widget.currentSeasonNumber && episodeNumber == widget.currentEpisodeNumber;
                      return ListTile(
                        title: Text(
                          'Episode $episodeNumber: ${episode['name'] ?? 'Episode $episodeNumber'}',
                          style: TextStyle(color: isCurrent ? Colors.grey : Colors.white),
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
        ));
  }
}
