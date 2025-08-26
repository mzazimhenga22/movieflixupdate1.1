// movie_detail_screen.dart
import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
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

/// Full MovieDetailScreen (uses TVShowEpisodesSection from tvshow_episodes_section.dart).
/// Centralized modal helpers (showModalLoading/dismissModalLoading) to avoid
/// accidentally popping bottom sheets when showing dialogs.

class MovieDetailScreen extends StatefulWidget {
  final Map<String, dynamic> movie;

  const MovieDetailScreen({super.key, required this.movie});

  @override
  MovieDetailScreenState createState() => MovieDetailScreenState();
}

class MovieDetailScreenState extends State<MovieDetailScreen> {
  Future<Map<String, dynamic>>? _tvDetailsFuture;
  String _selectedResolution = "720p";
  bool _enableSubtitles = false;
  late final bool _isTvShow;
  List<Map<String, dynamic>> _similarMovies = [];
  int? _releaseYear;

  // Download notifier & cancel token for progress dialog
  final ValueNotifier<DownloadProgress?> _downloadProgressNotifier = ValueNotifier(null);

  // active downloads guard to avoid duplicate downloads and floods
  final Set<String> _activeDownloads = <String>{};

  // Modal loading guard (used by children to show a centralized loading dialog)
  bool _isModalLoadingVisible = false;

  // Background download state (for "Run in background" flows)
  CancelToken? _currentCancelToken;
  bool _isBackgroundDownloading = false;
  bool _backgroundCancelRequested = false;
  String? _backgroundMessage;
  Future<String>? _backgroundMergeFuture;
  String? _backgroundTitle;

  @override
  void initState() {
    super.initState();
    _isTvShow = (widget.movie['media_type']?.toString().toLowerCase() == 'tv') ||
        (widget.movie['seasons'] != null && (widget.movie['seasons'] as List).isNotEmpty);

    if (_isTvShow) {
      // ensure heavy parsing in TMDBApi uses compute()
      _tvDetailsFuture = tmdb.TMDBApi.fetchTVShowDetails(widget.movie['id']);
    }

    // Defer non-critical work after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchSimilarMovies();
      _fetchReleaseYear();
    });
  }

  @override
  void dispose() {
    _downloadProgressNotifier.dispose();
    super.dispose();
  }

  // ------------------ modal-loading helpers (public) ------------------
  // These should be called by nested widgets instead of showing a new dialog
  // from their own context. They use the root navigator so they live above
  // bottom sheets and other route layers.

  /// Show a modal loading dialog (root navigator). Safe to call multiple times.
  void showModalLoading() {
    if (!mounted) return;
    if (_isModalLoadingVisible) return;
    _isModalLoadingVisible = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dctx) => const LoadingDialog(),
    );
  }

  /// Dismiss the modal loading dialog if visible.
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

  // Use SharePlus.instance.share to satisfy deprecation advice
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
                child: Text("Open Settings", style: TextStyle(color: Provider.of<SettingsProvider>(context, listen: false).accentColor)),
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

  /// PUBLIC method called by nested widgets (episode section) to request a download.
  /// This enqueues the download (non-blocking).
  Future<void> downloadEpisodeFromChild({
    required int season,
    required int episode,
    required String showTitle,
    required int showId,
    required String resolution,
    required bool subtitles,
  }) async {
    final details = <String, dynamic>{'id': showId, 'title': showTitle, 'season': season, 'episode': episode};

    // Give immediate feedback so UI remains responsive
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Starting download...')));
    }

    // Start guarded download in background (fire-and-forget)
    _startDownload(details, resolution, subtitles);
  }

  // internal guarded starter that prevents duplicates and actually awaits the download task
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

  // Core download function for movies and episodes (works with StreamingService + OfflineDownloader)
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

    final downloadId = 'movie_${tmdbId}${idSuffix}'; // unique folder id

    // assign current cancel token so overlay can cancel if user tapped background cancel
    _currentCancelToken = CancelToken();
    final cancelToken = _currentCancelToken!;
    _backgroundCancelRequested = false;
    _backgroundMessage = null;

    bool finished = false;
    Map<String, String>? result;

    // Show progress dialog (root navigator)
    _showDownloadProgressDialog(cancelToken);

    try {
      // IMPORTANT: ask OfflineDownloader to NOT merge segments — we will handle finalization separately
      result = await OfflineDownloader.downloadAnyStream(
        streamInfo: streamingInfo,
        id: downloadId,
        preferredResolution: resolution,
        mergeSegments: false, // <<-- changed: do segments download only
        concurrency: 6,
        onProgress: (p) {
          // publish progress to the notifier so dialog/overlay updates
          _downloadProgressNotifier.value = p;
        },
        cancelToken: cancelToken,
      );
      finished = true;
    } catch (e) {
      if (e.toString().toLowerCase().contains('cancel')) {
        if (mounted) {
          try {
            Navigator.of(context, rootNavigator: true).pop(); // close progress dialog if open
          } catch (_) {}
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download cancelled.')));
        }
        _currentCancelToken = null;
        _isBackgroundDownloading = false;
        return;
      }
      if (mounted) {
        try {
          Navigator.of(context, rootNavigator: true).pop(); // close progress dialog if open
        } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
      _currentCancelToken = null;
      _isBackgroundDownloading = false;
      return;
    } finally {
      // Ensure progress dialog is closed if still open (we will present finalizing dialog next)
      if (mounted) {
        try {
          Navigator.of(context, rootNavigator: true).pop();
        } catch (_) {}
      }
    }

    if (!finished || result == null) {
      _currentCancelToken = null;
      _isBackgroundDownloading = false;
      return;
    }

    // Make a non-nullable local copy
    final res = result;

    // Determine playable path (merged ts > file (mp4) > playlist)
    final playablePathBeforeMerge = res['merged'] ?? res['file'] ?? res['playlist'] ?? '';

    // If it was an mp4 non-HLS, we're done
    if (res['type'] == 'mp4' && res['file'] != null) {
      // Save download metadata to SharedPreferences
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

    // If it's HLS (m3u8), we likely need to finalize (rewrite playlist + optional merge)
    if (res['type'] == 'm3u8' && res['playlist'] != null && res['playlist']!.isNotEmpty) {
      final playlistPath = res['playlist']!;
      final outDir = p.dirname(playlistPath);

      // Prepare the merge worker args
      final workerArgs = <String, String>{
        'playlist': playlistPath,
        'outDir': outDir,
        'id': downloadId,
        'title': title,
        'resolution': resolution,
        'subtitle': res['subtitle'] ?? streamingInfo['subtitleUrl'] ?? '',
      };

      // Create the merge compute future (does heavy file I/O off the UI isolate)
      Future<String> mergeFuture;
      try {
        mergeFuture = compute(mergeSegmentsWorker, workerArgs);
      } catch (e) {
        // compute may throw on web or restricted platforms, fallback to direct merge (still non-ideal)
        mergeFuture = Future<String>(() async {
          return await _mergeSegmentsOnMainIsolate(playlistPath, outDir, downloadId);
        });
      }

      // Show a finalizing dialog giving the user a choice to wait or run in background.
      // This dialog will auto-close when the mergeFuture completes (if the user chose to wait).
      final runInBackground = await _showFinalizingDialog(mergeFuture);

      if (runInBackground) {
        // User asked to run in background -> attach callbacks to notify when done
        // show background UI
        if (mounted) {
          setState(() {
            _isBackgroundDownloading = true;
            _backgroundMergeFuture = mergeFuture;
            _backgroundTitle = title;
            _backgroundMessage = 'Finalizing in background...';
            _backgroundCancelRequested = false;
          });
        }

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
            debugPrint('Failed to save download record after background merge: $e');
          }

          if (mounted) {
            setState(() {
              _isBackgroundDownloading = false;
              _backgroundMergeFuture = null;
              _backgroundMessage = null;
              _backgroundTitle = null;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Finalizing finished: ${details['title'] ?? details['name']}'),
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
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Finalizing failed: $e')));
          }
        }).whenComplete(() {
          // clear current token after finalization attempt
          _currentCancelToken = null;
        });

        // Let user continue; we already dismissed the finalizing dialog (it returns true when user taps Run in background)
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Finalizing will continue in background.')));
        }
        return;
      } else {
        // User chose to wait — mergeFuture was awaited by _showFinalizingDialog (which only returns after completion or user-run-in-background)
        // The dialog returned false to indicate it completed waiting; we need the merge result to save record & show "finished"
        String mergedPath = '';
        try {
          mergedPath = await mergeFuture;
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Finalizing failed: $e')));
          }
          _currentCancelToken = null;
          _isBackgroundDownloading = false;
          return;
        }

        // Save download metadata to SharedPreferences
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
        await _saveDownloadRecord(record);

        _currentCancelToken = null;
        _isBackgroundDownloading = false;

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
        return;
      }
    }

    // fallback: unknown type
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download finished but no playable file found.')));
    }
    _currentCancelToken = null;
    _isBackgroundDownloading = false;
  }

  // ---------- DOWNLOAD HELPERS ----------
  // Shows a cancellable progress dialog that listens to _downloadProgressNotifier.
  // Updated to prefer bytes display and to show determinate progress when totalBytes (or segments) present.
  void _showDownloadProgressDialog(CancelToken cancelToken) {
    if (!mounted) return;
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true, // important: show above bottom sheet
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.black87,
          content: SizedBox(
            width: double.maxFinite,
            child: ValueListenableBuilder<DownloadProgress?>(
              valueListenable: _downloadProgressNotifier,
              builder: (context, progress, _) {
                final downloadedSegments = progress?.downloadedSegments ?? 0;
                final totalSegments = progress?.totalSegments ?? 0;
                final bytes = progress?.bytesDownloaded ?? 0;
                final totalBytes = progress?.totalBytes;
                final isFinalizing = progress?.finalizing ?? false;
                final message = progress?.message ?? '';

                // prefer bytes-based percent if totalBytes is available
                double? fraction;
                String progressLabel = _bytesToReadable(bytes);
                if (totalBytes != null && totalBytes > 0) {
                  fraction = bytes / totalBytes;
                  final percentStr = (fraction * 100).toStringAsFixed(1) + '%';
                  progressLabel = '${_bytesToReadable(bytes)} / ${_bytesToReadable(totalBytes)} ($percentStr)';
                } else if (totalSegments > 0) {
                  // fallback: show bytes downloaded and a compact segments hint (less prominent)
                  final segPercent = (downloadedSegments / totalSegments) * 100;
                  // Show bytes + small segments hint to help estimate progress
                  progressLabel = '${_bytesToReadable(bytes)} • ${downloadedSegments}/${totalSegments} segs (${segPercent.toStringAsFixed(0)}%)';
                  fraction = (totalSegments > 0) ? (downloadedSegments / totalSegments) : null;
                } else {
                  // nothing reliable — show bytes downloaded only
                  progressLabel = _bytesToReadable(bytes);
                  fraction = null;
                }

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(isFinalizing ? 'Finalizing...' : 'Downloading...', style: const TextStyle(color: Colors.white)),
                    const SizedBox(height: 12),
                    // determinate when we have a fraction, otherwise indeterminate
                    (fraction != null)
                        ? LinearProgressIndicator(value: fraction)
                        : const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    if (isFinalizing && (message.isNotEmpty))
                      Text(message, style: const TextStyle(color: Colors.white70))
                    else
                      Text(progressLabel, style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (!isFinalizing) ...[
                          TextButton(
                            onPressed: () {
                              // Cancel download
                              cancelToken.cancel();
                              try {
                                Navigator.of(context, rootNavigator: true).pop();
                              } catch (_) {}
                            },
                            child: const Text('Cancel', style: TextStyle(color: Colors.red)),
                          ),
                        ] else ...[
                          TextButton(
                            onPressed: () {
                              // Allow user to run finalization in background.
                              // We'll dismiss progress dialog and the caller will handle background merge.
                              try {
                                Navigator.of(context, rootNavigator: true).pop(true);
                              } catch (_) {}
                            },
                            child: const Text('Run in background', style: TextStyle(color: Colors.orange)),
                          ),
                          TextButton(
                            onPressed: () {
                              // If user chooses to "Wait", we dismiss this progress dialog and open the finalizing dialog
                              // which will remain visible until merge completes (or user runs it in background).
                              try {
                                Navigator.of(context, rootNavigator: true).pop(false);
                              } catch (_) {}
                            },
                            child: const Text('Wait', style: TextStyle(color: Colors.white)),
                          ),
                        ]
                      ],
                    )
                  ],
                );
              },
            ),
          ),
        );
      },
    ).then((value) {
      // When user dismissed the dialog using the finalizing options, .then(value) will be called.
      // We don't need to do anything here — upstream logic in _downloadMovie handles choices by showing
      // the finalizing dialog and the mergeFuture work.
      return;
    });
  }

  /// Display a finalizing dialog and return true if the user chose to run in background.
  /// This dialog will auto-close when [mergeFuture] completes (and return false).
  Future<bool> _showFinalizingDialog(Future<String> mergeFuture) async {
    if (!mounted) return true;

    // We show a dialog that listens to the progress notifier for messages.
    // The dialog has a "Run in background" button. If user presses it, dialog returns true.
    // If the mergeFuture completes while the dialog is open, we programmatically pop the dialog with false.
    // The returned boolean is:
    //  - true: user pressed "Run in background" (we should let merge continue and notify later)
    //  - false: merge finished while user waited (or merge completed and we auto-closed)

    // Start the dialog
    final dialogFuture = showDialog<bool>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (context) {
        final settings = Provider.of<SettingsProvider>(context);
        return AlertDialog(
          backgroundColor: Colors.black87,
          content: SizedBox(
            width: double.maxFinite,
            child: ValueListenableBuilder<DownloadProgress?>(
              valueListenable: _downloadProgressNotifier,
              builder: (context, progress, _) {
                final message = progress?.message ?? 'Finalizing download...';
                final bytes = progress?.bytesDownloaded ?? 0;
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(color: settings.accentColor),
                  const SizedBox(height: 12),
                  Text(message, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(_bytesToReadable(bytes), style: const TextStyle(color: Colors.white70)),
                ]);
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                // run in background: pop(true)
                Navigator.of(context, rootNavigator: true).pop(true);
              },
              child: const Text('Run in background', style: TextStyle(color: Colors.orange)),
            ),
          ],
        );
      },
    );

    // If merge completes while dialog is open, close it with false.
    mergeFuture.then((_) {
      try {
        Navigator.of(context, rootNavigator: true).pop(false);
      } catch (_) {
        // dialog already closed by user (Run in background) — ignore
      }
    }).catchError((e) {
      try {
        Navigator.of(context, rootNavigator: true).pop(false);
      } catch (_) {}
    });

    final res = await dialogFuture;
    return res ?? false;
  }

  /// Save simple download record to SharedPreferences under key 'downloads'
  Future<void> _saveDownloadRecord(Map<String, dynamic> record) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('downloads') ?? [];
    list.add(json.encode(record));
    await prefs.setStringList('downloads', list);
  }

  // utility to show bytes as a readable string
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
  // ---------- END DOWNLOAD HELPERS ----------

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

  Future<void> _launchStreamingPlayer(Map<String, dynamic> details, bool isTvShow, String resolution, bool subtitles) async {
    if (!mounted) return;

    // Show centralized loading dialog (root navigator) so it won't accidentally
    // close the bottom sheet.
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
          episodeFiles = episodes.map<String>((e) => '').toList(); // Kept for compatibility
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

    final streamUrl = streamingInfo['url'] ?? '';
    final urlType = streamingInfo['type'] ?? 'unknown';
    final subtitleUrl = streamingInfo['subtitleUrl'];

    if (streamUrl.isEmpty) {
      dismissModalLoading();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Streaming unavailable at this time.")));
      }
      return;
    }

    // close centralized loading dialog properly (root navigator)
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
            isHls: urlType == 'm3u8',
            seasons: isTvShow ? details['seasons']?.cast<Map<String, dynamic>>() : null,
            initialSeasonNumber: isTvShow ? initialSeasonNumber : null,
            initialEpisodeNumber: isTvShow ? initialEpisodeNumber : null,
          ),
        ),
      );
    }
  }

  void _showLoadingDialog() {
    if (!mounted) return;
    // Keep for internal uses — make sure to use root navigator to avoid popping
    // the bottom sheet.
    showDialog(context: context, barrierDismissible: false, useRootNavigator: true, builder: (context) => const LoadingDialog());
  }

  // Smaller widget components for _buildDetailsContent
  Widget _TitleSection(Map<String, dynamic> details, bool isTvShow) {
    final title = isTvShow ? (details['name'] ?? details['title'] ?? 'No Title') : (details['title'] ?? details['name'] ?? 'No Title');
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(title, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    );
  }

  Widget _ReleaseDateSection(Map<String, dynamic> details, bool isTvShow) {
    final dateLabel = isTvShow ? 'First Air Date' : 'Release Date';
    final releaseDate = isTvShow ? (details['first_air_date'] ?? 'Unknown') : (details['release_date'] ?? 'Unknown');
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text('$dateLabel: $releaseDate', style: const TextStyle(fontSize: 16, color: Colors.white70)),
      ),
    );
  }

  Widget _TagsSection(Map<String, dynamic> details, bool isLoading) {
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
    } else if (details['tags'] != null && (details['tags'] as List).isNotEmpty) {
      return RepaintBoundary(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Wrap(
            spacing: 8,
            children: (details['tags'] as List)
                .map((tag) => Chip(label: Text(tag.toString(), style: const TextStyle(color: Colors.white)), backgroundColor: Colors.grey[800]))
                .toList(),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _RatingSection(Map<String, dynamic> details, bool isLoading) {
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

  Widget _SynopsisSection(Map<String, dynamic> details, bool isLoading) {
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
          : Text(details['synopsis'] ?? details['overview'] ?? 'No overview available.', style: const TextStyle(fontSize: 16, color: Colors.white)),
    );
  }

  Widget _CastSection(Map<String, dynamic> details, bool isLoading) {
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
    } else if (details['cast'] != null && (details['cast'] as List).isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(title: 'Cast'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: (details['cast'] as List)
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

  Widget _AwardsSection(Map<String, dynamic> details, bool isLoading) {
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

  // Glass container used for Trailers & Similar sections
  // NOTE: replaced expensive BackdropFilter blur with a lightweight "frosted" look
  // using translucent gradients, subtle border and shadow. This reduces GPU usage
  // while keeping a similar visual style.
  Widget _GlassContainer({required Widget child, EdgeInsets padding = const EdgeInsets.all(12)}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            // subtle frosted look: a semi-transparent color + soft gradient
            gradient: LinearGradient(
              colors: [
                Colors.white.withOpacity(0.035),
                Colors.white.withOpacity(0.02),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
            color: Colors.black.withOpacity(0.04),
            boxShadow: [
              // give a little lift without heavy blur operations
              BoxShadow(
                color: Colors.black.withOpacity(0.45),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Stack(
            children: [
              // optional subtle noise / grain overlay using a low-cost Container with
              // a slightly transparent radial gradient to emulate the soft scattering
              // of light that blur would produce.
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: RadialGradient(
                        center: const Alignment(-0.2, -0.4),
                        radius: 1.3,
                        colors: [
                          Colors.white.withOpacity(0.007),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.6],
                      ),
                    ),
                  ),
                ),
              ),
              // content
              child,
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildDetailsContent(Map<String, dynamic> details, bool isTvShow, bool isLoading) {
    final widgets = <Widget>[
      _TitleSection(details, isTvShow),
      _ReleaseDateSection(details, isTvShow),
      _TagsSection(details, isLoading),
      _RatingSection(details, isLoading),
      _SynopsisSection(details, isLoading),
      _CastSection(details, isLoading),
      _AwardsSection(details, isLoading),
    ];

    // Episodes first for TV shows (glass header + section widget)
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

    // Trailers (glass)
    widgets.add(const _SectionTitle(title: 'Trailers'));
    widgets.add(
      VisibilityDetector(
        key: ValueKey('trailers_${details['id']}'),
        onVisibilityChanged: (info) {},
        child: _GlassContainer(child: TrailerSection(movieId: details['id'])),
      ),
    );

    // Similar movies (glass)
    widgets.add(_SectionTitle(title: 'Related ${isTvShow ? 'TV Shows' : 'Movies'}'));
    widgets.add(
      VisibilityDetector(
        key: ValueKey('similar_${details['id']}'),
        onVisibilityChanged: (info) {},
        child: _GlassContainer(child: SimilarMoviesSection(movieId: details['id'])),
      ),
    );

    widgets.add(const SizedBox(height: 32));
    return widgets;
  }

  Widget _buildDetailScreen(Map<String, dynamic> details) {
    final posterUrl = 'https://image.tmdb.org/t/p/w500${details['poster'] ?? details['poster_path'] ?? ''}';
    final settings = Provider.of<SettingsProvider>(context);

    // prebuild details widgets to avoid recomputing inside SliverList builder
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
                              Colors.black.withAlpha(230),
                              Colors.black.withAlpha(178),
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

          // Background download overlay (floating card): appears when finalization runs in background
          if (_isBackgroundDownloading)
            Positioned(
              right: 16,
              bottom: 24,
              child: GestureDetector(
                onTap: () {
                  // tap to expand/hide is intentionally simple: we open a small dialog with actions.
                  showDialog(
                    context: context,
                    builder: (ctx) {
                      final settings = Provider.of<SettingsProvider>(ctx);
                      return AlertDialog(
                        backgroundColor: Colors.black87,
                        title: Text('Background download', style: TextStyle(color: settings.accentColor)),
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
                                    CircularProgressIndicator(color: settings.accentColor),
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
                              // Hide overlay (the merge still runs)
                              Navigator.of(ctx).pop();
                              setState(() {
                                _isBackgroundDownloading = false;
                              });
                            },
                            child: const Text('Hide', style: TextStyle(color: Colors.white)),
                          ),
                          TextButton(
                            onPressed: () {
                              // Attempt cancel: cancels segment downloads. compute cannot be cancelled.
                              _backgroundCancelRequested = true;
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
                            // hide overlay
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
        if (_isTvShow && _tvDetailsFuture != null) {
          return FutureBuilder<Map<String, dynamic>>(
            future: _tvDetailsFuture,
            builder: (context, snapshot) {
              final details = snapshot.connectionState == ConnectionState.waiting ? widget.movie : {...widget.movie, ...?snapshot.data};
              if (snapshot.hasError) {
                return const Scaffold(
                  backgroundColor: Colors.black,
                  body: Center(
                    child: Text('Unable to load details. Please try again later.', style: TextStyle(color: Colors.white)),
                  ),
                );
              }
              return _buildDetailScreen(details);
            },
          );
        }
        return _buildDetailScreen(widget.movie);
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
                  colors: [settings.accentColor.withOpacity(0.4), Colors.transparent],
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
                  colors: [settings.accentColor.withOpacity(0.2), Colors.transparent],
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
        Container(width: 80, height: 80, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [accentColor.withAlpha(204), Colors.transparent], stops: const [0.5, 1.0]))),
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
    // kept as subtle translucent accent bar (you can switch to BackdropFilter if you want)
    return Positioned(
      bottom: 16,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(color: accentColor.withOpacity(0.3), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withOpacity(0.125))),
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

// Episode Loading Dialog
class EpisodeLoadingDialog extends StatelessWidget {
  const EpisodeLoadingDialog({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    return Dialog(
      backgroundColor: Colors.black.withOpacity(0.85),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: settings.accentColor),
          const SizedBox(width: 16),
          const Flexible(child: Text('Preparing episode...', style: TextStyle(color: Colors.white))),
        ]),
      ),
    );
  }
}

// =============================
// Merge helper run on isolate
// =============================

/// Worker called via `compute` to merge TS segments and rewrite a local playlist.
/// Input: Map<String, String> with keys 'playlist', 'outDir', 'id'
/// Returns: merged file path (empty string on failure)
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

    // Ensure merged file is new
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
          // remove keys for local file
          rewritten.add('#EXT-X-KEY:METHOD=NONE');
        } else if (trimmed.startsWith('#')) {
          rewritten.add(trimmed);
        } else {
          // resolved: treat trimmed as filename or relative path already resolved by downloader
          final segPath = p.join(outDir, p.basename(trimmed));
          final segFile = File(segPath);
          if (!await segFile.exists()) {
            // If not present, skip (but still continue)
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

    // Write local playlist referencing local segment filenames
    final localPlaylistPath = p.join(outDir, '$id-local.m3u8');
    await File(localPlaylistPath).writeAsString(rewritten.join('\n'));

    return mergedFilePath;
  } catch (e) {
    // swallow errors and return empty string to signal failure
    debugPrint('mergeSegmentsWorker failed: $e');
    return '';
  }
}

/// Fallback merge on main isolate if compute isn't available
Future<String> _mergeSegmentsOnMainIsolate(String playlistPath, String outDir, String id) async {
  return await mergeSegmentsWorker({'playlist': playlistPath, 'outDir': outDir, 'id': id});
}
