// lib/services/fcm_sender.dart
//
// Backend-only FCM sender (posts to your backend endpoint).
// Safe for apps: no service account JSON shipped in the app.
//
// Behavior:
//  - Posts JSON to FcmSender.baseUrl (default: your Render /sendPush endpoint).
//  - Includes X-Api-Key header when FcmSender.apiKey is configured or apiKey passed.
//  - Adaptive retry with exponential backoff + jitter to handle sleeping/free backends.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class FcmSender {
  /// Your backend endpoint (change to your Render URL if different).
  static String baseUrl = 'https://movieflixprov2.onrender.com/sendPush';

  /// Optional API key the backend expects (sent as X-Api-Key).
  /// It can be provided by:
  ///  - compile-time via --dart-define=PUSH_API_KEY=xxxx (picked up automatically below)
  ///  - calling FcmSender.configure(apiKey: '...') at runtime
  static String? apiKey = _loadApiKeyFromEnv();

  static String? _loadApiKeyFromEnv() {
    // This reads a compile-time define: flutter run --dart-define=PUSH_API_KEY=@Key
    const env = String.fromEnvironment('PUSH_API_KEY', defaultValue: '');
    return env.trim().isEmpty ? null : env.trim();
  }

  /// Optional configure at startup: FcmSender.configure(baseUrl: 'https://...', apiKey: '...')
  static void configure({String? baseUrl, String? apiKey}) {
    if (baseUrl != null && baseUrl.isNotEmpty) FcmSender.baseUrl = baseUrl;
    if (apiKey != null && apiKey.isNotEmpty) {
      FcmSender.apiKey = apiKey.trim();
    }
    if (kDebugMode) {
      final info = (FcmSender.apiKey != null && FcmSender.apiKey!.isNotEmpty)
          ? 'configured apiKey=${_maskKey(FcmSender.apiKey!)}'
          : 'no apiKey configured';
      debugPrint('[FcmSender][configure] baseUrl=${FcmSender.baseUrl} $info');
    }
  }

  /// Utility: mask a key for safe debug logging (do NOT log full secret).
  static String _maskKey(String k) {
    if (k.isEmpty) return '';
    if (k.length <= 6) return '***';
    return '${k.substring(0, 3)}...${k.substring(k.length - 3)}';
  }

  /// Coerce a dynamic map into Map<String, String> safely (backend expects string values)
  static Map<String, String> _coerceExtraData(Map<String, dynamic>? raw) {
    final Map<String, String> out = <String, String>{};
    if (raw == null) return out;
    raw.forEach((k, v) {
      try {
        if (v == null) {
          out[k] = '';
        } else if (v is String || v is num || v is bool) {
          out[k] = v.toString();
        } else {
          // For objects/collections try JSON encode first, fallback to toString()
          try {
            out[k] = jsonEncode(v);
          } catch (_) {
            out[k] = v.toString();
          }
        }
      } catch (_) {
        out[k] = '';
      }
    });
    return out;
  }

  /// Post payload to backend /sendPush endpoint.
  static Future<bool> _postToBackend({
    required Uri uri,
    required Map<String, dynamic> payload,
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    final resp = await http
        .post(uri, headers: headers, body: jsonEncode(payload))
        .timeout(timeout);

    if (kDebugMode) {
      debugPrint('[FcmSender][_postToBackend] ${resp.statusCode} ${resp.body}');
    }

    if (resp.statusCode != 200) return false;

    try {
      final parsed = jsonDecode(resp.body);
      if (parsed is Map && (parsed['ok'] == true || parsed['success'] == true)) return true;
      // treat 200 with no "ok" as success (be forgiving)
      return true;
    } catch (_) {
      // Not JSON but 200 => treat as success
      return true;
    }
  }
}

/// Top-level function — use everywhere in app as before.
/// Added optional `projectId` param so existing call-sites that pass it compile.
Future<bool> sendFcmPush({
  String? fcmToken,
  String? topic,
  String? projectId, // optional, preserved for compatibility (sent to backend)
  required String title,
  required String body,
  Map<String, dynamic>? extraData,
  bool notification = true,
  String? androidChannelId,
  bool dryRun = false,
  String? apiKey, // optional header for backend; falls back to FcmSender.apiKey
  String? baseUrl, // optional override
  Duration timeout = const Duration(seconds: 65), // longer by default (Render may wake)
  int maxRetries = 4, // number of retries (0 = single attempt)
}) async {
  // Validate
  if ((fcmToken == null || fcmToken.isEmpty) && (topic == null || topic.isEmpty)) {
    if (kDebugMode) {
      debugPrint('[sendFcmPush] error: either fcmToken or topic must be provided');
    }
    return false;
  }

  final data = FcmSender._coerceExtraData(extraData);

  if (androidChannelId != null && androidChannelId.isNotEmpty) {
    data['androidChannelId'] = androidChannelId;
  }

  final uri = Uri.parse(baseUrl ?? FcmSender.baseUrl);
  final keyRaw = apiKey ?? FcmSender.apiKey;
  final key = keyRaw?.trim();

  final headers = <String, String>{
    'Content-Type': 'application/json',
    if (key != null && key.isNotEmpty) 'X-Api-Key': key,
  };

  // Build payload once (projectId included for compatibility)
  final Map<String, dynamic> payload = {
    if (fcmToken != null && fcmToken.isNotEmpty) 'fcmToken': fcmToken,
    if (topic != null && topic.isNotEmpty) 'topic': topic,
    if (projectId != null && projectId.isNotEmpty) 'projectId': projectId,
    'title': title,
    'body': body,
    'extraData': data,
    'notification': notification == true,
    'dryRun': dryRun == true,
  };

  final rnd = Random.secure();

  for (int attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      if (kDebugMode) {
        final maskedKeyInfo = (key != null && key.isNotEmpty) ? 'X-Api-Key=${FcmSender._maskKey(key)}' : 'no-api-key';
        debugPrint('[sendFcmPush] attempt ${attempt + 1}/${maxRetries + 1} -> POST $uri headers=[Content-Type, ${maskedKeyInfo}] payload=${jsonEncode(payload)}');
      }

      final ok = await FcmSender._postToBackend(uri: uri, payload: payload, headers: headers, timeout: timeout);
      if (ok) {
        if (kDebugMode) debugPrint('[sendFcmPush] backend send succeeded (attempt ${attempt + 1})');
        return true;
      } else {
        if (kDebugMode) debugPrint('[sendFcmPush] backend returned non-200/failed (attempt ${attempt + 1})');
      }
    } on TimeoutException catch (e) {
      if (kDebugMode) debugPrint('[sendFcmPush] timeout attempt ${attempt + 1}: $e');
    } catch (e, st) {
      if (kDebugMode) debugPrint('[sendFcmPush] error attempt ${attempt + 1}: $e\n$st');
    }

    // if last attempt, break
    if (attempt == maxRetries) break;

    // Exponential backoff with jitter (cap base wait at 60s)
    final baseMs = (1000 * pow(2, attempt)).toInt(); // 1s,2s,4s,8s...
    final cappedBase = baseMs > 60000 ? 60000 : baseMs;
    final jitter = rnd.nextInt(1000); // up to 1s jitter
    final waitMs = cappedBase + jitter;
    if (kDebugMode) debugPrint('[sendFcmPush] waiting ${waitMs}ms before retry ${attempt + 2}');
    await Future.delayed(Duration(milliseconds: waitMs));
  }

  if (kDebugMode) debugPrint('[sendFcmPush] all attempts failed (total ${maxRetries + 1} attempts)');
  return false;
}
