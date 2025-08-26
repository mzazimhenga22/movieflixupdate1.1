// lib/services/fcm_sender.dart
//
// Lightweight helper to send FCM push requests through your server-side endpoint
// (e.g. https://moviflxpro.onrender.com/sendPush).
//
// - Coerces extraData values to strings (primitives -> .toString(), objects -> jsonEncode or toString())
// - Sends X-Api-Key header if provided (or configured via FcmSender.configure)
// - Adaptive retry with exponential backoff: tries with 10s → 30s → 65s
// - Returns true on success (HTTP 200 and backend ok:true), false otherwise
//
// Usage example:
//   FcmSender.configure(
//     baseUrl: 'https://moviflxpro.onrender.com/sendPush',
//     apiKey: YOUR_PUSH_API_KEY,
//   );
//
//   unawaited(sendFcmPush(
//     fcmToken: token,
//     title: 'Hi',
//     body: 'You have a message',
//     extraData: {'chatId': chatId, 'messageId': messageId},
//   ));

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class FcmSender {
  /// Default backend endpoint (can be overridden by configure or per-call)
  static String baseUrl = 'https://moviflxpro.onrender.com/sendPush';

  /// Optional API key for your backend (sent as X-Api-Key)
  static String? apiKey;

  /// Configure defaults for the sender (call once at startup if you want).
  static void configure({required String baseUrl, String? apiKey}) {
    FcmSender.baseUrl = baseUrl;
    FcmSender.apiKey = apiKey;
  }

  /// Coerce a dynamic map into Map<String, String> safely.
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
}

/// Send a push via your server's /sendPush endpoint with adaptive retry.
Future<bool> sendFcmPush({
  String? fcmToken,
  String? topic,
  required String projectId,
  required String title,
  required String body,
  Map<String, dynamic>? extraData,
  bool notification = true,
  String? androidChannelId,
  bool dryRun = false,
  String? apiKey,
  String? baseUrl,
}) async {
  final uri = Uri.parse(baseUrl ?? FcmSender.baseUrl);
  final key = apiKey ?? FcmSender.apiKey;

  if ((fcmToken == null || fcmToken.isEmpty) &&
      (topic == null || topic.isEmpty)) {
    if (kDebugMode) {
      debugPrint('[sendFcmPush] error: either fcmToken or topic must be provided');
    }
    return false;
  }

  final data = FcmSender._coerceExtraData(extraData);

  if (androidChannelId != null && androidChannelId.isNotEmpty) {
    data['androidChannelId'] = androidChannelId;
  }

  final payload = <String, dynamic>{
    if (fcmToken != null && fcmToken.isNotEmpty) 'fcmToken': fcmToken,
    if (topic != null && topic.isNotEmpty) 'topic': topic,
    'title': title,
    'body': body,
    'extraData': data,
    'notification': notification,
    'dryRun': dryRun,
  };

  final headers = <String, String>{
    'Content-Type': 'application/json',
    if (key != null && key.isNotEmpty) 'X-Api-Key': key,
  };

  // Retry sequence
  final timeouts = <Duration>[
    const Duration(seconds: 10),
    const Duration(seconds: 30),
    const Duration(seconds: 65),
  ];

  for (int attempt = 0; attempt < timeouts.length; attempt++) {
    final timeout = timeouts[attempt];
    try {
      if (kDebugMode) {
        debugPrint('[sendFcmPush] Attempt ${attempt + 1}/${timeouts.length} '
            'with timeout=${timeout.inSeconds}s POST $uri');
      }

      final resp = await http
          .post(uri, headers: headers, body: jsonEncode(payload))
          .timeout(timeout);

      if (kDebugMode) {
        debugPrint('[sendFcmPush] response: ${resp.statusCode} ${resp.body}');
      }

      if (resp.statusCode != 200) {
        continue; // retry on non-200
      }

      try {
        final Map<String, dynamic> parsed =
            jsonDecode(resp.body) as Map<String, dynamic>;
        final ok = parsed['ok'];
        if (ok is bool) return ok;
        return true;
      } catch (_) {
        return true; // 200 but not JSON
      }
    } on TimeoutException {
      if (kDebugMode) {
        debugPrint('[sendFcmPush] attempt ${attempt + 1} timed out after $timeout');
      }
      // retry
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[sendFcmPush] error on attempt ${attempt + 1}: $e\n$st');
      }
      // retry
    }
  }

  return false;
}
