// services/fcm_sender.dart
// Backend-forwarding FCM helper for Flutter
//
// Behavior:
//  - In release builds the function will POST to your secure server endpoint
//    (default: https://moviflxpro.onrender.com/sendPush). The server is expected
//    to perform service-account signing and call FCM HTTP v1.
//  - In debug/dev builds, the function will still support signing on-device
//    using a service account JSON (via compute) if no serverUrl is provided.
//
// Important: FCM `message.data` requires Map<String, String>. This file
// strictly coerces all extraData values to strings (json-encoding non-primitives).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, kReleaseMode;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

String _shortSample(Object? v, [int max = 200]) {
  try {
    final s = jsonEncode(v);
    if (s.length <= max) return s;
    return s.substring(0, max) + '...';
  } catch (_) {
    final s = v?.toString() ?? '<null>';
    if (s.length <= max) return s;
    return s.substring(0, max) + '...';
  }
}

const String _defaultServerBase = 'https://moviflxpro.onrender.com';
const String _defaultServerPath = '/sendPush';

String _normalizeServerUrl(String baseOrFull) {
  final trimmed = (baseOrFull ?? '').trim();
  if (trimmed.isEmpty) return '$_defaultServerBase$_defaultServerPath';
  if (trimmed.endsWith('/sendPush')) return trimmed;
  if (trimmed.endsWith('/')) return '$trimmed${_defaultServerPath.substring(1)}';
  if (trimmed.contains('/sendPush')) return trimmed;
  return '$trimmed$_defaultServerPath';
}

/// Sends an FCM push. In release mode this posts to a secure server which must
/// sign requests and call the FCM HTTP v1 API (recommended). In dev you may
/// either provide `serviceAccount` (decoded JSON map) or include the JSON file
/// as an asset and set `assetPath`.
Future<void> sendFcmPush({
  String? fcmToken,
  String? topic,
  required String projectId,
  required String title,
  required String body,
  Map<String, dynamic>? extraData,
  bool notification = false,
  String? androidChannelId,
  int? ttlSeconds,
  Map<String, dynamic>? serviceAccount,
  String assetPath = 'assets/service_account.json',
  String? serverUrl,
  String? apiKey,
}) async {
  // validate
  if ((fcmToken == null || fcmToken.trim().isEmpty) &&
      (topic == null || topic.trim().isEmpty)) {
    throw Exception('Either fcmToken or topic must be provided.');
  }

  final resolvedServerUrl = _normalizeServerUrl(serverUrl ?? _defaultServerBase);

  // Release: forward to your server (recommended).
  if (kReleaseMode) {
    final payload = <String, dynamic>{
      if (fcmToken != null && fcmToken.trim().isNotEmpty) 'fcmToken': fcmToken,
      if (topic != null && topic.trim().isNotEmpty) 'topic': topic,
      'projectId': projectId,
      'title': title,
      'body': body,
      // ensure server receives only strings in extraData
      'extraData': _coerceExtraDataForServer(extraData),
      'notification': notification,
      if (androidChannelId != null) 'androidChannelId': androidChannelId,
      if (ttlSeconds != null) 'ttlSeconds': ttlSeconds,
    };

    final headers = <String, String>{'Content-Type': 'application/json'};
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      headers['X-Api-Key'] = apiKey;
    }

    final resp = await http
        .post(
          Uri.parse(resolvedServerUrl),
          headers: headers,
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 20));

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return;
    } else {
      String bodyPreview = resp.body;
      try {
        final parsed = jsonDecode(resp.body);
        if (parsed is Map && parsed['error'] != null) {
          bodyPreview = parsed['error'].toString();
        } else {
          bodyPreview = resp.body.toString();
        }
      } catch (_) {
        // keep raw body
      }
      throw Exception('Server-side push failed (${resp.statusCode}): $bodyPreview');
    }
  }

  // ----------------- Dev/local signing -----------------
  Map<String, dynamic>? sa = serviceAccount;
  if (sa == null) {
    try {
      final raw = await rootBundle.loadString(assetPath);
      sa = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      throw Exception(
          'Failed to load service account from asset "$assetPath": ${e.toString()}.\n'
          'In development, add the JSON to your assets and declare it in pubspec.yaml, or '
          'pass the decoded map via the "serviceAccount" parameter.');
    }
  }

  final args = <String, dynamic>{
    'fcmToken': fcmToken,
    'topic': topic,
    'projectId': projectId,
    'title': title,
    'body': body,
    'extraData': extraData ?? <String, dynamic>{},
    'notification': notification,
    'androidChannelId': androidChannelId,
    'ttlSeconds': ttlSeconds,
    'serviceAccount': sa,
  };

  final result = await compute(_sendFcmPushIsolateSafe, args);

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
    if (badExtra != null) {
      // ignore: avoid_print
      print('sendFcmPush (dev) badExtra: $badExtra');
    }

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

/// Coerce a Map<String, dynamic> into Map<String, String> for server-forwarding.
/// For non-primitives we JSON-encode; on failure we fallback to `toString()`.
Map<String, String> _coerceExtraDataForServer(Map<String, dynamic>? raw) {
  final out = <String, String>{};
  if (raw == null) return out;
  raw.forEach((k, v) {
    if (k == null) return;
    final key = k.toString();
    try {
      if (v == null) {
        out[key] = '';
      } else if (v is String || v is num || v is bool) {
        out[key] = v.toString();
      } else {
        try {
          out[key] = jsonEncode(v);
        } catch (_) {
          out[key] = v.toString();
        }
      }
    } catch (_) {
      out[key] = '';
    }
  });
  return out;
}

/// Isolate entrypoint with safe coercion & logging (dev signing flow)
/// Isolate entrypoint with safe coercion & logging (dev signing flow)
Future<Map<String, dynamic>> _sendFcmPushIsolateSafe(Map<String, dynamic> args) async {
  try {
    final serviceAccount = (args['serviceAccount'] as Map).cast<String, dynamic>();

    final clientEmail = serviceAccount['client_email']?.toString();
    final tokenUri = serviceAccount['token_uri']?.toString();
    final privateKeyPem = serviceAccount['private_key']?.toString();

    // ignore: avoid_print
    print('DEBUG sendFcmPushIsolate: clientEmail=$clientEmail tokenUri=$tokenUri now=${DateTime.now().toUtc().toIso8601String()}');

    if (clientEmail == null || tokenUri == null || privateKeyPem == null) {
      return {
        'ok': false,
        'error': 'serviceAccount missing required fields (client_email, token_uri, private_key).'
      };
    }

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

    // Build a permissive data map (values may be dynamic initially)
    final Map<String, dynamic> dataMap = {
      'click_action': 'FLUTTER_NOTIFICATION_CLICK',
      'title': args['title']?.toString() ?? '',
      'body': args['body']?.toString() ?? '',
    };

    final rawExtra = args['extraData'];
    // ignore: avoid_print
    print('DEBUG: extraData runtimeType=${rawExtra?.runtimeType} sample=${_shortSample(rawExtra, 300)}');

    final List<Map<String, dynamic>> problems = [];

    // Coerce extraData into strings consistently
    if (rawExtra is Map) {
      rawExtra.forEach((rawKey, rawValue) {
        final k = rawKey?.toString() ?? '';
        if (k.isEmpty) return;

        try {
          String s;
          if (rawValue == null) {
            s = '';
          } else if (rawValue is String || rawValue is num || rawValue is bool) {
            s = rawValue.toString();
          } else {
            try {
              s = jsonEncode(rawValue); // Try JSON encoding for complex objects
            } catch (eJson) {
              try {
                s = rawValue.toString(); // Fallback to toString
                problems.add({
                  'key': k,
                  'type': rawValue.runtimeType.toString(),
                  'note': 'jsonEncode failed; used toString() fallback',
                  'valueSample': _shortSample(rawValue),
                  'error': eJson.toString()
                });
                // ignore: avoid_print
                print('DEBUG: jsonEncode failed for key=$k type=${rawValue.runtimeType} sample=${_shortSample(rawValue)} error=$eJson');
              } catch (eToString) {
                problems.add({
                  'key': k,
                  'type': rawValue.runtimeType.toString(),
                  'error': 'jsonEncode failed and toString failed: ${eToString.toString()}',
                  'valueSample': _shortSample(rawValue),
                });
                s = '';
              }
            }
          }

          // assign string value
          dataMap[k] = s;
        } catch (e, st) {
          problems.add({
            'key': rawKey?.toString() ?? '<unknown>',
            'type': rawValue?.runtimeType.toString(),
            'error': e.toString(),
            'stack': st.toString(),
            'valueSample': _shortSample(rawValue),
          });
          // ignore: avoid_print
          print('DEBUG: Exception while coercing extraData key=$rawKey type=${rawValue?.runtimeType} sample=${_shortSample(rawValue)} error=$e');
        }
      });

      if (problems.isNotEmpty) {
        // ignore: avoid_print
        print('DEBUG: extraData problems detected: ${jsonEncode(problems)}');
        return {
          'ok': false,
          'error': 'extraData contains entries which had issues converting to strings.',
          'badExtra': problems,
        };
      }
    } else if (rawExtra != null) {
      return {
        'ok': false,
        'error': 'extraData must be a Map. Received type: ${rawExtra.runtimeType}.'
      };
    }

    // ----- Ensure every value in finalData is a String -----
// ----- Ensure every value in finalData is a String -----
final Map<String, String> finalData = {};
String? lastKey;
dynamic lastVal;

try {
  for (final entry in dataMap.entries) {
    final rawKey = entry.key;
    final rawVal = entry.value;
    lastKey = rawKey?.toString();
    lastVal = rawVal;

    if (rawKey == null) continue;
    final k = rawKey.toString();
    String s;
    if (rawVal == null) {
      s = '';
    } else if (rawVal is String) {
      s = rawVal;
    } else if (rawVal is num || rawVal is bool) {
      s = rawVal.toString();
    } else {
      try {
        s = jsonEncode(rawVal); // Try JSON encoding
      } catch (_) {
        try {
          s = rawVal.toString(); // Fallback
        } catch (_) {
          s = ''; // Ultimate fallback
        }
      }
    }
    finalData[k] = s;
  }
} catch (e, st) {
  print(
    'DEBUG: Failed to coerce dataMap entry: key=$lastKey, '
    'value=${_shortSample(lastVal)}, error=$e',
  );
  return {
    'ok': false,
    'error': 'Failed to coerce data map to strings: ${e.toString()}',
    'stack': st.toString()
  };
}

    // Build the message without using conditional expressions inside map literal
    final Map<String, dynamic> message = {};
    if (args['topic'] != null && (args['topic'] as String).isNotEmpty) {
      message['topic'] = args['topic']?.toString();
    } else {
      message['token'] = args['fcmToken']?.toString();
    }

    message['data'] = finalData;
    message['android'] = {'priority': 'high'};
    message['apns'] = {
      'headers': {
        'apns-priority': '10',
        'apns-push-type': (args['notification'] as bool) ? 'alert' : 'background',
      },
      'payload': (args['notification'] as bool)
          ? {
              'aps': {
                'alert': {
                  'title': args['title']?.toString(),
                  'body': args['body']?.toString(),
                },
                'sound': 'default',
              }
            }
          : {
              'aps': {'content-available': 1}
            },
    };

    if (args['notification'] as bool) {
      message['notification'] = {'title': args['title']?.toString(), 'body': args['body']?.toString()};
      final android = (message['android'] as Map<String, dynamic>);
      final Map<String, dynamic> androidNotification = {};
      if (args['androidChannelId'] != null) {
        androidNotification['channel_id'] = args['androidChannelId']?.toString();
      }
      androidNotification['sound'] = 'default';
      androidNotification['click_action'] = 'FLUTTER_NOTIFICATION_CLICK';
      android['notification'] = androidNotification;
      if (args['ttlSeconds'] != null) android['ttl'] = '${args['ttlSeconds']}s';
    }

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
    // ignore: avoid_print
    print('DEBUG: unexpected error in _sendFcmPushIsolateSafe: $e\n$st');
    return {'ok': false, 'error': e.toString(), 'stack': st.toString()};
  }
}