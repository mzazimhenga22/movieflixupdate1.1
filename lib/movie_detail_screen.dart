// movie_detail_screen.dart
import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart' hide DownloadProgress;
import 'package:shimmer/shimmer.dart';
import 'package:path/path.dart' as p;

import 'package:movie_app/main_videoplayer.dart';
import 'package:movie_app/components/trailer_section.dart';
import 'package:movie_app/components/similar_movies_section.dart';
import 'package:movie_app/mylist_screen.dart';
import 'package:movie_app/tmdb_api.dart' as tmdb;
import 'package:movie_app/streaming_service.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/tv_show_episodes_section.dart';

/// AD: google_mobile_ads
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// MovieDetailScreen with a Netflix-like persistent download overlay.
/// Passes the full m3u8 returned by StreamingService to MainVideoPlayer.

class MovieDetailScreen extends StatefulWidget {
  final Map<String, dynamic> movie;

  const MovieDetailScreen({super.key, required this.movie});

  @override
  MovieDetailScreenState createState() => MovieDetailScreenState();
}

class MovieDetailScreenState extends State<MovieDetailScreen> {
  Future<Map<String, dynamic>>? _tvDetailsFuture;
  Future<Map<String, dynamic>>? _processedDetailsFuture; // COMPUTE: processed ui data
  String _selectedResolution = "720p";
  bool _enableSubtitles = false;
  late final bool _isTvShow;
  List<Map<String, dynamic>> _similarMovies = [];
  int? _releaseYear;

  final ValueNotifier<DownloadProgress?> _downloadProgressNotifier = ValueNotifier(null);
  final Set<String> _activeDownloads = <String>{};

  bool _isModalLoadingVisible = false;

  // Overlay for persistent download UI
  OverlayEntry? _downloadOverlayEntry;

  // Background download state
  CancelToken? _currentCancelToken;
  bool _isBackgroundDownloading = false;
  String? _backgroundMessage;
  Future<String>? _backgroundMergeFuture;
  String? _backgroundTitle;

  // ---------- AD: RewardedAd for loading period ----------
  RewardedAd? _loadingRewardedAd;
  bool _adShownDuringLoad = false;
  bool _isAdLoading = false;

  @override
  void initState() {
    super.initState();

    _isTvShow = (widget.movie['media_type']?.toString().toLowerCase() == 'tv') ||
        (widget.movie['seasons'] != null && (widget.movie['seasons'] as List).isNotEmpty);

    /// AD: initialize Mobile Ads
    MobileAds.instance.initialize();

    if (_isTvShow) {
      _tvDetailsFuture = tmdb.TMDBApi.fetchTVShowDetails(widget.movie['id']);
      // chain compute once tv details are present
      _processedDetailsFuture = _tvDetailsFuture!.then((tvData) {
        final merged = {...widget.movie, ...?tvData};
        return compute<Map<String, dynamic>, Map<String, dynamic>>(prepareDetailsWorker, merged);
      }).catchError((_) {
        // fallback to computing from original movie map
        return compute<Map<String, dynamic>, Map<String, dynamic>>(prepareDetailsWorker, widget.movie);
      });
    } else {
      _processedDetailsFuture = compute<Map<String, dynamic>, Map<String, dynamic>>(prepareDetailsWorker, widget.movie);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchSimilarMovies();
      _fetchReleaseYear();
    });
  }

  @override
  void dispose() {
    _downloadProgressNotifier.dispose();
    _removeDownloadOverlay();

    // AD cleanup
    _loadingRewardedAd = null;
    super.dispose();
  }

  // ------------------ modal-loading helpers (AD integrated) ------------------

  void showModalLoading() {
    if (!mounted) return;
    if (_isModalLoadingVisible) return;
    _isModalLoadingVisible = true;

    // Start loading an ad while the dialog is visible
    _loadRewardedAd();

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dctx) => const LoadingDialog(),
    );
  }

  void dismissModalLoading() {
    if (!_isModalLoadingVisible) return;
    if (!mounted) {
      _isModalLoadingVisible = false;
      return;
    }
    try {
      Navigator.of(context, rootNavigator: true).pop();
    } catch (_) {}
    _isModalLoadingVisible = false;
  }

  /// AD: Load RewardedAd and show it while loading dialog is up
  void _loadRewardedAd() {
    if (_isAdLoading || _loadingRewardedAd != null || _adShownDuringLoad) return;
    _isAdLoading = true;

    final adUnitId = Platform.isAndroid
        ? 'ca-app-pub-3940256099942544/5224354917' // test rewarded ad - Android
        : 'ca-app-pub-3940256099942544/1712485313'; // test rewarded ad - iOS

    RewardedAd.load(
      adUnitId: adUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          if (!mounted) return;
          _loadingRewardedAd = ad;
          _isAdLoading = false;

          // show ad if still showing loading dialog
          if (_isModalLoadingVisible && !_adShownDuringLoad) {
            try {
              _loadingRewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
                onAdShowedFullScreenContent: (ad) {
                  _adShownDuringLoad = true;
                },
                onAdDismissedFullScreenContent: (ad) {
                  // once dismissed, release
                  _loadingRewardedAd = null;
                },
                onAdFailedToShowFullScreenContent: (ad, err) {
                  debugPrint('Ad failed to show: $err');
                  _loadingRewardedAd = null;
                },
              );

              _loadingRewardedAd!.show(onUserEarnedReward: (ad, reward) {
                // optional: you could grant a small reward or track metrics
                debugPrint('User earned reward during loading: ${reward.amount} ${reward.type}');
              });
            } catch (e) {
              debugPrint('Exception showing rewarded ad: $e');
              _loadingRewardedAd = null;
            }
          }
        },
        onAdFailedToLoad: (err) {
          debugPrint('RewardedAd failed to load: $err');
          _isAdLoading = false;
          _loadingRewardedAd = null;
        },
      ),
    );
  }

  // ------------------ end modal-loading helpers -----------------------

  Future<void> _fetchReleaseYear() async {
    try {
      final releaseDate = _isTvShow
          ? widget.movie['first_air_date'] as String? ?? '1970-01-01'
          : widget.movie['release_date'] as String? ?? '1970-01-01';
      final year = int.parse(releaseDate.split('-')[0]);
      if (mounted) setState(() => _releaseYear = year);
    } catch (e) {
      debugPrint('Failed to parse release year: $e');
      if (mounted) setState(() => _releaseYear = 1970);
    }
  }

  Future<void> _fetchSimilarMovies() async {
    try {
      final similar = await tmdb.TMDBApi.fetchSimilarMovies(widget.movie['id']);
      if (mounted) {
        setState(() => _similarMovies = similar.cast<Map<String, dynamic>>());
      }
    } catch (e) {
      debugPrint('Failed to fetch similar movies: $e');
    }
  }

  Future<void> _shareMovie(Map<String, dynamic> details) async {
    const defaultSubject = 'Recommendation';
    final message = "Check out ${details['title'] ?? details['name']}!\n\n${details['synopsis'] ?? details['overview'] ?? ''}";
    final subject = details['title'] ?? details['name'] ?? defaultSubject;

    try {
      final params = ShareParams(text: message, subject: subject);
      await SharePlus.instance.share(params);
    } catch (e) {
      debugPrint('Share failed: $e');
    }
  }

  Future<void> _addToMyList(Map<String, dynamic> details) async {
    final prefs = await SharedPreferences.getInstance();
    final myList = prefs.getStringList('myList') ?? [];
    final movieId = details['id'].toString();

    if (!myList.any((jsonStr) => (json.decode(jsonStr))['id'].toString() == movieId)) {
      myList.add(json.encode(details));
      await prefs.setStringList('myList', myList);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${details['title'] ?? details['name']} added to My List.')),
      );
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const MyListScreen()));
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${details['title'] ?? details['name']} is already in My List.')),
      );
    }
  }

  void _showDownloadOptionsModal(Map<String, dynamic> details) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        String downloadResolution = _selectedResolution;
        bool downloadSubtitles = _enableSubtitles;
        return _DownloadOptionsModal(
          initialResolution: downloadResolution,
          initialSubtitles: downloadSubtitles,
          onConfirm: (resolution, subtitles) {
            if (_isTvShow && (details['season'] == null || details['episode'] == null)) {
              Navigator.pop(context);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Pick an episode from the Episodes list to download.')),
                );
              }
              return;
            }
            _downloadMovie(details, resolution: resolution, subtitles: subtitles, mergeSegments: true);
          },
        );
      },
    );
  }

  Future<bool> _requestStoragePermission() async {
    if (Platform.isAndroid) {
      final manageStatus = await Permission.manageExternalStorage.status;
      if (manageStatus.isGranted) {
        return true;
      }

      final result = await Permission.manageExternalStorage.request();
      if (result.isGranted) {
        return true;
      }

      if (result.isPermanentlyDenied) {
        final accentColor = Provider.of<SettingsProvider>(context, listen: false).accentColor;
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: Colors.black87,
            title: const Text("Permission Required", style: TextStyle(color: Colors.white)),
            content: const Text("Please grant “All files access” in Settings\nso we can download your movies.", style: TextStyle(color: Colors.white70)),
            actions: [
              TextButton(
                onPressed: () {
                  openAppSettings();
                  Navigator.pop(context);
                },
                child: Text("Open Settings", style: TextStyle(color: accentColor)),
              ),
            ],
          ),
        );
      }
      return false;
    } else {
      final status = await Permission.storage.status;
      if (status.isGranted) return true;
      final result = await Permission.storage.request();
      return result.isGranted;
    }
  }

  /// Called by episodes list to start a background download
  Future<void> downloadEpisodeFromChild({
    required int season,
    required int episode,
    required String showTitle,
    required int showId,
    required String resolution,
    required bool subtitles,
  }) async {
    final details = <String, dynamic>{'id': showId, 'title': showTitle, 'season': season, 'episode': episode};

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Starting download...')));
    }

    _startDownload(details, resolution, subtitles);
  }

  Future<void> _startDownload(Map<String, dynamic> details, String resolution, bool subtitles) async {
    final tmdbId = details['id']?.toString() ?? '';
    final seasonNumber = details['season'] != null ? (details['season'] as num).toInt() : null;
    final episodeNumber = details['episode'] != null ? (details['episode'] as num?)?.toInt() : null;
    final idSuffix = (seasonNumber != null && episodeNumber != null) ? '_s${seasonNumber}_e${episodeNumber}' : '';
    final key = 'download_${tmdbId}${idSuffix}';

    if (_activeDownloads.contains(key)) {
      debugPrint('Download already active: $key');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download already in progress.')));
      }
      return;
    }

    _activeDownloads.add(key);
    try {
      await _downloadMovie(details, resolution: resolution, subtitles: subtitles, mergeSegments: true);
    } finally {
      _activeDownloads.remove(key);
    }
  }

  Future<void> _downloadMovie(Map<String, dynamic> details, {required String resolution, required bool subtitles, bool mergeSegments = true}) async {
    final tmdbId = details['id']?.toString() ?? '';
    final title = details['title']?.toString() ?? details['name']?.toString() ?? 'Untitled';
    final seasonNumber = details['season'] != null ? (details['season'] as num).toInt() : null;
    final episodeNumber = details['episode'] != null ? (details['episode'] as num?)?.toInt() : null;
    final idSuffix = (seasonNumber != null && episodeNumber != null) ? '_s${seasonNumber}_e${episodeNumber}' : '';

    Map<String, String> streamingInfo;
    try {
      streamingInfo = await StreamingService.getStreamingLink(
        tmdbId: tmdbId,
        title: title,
        releaseYear: _releaseYear ?? 1970,
        resolution: resolution,
        enableSubtitles: subtitles,
        season: seasonNumber,
        episode: episodeNumber,
        forDownload: true,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Unable to start download. Please try again later.")),
      );
      return;
    }

    final downloadUrl = streamingInfo['url'];
    final urlType = streamingInfo['type'] ?? 'unknown';

    if (downloadUrl == null || downloadUrl.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Download unavailable at this time.")));
      return;
    }

    if (!await _requestStoragePermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Storage permission is required to download.")));
      return;
    }

    final downloadId = 'movie_${tmdbId}${idSuffix}';

    _currentCancelToken = CancelToken();
    final cancelToken = _currentCancelToken!;
    _backgroundMessage = null;

    bool finished = false;
    Map<String, String>? result;

    _showDownloadOverlay(cancelToken, title);

    try {
      result = await OfflineDownloader.downloadAnyStream(
        streamInfo: streamingInfo,
        id: downloadId,
        preferredResolution: resolution,
        mergeSegments: false,
        concurrency: 6,
        onProgress: (p) {
          _downloadProgressNotifier.value = p;
        },
        cancelToken: cancelToken,
      );
      finished = true;
    } catch (e) {
      if (e.toString().toLowerCase().contains('cancel')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download cancelled.')));
        }
        _currentCancelToken = null;
        _isBackgroundDownloading = false;
        _downloadProgressNotifier.value = null;
        _removeDownloadOverlay();
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
      _currentCancelToken = null;
      _isBackgroundDownloading = false;
      _downloadProgressNotifier.value = null;
      _removeDownloadOverlay();
      return;
    }

    if (!finished || result == null) {
      _currentCancelToken = null;
      _isBackgroundDownloading = false;
      _downloadProgressNotifier.value = null;
      _removeDownloadOverlay();
      return;
    }

    final res = result;

    // For mp4 direct downloads
    if (res['type'] == 'mp4' && res['file'] != null) {
      final record = {
        'id': downloadId,
        'tmdbId': tmdbId,
        'title': title,
        'path': res['file']!,
        'type': res['type'] ?? urlType,
        'resolution': resolution,
        'subtitle': res['subtitle'] ?? streamingInfo['subtitleUrl'] ?? '',
        'timestamp': DateTime.now().toIso8601String(),
      };
      await _saveDownloadRecord(record);

      _currentCancelToken = null;
      _isBackgroundDownloading = false;
      _downloadProgressNotifier.value = null;
      _removeDownloadOverlay();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Download finished: ${details['title'] ?? details['name']}'),
          action: SnackBarAction(
            label: 'Play',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => MainVideoPlayer(
                    videoPath: res['file']!,
                    title: title,
                    releaseYear: _releaseYear ?? 1970,
                    isFullSeason: seasonNumber != null && episodeNumber != null,
                    episodeFiles: const [],
                    similarMovies: _similarMovies,
                    subtitleUrl: res['subtitle'] ?? streamingInfo['subtitleUrl'],
                    isHls: false,
                  ),
                ),
              );
            },
          ),
        ),
      );
      return;
    }

    // HLS finalization
    if (res['type'] == 'm3u8' && (res['playlist'] ?? '').isNotEmpty) {
      final playlistPath = res['playlist']!;
      final outDir = p.dirname(playlistPath);

      final workerArgs = <String, String>{
        'playlist': playlistPath,
        'outDir': outDir,
        'id': downloadId,
      };

      Future<String> mergeFuture;
      try {
        mergeFuture = compute(mergeSegmentsWorker, workerArgs);
      } catch (e) {
        mergeFuture = Future<String>(() async {
          return await _mergeSegmentsOnMainIsolate(playlistPath, outDir, downloadId);
        });
      }

      setState(() {
        _isBackgroundDownloading = true;
        _backgroundMergeFuture = mergeFuture;
        _backgroundTitle = title;
        _backgroundMessage = 'Finalizing download...';
      });

      mergeFuture.then((mergedPath) async {
        final record = {
          'id': downloadId,
          'tmdbId': tmdbId,
          'title': title,
          'path': mergedPath.isNotEmpty ? mergedPath : playlistPath,
          'type': 'm3u8',
          'resolution': resolution,
          'subtitle': res['subtitle'] ?? streamingInfo['subtitleUrl'] ?? '',
          'timestamp': DateTime.now().toIso8601String(),
        };
        try {
          await _saveDownloadRecord(record);
        } catch (e) {
          debugPrint('Failed to save download record after merge: $e');
        }

        if (mounted) {
          setState(() {
            _isBackgroundDownloading = false;
            _backgroundMergeFuture = null;
            _backgroundMessage = null;
            _backgroundTitle = null;
          });
          _downloadProgressNotifier.value = null;
          _removeDownloadOverlay();

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Download finished: ${details['title'] ?? details['name']}'),
              action: SnackBarAction(
                label: 'Play',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => MainVideoPlayer(
                        videoPath: mergedPath.isNotEmpty ? mergedPath : playlistPath,
                        title: title,
                        releaseYear: _releaseYear ?? 1970,
                        isFullSeason: seasonNumber != null && episodeNumber != null,
                        episodeFiles: const [],
                        similarMovies: _similarMovies,
                        subtitleUrl: res['subtitle'] ?? streamingInfo['subtitleUrl'],
                        isHls: true,
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        }
      }).catchError((e) {
        debugPrint('Background merge failed: $e');
        if (mounted) {
          setState(() {
            _isBackgroundDownloading = false;
            _backgroundMergeFuture = null;
            _backgroundMessage = 'Finalizing failed';
          });
          _downloadProgressNotifier.value = null;
          _removeDownloadOverlay();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Finalizing failed: $e')));
        }
      }).whenComplete(() {
        _currentCancelToken = null;
      });

      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download finished but no playable file found.')));
    }
    _currentCancelToken = null;
    _isBackgroundDownloading = false;
    _downloadProgressNotifier.value = null;
    _removeDownloadOverlay();
  }

  // ---------- Overlay (Netflix-like) ----------
  void _showDownloadOverlay(CancelToken cancelToken, String title) {
    if (_downloadOverlayEntry != null) return;

    _downloadOverlayEntry = OverlayEntry(builder: (context) {
      final settings = Provider.of<SettingsProvider>(context);
      return Positioned(
        left: 16,
        right: 16,
        bottom: 24,
        child: Material(
          color: Colors.transparent,
          child: ValueListenableBuilder<DownloadProgress?>(
            valueListenable: _downloadProgressNotifier,
            builder: (context, progress, _) {
              final downloadedSegments = progress?.downloadedSegments ?? 0;
              final totalSegments = progress?.totalSegments ?? 0;
              final bytes = progress?.bytesDownloaded ?? 0;
              final totalBytes = progress?.totalBytes;
              final isFinalizing = progress?.finalizing ?? _isBackgroundDownloading;
              final message = progress?.message ?? _backgroundMessage ?? (isFinalizing ? 'Finalizing...' : 'Downloading...');
              double? fraction;
              if (totalBytes != null && totalBytes > 0) {
                fraction = bytes / totalBytes;
              } else if (totalSegments > 0) {
                fraction = downloadedSegments / totalSegments;
              }

              return Card(
                color: Colors.black87,
                elevation: 12,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(
                    children: [
                      Container(
                        width: 64,
                        height: 36,
                        color: Colors.grey[850],
                        child: const Icon(Icons.downloading, color: Colors.white54),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 6),
                            Text(message, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: LinearProgressIndicator(value: fraction, minHeight: 6),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  totalBytes != null
                                      ? '${_bytesToReadable(bytes)} / ${_bytesToReadable(totalBytes)}'
                                      : (totalSegments > 0 ? '${downloadedSegments}/${totalSegments} segs' : _bytesToReadable(bytes)),
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                                Row(
                                  children: [
                                    TextButton(
                                      onPressed: () {
                                        _removeDownloadOverlay();
                                      },
                                      child: const Text('Hide', style: TextStyle(color: Colors.white70)),
                                    ),
                                    const SizedBox(width: 4),
                                    TextButton(
                                      onPressed: () {
                                        cancelToken.cancel();
                                        setState(() {
                                          _backgroundMessage = 'Cancel requested...';
                                        });
                                        _currentCancelToken = null;
                                        _downloadProgressNotifier.value = null;
                                        _removeDownloadOverlay();
                                      },
                                      child: const Text('Cancel', style: TextStyle(color: Colors.redAccent)),
                                    ),
                                  ],
                                )
                              ],
                            )
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
    });

    try {
      final overlay = Overlay.of(context);
      overlay?.insert(_downloadOverlayEntry!);
    } catch (e) {
      debugPrint('Failed to insert overlay: $e');
    }
  }

  void _removeDownloadOverlay() {
    try {
      _downloadOverlayEntry?.remove();
    } catch (_) {}
    _downloadOverlayEntry = null;
  }

  // ---------- Download helpers ----------
  Future<void> _saveDownloadRecord(Map<String, dynamic> record) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('downloads') ?? [];
    list.add(json.encode(record));
    await prefs.setStringList('downloads', list);
  }

  String _bytesToReadable(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(2)} ${suffixes[i]}';
  }

  void _rateMovie(Map<String, dynamic> details) {
    double rating = 3.0;
    showDialog(
      context: context,
      builder: (context) {
        return _RatingDialog(
          title: details['title'] ?? details['name'] ?? 'Rate Item',
          onRatingChanged: (value) => rating = value,
          onSubmit: () {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Rating submitted: $rating")));
          },
        );
      },
    );
  }

  void _showPlayOptionsModal(Map<String, dynamic> details, bool isTvShow) {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (modalContext) {
        return _PlayOptionsModal(
          initialResolution: _selectedResolution,
          initialSubtitles: _enableSubtitles,
          onConfirm: (resolution, subtitles) async {
            setState(() {
              _selectedResolution = resolution;
              _enableSubtitles = subtitles;
            });
            await _launchStreamingPlayer(details, isTvShow, resolution, subtitles);
          },
        );
      },
    );
  }

  String _normalizeVideoPath(String raw) {
    if (raw.startsWith('file://')) return raw;
    if (raw.startsWith('/')) return raw;
    return raw;
  }

  Future<void> _launchStreamingPlayer(Map<String, dynamic> details, bool isTvShow, String resolution, bool subtitles) async {
    if (!mounted) return;

    showModalLoading();

    Map<String, String> streamingInfo = {};
    List<String> episodeFiles = [];
    int initialSeasonNumber = 1;
    int initialEpisodeNumber = 1;

    try {
      if (isTvShow) {
        final seasons = details['seasons'] as List<dynamic>?;
        if (seasons != null && seasons.isNotEmpty) {
          final selectedSeason = seasons.firstWhere(
            (season) => season['episodes'] != null && (season['episodes'] as List).isNotEmpty,
            orElse: () => throw Exception('No episodes available'),
          );
          final episodes = selectedSeason['episodes'] as List<dynamic>;
          final firstEpisode = episodes[0];
          initialSeasonNumber = (selectedSeason['season_number'] as num?)?.toInt() ?? 1;
          initialEpisodeNumber = (firstEpisode['episode_number'] as num?)?.toInt() ?? 1;

          streamingInfo = await StreamingService.getStreamingLink(
            tmdbId: details['id']?.toString() ?? 'Unknown Show',
            title: details['name']?.toString() ?? details['title']?.toString() ?? 'Unknown Show',
            releaseYear: _releaseYear ?? 1970,
            season: initialSeasonNumber,
            episode: initialEpisodeNumber,
            resolution: resolution,
            enableSubtitles: subtitles,
          );
          episodeFiles = List<String>.filled(episodes.length, '');
        } else {
          throw Exception('No seasons available');
        }
      } else {
        streamingInfo = await StreamingService.getStreamingLink(
          tmdbId: details['id']?.toString() ?? 'Unknown Movie',
          title: details['title']?.toString() ?? details['name']?.toString() ?? 'Unknown Movie',
          releaseYear: _releaseYear ?? 1970,
          resolution: resolution,
          enableSubtitles: subtitles,
        );
      }
    } catch (e) {
      if (mounted) {
        dismissModalLoading();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Unable to start streaming. Please try again later.")));
      }
      return;
    }

    if (!mounted) {
      dismissModalLoading();
      return;
    }

    final streamUrlRaw = streamingInfo['url'] ?? '';
    final urlType = (streamingInfo['type'] ?? 'unknown').toString().toLowerCase();
    final subtitleUrl = streamingInfo['subtitleUrl'] as String?;
    final streamUrl = _normalizeVideoPath(streamUrlRaw);
    final isHls = urlType == 'm3u8' || streamUrl.contains('.m3u8');

    if (streamUrl.isEmpty) {
      dismissModalLoading();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Streaming unavailable at this time.")));
      }
      return;
    }

    dismissModalLoading();

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => MainVideoPlayer(
            videoPath: streamUrl,
            title: streamingInfo['title'] ?? details['title'] ?? details['name'] ?? 'Untitled',
            releaseYear: _releaseYear ?? 1970,
            isFullSeason: isTvShow,
            episodeFiles: episodeFiles,
            similarMovies: _similarMovies,
            subtitleUrl: subtitleUrl,
            isHls: isHls,
            seasons: isTvShow ? (details['seasons'] as List?)?.cast<Map<String, dynamic>>() : null,
            initialSeasonNumber: isTvShow ? initialSeasonNumber : null,
            initialEpisodeNumber: isTvShow ? initialEpisodeNumber : null,
          ),
        ),
      );
    }
  }

  // ----- UI sections: renamed to lowerCamelCase -----
  Widget _titleSection(Map<String, dynamic> details, bool isTvShow) {
    final title = details['_title'] ?? (isTvShow ? (details['name'] ?? details['title'] ?? 'No Title') : (details['title'] ?? details['name'] ?? 'No Title'));
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(title, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    );
  }

  Widget _releaseDateSection(Map<String, dynamic> details, bool isTvShow) {
    final dateLabel = isTvShow ? 'First Air Date' : 'Release Date';
    final releaseDate = isTvShow ? (details['first_air_date'] ?? 'Unknown') : (details['release_date'] ?? 'Unknown');
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text('$dateLabel: $releaseDate', style: const TextStyle(fontSize: 16, color: Colors.white70)),
      ),
    );
  }

  Widget _tagsSection(Map<String, dynamic> details, bool isLoading) {
    if (isLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Wrap(
          spacing: 8,
          children: List.generate(
            3,
            (index) => Shimmer.fromColors(
              baseColor: Colors.grey[800]!,
              highlightColor: Colors.grey[600]!,
              child: Container(
                width: 80,
                height: 32,
                decoration: BoxDecoration(color: Colors.grey[800], borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
        ),
      );
    } else if (details['_tags'] != null && (details['_tags'] as List).isNotEmpty) {
      return RepaintBoundary(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Wrap(
            spacing: 8,
            children: (details['_tags'] as List)
                .map((tag) => Chip(label: Text(tag.toString(), style: const TextStyle(color: Colors.white)), backgroundColor: Colors.grey[800]))
                .toList(),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _ratingSection(Map<String, dynamic> details, bool isLoading) {
    if (isLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Shimmer.fromColors(baseColor: Colors.grey[800]!, highlightColor: Colors.grey[600]!, child: Container(width: 120, height: 20, color: Colors.grey[800])),
      );
    } else if (details['rating'] != null && details['rating'].toString().isNotEmpty) {
      return RepaintBoundary(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text('Rating: ${details['rating']}/10', style: const TextStyle(fontSize: 16, color: Colors.white70)),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _synopsisSection(Map<String, dynamic> details, bool isLoading) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: isLoading
          ? Shimmer.fromColors(
              baseColor: Colors.grey[800]!,
              highlightColor: Colors.grey[600]!,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(
                  3,
                  (index) => Container(
                    width: double.infinity,
                    height: 16,
                    color: Colors.grey[800],
                    margin: const EdgeInsets.only(bottom: 8),
                  ),
                ),
              ),
            )
          : Text(details['_synopsis'] ?? details['synopsis'] ?? details['overview'] ?? 'No overview available.', style: const TextStyle(fontSize: 16, color: Colors.white)),
    );
  }

  Widget _castSection(Map<String, dynamic> details, bool isLoading) {
    if (isLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Shimmer.fromColors(baseColor: Colors.grey[800]!, highlightColor: Colors.grey[600]!, child: Container(width: 100, height: 24, color: Colors.grey[800])),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: List.generate(
                4,
                (index) => Shimmer.fromColors(
                  baseColor: Colors.grey[800]!,
                  highlightColor: Colors.grey[600]!,
                  child: Container(width: 100, height: 32, decoration: BoxDecoration(color: Colors.grey[800], borderRadius: BorderRadius.circular(16))),
                ),
              ),
            ),
          ],
        ),
      );
    } else if (details['_castList'] != null && (details['_castList'] as List).isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(title: 'Cast'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: (details['_castList'] as List)
                  .asMap()
                  .entries
                  .map((entry) => Chip(
                        label: Text(entry.value.toString(), style: const TextStyle(color: Colors.white)),
                        backgroundColor: entry.key % 3 == 0 ? Colors.red[800] : entry.key % 3 == 1 ? Colors.blue[800] : Colors.green[800],
                      ))
                  .toList(),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _awardsSection(Map<String, dynamic> details, bool isLoading) {
    if (isLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Shimmer.fromColors(baseColor: Colors.grey[800]!, highlightColor: Colors.grey[600]!, child: Container(width: 100, height: 24, color: Colors.grey[800])),
            const SizedBox(height: 8),
            Shimmer.fromColors(baseColor: Colors.grey[800]!, highlightColor: Colors.grey[600]!, child: Container(width: double.infinity, height: 16, color: Colors.grey[800])),
          ],
        ),
      );
    } else if (details['cinemeta'] != null && details['cinemeta']['awards'] != null && details['cinemeta']['awards'].toString().isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(title: 'Awards'),
            const SizedBox(height: 8),
            Text(
              details['cinemeta']['awards'].length > 50 ? '${details['cinemeta']['awards'].substring(0, 50)}...' : details['cinemeta']['awards'],
              style: const TextStyle(fontSize: 16, color: Colors.white70),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _glassContainer({required Widget child, EdgeInsets padding = const EdgeInsets.all(12)}) {
    final settings = Provider.of<SettingsProvider>(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color.fromRGBO(255, 255, 255, 0.035),
                Color.fromRGBO(255, 255, 255, 0.02),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Color.fromRGBO(255, 255, 255, 0.06)),
            color: Colors.black.withOpacity(0.04),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.45),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: RadialGradient(
                        center: const Alignment(-0.2, -0.4),
                        radius: 1.3,
                        colors: [
                          Color.fromRGBO(255, 255, 255, 0.007),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.6],
                      ),
                    ),
                  ),
                ),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildDetailsContent(Map<String, dynamic> details, bool isTvShow, bool isLoading) {
    final widgets = <Widget>[
      _titleSection(details, isTvShow),
      _releaseDateSection(details, isTvShow),
      _tagsSection(details, isLoading),
      _ratingSection(details, isLoading),
      _synopsisSection(details, isLoading),
      _castSection(details, isLoading),
      _awardsSection(details, isLoading),
    ];

    if (isTvShow) {
      widgets.add(const _SectionTitle(title: 'Episodes'));
      widgets.add(
        TVShowEpisodesSection(
          key: ValueKey('tv_${details['id']}_in_details'),
          tvId: details['id'],
          seasons: details['seasons'] ?? [],
          tvShowName: details['name']?.toString() ?? details['title']?.toString() ?? 'Unknown Show',
          releaseYear: _releaseYear,
        ),
      );
    }

    widgets.add(const _SectionTitle(title: 'Trailers'));
    widgets.add(
      VisibilityDetector(
        key: ValueKey('trailers_${details['id']}'),
        onVisibilityChanged: (info) {},
        child: _glassContainer(child: TrailerSection(movieId: details['id'])),
      ),
    );

    widgets.add(_SectionTitle(title: 'Related ${isTvShow ? 'TV Shows' : 'Movies'}'));
    widgets.add(
      VisibilityDetector(
        key: ValueKey('similar_${details['id']}'),
        onVisibilityChanged: (info) {},
        child: _glassContainer(child: SimilarMoviesSection(movieId: details['id'])),
      ),
    );

    widgets.add(const SizedBox(height: 32));
    return widgets;
  }

  Widget _buildDetailScreen(Map<String, dynamic> details) {
    final posterUrl = details['_posterUrl'] ?? 'https://image.tmdb.org/t/p/w500${details['poster'] ?? details['poster_path'] ?? ''}';
    final settings = Provider.of<SettingsProvider>(context);

    final detailsWidgets = _buildDetailsContent(details, _isTvShow, false);

    return Scaffold(
      body: Stack(
        children: [
          const _BackgroundDecoration(),
          CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 400,
                pinned: true,
                backgroundColor: Colors.black87,
                title: Text(details['title'] ?? details['name'] ?? ''),
                flexibleSpace: FlexibleSpaceBar(
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedNetworkImage(
                        imageUrl: posterUrl,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Shimmer.fromColors(
                          baseColor: Colors.grey[800]!,
                          highlightColor: Colors.grey[600]!,
                          child: Container(color: Colors.grey[800]),
                        ),
                        errorWidget: (context, url, error) => Container(color: Colors.grey),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Color.fromRGBO(0, 0, 0, 0.9),
                              Color.fromRGBO(0, 0, 0, 0.7),
                              Colors.transparent
                            ],
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            stops: const [0.0, 0.3, 1.0],
                          ),
                        ),
                      ),
                      Center(
                        child: _PlayButton(
                          onPressed: () => _showPlayOptionsModal(details, _isTvShow),
                          accentColor: settings.accentColor,
                        ),
                      ),
                      _GlassActionBar(
                        onShare: () => _shareMovie(details),
                        onAddToList: () => _addToMyList(details),
                        onDownload: () => _showDownloadOptionsModal(details),
                        onRate: () => _rateMovie(details),
                        accentColor: settings.accentColor,
                      ),
                    ],
                  ),
                ),
              ),

              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    return RepaintBoundary(child: detailsWidgets[index]);
                  },
                  childCount: detailsWidgets.length,
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 48)),
            ],
          ),

          if (_isBackgroundDownloading)
            Positioned(
              right: 16,
              bottom: 24,
              child: GestureDetector(
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (ctx) {
                      final accent = Provider.of<SettingsProvider>(ctx).accentColor;
                      return AlertDialog(
                        backgroundColor: Colors.black87,
                        title: Text('Background download', style: TextStyle(color: accent)),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_backgroundTitle != null) Text(_backgroundTitle!, style: const TextStyle(color: Colors.white)),
                            const SizedBox(height: 8),
                            ValueListenableBuilder<DownloadProgress?>(
                              valueListenable: _downloadProgressNotifier,
                              builder: (c, p, _) {
                                final bytes = p?.bytesDownloaded ?? 0;
                                final totalBytes = p?.totalBytes;
                                return Column(
                                  children: [
                                    CircularProgressIndicator(color: accent),
                                    const SizedBox(height: 8),
                                    Text(_backgroundMessage ?? 'Finalizing...', style: const TextStyle(color: Colors.white70)),
                                    const SizedBox(height: 8),
                                    Text(totalBytes != null ? '${_bytesToReadable(bytes)} / ${_bytesToReadable(totalBytes)}' : _bytesToReadable(bytes), style: const TextStyle(color: Colors.white70)),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              setState(() {
                                _isBackgroundDownloading = false;
                              });
                            },
                            child: const Text('Hide', style: TextStyle(color: Colors.white)),
                          ),
                          TextButton(
                            onPressed: () {
                              _currentCancelToken?.cancel();
                              setState(() {
                                _backgroundMessage = 'Cancel requested...';
                              });
                              Navigator.of(ctx).pop();
                            },
                            child: const Text('Cancel', style: TextStyle(color: Colors.red)),
                          ),
                        ],
                      );
                    },
                  );
                },
                child: Card(
                  color: Colors.black87,
                  elevation: 8,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_backgroundTitle ?? 'Finalizing', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Text(_backgroundMessage ?? 'Running in background', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white70),
                          onPressed: () {
                            setState(() {
                              _isBackgroundDownloading = false;
                            });
                          },
                        )
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

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, child) {
        // If TV show: show tv details future -> then processed details future is already chained in initState
        // Use processed details future to build UI (COMPUTE reduces expensive processing)
        return FutureBuilder<Map<String, dynamic>>(
          future: _processedDetailsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              // show skeleton screen until processed details ready
              return const Scaffold(
                backgroundColor: Colors.black,
                body: Center(child: CircularProgressIndicator()),
              );
            } else if (snapshot.hasError) {
              return const Scaffold(
                backgroundColor: Colors.black,
                body: Center(
                  child: Text('Unable to load details. Please try again later.', style: TextStyle(color: Colors.white)),
                ),
              );
            } else if (snapshot.hasData) {
              return _buildDetailScreen(snapshot.data!);
            } else {
              // fallback to raw movie map
              return _buildDetailScreen(widget.movie);
            }
          },
        );
      },
    );
  }
}

// --------------------------- remaining widgets ---------------------------

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
    );
  }
}

class _BackgroundDecoration extends StatelessWidget {
  const _BackgroundDecoration();

  @override
  Widget build(context) {
    final settings = Provider.of<SettingsProvider>(context);
    return Container(
      decoration: const BoxDecoration(color: Color(0xff0d121d)),
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.06, -0.34),
                  radius: 0.8,
                  colors: [Color.fromRGBO(settings.accentColor.red, settings.accentColor.green, settings.accentColor.blue, 0.4), Colors.transparent],
                  stops: const [0.0, 0.59],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.64, 0.30),
                  radius: 0.8,
                  colors: [Color.fromRGBO(settings.accentColor.red, settings.accentColor.green, settings.accentColor.blue, 0.2), Colors.transparent],
                  stops: const [0.0, 0.55],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final VoidCallback onPressed;
  final Color accentColor;

  const _PlayButton({required this.onPressed, required this.accentColor});

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(width: 80, height: 80, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [Color.fromRGBO(accentColor.red, accentColor.green, accentColor.blue, 0.8), Colors.transparent], stops: const [0.5, 1.0]))),
        Card(
          elevation: 8,
          shadowColor: Colors.black54,
          shape: const CircleBorder(),
          child: SizedBox(
            width: 60,
            height: 60,
            child: IconButton(icon: const Icon(Icons.play_arrow, color: Colors.black, size: 30), onPressed: onPressed),
          ),
        ),
      ],
    );
  }
}

class _GlassActionBar extends StatelessWidget {
  final VoidCallback onShare;
  final VoidCallback onAddToList;
  final VoidCallback onDownload;
  final VoidCallback onRate;
  final Color accentColor;

  const _GlassActionBar({required this.onShare, required this.onAddToList, required this.onDownload, required this.onRate, required this.accentColor});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 16,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(color: Color.fromRGBO(accentColor.red, accentColor.green, accentColor.blue, 0.3), borderRadius: BorderRadius.circular(20), border: Border.all(color: Color.fromRGBO(255, 255, 255, 0.125))),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(icon: const Icon(Icons.share, color: Colors.white), onPressed: onShare),
            IconButton(icon: const Icon(Icons.add, color: Colors.white), onPressed: onAddToList),
            IconButton(icon: const Icon(Icons.download, color: Colors.white), onPressed: onDownload),
            IconButton(icon: const Icon(Icons.star, color: Colors.white), onPressed: onRate),
          ],
        ),
      ),
    );
  }
}

class _DownloadOptionsModal extends StatefulWidget {
  final String initialResolution;
  final bool initialSubtitles;
  final void Function(String, bool) onConfirm;

  const _DownloadOptionsModal({required this.initialResolution, required this.initialSubtitles, required this.onConfirm});

  @override
  _DownloadOptionsModalState createState() => _DownloadOptionsModalState();
}

class _DownloadOptionsModalState extends State<_DownloadOptionsModal> {
  late String _resolution;
  late bool _subtitles;

  @override
  void initState() {
    super.initState();
    _resolution = widget.initialResolution;
    _subtitles = widget.initialSubtitles;
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    return Container(
      padding: const EdgeInsets.all(16),
      height: 300,
      decoration: const BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Download Options", style: TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          const Text("Select Resolution:", style: TextStyle(color: Colors.white)),
          DropdownButton<String>(
            value: _resolution,
            dropdownColor: Colors.black87,
            items: const [
              DropdownMenuItem(value: "480p", child: Text("480p", style: TextStyle(color: Colors.white))),
              DropdownMenuItem(value: "720p", child: Text("720p", style: TextStyle(color: Colors.white))),
              DropdownMenuItem(value: "1080p", child: Text("1080p", style: TextStyle(color: Colors.white))),
            ],
            onChanged: (value) => setState(() => _resolution = value!),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text("Enable Subtitles:", style: TextStyle(color: Colors.white)),
              Switch(value: _subtitles, activeColor: settings.accentColor, onChanged: (value) => setState(() => _subtitles = value)),
            ],
          ),
          const Spacer(),
          Center(
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: settings.accentColor),
              onPressed: () {
                Navigator.pop(context);
                widget.onConfirm(_resolution, _subtitles);
              },
              child: const Text("Start Download", style: TextStyle(color: Colors.black)),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayOptionsModal extends StatefulWidget {
  final String initialResolution;
  final bool initialSubtitles;
  final void Function(String, bool) onConfirm;

  const _PlayOptionsModal({required this.initialResolution, required this.initialSubtitles, required this.onConfirm});

  @override
  _PlayOptionsModalState createState() => _PlayOptionsModalState();
}

class _PlayOptionsModalState extends State<_PlayOptionsModal> {
  late String _resolution;
  late bool _subtitles;

  @override
  void initState() {
    super.initState();
    _resolution = widget.initialResolution;
    _subtitles = widget.initialSubtitles;
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    return Container(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, top: 16, left: 16, right: 16),
      height: MediaQuery.of(context).size.height * 0.5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Center(child: Text("Play Options", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white))),
          const SizedBox(height: 16),
          const Text("Select Resolution:", style: TextStyle(fontSize: 16, color: Colors.white)),
          DropdownButton<String>(
            value: _resolution,
            dropdownColor: Colors.black87,
            items: const [
              DropdownMenuItem(value: "480p", child: Text("480p", style: TextStyle(color: Colors.white))),
              DropdownMenuItem(value: "720p", child: Text("720p", style: TextStyle(color: Colors.white))),
              DropdownMenuItem(value: "1080p", child: Text("1080p", style: TextStyle(color: Colors.white))),
            ],
            onChanged: (value) => setState(() => _resolution = value!),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text("Enable Subtitles:", style: TextStyle(fontSize: 16, color: Colors.white)),
              Switch(value: _subtitles, activeColor: settings.accentColor, onChanged: (value) => setState(() => _subtitles = value)),
            ],
          ),
          const Spacer(),
          Center(
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: settings.accentColor),
              onPressed: () {
                Navigator.pop(context);
                widget.onConfirm(_resolution, _subtitles);
              },
              child: const Text("Play Now", style: TextStyle(color: Colors.black)),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// Rating dialog
class _RatingDialog extends StatefulWidget {
  final String title;
  final void Function(double) onRatingChanged;
  final VoidCallback onSubmit;

  const _RatingDialog({required this.title, required this.onRatingChanged, required this.onSubmit});

  @override
  _RatingDialogState createState() => _RatingDialogState();
}

class _RatingDialogState extends State<_RatingDialog> {
  double _rating = 3.0;

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    return AlertDialog(
      title: Text('Rate ${widget.title}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Select rating:"),
          Slider(
            value: _rating,
            min: 1.0,
            max: 5.0,
            divisions: 4,
            label: _rating.toString(),
            activeColor: settings.accentColor,
            onChanged: (value) {
              setState(() => _rating = value);
              widget.onRatingChanged(value);
            },
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: settings.accentColor), onPressed: widget.onSubmit, child: const Text("Submit", style: TextStyle(color: Colors.black))),
      ],
    );
  }
}

// Loading dialog
class LoadingDialog extends StatefulWidget {
  const LoadingDialog({super.key});

  @override
  _LoadingDialogState createState() => _LoadingDialogState();
}

class _LoadingDialogState extends State<LoadingDialog> {
  bool _showSecondMessage = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 30), () {
      if (mounted) setState(() => _showSecondMessage = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    return Dialog(
      backgroundColor: Colors.black.withOpacity(0.8),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: settings.accentColor),
          const SizedBox(height: 16),
          const Text("Preparing your content...", style: TextStyle(color: Colors.white), textAlign: TextAlign.center),
          if (_showSecondMessage) ...[
            const SizedBox(height: 12),
            const Text("The app is in its inception stage,\nso some content might not be available yet.", style: TextStyle(color: Colors.white70), textAlign: TextAlign.center),
          ],
        ]),
      ),
    );
  }
}

// =============================
// Merge helper run on isolate
// =============================

Future<String> mergeSegmentsWorker(Map<String, String> args) async {
  final playlistPath = args['playlist'] ?? '';
  final outDir = args['outDir'] ?? '';
  final id = args['id'] ?? 'merged';
  if (playlistPath.isEmpty || outDir.isEmpty) return '';

  try {
    final playlistFile = File(playlistPath);
    if (!await playlistFile.exists()) return '';

    final lines = (await playlistFile.readAsString()).replaceAll('\r\n', '\n').split('\n');
    final rewritten = <String>[];
    final mergedFilePath = p.join(outDir, '$id-merged.ts');
    final mergedFile = File(mergedFilePath);

    if (await mergedFile.exists()) {
      try {
        await mergedFile.delete();
      } catch (_) {}
    }

    final raf = mergedFile.openSync(mode: FileMode.write);
    try {
      for (var line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed.startsWith('#EXT-X-KEY')) {
          rewritten.add('#EXT-X-KEY:METHOD=NONE');
        } else if (trimmed.startsWith('#')) {
          rewritten.add(trimmed);
        } else {
          final segPath = p.join(outDir, p.basename(trimmed));
          final segFile = File(segPath);
          if (!await segFile.exists()) {
            continue;
          }
          final bytes = await segFile.readAsBytes();
          raf.writeFromSync(bytes);
          rewritten.add(p.basename(trimmed));
        }
      }
    } finally {
      await raf.close();
    }

    final localPlaylistPath = p.join(outDir, '$id-local.m3u8');
    await File(localPlaylistPath).writeAsString(rewritten.join('\n'));

    return mergedFilePath;
  } catch (e) {
    debugPrint('mergeSegmentsWorker failed: $e');
    return '';
  }
}

Future<String> _mergeSegmentsOnMainIsolate(String playlistPath, String outDir, String id) async {
  return await mergeSegmentsWorker({'playlist': playlistPath, 'outDir': outDir, 'id': id});
}

/// COMPUTE: prepare details for UI on background isolate
/// runs via compute(...) with a plain Map (must be encodable)
Map<String, dynamic> prepareDetailsWorker(Map<String, dynamic> rawDetails) {
  // Make defensive copy
  final details = Map<String, dynamic>.from(rawDetails);

  // poster url
  final poster = details['poster'] ?? details['poster_path'] ?? '';
  details['_posterUrl'] = poster.toString().isNotEmpty ? 'https://image.tmdb.org/t/p/w500$poster' : '';

  // title normalization
  details['_title'] = (details['title'] ?? details['name'] ?? 'Untitled').toString();

  // synopsis trimming
  final synopsis = (details['synopsis'] ?? details['overview'] ?? '').toString();
  details['_synopsis'] = synopsis.length > 1000 ? '${synopsis.substring(0, 1000)}...' : synopsis;

  // tags extraction (ensure list of strings)
  List<String> tags = [];
  try {
    if (details['tags'] is List) {
      tags = (details['tags'] as List).map((t) => t?.toString() ?? '').where((t) => t.isNotEmpty).toList();
    } else if (details['genres'] is List) {
      tags = (details['genres'] as List).map((g) => (g is Map && g['name'] != null) ? g['name'].toString() : g.toString()).where((t) => t.isNotEmpty).toList();
    }
  } catch (_) {
    tags = [];
  }
  details['_tags'] = tags;

  // cast extraction
  List<String> castList = [];
  try {
    if (details['cast'] is List) {
      castList = (details['cast'] as List).map((c) {
        if (c == null) return '';
        if (c is Map) {
          return (c['name'] ?? c['original_name'] ?? c['character'] ?? '').toString();
        }
        return c.toString();
      }).where((s) => s.isNotEmpty).toList();
    } else if (details['credits'] is Map && details['credits']['cast'] is List) {
      castList = (details['credits']['cast'] as List).map((c) => (c is Map && c['name'] != null) ? c['name'].toString() : c.toString()).where((s) => s.isNotEmpty).toList();
    }
  } catch (_) {
    castList = [];
  }
  details['_castList'] = castList;

  return details;
}
