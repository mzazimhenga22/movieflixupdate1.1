// tvshow_episodes_section.dart
import 'dart:async';
import 'dart:ui' show ImageFilter;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart' hide DownloadProgress;
import 'package:shimmer/shimmer.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:movie_app/tmdb_api.dart' as tmdb;
import 'package:movie_app/streaming_service.dart';
import 'package:movie_app/main_videoplayer.dart';
import 'package:movie_app/settings_provider.dart';

import 'package:movie_app/movie_detail_screen.dart'; // find ancestor for downloads and centralized modal helpers

/// Optimized TVShowEpisodesSection:
/// - Offloads episode normalization/parsing to compute()
/// - Keeps episodes state alive (AutomaticKeepAliveClientMixin)
/// - Extracts episode row to a lightweight StatelessWidget
/// - Minimizes widget allocations, uses const where possible
/// - Reduces per-row GPU cost by removing BackdropFilter from each row

// ----------------------------- isolate helpers -----------------------------
// compute() target must be top-level or static
List<Map<String, dynamic>> _extractEpisodes(List<dynamic> rawEpisodes) {
  final out = <Map<String, dynamic>>[];
  for (final e in rawEpisodes) {
    if (e is Map) {
      final episodeNumber = (e['episode_number'] as num?)?.toInt() ?? 0;
      final runtime = (e['runtime'] is int)
          ? e['runtime'] as int
          : (e['runtime'] is num ? (e['runtime'] as num).toInt() : 0);
      out.add({
        'episode_number': episodeNumber,
        'name': e['name']?.toString() ?? 'Episode $episodeNumber',
        'overview': e['overview']?.toString() ?? '',
        'still_path': e['still_path']?.toString(),
        'runtime': runtime,
      });
    }
  }
  return out;
}

// ----------------------------- lightweight style constants -----------------------------
const _titleTextStyle = TextStyle(color: Colors.white, fontWeight: FontWeight.w600);
const _overviewTextStyle = TextStyle(color: Colors.white70, fontSize: 13);
const _headerTitleStyle = TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white);

// ----------------------------- glass helper widgets -----------------------------
class GlassContainer extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final BorderRadius borderRadius;

  const GlassContainer({
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    // keep this widget cheap — no Provider here (read from parent if needed)
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.white.withOpacity(0.04), Colors.white.withOpacity(0.02)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: borderRadius,
              border: Border.all(color: Colors.white.withOpacity(0.06)),
              color: Colors.black.withOpacity(0.04),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Episode card — keep visual but avoid expensive per-row BackdropFilter
class EpisodeGlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const EpisodeGlassCard({required this.child, this.padding = const EdgeInsets.symmetric(vertical: 8, horizontal: 12), super.key});

  @override
  Widget build(BuildContext context) {
    // Use a lightweight translucent decoration (no per-row blur)
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.05)),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
          ),
          child: child,
        ),
      ),
    );
  }
}

// ----------------------------- Episode Row (stateless) -----------------------------
// Keeps a minimal build cost per item.
class _EpisodeRow extends StatelessWidget {
  final Map<String, dynamic> episode;
  final int seasonNumber;
  final String tvShowName;
  final int tvId;
  final int? releaseYear;
  final VoidCallback onPlayPressed;
  final VoidCallback onDownloadPressed;

  const _EpisodeRow({
    required this.episode,
    required this.seasonNumber,
    required this.tvShowName,
    required this.tvId,
    required this.releaseYear,
    required this.onPlayPressed,
    required this.onDownloadPressed,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final epNum = (episode['episode_number'] as int?) ?? 0;
    final epName = episode['name'] as String? ?? 'Episode $epNum';
    final epOverview = episode['overview'] as String? ?? '';
    final stillPath = episode['still_path'] as String?;
    final runtime = (episode['runtime'] as int?) ?? 0;

    return EpisodeGlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 140,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), color: Colors.grey[800]),
                clipBehavior: Clip.hardEdge,
                child: (stillPath != null && stillPath.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: 'https://image.tmdb.org/t/p/w300$stillPath',
                        fit: BoxFit.cover,
                        fadeInDuration: Duration.zero,
                        errorWidget: (c, u, e) => Container(color: Colors.grey),
                      )
                    : const Icon(Icons.tv, color: Colors.white70),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(epName, maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleTextStyle),
                const SizedBox(height: 4),
                if (epOverview.isNotEmpty) Text(epOverview, maxLines: 4, overflow: TextOverflow.ellipsis, style: _overviewTextStyle),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 96, maxWidth: 120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                if (runtime > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                    decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12)),
                    child: Text('${runtime}m', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      icon: const Icon(Icons.play_arrow, color: Colors.white),
                      onPressed: onPlayPressed,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.download, color: Colors.white),
                      onPressed: onDownloadPressed,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------- Episode options modal (reusable, public name) -----------------------------
class EpisodePlayOptionsModal extends StatefulWidget {
  final String initialResolution;
  final bool initialSubtitles;
  final void Function(String resolution, bool subtitles) onPlay;
  final void Function(String resolution, bool subtitles) onDownload;

  const EpisodePlayOptionsModal({
    required this.initialResolution,
    required this.initialSubtitles,
    required this.onPlay,
    required this.onDownload,
    super.key,
  });

  @override
  State<EpisodePlayOptionsModal> createState() => _EpisodePlayOptionsModalState();
}

class _EpisodePlayOptionsModalState extends State<EpisodePlayOptionsModal> {
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
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    return Container(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, top: 16, left: 16, right: 16),
      height: MediaQuery.of(context).size.height * 0.45,
      color: Colors.black87,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Center(child: Text("Episode Options", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white))),
        const SizedBox(height: 12),
        const Text("Select Resolution:", style: TextStyle(color: Colors.white)),
        DropdownButton<String>(
          value: _resolution,
          dropdownColor: Colors.black87,
          items: const [
            DropdownMenuItem(value: "480p", child: Text("480p", style: TextStyle(color: Colors.white))),
            DropdownMenuItem(value: "720p", child: Text("720p", style: TextStyle(color: Colors.white))),
            DropdownMenuItem(value: "1080p", child: Text("1080p", style: TextStyle(color: Colors.white))),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _resolution = v);
          },
        ),
        const SizedBox(height: 12),
        Row(children: [
          const Text("Enable Subtitles:", style: TextStyle(color: Colors.white)),
          const SizedBox(width: 8),
          Switch(value: _subtitles, activeColor: settings.accentColor, onChanged: (val) => setState(() => _subtitles = val)),
        ]),
        const Spacer(),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: settings.accentColor),
            onPressed: () {
              // close bottom sheet then notify host
              Navigator.of(context).pop();
              widget.onPlay(_resolution, _subtitles);
            },
            child: const Text("Play Now", style: TextStyle(color: Colors.black)),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(side: BorderSide(color: settings.accentColor)),
            onPressed: () {
              Navigator.of(context).pop();
              widget.onDownload(_resolution, _subtitles);
            },
            child: const Text("Download", style: TextStyle(color: Colors.white)),
          ),
        ]),
        const SizedBox(height: 16),
      ]),
    );
  }
}

// ----------------------------- main widget -----------------------------
class TVShowEpisodesSection extends StatefulWidget {
  final int tvId;
  final List<dynamic> seasons;
  final String tvShowName;
  final int? releaseYear; // parent provides this to avoid duplicate TV show fetch

  const TVShowEpisodesSection({
    super.key,
    required this.tvId,
    required this.seasons,
    required this.tvShowName,
    this.releaseYear,
  });

  @override
  State<TVShowEpisodesSection> createState() => TVShowEpisodesSectionState();
}

class TVShowEpisodesSectionState extends State<TVShowEpisodesSection> with AutomaticKeepAliveClientMixin {
  final Map<int, List<Map<String, dynamic>>> _episodesCache = <int, List<Map<String, dynamic>>>{};
  late int _selectedSeasonNumber;
  bool _isLoading = false;
  bool _isVisible = false;
  int? _releaseYear;

  // expose error message so UI doesn't spin forever
  String? _errorMessage;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _selectedSeasonNumber = widget.seasons.isNotEmpty ? (widget.seasons.first['season_number'] as int? ?? 1) : 1;
    _releaseYear = widget.releaseYear;
  }

  Future<void> _fetchEpisodes(int seasonNumber) async {
    if (_episodesCache.containsKey(seasonNumber) || _isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // tiny yield so layout completes before heavy work
    await Future.delayed(const Duration(milliseconds: 10));

    final stopwatch = Stopwatch()..start();
    try {
      debugPrint('TVShowEpisodesSection: fetching season $seasonNumber for tvId=${widget.tvId}');

      final seasonDetails = await tmdb.TMDBApi.fetchTVSeasonDetails(widget.tvId, seasonNumber).timeout(const Duration(seconds: 20));

      stopwatch.stop();
      debugPrint('Fetched season $seasonNumber in ${stopwatch.elapsedMilliseconds}ms');

      if (!mounted) return;

      final rawEpisodes = (seasonDetails['episodes'] is List) ? seasonDetails['episodes'] as List<dynamic> : <dynamic>[];

      // Offload normalization to background isolate — reduces main-thread work when many episodes exist
      final List<Map<String, dynamic>> episodes = await compute(_extractEpisodes, rawEpisodes);

      if (!mounted) return;

      setState(() {
        _episodesCache[seasonNumber] = episodes;
        _isLoading = false;
        _errorMessage = null;
      });
    } on TimeoutException catch (e) {
      stopwatch.stop();
      debugPrint('Timeout fetching season $seasonNumber: $e');
      if (!mounted) return;
      setState(() {
        _episodesCache[seasonNumber] = <Map<String, dynamic>>[];
        _isLoading = false;
        _errorMessage = 'Request timed out while loading episodes.';
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Request timed out while loading episodes.')));
    } catch (e, st) {
      stopwatch.stop();
      debugPrint('Error fetching season $seasonNumber: $e\n$st');
      if (!mounted) return;
      setState(() {
        _episodesCache[seasonNumber] = <Map<String, dynamic>>[];
        _isLoading = false;
        _errorMessage = 'Unable to load episodes. Tap Retry.';
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Unable to load episodes. Please try again.')));
    }
  }

  /// Show a small fallback dialog if parent MovieDetailScreenState isn't available.
  Future<void> _showLocalLoadingDialog() async {
    if (!mounted) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dctx) {
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
      },
    );
  }

  Future<void> _dismissLocalLoadingDialog() async {
    try {
      Navigator.of(context, rootNavigator: true).pop();
    } catch (_) {}
  }

  void _showEpisodePlayOptionsModal(Map<String, dynamic> episode, int seasonNumber) {
    if (!mounted) return;
    // Read accent color once w/out listen to keep rebuilds cheap
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    // find parent helpers (safe to call; method exists on MovieDetailScreenState added previously)
    final MovieDetailScreenState? parentState = context.findAncestorStateOfType<MovieDetailScreenState>();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (modalContext) {
        return EpisodePlayOptionsModal(
          initialResolution: '720p',
          initialSubtitles: false,
          onPlay: (resolution, subtitles) async {
            // immediate loader behavior (same as movie flow)
            final MovieDetailScreenState? parent = context.findAncestorStateOfType<MovieDetailScreenState>();

            // show loading immediately (parent modal if available, else local dialog)
            if (parent != null) {
              try {
                parent.showModalLoading();
              } catch (e) {
                // ignore
              }
            } else {
              await _showLocalLoadingDialog();
            }

            final episodeNumber = (episode['episode_number'] as int?) ?? 1;
            final episodeName = episode['name'] as String? ?? 'Untitled';
            Map<String, String> streamingInfo = <String, String>{};

            try {
              streamingInfo = await StreamingService.getStreamingLink(
                tmdbId: widget.tvId.toString(),
                title: widget.tvShowName.isNotEmpty ? widget.tvShowName : episodeName,
                releaseYear: _releaseYear ?? 1970,
                season: seasonNumber,
                episode: episodeNumber,
                resolution: resolution,
                enableSubtitles: subtitles,
              );
            } catch (e) {
              // dismiss loader and show error
              if (parent != null) {
                try {
                  parent.dismissModalLoading();
                } catch (_) {}
              } else {
                await _dismissLocalLoadingDialog();
              }
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Unable to start streaming. Please try again later.")));
              return;
            }

            final streamUrl = streamingInfo['url'] ?? '';
            final urlType = streamingInfo['type'] ?? 'unknown';
            final subtitleUrl = streamingInfo['subtitleUrl'];

            if (streamUrl.isEmpty) {
              if (parent != null) {
                try {
                  parent.dismissModalLoading();
                } catch (_) {}
              } else {
                await _dismissLocalLoadingDialog();
              }
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Streaming unavailable at this time.")));
              return;
            }

            // success: dismiss loading and navigate to player
            if (parent != null) {
              try {
                parent.dismissModalLoading();
              } catch (_) {}
            } else {
              await _dismissLocalLoadingDialog();
            }

            if (!mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => MainVideoPlayer(
                  videoPath: streamUrl,
                  title: streamingInfo['title'] ?? episodeName,
                  releaseYear: _releaseYear ?? 1970,
                  isFullSeason: true,
                  episodeFiles: const [],
                  similarMovies: const [],
                  subtitleUrl: subtitleUrl,
                  isHls: urlType == 'm3u8',
                ),
              ),
            );
          },

          onDownload: (resolution, subtitles) async {
            // sheet closed inside modal; call parent state's download method if available
            final episodeNumber = (episode['episode_number'] as int?) ?? 1;
            final parent = context.findAncestorStateOfType<MovieDetailScreenState>();
            if (parent != null) {
              await parent.downloadEpisodeFromChild(
                season: seasonNumber,
                episode: episodeNumber,
                showTitle: widget.tvShowName,
                showId: widget.tvId,
                resolution: resolution,
                subtitles: subtitles,
              );
            } else {
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Unable to start download.')));
            }
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    if (widget.seasons.isEmpty) return const SizedBox.shrink();

    // read accent color once without listening for changes (cheap)
    final accentColor = Provider.of<SettingsProvider>(context, listen: false).accentColor;

    return VisibilityDetector(
      key: ValueKey('episodes_${widget.tvId}'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction > 0.05 && !_isVisible && !_isLoading && _episodesCache[_selectedSeasonNumber] == null) {
          _isVisible = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Future.microtask(() => _fetchEpisodes(_selectedSeasonNumber));
          });
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // header + season selector inside glass container
          GlassContainer(
            child: Row(
              children: <Widget>[
                const Text('Episodes', style: _headerTitleStyle),
                const Spacer(),
                DropdownButton<int>(
                  value: _selectedSeasonNumber,
                  dropdownColor: Colors.black87,
                  style: const TextStyle(color: Colors.white),
                  iconEnabledColor: accentColor,
                  items: widget.seasons
                      .map<DropdownMenuItem<int>>((season) => DropdownMenuItem(
                            value: season['season_number'] as int? ?? 0,
                            child: Text('Season ${season['season_number'] ?? 0}'),
                          ))
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value != null && mounted) {
                      setState(() {
                        _selectedSeasonNumber = value;
                        _errorMessage = null;
                      });
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        Future.microtask(() => _fetchEpisodes(value));
                      });
                    }
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // content: shimmer / error / empty / list
          Builder(builder: (ctx) {
            final episodes = _episodesCache[_selectedSeasonNumber];

            if (_isLoading && (episodes == null || episodes.isEmpty)) {
              // shimmer placeholder
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: List<Widget>.generate(
                    4,
                    (index) => Padding(
                      padding: const EdgeInsets.only(bottom: 12.0),
                      child: Shimmer.fromColors(
                        baseColor: Colors.grey[800]!,
                        highlightColor: Colors.grey[600]!,
                        child: Container(height: 72, decoration: BoxDecoration(color: Colors.grey[800], borderRadius: BorderRadius.circular(8))),
                      ),
                    ),
                  ),
                ),
              );
            }

            if (_errorMessage != null && (episodes == null || episodes.isEmpty)) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                  Text(_errorMessage!, style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: accentColor),
                    onPressed: () => _fetchEpisodes(_selectedSeasonNumber),
                    child: const Text('Retry', style: TextStyle(color: Colors.black)),
                  ),
                ]),
              );
            }

            final list = episodes ?? <Map<String, dynamic>>[];
            if (list.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('No episodes found for this season.', style: TextStyle(color: Colors.white70)),
              );
            }

            // Lazy list of episodes — each item is a minimal StatelessWidget
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final episode = list[index];
                  final epNum = (episode['episode_number'] as int?) ?? index;
                  final key = ValueKey('${widget.tvId}_s${_selectedSeasonNumber}_e$epNum');

                  return KeyedSubtree(
                    key: key,
                    child: _EpisodeRow(
                      episode: episode,
                      seasonNumber: _selectedSeasonNumber,
                      tvShowName: widget.tvShowName,
                      tvId: widget.tvId,
                      releaseYear: _releaseYear,
                      onPlayPressed: () => _showEpisodePlayOptionsModal(episode, _selectedSeasonNumber),
                      onDownloadPressed: () {
                        final parentState = context.findAncestorStateOfType<MovieDetailScreenState>();
                        if (parentState != null) {
                          final epNumber = (episode['episode_number'] as int?) ?? 1;
                          parentState.downloadEpisodeFromChild(
                            season: _selectedSeasonNumber,
                            episode: epNumber,
                            showTitle: widget.tvShowName,
                            showId: widget.tvId,
                            resolution: '720p',
                            subtitles: false,
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Unable to start download.')));
                        }
                      },
                    ),
                  );
                },
              ),
            );
          }),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
