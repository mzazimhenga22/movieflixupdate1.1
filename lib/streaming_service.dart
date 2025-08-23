import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:universal_html/html.dart' as html;

// Added imports for downloader
import 'package:path/path.dart' as p;
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

class StreamingNotAvailableException implements Exception {
  final String message;
  StreamingNotAvailableException(this.message);

  @override
  String toString() => 'StreamingNotAvailableException: $message';
}

class StreamingService {
  static final _logger = Logger();

  static int _parseResolution(String? res) {
    if (res == null) return 0;
    final match = RegExp(r'(\d+)p').firstMatch(res);
    return match != null ? int.tryParse(match.group(1)!) ?? 0 : 0;
  }

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
    _logger.i('Calling backend for streaming link: $tmdbId');

    final url = Uri.parse('https://moviflxpro.onrender.com/media-links');
    final isShow = season != null && episode != null;

final body = <String, dynamic>{
  'type': isShow ? 'show' : 'movie',
  'tmdbId': tmdbId,
  'title': title,
  'releaseYear': releaseYear, // send a number, not a string
  'resolution': resolution,
  'subtitleLanguage': 'en',
  if (isShow) ...{
    'seasonNumber': season,
    // make sure these are strings of digits if you have IDs, otherwise omit them
    'seasonTmdbId': seasonTmdbId?.toString() ?? tmdbId,
    'episodeNumber': episode,
    'episodeTmdbId': episodeTmdbId?.toString() ?? tmdbId,
  }
};


    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (response.statusCode != 200) {
        _logger.e('Backend error: ${response.statusCode} ${response.body}');
        throw StreamingNotAvailableException(
          'Failed to get streaming link: ${response.statusCode}',
        );
      }

      final decodedRaw = jsonDecode(response.body);
      if (decodedRaw is! Map<String, dynamic>) {
        _logger.e('Invalid response format: $decodedRaw');
        throw StreamingNotAvailableException('Invalid response format.');
      }

      final decoded = Map<String, dynamic>.from(decodedRaw);
      dynamic raw = decoded['streams'] ??
          (decoded.containsKey('stream') ? [decoded['stream']] : null);
      if (raw == null) {
        _logger.e('No streams found: $decoded');
        throw StreamingNotAvailableException('No streaming links available.');
      }

      final streams = List<Map<String, dynamic>>.from(raw);
      if (streams.isEmpty)
        throw StreamingNotAvailableException('No streams available.');

      Map<String, dynamic> selectedStream;

      if (resolution == "auto") {
        List<Map<String, dynamic>> hls = streams.where((s) {
          final type = s['type'] as String?;
          final url = s['url'] as String?;
          return type == 'm3u8' || (url != null && url.endsWith('.m3u8'));
        }).toList();
        selectedStream = hls.isNotEmpty ? hls.first : streams.first;
      } else {
        selectedStream = streams.first;
      }

      String? playlist;
      String streamType = 'm3u8';
      String streamUrl = '';
      String subtitleUrl = '';

      final playlistEncoded = selectedStream['playlist'] as String?;
      if (playlistEncoded != null &&
          playlistEncoded
              .startsWith('data:application/vnd.apple.mpegurl;base64,')) {
        final base64Part = playlistEncoded.split(',')[1];
        playlist = utf8.decode(base64Decode(base64Part));

        if (kIsWeb) {
          final bytes = base64Decode(base64Part);
          final blob = html.Blob([bytes], 'application/vnd.apple.mpegurl');
          streamUrl = html.Url.createObjectUrlFromBlob(blob);
        } else {
          final file = File(
              '${(await getTemporaryDirectory()).path}/$tmdbId-playlist.m3u8');
          await file.writeAsString(playlist);
          streamUrl = file.path;
        }
      } else {
        final urlValue = selectedStream['url']?.toString();
        if (urlValue == null || urlValue.isEmpty) {
          throw StreamingNotAvailableException('No stream URL available.');
        }
        streamUrl = urlValue;

        if (streamUrl.endsWith('.m3u8') && forDownload && !kIsWeb) {
          final playlistResponse = await http.get(Uri.parse(streamUrl));
          if (playlistResponse.statusCode == 200) {
            final file = File(
                '${(await getTemporaryDirectory()).path}/$tmdbId-playlist.m3u8');
            await file.writeAsString(playlistResponse.body);
            streamUrl = file.path;
          }
        }
        streamType = streamUrl.endsWith('.mp4') ? 'mp4' : 'm3u8';
      }

      final captionsList = selectedStream['captions'] as List<dynamic>?;
      if (enableSubtitles && captionsList != null && captionsList.isNotEmpty) {
        final selectedCap = captionsList.firstWhere(
          (c) => c['language'] == 'en',
          orElse: () => captionsList.first,
        );

        final srtUrl = selectedCap['url']?.toString() ?? '';
        if (srtUrl.isNotEmpty && !kIsWeb) {
          try {
            final subtitleResponse = await http.get(Uri.parse(srtUrl));
            if (subtitleResponse.statusCode == 200) {
              final srtContent = utf8.decode(subtitleResponse.bodyBytes);
              final vttContent = _convertSrtToVtt(srtContent);

              final vttFile = File(
                  '${(await getTemporaryDirectory()).path}/$tmdbId-subtitles.vtt');
              await vttFile.writeAsString(vttContent);

              subtitleUrl = vttFile.path;
            }
          } catch (e) {
            _logger.w('Failed to convert/download subtitles: $e');
          }
        }
      }

      final result = <String, String>{
        'url': streamUrl,
        'type': streamType,
        'title': title,
      };
      if (playlist != null) result['playlist'] = playlist;
      if (subtitleUrl.isNotEmpty) result['subtitleUrl'] = subtitleUrl;

      return result;
    } catch (e, st) {
      _logger.e('Error fetching stream: $e', stackTrace: st);
      rethrow;
    }
  }

  /// Converts SRT subtitles to VTT format.
  static String _convertSrtToVtt(String srtContent) {
    final lines = srtContent.split('\n');
    final buffer = StringBuffer()..writeln('WEBVTT\n');

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      if (RegExp(r'^\d+$').hasMatch(line)) {
        // Skip subtitle index line
        continue;
      } else if (line.contains('-->')) {
        buffer.writeln(
          line.replaceAll(',', '.'), // Convert SRT time format to VTT
        );
      } else {
        buffer.writeln(line);
      }
    }

    return buffer.toString().trim();
  }
}

/// =========================
/// Offline downloader below
/// =========================

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
  DownloadProgress({
    required this.downloadedSegments,
    required this.totalSegments,
    required this.bytesDownloaded,
    this.totalBytes,
  });
}

class OfflineDownloader {
  static final _log = Logger();

  /// Accepts the streamInfo map returned by StreamingService.getStreamingLink(...)
  /// and downloads it to app documents under /offline/<id>.
  /// Returns a map describing the stored files:
  /// - for HLS: { 'type':'m3u8', 'playlist': '/abs/path/local.m3u8', 'merged': '/abs/path/merged.ts' (optional) }
  /// - for direct file: { 'type':'mp4', 'file': '/abs/path/file.mp4' }
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
          ));
        },
      );
      return {'type': 'mp4', 'file': filePath};
    }
  }

  // -------------------------
  // MP4 / direct file download (resume using HTTP Range if available)
  // -------------------------
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
      final total = headResp.headers['content-length'] != null
          ? int.tryParse(headResp.headers['content-length']!)
          : null;

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
      final totalBytes = streamed.contentLength != null
          ? (existing + streamed.contentLength!)
          : null;
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

  // -------------------------
  // HLS download implementation (supports AES-128)
  // -------------------------
  static Future<Map<String, String>> _downloadHls({
    required String m3u8Url,
    required String id,
    String? preferredResolution,
    bool mergeSegments = false,
    int concurrency = 4,
    void Function(DownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final baseUri = Uri.parse(m3u8Url);

    final doc = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(doc.path, 'offline', id));
    if (!await outDir.exists()) await outDir.create(recursive: true);

    final client = http.Client();
    try {
      final resp = await client.get(baseUri);
      if (resp.statusCode != 200)
        throw Exception('Playlist download failed: ${resp.statusCode}');
      String playlist = resp.body.replaceAll('\r\n', '\n');

      // Master playlist detection and variant selection
      if (playlist.contains('#EXT-X-STREAM-INF')) {
        final lines = playlist.split('\n');
        String? pickedVariant;
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i].trim();
          if (l.startsWith('#EXT-X-STREAM-INF')) {
            var j = i + 1;
            while (j < lines.length && lines[j].trim().isEmpty) j++;
            if (j < lines.length) {
              final candidate = lines[j].trim();
              if (preferredResolution != null &&
                  l.contains(preferredResolution)) {
                pickedVariant = candidate;
                break;
              }
              pickedVariant ??= candidate;
            }
          }
        }
        if (pickedVariant == null)
          throw Exception('No variant streams found in master playlist.');
        final variantUrl = _resolveUri(baseUri, pickedVariant);
        final vresp = await client.get(Uri.parse(variantUrl));
        if (vresp.statusCode != 200)
          throw Exception(
              'Variant playlist download failed: ${vresp.statusCode}');
        playlist = vresp.body.replaceAll('\r\n', '\n');
      }

      // Parse playlist, detect AES-128 keys and segments
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

      // Pre-fetch unique AES keys if present
      final uniqueKeyUris = <String>{};
      for (var seg in segments) {
        final kl = seg.keyLine;
        if (kl != null) {
          final attrs = _parseAttributes(kl.substring('#EXT-X-KEY:'.length));
          final method = attrs['METHOD'];
          final uriRaw = attrs['URI']?.replaceAll('"', '');
          if (method != null &&
              method.toUpperCase() == 'AES-128' &&
              uriRaw != null) {
            final keyUri = _resolveUri(baseUri, uriRaw);
            uniqueKeyUris.add(keyUri);
          }
        }
      }

      final keyCache = <String, Uint8List>{};
      for (var keyUri in uniqueKeyUris) {
        final kresp = await client.get(Uri.parse(keyUri));
        if (kresp.statusCode != 200)
          throw Exception('Failed to download key: ${kresp.statusCode}');
        keyCache[keyUri] = Uint8List.fromList(kresp.bodyBytes);
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
              bytesDownloaded += await outFile.length();
              onProgress?.call(DownloadProgress(
                downloadedSegments: downloadedSegments,
                totalSegments: totalSegments,
                bytesDownloaded: bytesDownloaded,
              ));
              return;
            }

            final r = await client.get(segUri);
            if (r.statusCode != 200)
              throw Exception(
                  'Failed to download segment ${seg.url}: ${r.statusCode}');
            Uint8List data = Uint8List.fromList(r.bodyBytes);

            // Decrypt if AES-128 key present for this segment
            if (seg.keyLine != null) {
              final attrs = _parseAttributes(
                  seg.keyLine!.substring('#EXT-X-KEY:'.length));
              final method = attrs['METHOD'];
              final uriRaw = attrs['URI']?.replaceAll('"', '');
              final ivRaw = attrs['IV']; // optional
              if (method != null &&
                  method.toUpperCase() == 'AES-128' &&
                  uriRaw != null) {
                final keyUri = _resolveUri(baseUri, uriRaw);
                final key = keyCache[keyUri];
                if (key == null)
                  throw Exception('Key missing for AES-128 segment');
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
            ));
          } finally {
            semaphore.release();
          }
        }();
        futures.add(f);
      }

      await Future.wait(futures);

      // Write local playlist (rewrite segment URIs to local filenames and remove AES key URIs)
      final localPlaylistPath = p.join(outDir.path, '$id-local.m3u8');
      final localPlaylistFile = File(localPlaylistPath);
      final rewritten = <String>[];
      for (var line in lines) {
        if (line.trim().isEmpty) continue;
        if (line.startsWith('#EXT-X-KEY')) {
          // replace with METHOD=NONE because segments are decrypted locally
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

      String? mergedPath;
      if (mergeSegments) {
        final mergedFile = File(p.join(outDir.path, '$id-merged.ts'));
        final raf = mergedFile.openSync(mode: FileMode.write);
        try {
          for (var seg in segments) {
            final segUri = Uri.parse(seg.url);
            final filename = p.basename(segUri.path);
            final segFile = File(p.join(outDir.path, filename));
            if (!await segFile.exists())
              throw Exception('Segment missing: ${segFile.path}');
            final bytes = await segFile.readAsBytes();
            raf.writeFromSync(bytes);
          }
        } finally {
          await raf.close();
        }
        mergedPath = mergedFile.path;
      }

      return {
        'type': 'm3u8',
        'playlist': localPlaylistFile.path,
        if (mergedPath != null) 'merged': mergedPath,
      };
    } finally {
      client.close();
    }
  }

  // -------------------------
  // Helpers
  // -------------------------
  static String _resolveUri(Uri playlistUri, String line) {
    final trimmed = line.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://'))
      return trimmed;
    if (trimmed.startsWith('/'))
      return '${playlistUri.scheme}://${playlistUri.authority}$trimmed';
    return playlistUri.resolve(trimmed).toString();
  }

  static Map<String, String> _parseAttributes(String input) {
    final map = <String, String>{};
    final parts = RegExp(r'([A-Z0-9-]+)=("(?:[^"]*)"|[^,]*)').allMatches(input);
    for (final m in parts) {
      final key = m.group(1)!;
      var value = m.group(2)!;
      if (value.startsWith('"') && value.endsWith('"'))
        value = value.substring(1, value.length - 1);
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

  static Uint8List _aes128CbcDecrypt(
      Uint8List data, Uint8List key, Uint8List iv) {
    final params = ParametersWithIV(KeyParameter(key), iv);
    final cipher = CBCBlockCipher(AESEngine())..init(false, params);

    final out = Uint8List(data.length);
    final blockSize = cipher.blockSize;
    var offset = 0;
    final input = Uint8List(blockSize);
    final output = Uint8List(blockSize);

    while (offset < data.length) {
      final inLen = ((offset + blockSize) <= data.length)
          ? blockSize
          : data.length - offset;
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
