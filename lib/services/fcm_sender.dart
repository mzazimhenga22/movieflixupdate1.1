// services/fcm_sender.dart
// Release-safe FCM HTTP v1 helper.
//
// Behavior:
//  - In debug/non-release builds: can sign & send directly using a service account
//    (loaded from assets/service_account.json or passed via `serviceAccount`) — useful for dev.
//  - In release builds: direct signing is disabled for security. You MUST provide `serverUrl`
//    (your backend) which will perform signing + send. If `serverUrl` is not provided the
//    function throws an exception to avoid accidentally shipping secrets.
//
// SECURITY: Do NOT embed service account JSON in production apps. Use a server (Cloud Function,
// Cloud Run, etc.) to sign JWTs and call FCM.

import 'dart:convert';
import 'package:flutter/foundation.dart' show compute, kReleaseMode;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

/// Sends an FCM message.
///
/// Parameters:
///  - fcmToken, projectId, title, body: standard fields.
///  - extraData: Map of extra key-values sent in `message.data`. Values can be any JSON
///               type but will be coerced to strings. If any value is a nested Map/List
///               the function will return a friendly error showing the offending keys.
///  - notification: whether to include the `notification` block (may show system UI).
///  - androidChannelId, ttlSeconds: optional android settings.
///  - serviceAccount: optional decoded service account JSON (preferred over embedding asset).
///  - assetPath: fallback asset path used in debug mode when serviceAccount isn't supplied.
///  - serverUrl: in release builds this must be provided. The client will POST the payload
///               to this URL and the server must perform the secure signing and FCM send.
///               The POST body is JSON:
///               { fcmToken, projectId, title, body, extraData, notification, androidChannelId, ttlSeconds }
Future<void> sendFcmPush({
  required String fcmToken,
  required String projectId,
  required String title,
  required String body,
  Map<String, dynamic>? extraData,
  bool notification = false,
  String? androidChannelId,
  int? ttlSeconds,
  Map<String, dynamic>? serviceAccount,
  String assetPath = 'assets/service_account.json',
  /// Required in release builds: HTTPS endpoint on your server that will perform signing + FCM send.
  String? serverUrl,
}) async {
  // If we're in release mode, do NOT attempt to sign locally.
  if (kReleaseMode) {
    if (serverUrl == null || serverUrl.trim().isEmpty) {
      throw Exception(
          'In release builds sendFcmPush cannot sign with a service account on-device. '
          'Provide a secure server endpoint using the "serverUrl" parameter and have your server '
          'perform signing and the FCM HTTP v1 send. This prevents shipping service account keys in your app.');
    }

    // Convert extraData to Map<String, String> for server side; server should do its own validation.
    final serverExtra = _coerceExtraDataForServer(extraData);

    // Send a lightweight JSON payload to your server. Server must handle auth and FCM send.
    final payload = {
      'fcmToken': fcmToken,
      'projectId': projectId,
      'title': title,
      'body': body,
      'extraData': serverExtra,
      'notification': notification,
      if (androidChannelId != null) 'androidChannelId': androidChannelId,
      if (ttlSeconds != null) 'ttlSeconds': ttlSeconds,
    };

    final resp = await http.post(
      Uri.parse(serverUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      // success
      return;
    } else {
      throw Exception('Server-side push failed (${resp.statusCode}): ${resp.body}');
    }
  }

  // Non-release (dev) path: allow local signing for development convenience.
  // Load service account from assets if not provided
  Map<String, dynamic>? sa = serviceAccount;
  if (sa == null) {
    try {
      final raw = await rootBundle.loadString(assetPath);
      sa = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      throw Exception(
          'Failed to load service account from asset "$assetPath": ${e.toString()}.'
          '\nIn development, add the JSON to your assets and declare it in pubspec.yaml, or '
          'pass the decoded map via the "serviceAccount" parameter.');
    }
  }

  final args = <String, dynamic>{
    'fcmToken': fcmToken,
    'projectId': projectId,
    'title': title,
    'body': body,
    // pass raw extraData to isolate; isolate will validate and coerce
    'extraData': extraData ?? <String, dynamic>{},
    'notification': notification,
    'androidChannelId': androidChannelId,
    'ttlSeconds': ttlSeconds,
    'serviceAccount': sa,
  };

  final result = await compute(_sendFcmPushIsolate, args);

  if (result['ok'] == true) {
    return;
  } else {
    final err = result['error'] ?? 'unknown error';
    final stack = result['stack'];
    final badExtra = result['badExtra'];
    // ignore: avoid_print
    print('sendFcmPush (dev) failed: $err');
    if (stack != null) {
      // ignore: avoid_print
      print(stack);
    }

    // Provide a friendly error that includes the root cause if available
    final buffer = StringBuffer();
    buffer.writeln(err);
    if (badExtra != null) {
      buffer.writeln('\nProblematic extraData entries:');
      buffer.writeln(badExtra.toString());
      buffer.writeln('\nHint: extraData values must be primitive (string/number/bool/null).');
      buffer.writeln('If you intended to send a nested structure, serialize it to a JSON string first.');
    }

    throw Exception('sendFcmPush failed: ${buffer.toString()}');
  }
}

// Helper used in release path to coerce extraData into Map<String, String>
Map<String, String> _coerceExtraDataForServer(Map<String, dynamic>? raw) {
  final out = <String, String>{};
  if (raw == null) return out;
  raw.forEach((k, v) {
    if (k == null) return;
    final key = k.toString();
    if (v == null) {
      out[key] = '';
    } else if (v is String || v is num || v is bool) {
      out[key] = v.toString();
    } else {
      // For release path we stringify complex structures to JSON so server receives something useful
      try {
        out[key] = jsonEncode(v);
      } catch (_) {
        out[key] = v.toString();
      }
    }
  });
  return out;
}

/// Background isolate that signs JWT with the service account and sends to FCM.
/// This is only used in non-release (development) mode.
Future<Map<String, dynamic>> _sendFcmPushIsolate(Map<String, dynamic> args) async {
  try {
    final serviceAccount = (args['serviceAccount'] as Map).cast<String, dynamic>();

    final clientEmail = serviceAccount['client_email']?.toString();
    final tokenUri = serviceAccount['token_uri']?.toString();
    final privateKeyPem = serviceAccount['private_key']?.toString();

    if (clientEmail == null || tokenUri == null || privateKeyPem == null) {
      return {
        'ok': false,
        'error': 'serviceAccount missing required fields (client_email, token_uri, private_key).'
      };
    }

    // Validate PEM block
    final pemMatch =
        RegExp(r'-----BEGIN PRIVATE KEY-----\s*([\s\S]+?)\s*-----END PRIVATE KEY-----')
            .firstMatch(privateKeyPem);
    if (pemMatch == null) {
      return {
        'ok': false,
        'error': 'private_key PEM missing BEGIN/END markers. Ensure full PEM in service account JSON.'
      };
    }

    final base64Body = pemMatch.group(1)!.replaceAll(RegExp(r'\s+'), '');
    try {
      base64Decode(base64Body);
    } catch (e) {
      return {
        'ok': false,
        'error':
            'private_key appears invalid or truncated (base64 decode failed). Replace with the full key from Google.'
      };
    }

    // Build & sign JWT
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final jwt = JWT({
      'iss': clientEmail,
      'scope': 'https://www.googleapis.com/auth/firebase.messaging',
      'aud': tokenUri,
      'iat': nowSec,
      'exp': nowSec + 3600,
    });

    final key = RSAPrivateKey(privateKeyPem);
    final signedJwt = jwt.sign(key, algorithm: JWTAlgorithm.RS256);

    // Exchange JWT for access token
    final oauthResp = await http
        .post(
          Uri.parse(tokenUri),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
            'assertion': signedJwt,
          },
        )
        .timeout(const Duration(seconds: 20));

    if (oauthResp.statusCode != 200) {
      return {
        'ok': false,
        'error': 'Failed to obtain access token: ${oauthResp.statusCode} ${oauthResp.body}'
      };
    }

    final oauthJson = jsonDecode(oauthResp.body) as Map<String, dynamic>;
    final accessToken = oauthJson['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      return {'ok': false, 'error': 'No access_token in OAuth response: ${oauthResp.body}'};
    }

    // Build dataMap (strict Map<String, String>) and coerce any extra values to strings,
    // but detect nested Maps/Lists and return a helpful error listing offending keys.
    final Map<String, String> dataMap = {
      'click_action': 'FLUTTER_NOTIFICATION_CLICK',
      'title': args['title']?.toString() ?? '',
      'body': args['body']?.toString() ?? '',
    };

    // Add extraData safely: coerce keys and values to strings, collect problematic entries
    final rawExtra = args['extraData'];
    final List<Map<String, dynamic>> problems = [];
    if (rawExtra is Map) {
      rawExtra.forEach((key, value) {
        final k = key?.toString() ?? '';
        if (k.isEmpty) return;

        if (value == null) {
          dataMap[k] = '';
          return;
        }

        // Allowed primitive types
        if (value is String || value is num || value is bool) {
          dataMap[k] = value.toString();
          return;
        }

        // If value is a Map or Iterable (nested), that's likely the cause of your runtime error.
        if (value is Map || value is Iterable) {
          // Record problem with sample (truncated)
          String sample;
          try {
            sample = jsonEncode(value);
            if (sample.length > 200) sample = sample.substring(0, 200) + '...';
          } catch (_) {
            sample = value.toString();
            if (sample.length > 200) sample = sample.substring(0, 200) + '...';
          }
          problems.add({'key': k, 'type': value.runtimeType.toString(), 'sample': sample});
          return;
        }

        // For any other non-primitive value try to jsonEncode; if it fails, record as problem
        try {
          dataMap[k] = jsonEncode(value);
        } catch (e) {
          problems.add({'key': k, 'type': value.runtimeType.toString(), 'sample': value.toString()});
        }
      });

      if (problems.isNotEmpty) {
        return {
          'ok': false,
          'error': 'extraData contains nested objects which cannot be used as FCM data values.',
          'badExtra': problems,
        };
      }
    } else if (rawExtra != null) {
      return {
        'ok': false,
        'error': 'extraData must be a Map. Received type: ${rawExtra.runtimeType}.'
      };
    }

    // Build FCM message (HTTP v1)
    final message = <String, dynamic>{
      'token': args['fcmToken']?.toString(),
      'data': dataMap,
      'android': {'priority': 'high'},
      'apns': {
        'headers': {
          'apns-priority': '10',
          'apns-push-type': (args['notification'] as bool) ? 'alert' : 'background',
        },
        'payload': (args['notification'] as bool)
            ? {
                'aps': {
                  'alert': {'title': args['title']?.toString(), 'body': args['body']?.toString()},
                  'sound': 'default',
                }
              }
            : {
                'aps': {'content-available': 1}
              },
      },
    };

    if (args['notification'] as bool) {
      message['notification'] = {'title': args['title']?.toString(), 'body': args['body']?.toString()};
      final android = (message['android'] as Map<String, dynamic>);
      android['notification'] = {
        if (args['androidChannelId'] != null) 'channel_id': args['androidChannelId']?.toString(),
        'sound': 'default',
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
      };
      if (args['ttlSeconds'] != null) android['ttl'] = '${args['ttlSeconds']}s';
    }

    // Encode & send
    String requestBody;
    try {
      requestBody = jsonEncode({'message': message});
    } catch (e) {
      return {
        'ok': false,
        'error': 'jsonEncode failed when encoding request body: ${e.toString()}',
        'stack': StackTrace.current.toString(),
      };
    }

    final projectId = args['projectId']?.toString();
    if (projectId == null || projectId.isEmpty) {
      return {'ok': false, 'error': 'projectId missing or empty.'};
    }

    final fcmResp = await http
        .post(
          Uri.parse('https://fcm.googleapis.com/v1/projects/$projectId/messages:send'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $accessToken',
          },
          body: requestBody,
        )
        .timeout(const Duration(seconds: 20));

    if (fcmResp.statusCode == 200) {
      return {'ok': true, 'messageId': fcmResp.body};
    } else {
      return {'ok': false, 'error': 'FCM failed: ${fcmResp.statusCode} ${fcmResp.body}'};
    }
  } catch (e, st) {
    return {'ok': false, 'error': e.toString(), 'stack': st.toString()};
  }
}
