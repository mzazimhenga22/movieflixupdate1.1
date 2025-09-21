// lib/main.dart
import 'dart:async';
import 'dart:isolate';
import 'dart:ui';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode, defaultTargetPlatform, compute;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'firebase_options.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:movie_app/splash_screen.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/database/auth_database.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:movie_app/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:movie_app/components/socialsection/ProfileScreen.dart';
import 'package:movie_app/components/socialsection/messages_controller.dart';
import 'package:movie_app/components/socialsection/messages_screen.dart';
import 'package:movie_app/components/socialsection/presence_wrapper.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:movie_app/downloads_screen.dart';
import 'package:movie_app/components/socialsection/widgets/call_overlay_service.dart';
import 'package:movie_app/components/socialsection/VoiceCallScreen_1to1.dart';
import 'package:movie_app/components/socialsection/VideoCallScreen_1to1.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:movie_app/services/fcm_sender.dart';
import 'package:movie_app/components/socialsection/chat_screen.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// -------------------- NEW: compute helpers (top-level, JSON-serializable safe) --------------------
/// These helpers perform CPU/string/JSON parsing and lightweight selection logic that can be safely
/// executed in a background isolate via `compute`. They DO NOT use platform channels or plugins.

@pragma('vm:entry-point')
Map<String, dynamic> _normalizeData(Map<dynamic, dynamic> raw) {
  // Ensure keys are strings and common fields have predictable types
  final Map<String, dynamic> data = {};
  try {
    raw.forEach((k, v) {
      final key = k?.toString() ?? '';
      if (v is Map || v is List) {
        // try to deep-serialize nested structures
        try {
          data[key] = jsonDecode(jsonEncode(v));
        } catch (_) {
          data[key] = v.toString();
        }
      } else {
        data[key] = v;
      }
    });

    // normalize duration to int (milliseconds)
    if (data.containsKey('duration')) {
      final d = data['duration'];
      if (d is int) {
        data['duration'] = d;
      } else if (d is String) {
        final parsed = int.tryParse(d);
        data['duration'] = parsed ?? 30000;
      } else {
        data['duration'] = 30000;
      }
    }

    // make sure callType/key typed as string
    if (data.containsKey('callType')) data['callType'] = data['callType']?.toString() ?? '';
    if (data.containsKey('type')) data['type'] = data['type']?.toString() ?? '';

  } catch (_) {}
  return data;
}

@pragma('vm:entry-point')
Map<String, dynamic> _parseDownloaderMessage(Map<dynamic, dynamic> msg) {
  final Map<String, dynamic> out = {'id': '<unknown>', 'statusInt': -1, 'progress': 0};
  try {
    final id = msg['id']?.toString() ?? '<unknown>';
    out['id'] = id;

    final rawStatus = msg['status'];
    int statusInt = -1;
    if (rawStatus is int) {
      statusInt = rawStatus;
    } else if (rawStatus is String) {
      statusInt = int.tryParse(rawStatus) ?? -1;
    }
    out['statusInt'] = statusInt;

    final rawProgress = msg['progress'];
    int progress = 0;
    if (rawProgress is int) {
      progress = rawProgress;
    } else if (rawProgress is String) {
      progress = int.tryParse(rawProgress) ?? 0;
    } else if (rawProgress is double) {
      progress = rawProgress.toInt();
    }
    out['progress'] = progress;
  } catch (_) {}
  return out;
}

@pragma('vm:entry-point')
Map<String, dynamic> _determineOtherUser(Map<dynamic, dynamic> args) {
  // args: { 'chatData': <Map or null>, 'currentUserId': '...', 'payloadData': <Map> }
  try {
    final chatData = (args['chatData'] is Map) ? Map<String, dynamic>.from(args['chatData']) : <String, dynamic>{};
    final currentUserId = args['currentUserId']?.toString() ?? '';
    final payload = (args['payloadData'] is Map) ? Map<String, dynamic>.from(args['payloadData']) : <String, dynamic>{};

    String? otherUserId;
    if (chatData.isNotEmpty) {
      final userIdsRaw = chatData['userIds'];
      if (userIdsRaw is List) {
        final List<String> userIds = userIdsRaw.map((e) => e.toString()).toList();
        for (final id in userIds) {
          if (id != currentUserId) {
            otherUserId = id;
            break;
          }
        }
      }
      if (otherUserId == null || otherUserId.isEmpty) {
        otherUserId = payload['senderId'] ?? payload['sender_id'] ?? payload['sender'] ?? null;
      }
    } else {
      otherUserId = payload['senderId'] ?? payload['sender_id'] ?? payload['sender'] ?? null;
    }
    return {'otherUserId': otherUserId?.toString() ?? ''};
  } catch (_) {
    return {'otherUserId': ''};
  }
}

@pragma('vm:entry-point')
String _snackPreview(Map<dynamic, dynamic> args) {
  final body = (args['body'] ?? '').toString();
  final maxLen = (args['max'] is int) ? args['max'] as int : int.tryParse(args['max']?.toString() ?? '') ?? 80;
  if (body.length <= maxLen) return body;
  return body.substring(0, maxLen) + '…';
}

/// -------------------- End compute helpers --------------------

/* Remaining code unchanged logically, but calls the compute helpers where appropriate. */

// A port to receive messages from the background isolate
final ReceivePort _port = ReceivePort();

// Global navigator key so we can push screens from overlay/service
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Local notifications plugin & channels
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

final AndroidNotificationChannel messagesChannel = AndroidNotificationChannel(
  'messages', // id
  'Messages', // name
  description: 'Message notifications',
  importance: Importance.max,
);

final AndroidNotificationChannel incomingCallChannel = AndroidNotificationChannel(
  'incoming_call',
  'Incoming Calls',
  description: 'Incoming call notifications (full-screen)',
  importance: Importance.max,
);

/// Manager that serializes calls to FirebaseMessaging.instance.requestPermission()
class FcmPermissionManager {
  static Future<NotificationSettings>? _pendingRequest;

  static Future<NotificationSettings> ensurePermissionRequested() {
    if (_pendingRequest != null) return _pendingRequest!;
    final future = () async {
      try {
        final settings = await FirebaseMessaging.instance.requestPermission(
          alert: true,
          badge: true,
          sound: true,
        );
        return settings;
      } finally {
        _pendingRequest = null;
      }
    }();
    _pendingRequest = future;
    return future;
  }
}

// Background handler must be top-level and annotated as entry-point
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Ensure Firebase is initialized in the background isolate
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Activate App Check in the background isolate as well (debug in non-release)
  try {
    if (kReleaseMode) {
      await FirebaseAppCheck.instance.activate(
        androidProvider: AndroidProvider.playIntegrity,
        appleProvider: AppleProvider.deviceCheck,
      );
      debugPrint('[BG] Firebase App Check activated (release providers)');
    } else {
      await FirebaseAppCheck.instance.activate(
        androidProvider: AndroidProvider.debug,
        appleProvider: AppleProvider.debug,
      );
      debugPrint('[BG] Firebase App Check activated (debug provider)');
    }
  } catch (e, st) {
    debugPrint('[BG] Firebase App Check activation failed: $e\n$st');
  }

  // Use compute to normalize and sanitize incoming data (light CPU work)
  final rawData = (message.data ?? <String, dynamic>{});
  final data = await compute(_normalizeData, Map<String, dynamic>.from(rawData));

  debugPrint('[BG] background message received data=$data');

  // Handle incoming call data-only pushes (background)
  if ((data['type'] ?? '') == 'incoming_call') {
    try {
      final params = CallKitParams.fromJson({
        'id': data['callId'] ?? '',
        'nameCaller': data['callerName'] ?? 'Unknown',
        'appName': 'MovieApp',
        'avatar': data['avatar'] ?? '',
        'handle': data['callerId'] ?? '',
        'type': (data['callType'] ?? '') == 'video' ? 1 : 0,
        'textAccept': 'Accept',
        'textDecline': 'Decline',
        'duration': (data['duration'] is int) ? data['duration'] : 30000,
        'extra': {'userId': data['receiverId'] ?? '', 'callerId': data['callerId'] ?? ''},
        'android': {
          'isCustomNotification': true,
          'isShowLogo': false,
          'ringtonePath': 'system_ringtone_default',
          'backgroundColor': '#0955fa',
          'actionColor': '#4CAF50',
          'incomingCallNotificationChannelName': 'Incoming Call',
          'missedCallNotificationChannelName': 'Missed Call',
          'isShowCallID': false,
        },
        'ios': {
          'iconName': 'CallKitLogo',
          'handleType': 'generic',
          'supportsVideo': true,
          'maximumCallGroups': 2,
          'maximumCallsPerCallGroup': 1,
          'audioSessionMode': 'default',
          'audioSessionActive': true,
          'audioSessionPreferredSampleRate': 44100.0,
          'audioSessionPreferredIOBufferDuration': 0.005,
          'supportsDTMF': true,
          'supportsHolding': true,
          'supportsGrouping': false,
          'supportsUngrouping': false,
          'ringtonePath': 'system_ringtone_default',
        },
      });

      debugPrint('[BG] showing CallKit incoming (background) for callId=${data['callId']}');
      if (!kIsWeb) {
        await FlutterCallkitIncoming.showCallkitIncoming(params);
      } else {
        debugPrint('[BG] skipping CallKit on web');
      }
    } catch (e, st) {
      debugPrint('[BG] CallKit show failed (headless): $e\n$st');
    }
  } else {
    debugPrint('[BG] background message is not incoming_call; type=${data['type']}');
  }
}

// Single downloader callback (entrypoint)
@pragma('vm:entry-point')
void downloadCallback(String id, int status, int progress) {
  try {
    final SendPort? send = IsolateNameServer.lookupPortByName('downloader_send_port');
    send?.send({'id': id, 'status': status, 'progress': progress});
  } catch (e, st) {
    debugPrint('[Downloader callback] error sending to port: $e\n$st');
  }
}

Future<void> _safeRegisterDownloaderCallback() async {
  if (kIsWeb) {
    debugPrint('[Downloader] skipping registration on web');
    return;
  }
  try {
    if (IsolateNameServer.lookupPortByName('downloader_send_port') == null) {
      IsolateNameServer.registerPortWithName(_port.sendPort, 'downloader_send_port');
    }
  } catch (e) {
    debugPrint('[Downloader] IsolateNameServer.register failed: $e');
  }
  try {
    FlutterDownloader.registerCallback(downloadCallback);
  } catch (e) {
    debugPrint('[Downloader] FlutterDownloader.registerCallback failed or already registered: $e');
  }
}

/// Detect permission concurrency error (fuzzy)
bool _isPermissionAlreadyRunningError(Object e) {
  try {
    final lower = e.toString().toLowerCase();
    return (lower.contains('a request for permissions is already running') ||
        lower.contains('request for permissions is already running') ||
        (lower.contains('already running') && lower.contains('permission')));
  } catch (_) {
    return false;
  }
}

Future<void> _safeAuthDatabaseInitialize({int maxRetries = 6}) async {
  int attempt = 0;
  while (true) {
    try {
      await AuthDatabase.instance.initialize();
      return;
    } catch (e, st) {
      attempt++;
      final isPermBusy = _isPermissionAlreadyRunningError(e);
      if (isPermBusy && attempt <= maxRetries) {
        final waitMs = 300 + (attempt * 300);
        debugPrint('[main] AuthDatabase.initialize retry ${attempt}/$maxRetries after $waitMs ms due to permission-race');
        try {
          await (FcmPermissionManager._pendingRequest ?? Future<void>.delayed(Duration(milliseconds: waitMs)));
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: waitMs));
        continue;
      }
      debugPrint('❌ AuthDatabase.initialize failed: $e\n$st');
      rethrow;
    }
  }
}

/// -------------------- Top-level helpers (so local notifications callbacks can use them) --------------------

Future<void> openChatFromNotification(Map<String, dynamic> data) async {
  try {
    final possibleChatId = data['chatId'] ?? data['chat_id'] ?? data['chatid'];
    if (possibleChatId == null || possibleChatId.toString().trim().isEmpty) {
      debugPrint('[notif->chat] no chatId in notification data: $data');
      return;
    }
    final chatId = possibleChatId.toString();

    final supaUser = Supabase.instance.client.auth.currentUser;
    if (supaUser == null) {
      debugPrint('[notif->chat] no authenticated user found - cannot open chat');
      return;
    }
    final currentUserId = supaUser.id;

    // Fetch current user's Firestore doc
    final curUserDoc = await FirebaseFirestore.instance.collection('users').doc(currentUserId).get();
    if (!curUserDoc.exists) {
      debugPrint('[notif->chat] current user doc not found for id=$currentUserId');
      return;
    }
    final Map<String, dynamic> currentUserMap = {...curUserDoc.data()!, 'id': curUserDoc.id};

    // Try to load the chat doc to determine the other participant
    final chatDocSnap = await FirebaseFirestore.instance.collection('chats').doc(chatId).get();
    String? otherUserId;
    if (chatDocSnap.exists) {
      final chatData = chatDocSnap.data()!;
      // Use compute to determine other user id (light CPU)
      final result = await compute(_determineOtherUser, {
        'chatData': chatData,
        'currentUserId': currentUserId,
        'payloadData': data,
      });
      otherUserId = result['otherUserId'] as String?;
      if (otherUserId == '') otherUserId = data['senderId'] ?? data['sender_id'] ?? null;
    } else {
      otherUserId = data['senderId'] ?? data['sender_id'] ?? null;
    }

    if (otherUserId == null || otherUserId.toString().isEmpty) {
      debugPrint('[notif->chat] could not determine other user id for chatId=$chatId');
      return;
    }

    final otherDoc = await FirebaseFirestore.instance.collection('users').doc(otherUserId.toString()).get();
    final Map<String, dynamic> otherUserMap =
        otherDoc.exists ? {...otherDoc.data()!, 'id': otherDoc.id} : {'id': otherUserId.toString()};

    final List<dynamic> storyInteractions = [];

    // Ensure navigator is ready
    if (navigatorKey.currentState == null) {
      debugPrint('[notif->chat] navigatorKey.currentState is null - aborting openChat');
      return;
    }

    // Get accentColor safely via provider if available
    Color accentColor = Colors.blue;
    try {
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        accentColor = Provider.of<SettingsProvider>(ctx, listen: false).accentColor;
      }
    } catch (_) {}

    navigatorKey.currentState!.push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        chatId: chatId,
        currentUser: currentUserMap,
        otherUser: otherUserMap,
        authenticatedUser: currentUserMap,
        storyInteractions: storyInteractions,
        accentColor: accentColor,
      ),
    ));

    debugPrint('[notif->chat] pushed ChatScreen for chatId=$chatId');
  } catch (e, st) {
    debugPrint('[notif->chat] failed to open chat from notification: $e\n$st');
  }
}

Future<void> handleIncomingCallTap(Map<String, dynamic> data) async {
  final callId = data['callId'] as String? ?? '';
  final callerId = data['callerId'] as String? ?? '';
  final receiverId = data['receiverId'] as String? ?? '';
  final callType = (data['callType'] ?? 'voice') as String;

  if (navigatorKey.currentState != null) {
    if (callType == 'video') {
      navigatorKey.currentState!.push(MaterialPageRoute(
        builder: (_) => VideoCallScreen1to1(
          callId: callId,
          callerId: callerId,
          receiverId: receiverId,
          currentUserId: receiverId,
          // pass empty map if we don't have caller/receiver metadata
          caller: <String, dynamic>{},
          receiver: <String, dynamic>{},
        ),
      ));
    } else {
      navigatorKey.currentState!.push(MaterialPageRoute(
        builder: (_) => VoiceCallScreen1to1(
          callId: callId,
          callerId: callerId,
          receiverId: receiverId,
          currentUserId: receiverId,
          caller: <String, dynamic>{},
          receiver: <String, dynamic>{},
        ),
      ));
    }
  } else {
    debugPrint('[call] navigator not ready - cannot open call screen now');
  }
}

Future<void> showIncomingCallUIFromData(Map<String, dynamic> data) async {
  try {
    final params = CallKitParams.fromJson({
      'id': data['callId'] ?? '',
      'nameCaller': data['callerName'] ?? 'Unknown',
      'appName': 'MovieApp',
      'avatar': data['avatar'] ?? '',
      'handle': data['callerId'] ?? '',
      'type': (data['callType'] ?? '') == 'video' ? 1 : 0,
      'textAccept': 'Accept',
      'textDecline': 'Decline',
      'duration': (data['duration'] is int) ? data['duration'] : 30000,
      'extra': {'userId': data['receiverId'] ?? '', 'callerId': data['callerId'] ?? ''},
      'android': {
        'isCustomNotification': true,
        'isShowLogo': false,
        'ringtonePath': 'system_ringtone_default',
        'backgroundColor': '#0955fa',
        'actionColor': '#4CAF50',
        'incomingCallNotificationChannelName': 'Incoming Call',
        'missedCallNotificationChannelName': 'Missed Call',
        'isShowCallID': false,
      },
      'ios': {
        'iconName': 'CallKitLogo',
        'handleType': 'generic',
        'supportsVideo': true,
        'maximumCallGroups': 2,
        'maximumCallsPerCallGroup': 1,
        'audioSessionMode': 'default',
        'audioSessionActive': true,
        'audioSessionPreferredSampleRate': 44100.0,
        'audioSessionPreferredIOBufferDuration': 0.005,
        'supportsDTMF': true,
        'supportsHolding': true,
        'supportsGrouping': false,
        'supportsUngrouping': false,
        'ringtonePath': 'system_ringtone_default',
      },
    });

    debugPrint('[FG] showing CallKit incoming (foreground) for callId=${data['callId']}');
    if (!kIsWeb) {
      await FlutterCallkitIncoming.showCallkitIncoming(params);
    } else {
      debugPrint('[FG] skipping CallKit UI on web');
    }
  } catch (e, st) {
    debugPrint('[FG] showCallkitIncoming failed: $e\n$st');
  }
}

/// ---------------------------------------------------------------------------------------------------------

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Configure FcmSender
  const fallbackKey = '@Mzazimhenga02';
  final pushApiKey = const String.fromEnvironment('PUSH_API_KEY', defaultValue: fallbackKey).trim();

  try {
    FcmSender.configure(
      baseUrl: 'https://movieflixprov2.onrender.com/sendPush',
      apiKey: pushApiKey.isNotEmpty ? pushApiKey : null,
    );
    debugPrint('[main] FcmSender configured to use backend: ${FcmSender.baseUrl} (api key ${pushApiKey.isNotEmpty ? 'provided' : 'not provided'})');
  } catch (e, st) {
    debugPrint('[main] FcmSender.configure failed: $e\n$st');
  }

  // dart-define flags
  const enableImpeller = bool.fromEnvironment('ENABLE_IMPELLER', defaultValue: false);
  const enableSksl = bool.fromEnvironment('ENABLE_SKSL', defaultValue: false);
  const useSoftwareRendering = bool.fromEnvironment('USE_SOFTWARE_RENDERING', defaultValue: false);

  try {
    // FlutterDownloader init (mobile-only)
    if (!kIsWeb) {
      try {
        await FlutterDownloader.initialize(debug: true, ignoreSsl: true);
        debugPrint('✅ FlutterDownloader initialized');
      } catch (e) {
        debugPrint('⚠️ FlutterDownloader.initialize failed: $e');
      }
      await _safeRegisterDownloaderCallback();
    } else {
      debugPrint('[Downloader] skipped initialization on web');
    }

    // Firebase
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    debugPrint('✅ Firebase initialized');

    // Initialize flutter_local_notifications & create channels (mobile only)
    try {
      const AndroidInitializationSettings androidInitSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      final InitializationSettings initSettings = InitializationSettings(
        android: androidInitSettings,
        // iOS/macOS settings can be added here if needed
      );

      await flutterLocalNotificationsPlugin.initialize(
        initSettings,
        // when user taps system notification
        onDidReceiveNotificationResponse: (NotificationResponse response) async {
          try {
            final payload = response.payload;
            if (payload != null && payload.isNotEmpty) {
              final Map<String, dynamic> data = jsonDecode(payload);
              final type = (data['type'] ?? '').toString();
              if (type == 'message') {
                await openChatFromNotification(data);
              } else if (type == 'incoming_call') {
                await handleIncomingCallTap(data);
              } else {
                // fallback: try to open chat if chatId present
                if (data['chatId'] != null) await openChatFromNotification(data);
              }
            }
          } catch (e) {
            debugPrint('[localNotif] onSelect payload parse failed: $e');
          }
        },
      );

      // create Android channels (no-op on iOS)
      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(messagesChannel);
      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(incomingCallChannel);

      // iOS: show alerts while in foreground
      try {
        await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
      } catch (e) {
        debugPrint('[FCM] setForegroundNotificationPresentationOptions failed: $e');
      }
    } catch (e) {
      debugPrint('[localNotif] initialization failed: $e');
    }

    // Firebase App Check activation (defensive)
    try {
      if (kIsWeb) {
        if (!kReleaseMode) {
          await FirebaseAppCheck.instance.activate(androidProvider: AndroidProvider.debug, appleProvider: AppleProvider.debug);
          debugPrint('✅ Firebase App Check activated (web debug provider)');
        } else {
          debugPrint('⚠️ Firebase App Check for web: no explicit activation performed (ensure recaptcha configured externally).');
        }
      } else {
        if (kReleaseMode) {
          await FirebaseAppCheck.instance.activate(androidProvider: AndroidProvider.playIntegrity, appleProvider: AppleProvider.deviceCheck);
          debugPrint('✅ Firebase App Check activated (release providers)');
        } else {
          await FirebaseAppCheck.instance.activate(androidProvider: AndroidProvider.debug, appleProvider: AppleProvider.debug);
          debugPrint('✅ Firebase App Check activated (debug provider)');
        }
      }
    } catch (e, st) {
      debugPrint('⚠️ Firebase App Check activation failed: $e\n$st');
    }

    // Auth DB
    await _safeAuthDatabaseInitialize();
    debugPrint('✅ AuthDatabase initialized (safe)');

    // Notification permissions
    try {
      final settings = await FcmPermissionManager.ensurePermissionRequested();
      debugPrint('🔔 Notification permissions: ${settings.authorizationStatus}');
    } catch (e, st) {
      debugPrint('⚠️ Failed to request notification permissions: $e\n$st');
    }

    // Register background handler (only on mobile)
    if (!kIsWeb) {
      try {
        FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
        debugPrint('✅ FCM background handler registered (mobile)');
      } catch (e, st) {
        debugPrint('⚠️ Failed to register FCM background handler: $e\n$st');
      }
    } else {
      debugPrint('[FCM] background message handler skipped on web');
    }

    // Firestore settings
    try {
      FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: true, cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED);
    } catch (e) {
      debugPrint('[Firestore] settings apply failed: $e');
    }

    // Supabase
    try {
      await Supabase.initialize(
        url: 'https://qumrbpxhyxkgreoqsnis.supabase.co',
        anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF1bXJicHhoeXhrZ3Jlb3FzbmlzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDg2NzkyNDksImV4cCI6MjA2NDI1NTI0OX0.r-Scwh1gYAfMwYjh1_wjAVb66XSjvcUgPeV_CH7VkS4',
      );
      debugPrint('✅ Supabase initialized');
    } catch (e, st) {
      debugPrint('⚠️ Supabase.initialize failed: $e\n$st');
    }
  } catch (e, st) {
    debugPrint('❌ Initialization error: $e\n$st');
    rethrow;
  }

  if (enableImpeller) debugPrint('✅ Enabling Impeller rendering');
  if (enableSksl) debugPrint('✅ Enabling SKSL shader warm-up');
  if (useSoftwareRendering) debugPrint('✅ Using software rendering');

  // Listen for download updates on main isolate port.
  _port.listen((dynamic message) async {
    try {
      // Offload parsing to background isolate
      final parsed = await compute(_parseDownloaderMessage, Map<String, dynamic>.from(message));
      final taskId = parsed['id']?.toString() ?? '<unknown>';
      final statusInt = parsed['statusInt'] as int? ?? -1;

      DownloadTaskStatus status = DownloadTaskStatus.undefined;
      try {
        if (statusInt >= 0 && statusInt < DownloadTaskStatus.values.length) {
          status = DownloadTaskStatus.values[statusInt];
        }
      } catch (_) {}

      final progress = (parsed['progress'] is int) ? parsed['progress'] as int : 0;
      debugPrint('[Downloader] task=$taskId status=$status progress=$progress');
    } catch (e, st) {
      debugPrint('[Downloader] parse error: $e\n$st');
    }
  });

  // CallKit events (mobile only)
  if (!kIsWeb) {
    try {
      FlutterCallkitIncoming.onEvent.listen((event) async {
        if (event == null) return;
        final data = (event.body is Map) ? Map<String, dynamic>.from(event.body as Map) : <String, dynamic>{};
        // Normalize callkit event data in background (light CPU)
        final normData = await compute(_normalizeData, data);

        final callId = normData['id'] as String? ?? '';
        final callerId = normData['handle'] as String? ?? '';
        final extra = (normData['extra'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
        final userId = extra['userId'] as String? ?? '';
        final callType = normData['type'] == 1 ? 'video' : 'voice';

        try {
          switch (normData['event']) {
            case 'ACTION_CALL_ACCEPT':
  Map<String, dynamic>? callerData;
  Map<String, dynamic>? receiverData;
  try {
    final callerDoc = await FirebaseFirestore.instance.collection('users').doc(callerId).get();
    if (callerDoc.exists) callerData = {...callerDoc.data()!, 'id': callerDoc.id};
    final recDoc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
    if (recDoc.exists) receiverData = {...recDoc.data()!, 'id': recDoc.id};
  } catch (_) {}

  if (navigatorKey.currentState != null) {
    // Updated to match RtcManager API: acceptCall(callId: ..., userId: ...)
    await RtcManager.acceptCall(callId: callId, userId: userId);

    if (callType == 'video') {
      navigatorKey.currentState!.push(MaterialPageRoute(
        builder: (_) => VideoCallScreen1to1(
          callId: callId,
          callerId: callerId,
          receiverId: userId,
          currentUserId: userId,
          caller: callerData ?? <String, dynamic>{},
          receiver: receiverData ?? <String, dynamic>{},
        ),
      ));
    } else {
      navigatorKey.currentState!.push(MaterialPageRoute(
        builder: (_) => VoiceCallScreen1to1(
          callId: callId,
          callerId: callerId,
          receiverId: userId,
          currentUserId: userId,
          caller: callerData ?? <String, dynamic>{},
          receiver: receiverData ?? <String, dynamic>{},
        ),
      ));
    }
  }
  break;


            case 'ACTION_CALL_DECLINE':
            case 'ACTION_CALL_TIMEOUT':
              // Updated to match RtcManager API: rejectCall(callId: ..., rejectedBy: ...)
              await RtcManager.rejectCall(callId: callId, rejectedBy: userId);
              await FlutterCallkitIncoming.endAllCalls();
              break;
            default:
              break;
          }
        } catch (e) {
          debugPrint('[CallkitEvent] error handling event: $e');
        }
      });
    } catch (e) {
      debugPrint('[CallKit] onEvent listener setup failed: $e');
    }
  } else {
    debugPrint('[CallKit] skipped onEvent listener on web');
  }

  // Request CallKit permissions (mobile only) and persist full-intent permission request
  if (!kIsWeb) {
    try {
      await FlutterCallkitIncoming.requestNotificationPermission({
        "title": "Notification permission",
        "rationaleMessagePermission": "Notification permission is required to show incoming call notifications.",
        "postNotificationMessageRequired": "Please enable notifications in Settings to receive incoming calls."
      });

      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          final deviceInfo = DeviceInfoPlugin();
          final androidInfo = await deviceInfo.androidInfo;
          final sdkInt = (androidInfo.version.sdkInt ?? 0);
          debugPrint('[CallKit] Android SDK: $sdkInt');
          if (sdkInt >= 34) {
            try {
              final prefs = await SharedPreferences.getInstance();
              final already = prefs.getBool('fc_requested_full_intent') ?? false;
              if (!already) {
                final granted = await FlutterCallkitIncoming.requestFullIntentPermission();
                debugPrint('[CallKit] requestFullIntentPermission result: $granted');
                await prefs.setBool('fc_requested_full_intent', true);
              } else {
                debugPrint('[CallKit] full-intent permission already requested in past, skipping prompt');
              }
            } catch (e) {
              debugPrint('[CallKit] full-intent permission flow failed: $e');
            }
          }
        } catch (e) {
          debugPrint('[CallKit] android-specific permission flow failed: $e');
        }
      }
    } catch (e) {
      debugPrint('⚠️ CallKit permission request failed: $e');
    }
  } else {
    debugPrint('[CallKit] permission flow skipped on web');
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => SettingsProvider()),
        ChangeNotifierProvider(create: (context) => CallOverlayService()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String? _initialMessageCallId;

  @override
  void initState() {
    super.initState();
    _setupFcmTokenAndHandlers();
  }

  Future<void> _setupFcmTokenAndHandlers() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        final fcm = FirebaseMessaging.instance;

        try {
          await FcmPermissionManager.ensurePermissionRequested();
        } catch (_) {}

        // Try to grab token (App Check should already be activated)
        try {
          final token = await fcm.getToken();
          if (token != null) {
            try {
              await FirebaseFirestore.instance.collection('users').doc(userId).set({'fcmToken': token}, SetOptions(merge: true));
              debugPrint('[FCM] saved token for user $userId');
            } catch (e) {
              debugPrint('[FCM] failed saving token to firestore: $e');
            }
          } else {
            debugPrint('[FCM] getToken returned null for user $userId');
          }
        } catch (e) {
          debugPrint('[FCM] getToken error: $e');
        }

        FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
          try {
            await FirebaseFirestore.instance.collection('users').doc(userId).set({'fcmToken': newToken}, SetOptions(merge: true));
            debugPrint('[FCM] refreshed token saved');
          } catch (e) {
            debugPrint('[FCM] failed saving refreshed token: $e');
          }
        });

        FirebaseMessaging.onMessage.listen((RemoteMessage msg) async {
          debugPrint('[FCM] onMessage: ${msg.messageId} data=${msg.data} notification=${msg.notification}');
          try {
            // Normalize data in background
            final data = await compute(_normalizeData, Map<String, dynamic>.from(msg.data ?? <String, dynamic>{}));
            final title = msg.notification?.title ?? data['title'] ?? '';
            final body = msg.notification?.body ?? data['body'] ?? '';

            if ((data['type'] ?? '') == 'incoming_call') {
              // show CallKit UI and also a full-screen intent notification (Android)
              await showIncomingCallUIFromData(data);

              final androidDetails = AndroidNotificationDetails(
                incomingCallChannel.id,
                incomingCallChannel.name,
                channelDescription: incomingCallChannel.description,
                importance: Importance.max,
                priority: Priority.max,
                fullScreenIntent: true,
                category: AndroidNotificationCategory.call,
              );

              final notifDetails = NotificationDetails(android: androidDetails);
              await flutterLocalNotificationsPlugin.show(
                data.hashCode,
                title.isNotEmpty ? title : 'Incoming call',
                body.isNotEmpty ? body : 'Tap to answer',
                notifDetails,
                payload: jsonEncode(data),
              );
              return;
            }

            // Regular message: show a system notification even when app is foreground
            final androidDetails = AndroidNotificationDetails(
              messagesChannel.id,
              messagesChannel.name,
              channelDescription: messagesChannel.description,
              importance: Importance.high,
              priority: Priority.high,
              ticker: 'ticker',
            );

            final notifDetails = NotificationDetails(android: androidDetails);
            await flutterLocalNotificationsPlugin.show(
              msg.hashCode,
              title,
              body,
              notifDetails,
              payload: jsonEncode(data),
            );

            // Optional in-app SnackBar (still useful for quick glance)
            final ctx = navigatorKey.currentState?.context;
            if (ctx != null) {
              // Build a short preview in background
              final preview = await compute(_snackPreview, {'body': body, 'max': 80});
              ScaffoldMessenger.of(ctx).showSnackBar(
                SnackBar(
                  behavior: SnackBarBehavior.floating,
                  content: Text('$title\n$preview'),
                  action: SnackBarAction(
                    label: 'Open',
                    onPressed: () async {
                      if ((data['type'] ?? '') == 'message') {
                        await openChatFromNotification(data);
                      } else if ((data['type'] ?? '') == 'incoming_call') {
                        await handleIncomingCallTap(data);
                      }
                    },
                  ),
                  duration: const Duration(seconds: 6),
                ),
              );
            }
          } catch (e, st) {
            debugPrint('[FCM] onMessage processing error: $e\n$st');
          }
        });

        FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
          final data = message.data;
          debugPrint('[FCM] onMessageOpenedApp data=$data');
          if ((data['type'] ?? '') == 'incoming_call') {
            handleIncomingCallTap(data);
            return;
          }
          if ((data['type'] ?? '') == 'message') {
            openChatFromNotification(data);
            return;
          }
        });

        try {
          final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
          if (initialMessage?.data != null) {
            final data = initialMessage!.data;
            debugPrint('[FCM] getInitialMessage data=$data');
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if ((data['type'] ?? '') == 'incoming_call') {
                handleIncomingCallTap(data);
              } else if ((data['type'] ?? '') == 'message') {
                openChatFromNotification(data);
              }
            });
          }
        } catch (e) {
          debugPrint('[FCM] getInitialMessage failed (likely web or unsupported): $e');
        }
      }
    } catch (e) {
      debugPrint('[FCM] token/handler setup failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final userId = Supabase.instance.client.auth.currentUser?.id;
    Widget home = const SplashScreen();
    if (userId != null) {
      home = PresenceWrapper(userId: userId, child: const SplashScreen());
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (userId != null) {
        final callService = Provider.of<CallOverlayService>(context, listen: false);
        try {
          await callService.init(userId, navigatorKey);
        } catch (e) {
          debugPrint('[CallOverlayService] init failed: $e');
        }
        try {
          final fcmToken = await FirebaseMessaging.instance.getToken();
          if (fcmToken != null) {
            await FirebaseFirestore.instance.collection('users').doc(userId).set({'fcmToken': fcmToken}, SetOptions(merge: true));
            debugPrint('[FCM] post-frame token saved for $userId');
          } else {
            debugPrint('[FCM] post-frame getToken returned null');
          }
        } catch (e) {
          debugPrint('[FCM] post-frame token save error: $e');
        }
      }
    });

    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.dark(primary: settings.accentColor),
        appBarTheme: AppBarTheme(backgroundColor: Colors.black, foregroundColor: settings.accentColor),
        floatingActionButtonTheme: FloatingActionButtonThemeData(backgroundColor: settings.accentColor),
        bottomNavigationBarTheme: BottomNavigationBarThemeData(backgroundColor: Colors.black, selectedItemColor: settings.accentColor, unselectedItemColor: Colors.grey),
      ),
      locale: settings.getLocale(),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      initialRoute: '/',
      routes: {
        '/': (context) => home,
        '/download': (context) => const DownloadsScreen(),
      },
      onGenerateRoute: (RouteSettings routeSettings) {
        if (routeSettings.name == '/profile') {
          final args = routeSettings.arguments as Map<String, dynamic>;
          return MaterialPageRoute(builder: (context) => ProfileScreen(user: args));
        } else if (routeSettings.name == '/messages') {
          final args = routeSettings.arguments as Map<String, dynamic>;
          final user = args['user'] as Map<String, dynamic>;
          Color accentColor = Provider.of<SettingsProvider>(context, listen: false).accentColor;
          if (args['accentColor'] is Color) accentColor = args['accentColor'] as Color;
          return MaterialPageRoute(
            builder: (newContext) => ChangeNotifierProvider(create: (newCtx) => MessagesController(user, newCtx), child: MessagesScreen(currentUser: user, accentColor: accentColor)),
          );
        }
        return null;
      },
    );
  }
}
