// lib/main.dart
import 'dart:async';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
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
import 'package:movie_app/services/fcm_sender.dart'; // optional server-side helper

// A port to receive messages from the background isolate
final ReceivePort _port = ReceivePort();

// Global navigator key so we can push screens from overlay/service
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

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

  final data = message.data ?? <String, dynamic>{};

  // Handle incoming call data-only pushes
  if (data['type'] == 'incoming_call') {
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
        'duration': 30000,
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
      // Best-effort: show the incoming call UI (Android may allow this from background)
      await FlutterCallkitIncoming.showCallkitIncoming(params);
    } catch (e, st) {
      // Keep this benign: log error but do not perform temporary FS writes here.
      debugPrint('[BG] CallKit show failed (headless): $e\n$st');
    }
  }
}

/// Register downloader callback safely (plugin may throw if already registered)
Future<void> _safeRegisterDownloaderCallback() async {
  try {
    IsolateNameServer.registerPortWithName(_port.sendPort, 'downloader_send_port');
  } catch (_) {
    // already registered - ignore
  }
  try {
    FlutterDownloader.registerCallback(downloadCallback);
  } catch (_) {
    // ignore
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

/// Safely initialize AuthDatabase with retries for permission races
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // dart-define flags
  const enableImpeller = bool.fromEnvironment('ENABLE_IMPELLER', defaultValue: false);
  const enableSksl = bool.fromEnvironment('ENABLE_SKSL', defaultValue: false);
  const useSoftwareRendering = bool.fromEnvironment('USE_SOFTWARE_RENDERING', defaultValue: false);

  try {
    // Initialize Flutter Downloader
    await FlutterDownloader.initialize(debug: true, ignoreSsl: true);
    debugPrint('✅ FlutterDownloader initialized');

    await _safeRegisterDownloaderCallback();

    // Initialize Firebase
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    debugPrint('✅ Firebase initialized');

    // Initialize auth db safely (handles permission race)
    await _safeAuthDatabaseInitialize();
    debugPrint('✅ AuthDatabase initialized (safe)');

    // Now ensure notification permissions (serialized)
    try {
      final settings = await FcmPermissionManager.ensurePermissionRequested();
      debugPrint('🔔 Notification permissions: ${settings.authorizationStatus}');
    } catch (e, st) {
      debugPrint('⚠️ Failed to request notification permissions: $e\n$st');
    }

    // Register background handler (must be registered after Firebase init)
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    debugPrint('✅ FCM background handler registered');

    // Firestore settings
    FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: true, cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED);

    // Initialize Supabase
    await Supabase.initialize(
      url: 'https://qumrbpxhyxkgreoqsnis.supabase.co',
      anonKey:
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF1bXJicHhoeXhrZ3Jlb3FzbmlzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDg2NzkyNDksImV4cCI6MjA2NDI1NTI0OX0.r-Scwh1gYAfMwYjh1_wjAVb66XSjvcUgPeV_CH7VkS4',
    );
    debugPrint('✅ Supabase initialized');
  } catch (e, st) {
    debugPrint('❌ Initialization error: $e\n$st');
    rethrow;
  }

  if (enableImpeller) debugPrint('✅ Enabling Impeller rendering');
  if (enableSksl) debugPrint('✅ Enabling SKSL shader warm-up');
  if (useSoftwareRendering) debugPrint('✅ Using software rendering');

  // Listen for download updates
  _port.listen((dynamic message) {
    final status = message['status'] as DownloadTaskStatus;
    if (status == DownloadTaskStatus.complete) {
      DownloadsScreenState.refreshCallback?.call();
    }
  });

  // Listen for CallKit events (main isolate)
  FlutterCallkitIncoming.onEvent.listen((event) async {
    if (event == null) return;
    final data = (event.body is Map) ? Map<String, dynamic>.from(event.body as Map) : <String, dynamic>{};
    final callId = data['id'] as String? ?? '';
    final callerId = data['handle'] as String? ?? '';
    final extra = (data['extra'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final userId = extra['userId'] as String? ?? '';
    final callType = data['type'] == 1 ? 'video' : 'voice';

    try {
      switch (data['event']) {
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
            await RtcManager.answerCall(callId: callId, peerId: userId);
            if (callType == 'video') {
              navigatorKey.currentState!.push(MaterialPageRoute(
                builder: (_) => VideoCallScreen1to1(
                  callId: callId,
                  callerId: callerId,
                  receiverId: userId,
                  currentUserId: userId,
                  caller: callerData,
                  receiver: receiverData,
                ),
              ));
            } else {
              navigatorKey.currentState!.push(MaterialPageRoute(
                builder: (_) => VoiceCallScreen1to1(
                  callId: callId,
                  callerId: callerId,
                  receiverId: userId,
                  currentUserId: userId,
                  caller: callerData,
                  receiver: receiverData,
                ),
              ));
            }
          }
          break;

        case 'ACTION_CALL_DECLINE':
        case 'ACTION_CALL_TIMEOUT':
          await RtcManager.rejectCall(callId: callId, peerId: userId);
          await FlutterCallkitIncoming.endAllCalls();
          break;
        default:
          break;
      }
    } catch (e) {
      debugPrint('[CallkitEvent] error handling event: $e');
    }
  });

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

/// This is invoked by the native downloader isolate when status/progress changes.
@pragma('vm:entry-point')
void downloadCallback(String id, int status, int progress) {
  final SendPort? send = IsolateNameServer.lookupPortByName('downloader_send_port');
  send?.send({
    'id': id,
    'status': DownloadTaskStatus.values[status],
    'progress': progress,
  });
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

        final token = await fcm.getToken();
        if (token != null) {
          try {
            await FirebaseFirestore.instance.collection('users').doc(userId).set({'fcmToken': token}, SetOptions(merge: true));
            debugPrint('[FCM] saved token for user $userId');
          } catch (e) {
            debugPrint('[FCM] failed saving token: $e');
          }
        }

        FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
          try {
            await FirebaseFirestore.instance.collection('users').doc(userId).set({'fcmToken': newToken}, SetOptions(merge: true));
            debugPrint('[FCM] refreshed token saved');
          } catch (e) {
            debugPrint('[FCM] failed saving refreshed token: $e');
          }
        });

        FirebaseMessaging.onMessage.listen((RemoteMessage msg) {
          debugPrint('[FCM] onMessage: ${msg.messageId} data=${msg.data}');
          // Optionally show in-app banner / routing here
        });

        FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
          final data = message.data;
          if (data['type'] == 'incoming_call') {
            _handleIncomingCallTap(data);
          }
        });

        final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
        if (initialMessage?.data != null) {
          final data = initialMessage!.data;
          if (data['type'] == 'incoming_call') _handleIncomingCallTap(data);
        }
      }
    } catch (e) {
      debugPrint('[FCM] token/handler setup failed: $e');
    }
  }

  void _handleIncomingCallTap(Map<String, dynamic> data) {
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
            caller: null,
            receiver: null,
          ),
        ));
      } else {
        navigatorKey.currentState!.push(MaterialPageRoute(
          builder: (_) => VoiceCallScreen1to1(
            callId: callId,
            callerId: callerId,
            receiverId: receiverId,
            currentUserId: receiverId,
            caller: null,
            receiver: null,
          ),
        ));
      }
    } else {
      _initialMessageCallId = callId;
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
        await callService.init(userId, navigatorKey);
        try {
          final fcmToken = await FirebaseMessaging.instance.getToken();
          if (fcmToken != null) {
            await FirebaseFirestore.instance.collection('users').doc(userId).set({'fcmToken': fcmToken}, SetOptions(merge: true));
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
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: settings.accentColor,
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: settings.accentColor,
        ),
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: Colors.black,
          selectedItemColor: settings.accentColor,
          unselectedItemColor: Colors.grey,
        ),
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
          return MaterialPageRoute(
            builder: (context) => ProfileScreen(user: args),
          );
        } else if (routeSettings.name == '/messages') {
          final args = routeSettings.arguments as Map<String, dynamic>;
          final user = args['user'] as Map<String, dynamic>;
          final accentColor = args['accentColor'] as Color? ?? Provider.of<SettingsProvider>(context).accentColor;
          return MaterialPageRoute(
            builder: (newContext) => ChangeNotifierProvider(
              create: (newCtx) => MessagesController(user, newCtx),
              child: MessagesScreen(
                currentUser: user,
                accentColor: accentColor,
              ),
            ),
          );
        }
        return null;
      },
    );
  }
}

