// streaming_service.dart
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

/// Top-level helper types (must NOT be declared inside another class)
class _DecodedCandidate {
  final String? url;
  final String? text; // raw playlist text if available

  _DecodedCandidate({this.url, this.text});

  bool get isPlaylistText => text != null && text!.isNotEmpty;
  bool get isRemoteM3u8 =>
      url != null &&
      (url!.startsWith('http://') ||
          url!.startsWith('https://') ||
          url!.startsWith('file://')) &&
      url!.contains('.m3u8');
}

class _StreamCandidate {
  final Map<String, dynamic> origin;
  final String rawUrl;
  final String fieldName;
  final String? type;
  final String? quality;
  _StreamCandidate({
    required this.origin,
    required this.rawUrl,
    required this.fieldName,
    this.type,
    this.quality,
  });
}

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

  /// Main public method: tries to return a usable 'url' (mp4 or m3u8) or a local
  /// playlist path in 'url', plus optional 'playlist' text and 'subtitleUrl'.
  static Future<Map<String, String>> getStreamingLink({
    required String tmdbId,
    required String title,
    required int releaseYear,
    required String resolution,
    required bool enableSubtitles,
    int? season,
    int? episode,
    String? seasonTmdbId,
    String? episodeTmdbId,
    bool forDownload = false,
  }) async {
    _logger.i('Requesting streaming link for tmdbId=$tmdbId title="$title" '
        'year=$releaseYear resolution=$resolution show=${season != null && episode != null}');

    final url = Uri.parse('https://moviflxpro.onrender.com/media-links');
    final isShow = season != null && episode != null;

    final body = <String, dynamic>{
      'type': isShow ? 'show' : 'movie',
      'tmdbId': tmdbId,
      'title': title,
      'releaseYear': releaseYear,
      'resolution': resolution,
      'subtitleLanguage': 'en',
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
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      _logger.i('Backend responded with status ${response.statusCode}');
      final respBodyRaw = response.body ?? '';
      _logger.d('Response headers: ${response.headers}');
      _logger.d('Response body (first 2000 chars): ${respBodyRaw.length > 2000 ? respBodyRaw.substring(0,2000) + "..." : respBodyRaw}');

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
      dynamic raw = decoded['streams'] ??
          (decoded.containsKey('stream') ? [decoded['stream']] : null);
      if (raw == null) {
        _logger.w('No streams found in backend response.');
        final snippet = respBodyRaw.length > 1000
            ? '${respBodyRaw.substring(0, 1000)}...'
            : respBodyRaw;
        throw StreamingNotAvailableException(
            'No streaming links available. Response snippet: $snippet');
      }

      final streams = List<Map<String, dynamic>>.from(raw);
      _logger.i('Found ${streams.length} stream(s) in backend response.');

      if (streams.isEmpty) {
        final snippet = respBodyRaw.length > 1000
            ? '${respBodyRaw.substring(0, 1000)}...'
            : respBodyRaw;
        throw StreamingNotAvailableException('No streams available. Response snippet: $snippet');
      }

      // collect candidates to try decoding
      final candidates = <_StreamCandidate>[];
      for (final s in streams) {
        final urlField = s['url']?.toString();
        final playlistField = s['playlist']?.toString();
        final typeField = s['type']?.toString();

        if (urlField != null && urlField.isNotEmpty) {
          candidates.add(_StreamCandidate(
              origin: s, rawUrl: urlField, fieldName: 'url', type: typeField));
          _logger.d('Candidate added from url: ${_short(urlField)}');
        }
        if (playlistField != null && playlistField.isNotEmpty) {
          candidates.add(_StreamCandidate(
              origin: s,
              rawUrl: playlistField,
              fieldName: 'playlist',
              type: typeField));
          _logger.d('Candidate added from playlist (may be text/url): ${_short(playlistField)}');
        }

        // qualities handling: qualities may be a map of resolution->string or object
        try {
          final qualRaw = s['qualities'];
          if (qualRaw is Map) {
            final qMap = Map<String, dynamic>.from(qualRaw);
            qMap.forEach((qualKey, qualVal) {
              if (qualVal == null) return;
              if (qualVal is String) {
                candidates.add(_StreamCandidate(
                    origin: s,
                    rawUrl: qualVal,
                    fieldName: 'qualities',
                    type: typeField,
                    quality: qualKey));
                _logger.d('Candidate added from qualities.$qualKey: ${_short(qualVal)}');
              } else if (qualVal is Map) {
                final inner = Map<String, dynamic>.from(qualVal);
                final u = inner['url']?.toString();
                final pstr = inner['playlist']?.toString();
                if (u != null && u.isNotEmpty) {
                  candidates.add(_StreamCandidate(
                      origin: s,
                      rawUrl: u,
                      fieldName: 'qualities.$qualKey.url',
                      type: typeField,
                      quality: qualKey));
                  _logger.d('Candidate added from qualities.$qualKey.url: ${_short(u)}');
                }
                if (pstr != null && pstr.isNotEmpty) {
                  candidates.add(_StreamCandidate(
                      origin: s,
                      rawUrl: pstr,
                      fieldName: 'qualities.$qualKey.playlist',
                      type: typeField,
                      quality: qualKey));
                  _logger.d('Candidate added from qualities.$qualKey.playlist (text/url)');
                }
              } else if (qualVal is List) {
                for (var it in qualVal) {
                  if (it is String) {
                    candidates.add(_StreamCandidate(
                        origin: s,
                        rawUrl: it,
                        fieldName: 'qualities.$qualKey',
                        type: typeField,
                        quality: qualKey));
                  } else if (it is Map && it['url'] != null) {
                    candidates.add(_StreamCandidate(
                        origin: s,
                        rawUrl: it['url'].toString(),
                        fieldName: 'qualities.$qualKey',
                        type: typeField,
                        quality: qualKey));
                  }
                }
              } else {
                final asStr = qualVal.toString();
                if (asStr.contains('.m3u8') || asStr.contains('http')) {
                  candidates.add(_StreamCandidate(
                      origin: s,
                      rawUrl: asStr,
                      fieldName: 'qualities.$qualKey',
                      type: typeField,
                      quality: qualKey));
                }
              }
            });
          }
        } catch (e, st) {
          _logger.w('Failed to inspect qualities: $e\n$st');
        }

        // attempt to gather caption urls as subtitle candidates
        try {
          final caps = s['captions'];
          if (caps is List && caps.isNotEmpty) {
            for (var c in caps) {
              if (c is String) {
                candidates.add(_StreamCandidate(origin: s, rawUrl: c, fieldName: 'captions', type: typeField));
              } else if (c is Map) {
                final m = Map<String, dynamic>.from(c);
                final u = (m['url'] ?? m['src'] ?? m['source'])?.toString();
                if (u != null && u.isNotEmpty) {
                  candidates.add(_StreamCandidate(origin: s, rawUrl: u, fieldName: 'captions', type: typeField));
                }
              }
            }
          }
        } catch (e, st) {
          _logger.w('Failed to inspect captions: $e\n$st');
        }

        // inspect JSON blob for embedded m3u8s or playlist text (and also video urls)
        try {
          final streamJson = jsonEncode(s);
          final extracted = _extractPossibleM3u8s(streamJson);
          for (final e in extracted) {
            if (e.url != null) {
              candidates.add(_StreamCandidate(
                  origin: s, rawUrl: e.url!, fieldName: 'embedded', type: typeField));
            } else if (e.text != null) {
              candidates.add(_StreamCandidate(
                  origin: s, rawUrl: e.text!, fieldName: 'embedded', type: typeField));
            }
          }

          // also look for direct video links (mp4/webm/etc)
          final extractedVideos = _extractHttpVideoUrls(streamJson);
          for (final v in extractedVideos) {
            candidates.add(_StreamCandidate(origin: s, rawUrl: v, fieldName: 'embeddedVideo', type: typeField));
          }
        } catch (e, st) {
          _logger.w('Failed to inspect embedded blobs: $e\n$st');
        }
      }

      _logger.i('Total candidate entries discovered: ${candidates.length}');

      if (candidates.isEmpty) {
        final snippet = respBodyRaw.length > 1000 ? respBodyRaw.substring(0, 1000) + '...' : respBodyRaw;
        throw StreamingNotAvailableException('No candidate urls found in streams. Response snippet: $snippet');
      }

      String? chosenUrl;
      String? chosenPlaylistText;
      String streamType = 'm3u8';
      String subtitleUrl = '';
      String? chosenQuality;

      final tried = <String>{};
      // iterate candidates in original order but we bias decoding to return base64-derived results first
      for (final c in candidates) {
        if (tried.contains(c.rawUrl)) continue;
        tried.add(c.rawUrl);

        _logger.d('Trying candidate (${c.fieldName}${c.quality != null ? '/${c.quality}' : ''}): ${_short(c.rawUrl)}');

        List<_DecodedCandidate> extracted = [];
        try {
          extracted = await _tryExtractAndDecode(c.rawUrl);
        } catch (e, st) {
          _logger.w('Decoding attempt failed for candidate: $e\n$st');
          continue;
        }

        if (extracted.isNotEmpty) {
          // prefer a remote m3u8 candidate or raw playlist text
          // but prefer first any candidate that originated from base64 decoding
          _DecodedCandidate? pick;
          // if any of the extracted items came from decoded base64/hex/gzip layers we'll see playlist text or url
          // we consider the order returned by _tryExtractAndDecode; we also compensate below by probing
          // pick first remote m3u8 else first available
          pick = extracted.firstWhere((x) => x.isRemoteM3u8, orElse: () => extracted.first);

          if (pick.isPlaylistText) {
            final tmp = await _writePlaylistToTempFile(tmdbId, pick.text!);
            chosenUrl = tmp;
            chosenPlaylistText = pick.text;
            streamType = 'm3u8';
            chosenQuality = c.quality;
            _logger.i('Selected candidate: playlist text -> saved to $tmp');
            break;
          } else if (pick.url != null && pick.url!.isNotEmpty) {
            // Before accepting remote http(s) URLs, probe to ensure it looks like real media
            final candidateUrl = pick.url!;
            if (candidateUrl.startsWith('http://') || candidateUrl.startsWith('https://')) {
              final probeOk = await _probePlayableUrl(candidateUrl, headers: {
                // sensible default headers; adjust if your service requires specific referer/cookies
                'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64)',
              });
              if (!probeOk) {
                _logger.w('Probe rejected candidate url (skipping): ${_short(candidateUrl)}');
                continue; // try next candidate
              }
            }
            chosenUrl = candidateUrl;
            streamType = chosenUrl.endsWith('.mp4') ? 'mp4' : 'm3u8';
            chosenQuality = c.quality;
            _logger.i('Selected candidate url: $chosenUrl (type: $streamType)');
            break;
          }
        }
      }

      // fallback scan entire response for inline m3u8s or video urls
      if (chosenUrl == null) {
        _logger.d('No candidate produced a usable url; scanning entire backend payload for m3u8s and video urls...');
        final allText = jsonEncode(decoded);
        final rawFound = _extractPossibleM3u8s(allText);
        if (rawFound.isNotEmpty) {
          final pick = rawFound.first;
          if (pick.isPlaylistText) {
            final tmp = await _writePlaylistToTempFile(tmdbId, pick.text!);
            chosenUrl = tmp;
            chosenPlaylistText = pick.text;
            streamType = 'm3u8';
            _logger.i('Fallback: found embedded playlist text -> saved to $tmp');
          } else {
            // probe fallback url too
            final fallbackUrl = pick.url!;
            if (fallbackUrl.startsWith('http://') || fallbackUrl.startsWith('https://')) {
              final probeOk = await _probePlayableUrl(fallbackUrl, headers: {
                'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64)',
              });
              if (probeOk) {
                chosenUrl = fallbackUrl;
                streamType = chosenUrl.endsWith('.mp4') ? 'mp4' : 'm3u8';
                _logger.i('Fallback: found embedded url -> $chosenUrl');
              } else {
                _logger.w('Fallback probe rejected $fallbackUrl');
              }
            } else {
              chosenUrl = fallbackUrl;
              streamType = chosenUrl.endsWith('.mp4') ? 'mp4' : 'm3u8';
              _logger.i('Fallback: found embedded url -> $chosenUrl (non-http)');
            }
          }
        } else {
          // also try generic video links
          final foundVideos = _extractHttpVideoUrls(allText);
          for (var v in foundVideos) {
            final probeOk = await _probePlayableUrl(v, headers: {
              'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64)',
            });
            if (probeOk) {
              chosenUrl = v;
              streamType = chosenUrl.endsWith('.mp4') ? 'mp4' : 'm3u8';
              _logger.i('Fallback: found embedded video url -> $chosenUrl');
              break;
            } else {
              _logger.w('Fallback probe rejected video url: ${_short(v)}');
            }
          }
        }
      }

      // If chosenUrl is remote m3u8 and forDownload requested, attempt to download playlist to temp file
      if (chosenUrl != null &&
          chosenUrl.isNotEmpty &&
          chosenUrl.endsWith('.m3u8') &&
          forDownload &&
          !kIsWeb) {
        try {
          _logger.d('forDownload=true, fetching remote playlist to store locally...');
          final playlistResponse = await http.get(Uri.parse(chosenUrl));
          if (playlistResponse.statusCode == 200) {
            final file = File('${(await getTemporaryDirectory()).path}/$tmdbId-playlist.m3u8');
            await file.writeAsString(playlistResponse.body);
            chosenPlaylistText = playlistResponse.body;
            chosenUrl = file.path;
            _logger.i('Saved remote playlist to ${file.path} for download mode.');
          } else {
            _logger.w('Failed to fetch remote playlist for download mode: ${playlistResponse.statusCode}');
          }
        } catch (e, st) {
          _logger.w('Failed to fetch remote playlist for download mode: $e\n$st');
        }
      }

      // Subtitles handling (try to decode if needed)
      for (final s in streams) {
        try {
          final captionsList = s['captions'] as List<dynamic>?;
          if (enableSubtitles && captionsList != null && captionsList.isNotEmpty) {
            // attempt to find english or first available caption with url
            dynamic selectedCap;
            for (var c in captionsList) {
              if (c is Map && (c['language'] == 'en' || c['lang'] == 'en')) {
                selectedCap = c;
                break;
              }
            }
            selectedCap ??= captionsList.first;
            String srtUrlRaw = '';
            if (selectedCap is String) {
              srtUrlRaw = selectedCap;
            } else if (selectedCap is Map) {
              srtUrlRaw = (selectedCap['url'] ?? selectedCap['src'] ?? selectedCap['source'] ?? '').toString();
            }

            if (srtUrlRaw.isNotEmpty) {
              _logger.d('Attempting to decode subtitle candidate: ${_short(srtUrlRaw)}');
              try {
                final decodedSubs = await _tryExtractAndDecodeSingle(srtUrlRaw);
                if (decodedSubs.isPlaylistText) {
                  final vfile = File('${(await getTemporaryDirectory()).path}/$tmdbId-subtitles.vtt');
                  await vfile.writeAsString(decodedSubs.text ?? '');
                  subtitleUrl = vfile.path;
                  _logger.i('Decoded inline subtitle text -> saved to ${vfile.path}');
                } else if (decodedSubs.url != null && decodedSubs.url!.isNotEmpty) {
                  try {
                    final sresp = await http.get(Uri.parse(decodedSubs.url!));
                    if (sresp.statusCode == 200) {
                      final bodyBytes = sresp.bodyBytes;
                      final extCandidate = p.extension(decodedSubs.url!);
                      String vttContent = '';
                      if (extCandidate.toLowerCase().contains('srt') ||
                          utf8.decode(bodyBytes, allowMalformed: true).contains('-->')) {
                        final srtContent = utf8.decode(bodyBytes);
                        vttContent = _convertSrtToVtt(srtContent);
                      } else {
                        vttContent = utf8.decode(bodyBytes);
                      }
                      final vfile = File('${(await getTemporaryDirectory()).path}/$tmdbId-subtitles.vtt');
                      await vfile.writeAsString(vttContent);
                      subtitleUrl = vfile.path;
                      _logger.i('Fetched & converted subtitle to VTT -> ${vfile.path}');
                    } else {
                      _logger.w('Failed to download subtitle: ${sresp.statusCode}');
                    }
                  } catch (e, st) {
                    _logger.w('Failed to fetch/convert subtitle: $e\n$st');
                  }
                }
              } catch (e, st) {
                _logger.w('Subtitle decode attempt failed: $e\n$st');
              }
            } else {
              _logger.d('Subtitle object did not contain url or src.');
            }
          }
        } catch (e, st) {
          _logger.w('Failed to inspect subtitles: $e\n$st');
        }
      }

      if (chosenUrl == null || chosenUrl.isEmpty) {
        final bodySnippet = respBodyRaw.length > 1000
            ? '${respBodyRaw.substring(0, 1000)}...'
            : respBodyRaw;
        _logger.w('No usable streamUrl found. snippet: $bodySnippet');
        throw StreamingNotAvailableException('No stream URL available. Response snippet: $bodySnippet');
      }

      final result = <String, String>{
        'url': chosenUrl,
        'type': streamType,
        'title': title,
      };
      if (chosenPlaylistText != null) result['playlist'] = chosenPlaylistText;
      if (subtitleUrl.isNotEmpty) result['subtitleUrl'] = subtitleUrl;
      if (chosenQuality != null) result['quality'] = chosenQuality;

      _logger.i('Streaming link resolved: ${result['url']} (type=${result['type']}) '
          '${result.containsKey('quality') ? 'quality=${result['quality']}' : ''}');

      return result;
    } catch (e, st) {
      _logger.e('Error fetching stream: $e\n$st');
      rethrow;
    }
  }

  // ------------------------------------------------------------
  // Probe helper: lightweight checks that remote url is likely playable
  // ------------------------------------------------------------
  /// Probe a remote URL to check whether it actually looks like a playable media stream.
  /// Returns true if it looks playable (mp4, m3u8, webm, mkv), false otherwise.
  /// Accepts optional headers (for referer/user-agent, etc).
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
      if (ct.isNotEmpty && !(ct.contains('video') || ct.contains('mpegurl') || ct.contains('application/vnd.apple.mpegurl') || ct.contains('application/octet-stream') || ct.contains('audio') || ct.contains('application'))) {
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
  // Decoding / Extraction helpers
  // ------------------------------------------------------------

  // Write playlist text to a temporary file and return path
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

  // Try many decoding strategies on a single raw string and return one decoded candidate.
static Future<_DecodedCandidate> _tryExtractAndDecodeSingle(String raw) async {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return _DecodedCandidate(url: null, text: null);

  // --- NEW: Handle data: URIs (e.g. data:application/vnd.apple.mpegurl;base64,...) ---
  try {
    final dataMatch = RegExp(r'^data:([^,;]+)(;base64)?,(.*)$', dotAll: true).firstMatch(trimmed);
    if (dataMatch != null) {
      final isBase64 = dataMatch.group(2) != null;
      final payload = dataMatch.group(3) ?? '';
      if (isBase64) {
        try {
          final bytes = base64Decode(payload);
          final decoded = utf8.decode(bytes, allowMalformed: true);
          if (_looksLikePlaylist(decoded)) return _DecodedCandidate(url: null, text: decoded);
          final vids = _extractHttpVideoUrls(decoded);
          if (vids.isNotEmpty) return _DecodedCandidate(url: vids.first, text: null);
        } catch (_) {
          // fall through
        }
      } else {
        // non-base64 data URIs (percent-encoded text)
        final decoded = Uri.decodeFull(payload);
        if (_looksLikePlaylist(decoded)) return _DecodedCandidate(url: null, text: decoded);
        final vids = _extractHttpVideoUrls(decoded);
        if (vids.isNotEmpty) return _DecodedCandidate(url: vids.first, text: null);
      }
    }
  } catch (_) {
    // defensive: if regex/decoding fails, continue with normal path
  }

  // Prioritize base64: attempt to decode the whole string as base64 first
  try {
    final bytes = base64Decode(trimmed);
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    if (text.isNotEmpty) {
      final foundVideo = _extractHttpVideoUrls(text);
      if (foundVideo.isNotEmpty) return _DecodedCandidate(url: foundVideo.first, text: null);

      final foundM3u8 = _extractHttpM3u8Urls(text);
      if (foundM3u8.isNotEmpty) return _DecodedCandidate(url: foundM3u8.first, text: null);

      if (_looksLikePlaylist(text)) return _DecodedCandidate(url: null, text: text);
    }
  } catch (_) {
    // not pure-base64, continue
  }

  // First: if raw contains a direct http(s) video or m3u8 link, return it immediately.
  final directVideo = _extractHttpVideoUrls(trimmed);
  if (directVideo.isNotEmpty) return _DecodedCandidate(url: directVideo.first, text: null);

  // raw playlist markers
  if (_looksLikePlaylist(trimmed)) return _DecodedCandidate(url: null, text: trimmed);

  // try decoding layers safely
  List<String?> decoded;
  try {
    decoded = _tryDecodeLayers(trimmed, depth: 4);
  } catch (e, st) {
    _logger.w('Decoding layers threw: $e\n$st');
    decoded = [trimmed];
  }

  for (final d in decoded) {
    if (d == null) continue;
    final t = d.trim();
    if (t.isEmpty) continue;

    final foundVideo = _extractHttpVideoUrls(t);
    if (foundVideo.isNotEmpty) return _DecodedCandidate(url: foundVideo.first, text: null);

    final found = _extractHttpM3u8Urls(t);
    if (found.isNotEmpty) return _DecodedCandidate(url: found.first, text: null);
    if (_looksLikePlaylist(t)) return _DecodedCandidate(url: null, text: t);
  }

  // local file path fallback
  if (trimmed.endsWith('.m3u8') && (trimmed.startsWith('/') || trimmed.startsWith('file://'))) {
    return _DecodedCandidate(url: trimmed, text: null);
  }

  return _DecodedCandidate(url: null, text: null);
}


  // Try to decode raw into multiple candidates (http/url/playlist)
  static Future<List<_DecodedCandidate>> _tryExtractAndDecode(String raw) async {
    final out = <_DecodedCandidate>[];

    final direct = await _tryExtractAndDecodeSingle(raw);
    if (direct.url != null || direct.text != null) {
      out.add(direct);
      return out;
    }

    final extracted = _extractPossibleM3u8s(raw);
    if (extracted.isNotEmpty) out.addAll(extracted);

    final layers = _tryDecodeLayers(raw, depth: 4);
    for (final layer in layers) {
      if (layer == null) continue;
      if (layer == raw) continue;
      final d = await _tryExtractAndDecodeSingle(layer);
      if (d.url != null || d.text != null) {
        out.add(d);
      } else {
        final ext = _extractPossibleM3u8s(layer);
        if (ext.isNotEmpty) out.addAll(ext);
      }
    }

    return out;
  }

  // multiple-decode BFS
  // Modified to prioritize base64-derived layers early in the queue.
  static List<String?> _tryDecodeLayers(String input, {int depth = 3}) {
    final results = <String?>[input];
    final seen = <String>{input};

    // decoders: note that base64/gzip-base64 are not pure string->string decoders here
    // We'll still include safe decoders in the main list, and handle base64/gzip/hex as special high-priority transforms.
    final decoders = <String Function(String)>[
      (s) => s, // identity
      (s) => _safeDecodeComponent(s),
      (s) => s.replaceAll('[dot]', '.').replaceAll('[slash]', '/').replaceAll('(dot)', '.'),
      (s) => String.fromCharCodes(s.runes.toList().reversed), // reverse
      (s) => _rot13(s),
    ];

    String? tryBase64(String s) {
      try {
        final bytes = base64Decode(s);
        final text = utf8.decode(bytes, allowMalformed: true);
        if (text.isNotEmpty) return text;
      } catch (_) {}
      return null;
    }

    String? tryHex(String s) {
      try {
        final clean = s.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
        if (clean.length % 2 != 0) return null;
        final bytes = Uint8List(clean.length ~/ 2);
        for (var i = 0; i < clean.length; i += 2) {
          bytes[i ~/ 2] = int.parse(clean.substring(i, i + 2), radix: 16);
        }
        final text = utf8.decode(bytes, allowMalformed: true);
        if (text.isNotEmpty) return text;
      } catch (_) {}
      return null;
    }

    String? tryGzipBase64(String s) {
      try {
        final bytes = base64Decode(s);
        final dec = gzip.decode(bytes);
        final text = utf8.decode(dec, allowMalformed: true);
        if (text.isNotEmpty) return text;
      } catch (_) {}
      return null;
    }

    var queue = <String>[input];
    var currentDepth = 0;
    while (queue.isNotEmpty && currentDepth < depth) {
      final nextQueue = <String>[];
      for (final item in queue) {
        // normal decoders
        for (final dec in decoders) {
          String outStr;
          try {
            outStr = dec(item);
          } catch (_) {
            // guard against any decoder throwing
            continue;
          }
          if (outStr.isNotEmpty && !seen.contains(outStr)) {
            results.add(outStr);
            seen.add(outStr);
            nextQueue.add(outStr);
          }
        }

        // base64 (high-priority): if it decodes, push to front of nextQueue
        final b64 = tryBase64(item);
        if (b64 != null && b64.isNotEmpty && !seen.contains(b64)) {
          results.add(b64);
          seen.add(b64);
          nextQueue.insert(0, b64); // high priority
        }

        // gzip-base64 next
        final gz = tryGzipBase64(item);
        if (gz != null && gz.isNotEmpty && !seen.contains(gz)) {
          results.add(gz);
          seen.add(gz);
          nextQueue.insert(0, gz); // high priority
        }

        // hex decode
        final hx = tryHex(item);
        if (hx != null && hx.isNotEmpty && !seen.contains(hx)) {
          results.add(hx);
          seen.add(hx);
          nextQueue.add(hx);
        }

        // unquote fallback
        if ((item.startsWith('"') && item.endsWith('"')) ||
            (item.startsWith("'") && item.endsWith("'"))) {
          final unq = item.substring(1, item.length - 1);
          if (!seen.contains(unq)) {
            results.add(unq);
            seen.add(unq);
            nextQueue.add(unq);
          }
        }
      }
      queue = nextQueue;
      currentDepth++;
    }

    return results;
  }

  // extract http(s) m3u8 urls or playlists
static List<_DecodedCandidate> _extractPossibleM3u8s(String input) {
  final found = <_DecodedCandidate>[];
  if (input.isEmpty) return found;

  // 1) data: URI with base64 payload (common in some backends)
  try {
    final dataUriRegex = RegExp(r'data:([^,;]+)(;base64)?,([A-Za-z0-9+/=\s-]+)', dotAll: true);
    for (final m in dataUriRegex.allMatches(input)) {
      final isBase64 = m.group(2) != null;
      final payload = (m.group(3) ?? '').replaceAll(RegExp(r'\s+'), '');
      if (isBase64 && payload.isNotEmpty) {
        try {
          final bytes = base64Decode(payload);
          final text = utf8.decode(bytes, allowMalformed: true);
          if (_looksLikePlaylist(text)) {
            found.add(_DecodedCandidate(url: null, text: text));
          } else {
            // may contain m3u8/video links
            for (final u in _extractHttpM3u8Urls(text)) found.add(_DecodedCandidate(url: u, text: null));
            for (final v in _extractHttpVideoUrls(text)) found.add(_DecodedCandidate(url: v, text: null));
          }
        } catch (_) {
          // ignore invalid base64 chunk
        }
      }
    }
  } catch (_) {}

  // direct http(s) m3u8 links
  final urlRegex = RegExp(
    r'(https?:\/\/[^\s"<>]+?\.m3u8[^\s"<>]*)',
    caseSensitive: false,
  );

  for (final m in urlRegex.allMatches(input)) {
    final s = m.group(0);
    if (s != null && s.isNotEmpty) {
      found.add(_DecodedCandidate(url: s, text: null));
    }
  }

  // file:// or absolute local paths (capture group 1 keeps the path)
  final fileRegex = RegExp(
    r'((?:file:\/\/)?\/[^\s"<>]*?\.m3u8)',
    caseSensitive: false,
  );

  for (final m in fileRegex.allMatches(input)) {
    final s = m.group(1) ?? m.group(0);
    if (s != null && s.isNotEmpty) {
      found.add(_DecodedCandidate(url: s, text: null));
    }
  }

  // raw playlist text (#EXTM3U etc.)
  if (_looksLikePlaylist(input)) {
    found.add(_DecodedCandidate(url: null, text: input));
  }

  // base64-ish chunks (long ones) that ARE NOT embedded in data: URIs (fallback)
  final b64Regex = RegExp(r'([A-Za-z0-9+/=]{60,})');
  for (final m in b64Regex.allMatches(input)) {
    final chunk = m.group(0);
    if (chunk == null) continue;
    try {
      final dec = base64Decode(chunk);
      final text = utf8.decode(dec, allowMalformed: true);
      if (_looksLikePlaylist(text)) {
        found.add(_DecodedCandidate(url: null, text: text));
      } else if (text.contains('.m3u8')) {
        for (final u in _extractHttpM3u8Urls(text)) {
          found.add(_DecodedCandidate(url: u, text: null));
        }
      } else {
        final vids = _extractHttpVideoUrls(text);
        for (final v in vids) found.add(_DecodedCandidate(url: v, text: null));
      }
    } catch (_) {
      // ignore invalid base64
    }
  }

  // hex-ish chunks that decode to playlist/text
  final hexRegex = RegExp(r'([0-9A-Fa-f]{80,})');
  for (final m in hexRegex.allMatches(input)) {
    final chunk = m.group(0);
    if (chunk == null) continue;
    try {
      final bytes = Uint8List(chunk.length ~/ 2);
      for (var i = 0; i < chunk.length; i += 2) {
        bytes[i ~/ 2] = int.parse(chunk.substring(i, i + 2), radix: 16);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      if (_looksLikePlaylist(text)) {
        found.add(_DecodedCandidate(url: null, text: text));
      } else if (text.contains('.m3u8')) {
        for (final u in _extractHttpM3u8Urls(text)) {
          found.add(_DecodedCandidate(url: u, text: null));
        }
      } else {
        final vids = _extractHttpVideoUrls(text);
        for (final v in vids) found.add(_DecodedCandidate(url: v, text: null));
      }
    } catch (_) {
      // ignore invalid hex
    }
  }

  // try simple obfuscation replacements and recurse once
  final replaced = input.replaceAll('[dot]', '.').replaceAll('(dot)', '.').replaceAll('[slash]', '/');
  if (replaced != input) {
    // avoid infinite recursion by not repeating replacement forever
    found.addAll(_extractPossibleM3u8s(replaced));
  }

  return found;
}


  // extract general http(s) video urls (mp4/webm/mkv/m3u8)
  static List<String> _extractHttpVideoUrls(String input) {
    final urls = <String>[];
    if (input.isEmpty) return urls;

    final regex = RegExp(
      r'(https?:\/\/[^\s"<>]+?\.(?:m3u8|mp4|webm|mkv)[^\s"<>]*)',
      caseSensitive: false,
    );

    for (final m in regex.allMatches(input)) {
      final s = m.group(0);
      if (s != null && s.isNotEmpty) urls.add(s);
    }
    return urls;
  }

  static List<String> _extractHttpM3u8Urls(String input) {
    final urls = <String>[];
    if (input.isEmpty) return urls;

    final regex = RegExp(
      r'(https?:\/\/[^\s"<>]+?\.m3u8[^\s"<>]*)',
      caseSensitive: false,
    );

    for (final m in regex.allMatches(input)) {
      final s = m.group(0);
      if (s != null && s.isNotEmpty) urls.add(s);
    }
    return urls;
  }

  static bool _looksLikePlaylist(String s) {
    final upper = s.toUpperCase();
    return upper.contains('#EXTM3U') ||
        upper.contains('#EXT-X-STREAM-INF') ||
        upper.contains('#EXTINF');
  }

  // Safe decode wrapper that returns original string if decodeComponent fails
  static String _safeDecodeComponent(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  static String _rot13(String s) {
    return s.replaceAllMapped(RegExp(r'[A-Za-z]'), (Match m) {
      final ch = m.group(0)!;
      final code = ch.codeUnitAt(0);
      final base = (code >= 97) ? 97 : 65;
      return String.fromCharCode(((code - base + 13) % 26) + base);
    });
  }

  // ------------------------------------------------------------
  // Subtitle conversion helper
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
// Offline downloader below
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
    if (url.endsWith('.m3u8')) {
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
  // Helpers
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
