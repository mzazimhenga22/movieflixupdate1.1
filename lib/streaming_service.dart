// streaming_service.dart
// Updated: return direct m3u8 when available — no heavy decoding/searching
// Selection logic improved: prefer explicit hls/file streams, probe ambiguous URLs
// to avoid handing HTML landing pages to the player.

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:universal_html/html.dart' as html;
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

/// Exception
class StreamingNotAvailableException implements Exception {
  final String message;
  StreamingNotAvailableException(this.message);

  @override
  String toString() => 'StreamingNotAvailableException: $message';
}

class StreamingService {
  // Configure logger with pretty printer for readable console output
  static final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 1,
      errorMethodCount: 3,
      lineLength: 120,
      colors: true,
    ),
  );

  /// Main public method: returns a map with 'url' (mp4 or m3u8 or local playlist path),
  /// 'type' ('m3u8'|'mp4'), optional 'playlist' (raw playlist text), optional 'subtitleUrl'.
  static Future<Map<String, String>> getStreamingLink({
    required String tmdbId,
    required String title,
    required int releaseYear,
    required String resolution,
    required bool enableSubtitles,
    String subtitleLanguage = 'en',
    String? imdbId,
    Map<String, dynamic>? externalIds,
    int? season,
    int? episode,
    String? seasonTmdbId,
    String? episodeTmdbId,
    bool forDownload = false,
    String baseUrl = 'https://moviflxpro.onrender.com',
  }) async {
    _logger.i('Requesting streaming link for tmdbId=$tmdbId title="$title" '
        'year=$releaseYear resolution=$resolution show=${season != null && episode != null} imdbId=${imdbId ?? "none"}');

    final url = Uri.parse('$baseUrl/media-links');
    final isShow = season != null && episode != null;

    // Build body including optional imdb/external fields
    final body = <String, dynamic>{
      'type': isShow ? 'show' : 'movie',
      'tmdbId': tmdbId,
      'title': title,
      'releaseYear': releaseYear,
      'resolution': resolution,
      'subtitleLanguage': subtitleLanguage,
      if (imdbId != null) 'imdbId': imdbId,
      if (imdbId != null) 'imdb_id': imdbId,
      'external_ids': externalIds ?? (imdbId != null ? {'imdb_id': imdbId} : {}),
      if (isShow) ...{
        'seasonNumber': season,
        'seasonTmdbId': seasonTmdbId?.toString() ?? tmdbId,
        'episodeNumber': episode,
        'episodeTmdbId': episodeTmdbId?.toString() ?? tmdbId,
      }
    };

    _logger.d('POST $url → body: ${jsonEncode(body)}');

    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(body),
      );

      _logger.i('Backend responded with status ${response.statusCode}');
      final respBodyRaw = response.body ?? '';
      _logger.d('Response headers: ${response.headers}');
      _logger.d(
          'Response body (first 2000 chars): ${respBodyRaw.length > 2000 ? respBodyRaw.substring(0, 2000) + "..." : respBodyRaw}');

      if (response.statusCode != 200) {
        final snippet =
            respBodyRaw.length > 1000 ? respBodyRaw.substring(0, 1000) + '...' : respBodyRaw;
        _logger.e('Backend error: ${response.statusCode} - snippet: $snippet');
        throw StreamingNotAvailableException(
          'Failed to get streaming link: ${response.statusCode}',
        );
      }

      if (respBodyRaw.trim().isEmpty || respBodyRaw.trim() == 'null') {
        _logger.w('Backend returned empty or null body. Headers: ${response.headers}\nBody: $respBodyRaw');
        throw StreamingNotAvailableException(
            'Backend returned empty/null body. Status: ${response.statusCode}. Body snippet: ${respBodyRaw.isEmpty ? "null" : (respBodyRaw.length>200?respBodyRaw.substring(0,200)+"...":respBodyRaw)}. Headers: ${response.headers}');
      }

      final decodedRaw = jsonDecode(respBodyRaw);
      if (decodedRaw is! Map<String, dynamic>) {
        _logger.e('Invalid response format: expected Map but got ${decodedRaw.runtimeType}');
        throw StreamingNotAvailableException('Invalid response format.');
      }

      final decoded = Map<String, dynamic>.from(decodedRaw);
      dynamic raw = decoded['streams'] ?? (decoded.containsKey('stream') ? [decoded['stream']] : null);
      if (raw == null) {
        _logger.w('No streams found in backend response.');
        final snippet = respBodyRaw.length > 1000 ? '${respBodyRaw.substring(0, 1000)}...' : respBodyRaw;
        throw StreamingNotAvailableException('No streaming links available. Response snippet: $snippet');
      }

      final streams = List<Map<String, dynamic>>.from(raw);
      _logger.i('Found ${streams.length} stream(s) in backend response.');

      if (streams.isEmpty) {
        final snippet = respBodyRaw.length > 1000 ? '${respBodyRaw.substring(0, 1000)}...' : respBodyRaw;
        throw StreamingNotAvailableException('No streams available. Response snippet: $snippet');
      }

      // --------- REPLACEMENT SELECTION LOGIC ----------
      // Build a prioritized list of candidate strings to inspect (playlist text, playlist URL, quality urls, url)
      String? chosenUrl;
      String? chosenPlaylistText;
      String streamType = 'm3u8';
      String subtitleUrl = '';
      String? chosenQuality;

      final List<Map<String, dynamic>> candidates = [];

      for (final s in streams) {
        try {
          final String? typeField = s['type']?.toString();

          // 1) raw playlist text (highest priority)
          final playlistField = s['playlist'];
          if (playlistField != null && playlistField is String && _looksLikePlaylist(playlistField)) {
            candidates.add({'kind': 'playlistText', 'value': playlistField, 'origin': s, 'priority': 100});
            // Don't continue; still collect other candidates from same stream (but playlistText is highest priority).
          }

          // 2) explicit playlist URL
          if (playlistField != null && playlistField is String && (playlistField.startsWith('http://') || playlistField.startsWith('https://') || playlistField.startsWith('file://'))) {
            candidates.add({'kind': 'playlistUrl', 'value': playlistField, 'origin': s, 'priority': 90});
          }

          // 3) qualities map (collect top candidates)
          final qualRaw = s['qualities'];
          if (qualRaw is Map) {
            for (final entry in qualRaw.entries) {
              final qKey = entry.key?.toString() ?? '';
              final qVal = entry.value;
              String? candidateUrl;
              if (qVal is String) candidateUrl = qVal;
              else if (qVal is Map && qVal['url'] != null) candidateUrl = qVal['url'].toString();
              if (candidateUrl != null && candidateUrl.isNotEmpty) {
                final pr = candidateUrl.contains('.m3u8') ? 95 : (candidateUrl.contains('.mp4') ? 80 : 50);
                candidates.add({'kind': 'quality', 'value': candidateUrl, 'origin': s, 'priority': pr, 'qualityKey': qKey});
              }
            }
          }

          // 4) url field
          final urlField = s['url'];
          if (urlField != null) {
            final us = urlField.toString();
            if (us.isNotEmpty) {
              final pr = us.contains('.m3u8') ? 90 : (us.contains('.mp4') ? 75 : (typeField == 'hls' ? 88 : 40));
              candidates.add({'kind': 'url', 'value': us, 'origin': s, 'priority': pr});
            }
          }

          // small heuristic to prefer explicit types
          if (typeField == 'hls' && playlistField == null && (s['url'] == null || s['url'].toString().isEmpty)) {
            // maybe there are nested urls in object - add dump of object as candidate string to be probed later
            try {
              candidates.add({'kind': 'jsonDump', 'value': jsonEncode(s), 'origin': s, 'priority': 30});
            } catch (_) {}
          }
        } catch (_) {}
      }

      // sort candidates by priority desc and take top N to avoid too many probes
      candidates.sort((a, b) => (b['priority'] as int).compareTo(a['priority'] as int));
      const int maxProbes = 8;
      final List<Map<String, dynamic>> scanList = candidates.take(maxProbes).toList();

      // helper to accept a playlist text
      Future<void> _acceptPlaylistText(String txt, {String? qualityKey}) async {
        final tmp = await _writePlaylistToTempFile(tmdbId, txt);
        chosenUrl = tmp;
        chosenPlaylistText = txt;
        streamType = 'm3u8';
        chosenQuality = qualityKey;
        _logger.i('Selected playlist text -> $tmp');
      }

      Future<bool> _tryUrlCandidate(String candidateUrl, {String? qualityKey}) async {
        final s = candidateUrl.trim();
        if (s.isEmpty) return false;

        // raw m3u8 string in candidate? (unlikely here)
        if (_looksLikePlaylist(s)) {
          await _acceptPlaylistText(s, qualityKey: qualityKey);
          return true;
        }

        // obvious m3u8 url -> accept immediately (frontend will handle)
        if ((s.startsWith('http://') || s.startsWith('https://') || s.startsWith('file://')) && s.contains('.m3u8')) {
          chosenUrl = s;
          streamType = 'm3u8';
          chosenQuality = qualityKey;
          _logger.i('Selected m3u8 url -> ${_short(s)}');
          return true;
        }

        // obvious mp4 -> accept (fast)
        if ((s.startsWith('http://') || s.startsWith('https://') || s.startsWith('file://')) && s.contains('.mp4')) {
          chosenUrl = s;
          streamType = 'mp4';
          chosenQuality = qualityKey;
          _logger.i('Selected mp4 url -> ${_short(s)}');
          return true;
        }

        // For ambiguous URLs (landing pages, redirectors) use probe
        _logger.d('Probing ambiguous candidate -> ${_short(s)}');
        final ok = await _probePlayableUrl(s);
        if (ok) {
          chosenUrl = s;
          streamType = s.endsWith('.mp4') ? 'mp4' : (s.contains('.m3u8') ? 'm3u8' : 'mp4');
          chosenQuality = qualityKey;
          _logger.i('Probe accepted -> ${_short(s)} (type=${streamType})');
          return true;
        } else {
          _logger.w('Probe rejected -> ${_short(s)}');
          return false;
        }
      }

      // iterate scanList and pick first acceptable candidate
      for (final c in scanList) {
        try {
          final kind = c['kind'] as String? ?? 'url';
          final value = (c['value'] ?? '').toString();
          final qualityKey = c['qualityKey']?.toString();
          if (kind == 'playlistText') {
            await _acceptPlaylistText(value, qualityKey: qualityKey);
            break;
          }
          if (kind == 'playlistUrl') {
            final ps = value;
            if (ps.contains('.m3u8')) {
              chosenUrl = ps;
              streamType = 'm3u8';
              chosenQuality = qualityKey;
              _logger.i('Selected playlist url -> ${_short(ps)}');
              break;
            } else {
              final ok = await _tryUrlCandidate(ps, qualityKey: qualityKey);
              if (ok) break;
            }
          } else {
            final ok = await _tryUrlCandidate(value, qualityKey: qualityKey);
            if (ok) break;
          }
        } catch (e, st) {
          _logger.w('Candidate check threw: $e\n$st');
        }
      }

      // If still nothing chosen, try a second pass for lower-priority candidates (without extra probes),
      // but only accept raw playlist text or explicit .m3u8/.mp4 urls.
      if (chosenUrl == null) {
        for (final c in candidates.skip(maxProbes)) {
          try {
            final v = (c['value'] ?? '').toString();
            if (v.contains('.m3u8') || v.contains('.mp4')) {
              chosenUrl = v;
              streamType = v.contains('.m3u8') ? 'm3u8' : 'mp4';
              chosenQuality = c['qualityKey']?.toString();
              _logger.i('Second-pass selected -> ${_short(v)}');
              break;
            }
            if (_looksLikePlaylist(v)) {
              final tmp = await _writePlaylistToTempFile(tmdbId, v);
              chosenUrl = tmp;
              chosenPlaylistText = v;
              streamType = 'm3u8';
              chosenQuality = c['qualityKey']?.toString();
              _logger.i('Second-pass playlist text selected -> $tmp');
              break;
            }
          } catch (_) {}
        }
      }

      if (chosenUrl == null || chosenUrl!.isEmpty) {
        final bodySnippet =
            respBodyRaw.length > 1000 ? '${respBodyRaw.substring(0, 1000)}...' : respBodyRaw;
        _logger.w('No usable streamUrl found after probing. snippet: $bodySnippet');
        throw StreamingNotAvailableException(
          'No stream URL available. Response snippet: $bodySnippet',
        );
      }
      // ---------- end replacement selection logic ----------

      // Subtitles handling (simple: take first caption that matches language or first available)
      for (final s in streams) {
        try {
          final caps = s['captions'];
          if (enableSubtitles && caps != null) {
            if (caps is List && caps.isNotEmpty) {
              dynamic selectedCap;
              for (var c in caps) {
                if (c is Map &&
                    ((c['language'] == subtitleLanguage) || (c['lang'] == subtitleLanguage))) {
                  selectedCap = c;
                  break;
                }
              }
              selectedCap ??= caps.first;
              String srtUrlRaw = '';
              if (selectedCap is String) {
                srtUrlRaw = selectedCap;
              } else if (selectedCap is Map) {
                srtUrlRaw = (selectedCap['url'] ?? selectedCap['src'] ?? selectedCap['source'] ?? '').toString();
              }
              if (srtUrlRaw.isNotEmpty) {
                // We purposely do NOT attempt heavy decoding here. If it's a direct URL, return it.
                subtitleUrl = srtUrlRaw;
                _logger.i('Selected subtitle URL -> ${_short(subtitleUrl)}');
                break;
              }
            } else if (caps is Map) {
              final srt = (caps['url'] ?? caps['src'] ?? caps['source'])?.toString();
              if (srt != null && srt.isNotEmpty) {
                subtitleUrl = srt;
                _logger.i('Selected subtitle from map -> ${_short(subtitleUrl)}');
                break;
              }
            } else if (caps is String) {
              subtitleUrl = caps;
              _logger.i('Selected subtitle string -> ${_short(subtitleUrl)}');
              break;
            }
          }
        } catch (e, st) {
          _logger.w('Failed to inspect subtitles for a stream: $e\n$st');
        }
      }

      // If chosenUrl is remote m3u8 and forDownload requested, attempt to download playlist to temp file
      if (chosenUrl != null &&
          chosenUrl!.isNotEmpty &&
          chosenUrl!.contains('.m3u8') &&
          forDownload &&
          !kIsWeb &&
          (chosenUrl!.startsWith('http://') || chosenUrl!.startsWith('https://'))) {
        try {
          _logger.d('forDownload=true, fetching remote playlist to store locally...');
          final cUrl = chosenUrl!; // safe unwrap here
          final playlistResponse = await http.get(Uri.parse(cUrl));
          if (playlistResponse.statusCode == 200) {
            final file = File('${(await getTemporaryDirectory()).path}/$tmdbId-playlist.m3u8');
            await file.writeAsString(playlistResponse.body);
            chosenPlaylistText = playlistResponse.body;
            chosenUrl = file.path; // now a valid local file path
            _logger.i('Saved remote playlist to ${file.path} for download mode.');
          } else {
            _logger.w(
              'Failed to fetch remote playlist for download mode: ${playlistResponse.statusCode}',
            );
          }
        } catch (e, st) {
          _logger.w('Failed to fetch remote playlist for download mode: $e\n$st');
        }
      }
      final result = <String, String>{
        'url': chosenUrl!,
        'type': streamType,
        'title': title,
      };
      if (chosenPlaylistText != null) result['playlist'] = chosenPlaylistText!;
      if (subtitleUrl.isNotEmpty) result['subtitleUrl'] = subtitleUrl;
      if (chosenQuality != null) result['quality'] = chosenQuality!;

      _logger.i('Streaming link resolved: ${result['url']} (type=${result['type']}) '
          '${result.containsKey('quality') ? 'quality=${result['quality']}' : ''}');

      return result;
    } catch (e, st) {
      _logger.e('Error fetching stream: $e\n$st');
      rethrow;
    }
  }

  // ------------------------------------------------------------
  // Write playlist text to a temporary file and return path
  // ------------------------------------------------------------
  static Future<String> _writePlaylistToTempFile(String tmdbId, String playlist) async {
    if (kIsWeb) {
      final bytes = utf8.encode(playlist);
      final blob = html.Blob([bytes], 'application/vnd.apple.mpegurl');
      return html.Url.createObjectUrlFromBlob(blob);
    } else {
      final file = File('${(await getTemporaryDirectory()).path}/$tmdbId-playlist-${DateTime.now().millisecondsSinceEpoch}.m3u8');
      await file.writeAsString(playlist);
      return file.path;
    }
  }

  // Helper to detect raw playlist text
  static bool _looksLikePlaylist(String s) {
    final upper = s.toUpperCase();
    return upper.contains('#EXTM3U') || upper.contains('#EXT-X-STREAM-INF') || upper.contains('#EXTINF');
  }

  // ------------------------------------------------------------
  // Probe helper kept for optional external uses (used in selection)
  // ------------------------------------------------------------
  static Future<bool> _probePlayableUrl(String url, {Map<String, String>? headers}) async {
    try {
      final uri = Uri.parse(url);
      final client = http.Client();

      // Try HEAD first
      http.Response? headResp;
      try {
        headResp = await client.head(uri, headers: headers ?? {});
      } catch (_) {
        headResp = null; // some servers don't support HEAD
      }

      final ct = headResp?.headers['content-type']?.toLowerCase() ?? '';
      if (ct.isNotEmpty &&
          !(ct.contains('video') ||
              ct.contains('mpegurl') ||
              ct.contains('application/vnd.apple.mpegurl') ||
              ct.contains('application/octet-stream') ||
              ct.contains('audio') ||
              ct.contains('application'))) {
        if (ct.contains('text') || ct.contains('html')) {
          _logger.w('Probe HEAD/content-type indicates non-media: $ct for $url');
          client.close();
          return false;
        }
      }

      // Now fetch a small byte range (0..16383) to inspect actual bytes
      final rangeHeaders = <String, String>{
        'Range': 'bytes=0-16383',
        if (headers != null) ...headers,
      };

      final resp = await client.get(uri, headers: rangeHeaders);

      if (resp.statusCode != 200 && resp.statusCode != 206) {
        _logger.w('Probe ranged GET returned ${resp.statusCode} for $url');
        client.close();
        return false;
      }

      final bodyBytes = resp.bodyBytes;
      if (bodyBytes.isEmpty) {
        _logger.w('Probe returned empty body for $url');
        client.close();
        return false;
      }

      // check for HTML (Cloudflare / anti-bot pages often start with '<' or contain 'cf-ray' etc)
      final headText = utf8.decode(bodyBytes.length > 512 ? bodyBytes.sublist(0, 512) : bodyBytes, allowMalformed: true).toLowerCase();
      if (headText.contains('<!doctype') || headText.contains('<html') || headText.contains('cloudflare') || headText.contains('captcha')) {
        _logger.w('Probe body looks like HTML/anti-bot page for $url');
        client.close();
        return false;
      }

      // textual playlist detection (#EXTM3U)
      if (headText.toUpperCase().contains('#EXTM3U') || headText.toUpperCase().contains('#EXT-X-STREAM-INF')) {
        client.close();
        return true;
      }

      // check first bytes for MP4 'ftyp' box (common), or for TS ('#EXTM3U'/EXTINF) or webm signature
      final snippet = bodyBytes.length > 256 ? bodyBytes.sublist(0, 256) : bodyBytes;
      final snippetStr = utf8.decode(snippet, allowMalformed: true);
      if (snippetStr.contains('ftyp') || snippetStr.contains('moov') || snippetStr.contains('mdat')) {
        client.close();
        return true;
      }

      // Matroska/webm signature check: 0x1A45DFA3
      final prefixHex = snippet.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (prefixHex.startsWith('1a45dfa3') || snippetStr.contains('webm')) {
        client.close();
        return true;
      }

      // fallback: content-type from ranged GET
      final rangedCt = resp.headers['content-type']?.toLowerCase() ?? '';
      if (rangedCt.contains('video') || rangedCt.contains('mpegurl') || rangedCt.contains('audio') || rangedCt.contains('application')) {
        client.close();
        return true;
      }

      _logger.w('Probe could not validate media signature for $url (prefixHex: $prefixHex, ct="$rangedCt")');
      client.close();
      return false;
    } catch (e, st) {
      _logger.w('Probe threw for $url: $e\n$st');
      return false;
    }
  }

  // ------------------------------------------------------------
  // Subtitle conversion helper (kept for offline converting)
  // ------------------------------------------------------------
  static String _convertSrtToVtt(String srtContent) {
    final lines = srtContent.split('\n');
    final buffer = StringBuffer()..writeln('WEBVTT\n');

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      if (RegExp(r'^\d+$').hasMatch(line)) {
        // Skip subtitle index line
        continue;
      } else if (line.contains('-->')) {
        buffer.writeln(line.replaceAll(',', '.')); // Convert SRT time format to VTT
      } else {
        buffer.writeln(line);
      }
    }

    return buffer.toString().trim();
  }

  // small helper for logging short versions of strings
  static String _short(String s, [int max = 160]) {
    if (s.length <= max) return s;
    return s.substring(0, max) + '...';
  }
}

// =========================
// Offline downloader below (unchanged from previous working implementation)
// =========================

class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class DownloadProgress {
  final int downloadedSegments;
  final int totalSegments;
  final int bytesDownloaded;
  final int? totalBytes;

  /// true when the downloader is performing final steps (playlist rewrite, merging, etc.)
  final bool finalizing;

  /// optional short message to show to the user, e.g. "Merging segments..." or "Writing playlist..."
  final String? message;

  DownloadProgress({
    required this.downloadedSegments,
    required this.totalSegments,
    required this.bytesDownloaded,
    this.totalBytes,
    this.finalizing = false,
    this.message,
  });
}

class OfflineDownloader {
  /// Accepts the streamInfo map returned by StreamingService.getStreamingLink(...)
  /// and downloads it to app documents under /offline/<id>.
  static Future<Map<String, String>> downloadAnyStream({
    required Map<String, String> streamInfo,
    required String id,
    String? preferredResolution,
    bool mergeSegments = false,
    int concurrency = 4,
    void Function(DownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final url = streamInfo['url']!;
    if (url.contains('.m3u8')) {
      return _downloadHls(
        m3u8Url: url,
        id: id,
        preferredResolution: preferredResolution,
        mergeSegments: mergeSegments,
        concurrency: concurrency,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    } else {
      final filePath = await _downloadFileWithResume(
        url: url,
        id: id,
        cancelToken: cancelToken,
        onProgressBytes: (downloaded, total) {
          onProgress?.call(DownloadProgress(
            downloadedSegments: 0,
            totalSegments: 1,
            bytesDownloaded: downloaded,
            totalBytes: total,
            finalizing: false,
          ));
        },
      );

      // Notify UI that we're finalizing (small UX nicety) so it doesn't remain "100%" without message
      onProgress?.call(DownloadProgress(
        downloadedSegments: 1,
        totalSegments: 1,
        bytesDownloaded: (await File(filePath).length()),
        totalBytes: null,
        finalizing: true,
        message: 'Finalizing file...',
      ));

      return {'type': 'mp4', 'file': filePath};
    }
  }

  // mp4 resume downloader
  static Future<String> _downloadFileWithResume({
    required String url,
    required String id,
    CancelToken? cancelToken,
    void Function(int downloaded, int? total)? onProgressBytes,
  }) async {
    final uri = Uri.parse(url);
    final doc = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(doc.path, 'offline', id));
    if (!await outDir.exists()) await outDir.create(recursive: true);

    final filename = p.basename(uri.path);
    final outFile = File(p.join(outDir.path, filename));
    int existing = 0;
    if (await outFile.exists()) {
      existing = await outFile.length();
    }

    final client = http.Client();
    try {
      final headResp = await client.head(uri);
      final total = headResp.headers['content-length'] != null ? int.tryParse(headResp.headers['content-length']!) : null;

      final headers = <String, String>{};
      if (existing > 0 && total != null && existing < total) {
        headers['Range'] = 'bytes=$existing-';
      }

      final req = http.Request('GET', uri);
      req.headers.addAll(headers);
      final streamed = await client.send(req);

      if (streamed.statusCode == 200 && existing > 0) {
        // server ignored range -> re-download
        await outFile.delete();
        existing = 0;
      }

      final iosink = outFile.openWrite(mode: FileMode.append);
      final totalBytes = streamed.contentLength != null ? (existing + streamed.contentLength!) : null;
      int downloaded = existing;
      final completer = Completer<String>();
      streamed.stream.listen((chunk) async {
        if (cancelToken?.isCancelled == true) {
          await iosink.close();
          completer.completeError(Exception('Download cancelled'));
          return;
        }
        iosink.add(chunk);
        downloaded += chunk.length;
        onProgressBytes?.call(downloaded, totalBytes);
      }, onDone: () async {
        await iosink.close();
        completer.complete(outFile.path);
      }, onError: (e) async {
        await iosink.close();
        completer.completeError(e);
      }, cancelOnError: true);

      return completer.future;
    } finally {
      client.close();
    }
  }

  // HLS downloader (keeps structure from previous code)
  static Future<Map<String, String>> _downloadHls({
    required String m3u8Url,
    required String id,
    String? preferredResolution,
    bool mergeSegments = false,
    int concurrency = 4,
    void Function(DownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final doc = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(doc.path, 'offline', id));
    if (!await outDir.exists()) await outDir.create(recursive: true);

    final client = http.Client();
    try {
      Uri baseUri;
      String playlist;

      if (m3u8Url.startsWith('http://') || m3u8Url.startsWith('https://')) {
        baseUri = Uri.parse(m3u8Url);
        final resp = await client.get(baseUri);
        if (resp.statusCode != 200) throw Exception('Playlist download failed: ${resp.statusCode}');
        playlist = resp.body.replaceAll('\r\n', '\n');
      } else {
        final maybe = m3u8Url;
        final file = File(maybe);
        if (await file.exists()) {
          playlist = (await file.readAsString()).replaceAll('\r\n', '\n');
          baseUri = Uri.file(file.path);
        } else {
          try {
            final uri = Uri.parse(maybe);
            if (uri.scheme == 'file') {
              final f2 = File(uri.toFilePath());
              if (!await f2.exists()) throw Exception('Local playlist file not found: ${f2.path}');
              playlist = (await f2.readAsString()).replaceAll('\r\n', '\n');
              baseUri = uri;
            } else {
              throw Exception('Local playlist file not found: $maybe');
            }
          } catch (e) {
            throw Exception('Local playlist file not found: $maybe');
          }
        }
      }

      // Master playlist detection
      if (playlist.contains('#EXT-X-STREAM-INF')) {
        final lines = playlist.split('\n');
        String? pickedVariant;
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i].trim();
          if (l.startsWith('#EXT-X-STREAM-INF')) {
            var j = i + 1;
            while (j < lines.length && lines[j].trim().isEmpty) {
              j++;
            }
            if (j < lines.length) {
              final candidate = lines[j].trim();
              if (preferredResolution != null && l.contains(preferredResolution)) {
                pickedVariant = candidate;
                break;
              }
              pickedVariant ??= candidate;
            }
          }
        }
        if (pickedVariant == null) throw Exception('No variant streams found in master playlist.');

        final variantUrl = _resolveUri(baseUri, pickedVariant);
        final variantUri = Uri.parse(variantUrl);

        if (variantUri.scheme == 'file') {
          final vfile = File(variantUri.toFilePath());
          if (!await vfile.exists()) throw Exception('Variant playlist file not found: ${vfile.path}');
          playlist = (await vfile.readAsString()).replaceAll('\r\n', '\n');
          baseUri = variantUri;
        } else {
          final vresp = await client.get(variantUri);
          if (vresp.statusCode != 200) throw Exception('Variant playlist download failed: ${vresp.statusCode}');
          playlist = vresp.body.replaceAll('\r\n', '\n');
          baseUri = variantUri;
        }
      }

      // Parse playlist for segments and keys
      final lines = playlist.split('\n');
      final segments = <_Segment>[];
      String? lastKeyLine;
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        if (line.startsWith('#EXT-X-KEY')) {
          lastKeyLine = line;
        } else if (!line.startsWith('#')) {
          final segUrl = _resolveUri(baseUri, line);
          final seq = segments.length;
          segments.add(_Segment(url: segUrl, seq: seq, keyLine: lastKeyLine));
        }
      }

      if (segments.isEmpty) throw Exception('No segments found in playlist.');

      // Pre-fetch AES keys
      final uniqueKeyUris = <String>{};
      for (var seg in segments) {
        final kl = seg.keyLine;
        if (kl != null) {
          final attrs = _parseAttributes(kl.substring('#EXT-X-KEY:'.length));
          final method = attrs['METHOD'];
          final uriRaw = attrs['URI']?.replaceAll('"', '');
          if (method != null && method.toUpperCase() == 'AES-128' && uriRaw != null) {
            final keyUri = _resolveUri(baseUri, uriRaw);
            uniqueKeyUris.add(keyUri);
          }
        }
      }

      final keyCache = <String, Uint8List>{};
      for (var keyUriStr in uniqueKeyUris) {
        final keyUri = Uri.parse(keyUriStr);
        if (keyUri.scheme == 'file') {
          final keyFile = File(keyUri.toFilePath());
          if (!await keyFile.exists()) throw Exception('Failed to load key file: ${keyFile.path}');
          keyCache[keyUriStr] = Uint8List.fromList(await keyFile.readAsBytes());
        } else {
          final kresp = await client.get(keyUri);
          if (kresp.statusCode != 200) throw Exception('Failed to download key: ${kresp.statusCode}');
          keyCache[keyUriStr] = Uint8List.fromList(kresp.bodyBytes);
        }
      }

      // Download segments concurrently
      int downloadedSegments = 0;
      int bytesDownloaded = 0;
      final totalSegments = segments.length;
      final semaphore = _AsyncSemaphore(concurrency);
      final futures = <Future>[];

      for (var seg in segments) {
        final segUri = Uri.parse(seg.url);
        final filename = p.basename(segUri.path);
        final outFile = File(p.join(outDir.path, filename));

        final f = () async {
          await semaphore.acquire();
          try {
            if (cancelToken?.isCancelled == true) throw Exception('Cancelled');

            if (await outFile.exists() && await outFile.length() > 0) {
              downloadedSegments++;
              final len = await outFile.length();
              bytesDownloaded += len;
              onProgress?.call(DownloadProgress(
                downloadedSegments: downloadedSegments,
                totalSegments: totalSegments,
                bytesDownloaded: bytesDownloaded,
                finalizing: false,
              ));
              return;
            }

            Uint8List data;
            if (segUri.scheme == 'file') {
              final localFile = File(segUri.toFilePath());
              if (!await localFile.exists()) throw Exception('Segment file not found: ${localFile.path}');
              data = await localFile.readAsBytes();
            } else {
              final r = await client.get(segUri);
              if (r.statusCode != 200) throw Exception('Failed to download segment ${seg.url}: ${r.statusCode}');
              data = Uint8List.fromList(r.bodyBytes);
            }

            // AES-128 decrypt if required
            if (seg.keyLine != null) {
              final attrs = _parseAttributes(seg.keyLine!.substring('#EXT-X-KEY:'.length));
              final method = attrs['METHOD'];
              final uriRaw = attrs['URI']?.replaceAll('"', '');
              final ivRaw = attrs['IV'];
              if (method != null && method.toUpperCase() == 'AES-128' && uriRaw != null) {
                final keyUri = _resolveUri(baseUri, uriRaw);
                final key = keyCache[keyUri];
                if (key == null) throw Exception('Key missing for AES-128 segment');
                Uint8List iv;
                if (ivRaw != null) {
                  iv = _hexToBytes(ivRaw.replaceFirst('0x', ''));
                } else {
                  iv = _ivFromSequence(seg.seq);
                }
                data = _aes128CbcDecrypt(data, key, iv);
              }
            }

            await outFile.writeAsBytes(data);
            downloadedSegments++;
            bytesDownloaded += data.length;
            onProgress?.call(DownloadProgress(
              downloadedSegments: downloadedSegments,
              totalSegments: totalSegments,
              bytesDownloaded: bytesDownloaded,
              finalizing: false,
            ));
          } finally {
            semaphore.release();
          }
        }();
        futures.add(f);
      }

      await Future.wait(futures);

      // Notify UI that all segments were downloaded and we are entering finalizing stage
      onProgress?.call(DownloadProgress(
        downloadedSegments: downloadedSegments,
        totalSegments: totalSegments,
        bytesDownloaded: bytesDownloaded,
        finalizing: true,
        message: 'Writing local playlist...',
      ));

      // Rewrite local playlist referencing local segment filenames and remove AES key URIs
      final localPlaylistPath = p.join(outDir.path, '$id-local.m3u8');
      final localPlaylistFile = File(localPlaylistPath);
      final rewritten = <String>[];
      for (var line in lines) {
        if (line.trim().isEmpty) continue;
        if (line.startsWith('#EXT-X-KEY')) {
          rewritten.add('#EXT-X-KEY:METHOD=NONE');
        } else if (line.startsWith('#')) {
          rewritten.add(line);
        } else {
          final resolved = _resolveUri(baseUri, line);
          final name = p.basename(Uri.parse(resolved).path);
          rewritten.add(name);
        }
      }
      await localPlaylistFile.writeAsString(rewritten.join('\n'));

      // If merging requested, inform about merging and run merge step
      String? mergedPath;
      if (mergeSegments) {
        onProgress?.call(DownloadProgress(
          downloadedSegments: downloadedSegments,
          totalSegments: totalSegments,
          bytesDownloaded: bytesDownloaded,
          finalizing: true,
          message: 'Merging segments...',
        ));

        final mergedFile = File(p.join(outDir.path, '$id-merged.ts'));
        final raf = mergedFile.openSync(mode: FileMode.write);
        try {
          for (var seg in segments) {
            final segUri = Uri.parse(seg.url);
            final filename = p.basename(segUri.path);
            final segFile = File(p.join(outDir.path, filename));
            if (!await segFile.exists()) throw Exception('Segment missing: ${segFile.path}');
            final bytes = await segFile.readAsBytes();
            raf.writeFromSync(bytes);
          }
        } finally {
          await raf.close();
        }
        mergedPath = mergedFile.path;

        // final signal after merging
        final mergedFileLen = await File(mergedPath).length();
        onProgress?.call(DownloadProgress(
          downloadedSegments: downloadedSegments,
          totalSegments: totalSegments,
          bytesDownloaded: bytesDownloaded + mergedFileLen,
          totalBytes: mergedFileLen,
          finalizing: true,
          message: 'Finalized',
        ));
      } else {
        // final signal after playlist writing only
        onProgress?.call(DownloadProgress(
          downloadedSegments: downloadedSegments,
          totalSegments: totalSegments,
          bytesDownloaded: bytesDownloaded,
          finalizing: true,
          message: 'Finalized',
        ));
      }

      return {'type': 'm3u8', 'playlist': localPlaylistFile.path, if (mergedPath != null) 'merged': mergedPath};
    } finally {
      client.close();
    }
  }

  // -------------------------
  // Helpers (resolve URIs, parse attrs, AES, etc.)
  // -------------------------
  static String _resolveUri(Uri playlistUri, String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return trimmed;

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) return trimmed;

    if (trimmed.startsWith('//')) {
      final scheme = (playlistUri.scheme.isNotEmpty) ? playlistUri.scheme : 'https';
      return '$scheme:$trimmed';
    }

    if (playlistUri.hasScheme && playlistUri.scheme == 'file') {
      final basePath = playlistUri.toFilePath();
      final resolvedPath = p.normalize(p.join(p.dirname(basePath), trimmed));
      return Uri.file(resolvedPath).toString();
    }

    if (trimmed.startsWith('/')) {
      return '${playlistUri.scheme}://${playlistUri.authority}$trimmed';
    }

    try {
      final resolved = playlistUri.resolve(trimmed);
      return resolved.toString();
    } catch (e) {
      return '${playlistUri.scheme}://${playlistUri.authority}/$trimmed';
    }
  }

  static Map<String, String> _parseAttributes(String input) {
    final map = <String, String>{};
    final parts = RegExp(r'([A-Z0-9-]+)=("(?:[^"]*)"|[^,]*)').allMatches(input);
    for (final m in parts) {
      final key = m.group(1)!;
      var value = m.group(2)!;
      if (value.startsWith('"') && value.endsWith('"')) value = value.substring(1, value.length - 1);
      map[key] = value;
    }
    return map;
  }

  static Uint8List _hexToBytes(String hex) {
    final clean = hex.length % 2 == 1 ? '0$hex' : hex;
    final bytes = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < clean.length; i += 2) {
      bytes[i ~/ 2] = int.parse(clean.substring(i, i + 2), radix: 16);
    }
    return bytes;
  }

  static Uint8List _ivFromSequence(int seq) {
    final iv = Uint8List(16);
    final seqBytes = ByteData(8)..setUint64(0, seq, Endian.big);
    for (var i = 0; i < 8; i++) iv[8 + i] = seqBytes.getUint8(i);
    return iv;
  }

  static Uint8List _aes128CbcDecrypt(Uint8List data, Uint8List key, Uint8List iv) {
    final params = ParametersWithIV(KeyParameter(key), iv);
    final cipher = CBCBlockCipher(AESEngine())..init(false, params);

    final out = Uint8List(data.length);
    final blockSize = cipher.blockSize;
    var offset = 0;
    final input = Uint8List(blockSize);
    final output = Uint8List(blockSize);

    while (offset < data.length) {
      final inLen = ((offset + blockSize) <= data.length) ? blockSize : data.length - offset;
      input.fillRange(0, blockSize, 0);
      input.setRange(0, inLen, data, offset);
      cipher.processBlock(input, 0, output, 0);
      final writeLen = (inLen == blockSize) ? blockSize : inLen;
      out.setRange(offset, offset + writeLen, output, 0);
      offset += inLen;
    }
    return out;
  }
}

class _Segment {
  final String url;
  final int seq;
  final String? keyLine;
  _Segment({required this.url, required this.seq, this.keyLine});
}

class _AsyncSemaphore {
  int _tokens;
  final List<Completer<void>> _waiters = [];
  _AsyncSemaphore(this._tokens);
  Future<void> acquire() {
    if (_tokens > 0) {
      _tokens--;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      final c = _waiters.removeAt(0);
      c.complete();
    } else {
      _tokens++;
    }
  }
}
