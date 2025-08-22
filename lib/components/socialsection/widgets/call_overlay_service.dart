import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:movie_app/components/socialsection/VoiceCallScreen_1to1.dart';
import 'package:movie_app/components/socialsection/VideoCallScreen_1to1.dart';
import 'package:uuid/uuid.dart';

/// CallOverlayService: Listens for incoming calls via Firestore and shows native call screen using flutter_callkit_incoming.
/// - Call init(userId, navigatorKey) after user login.
/// - Use debugShowTestBanner(...) to manually show a test call screen.
class CallOverlayService extends ChangeNotifier {
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  final Duration _callTimeout = const Duration(seconds: 30);
  GlobalKey<NavigatorState>? _navigatorKey;
  String? _userId;
  bool _initialized = false;

  Future<void> init(String userId, GlobalKey<NavigatorState> navigatorKey) async {
    debugPrint('[CallOverlayService] init: userId=$userId');

    if (_initialized && _userId == userId) return;

    _initialized = true;
    _userId = userId;
    _navigatorKey = navigatorKey;

    // Initialize CallKit event listener
    FlutterCallkitIncoming.onEvent.listen(_handleCallKitEvent);

    // Listen for Firestore call updates
    await _sub?.cancel();
    _sub = FirebaseFirestore.instance
        .collection('calls')
        .where('receiverId', isEqualTo: userId)
        .where('status', isEqualTo: 'ringing')
        .snapshots()
        .listen(_onCallsSnapshot, onError: (e, st) {
      debugPrint('[CallOverlayService] snapshots error: $e\n$st');
    });
  }

  /// For manual testing from UI
  void debugShowTestBanner({String callerName = 'Tester', String callType = 'voice'}) {
    _showNativeCallScreen(
      const Uuid().v4(),
      'debug-caller-id',
      callerName,
      callType,
      force: true,
    );
  }

  void _onCallsSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    debugPrint('[CallOverlayService] snapshot docCount=${snap.docs.length}');
    if (snap.docs.isEmpty) {
      _endCallScreen();
      return;
    }

    final doc = snap.docs.first;
    final data = doc.data();
    final callId = doc.id;
    final callerId = data['callerId'] as String? ?? '';
    final callType = data['type'] as String? ?? 'voice';
    final callerName = data['callerName'] as String? ?? 'Unknown';

    _showNativeCallScreen(callId, callerId, callerName, callType);
  }

  Future<void> _showNativeCallScreen(
    String callId,
    String callerId,
    String callerName,
    String callType, {
    bool force = false,
  }) async {
    // Query active call list first
    final currentCalls = await FlutterCallkitIncoming.activeCalls();
    if (currentCalls is List && currentCalls.isNotEmpty && !force) return;

    // Build params using the current package API
    final callKitParams = CallKitParams.fromJson({
      'id': callId,
      'nameCaller': callerName,
      'appName': 'MovieApp',
      'handle': callerId,
      'type': callType == 'video' ? 1 : 0,
      'textAccept': 'Accept',
      'textDecline': 'Decline',
      'duration': _callTimeout.inMilliseconds,
      'extra': {'userId': _userId ?? '', 'callerId': callerId},
      'headers': <String, dynamic>{},
      'android': {
        'isCustomNotification': true,
        'isShowLogo': false,
        'ringtonePath': 'system_ringtone_default',
        'backgroundColor': '#0955fa',
        'actionColor': '#4CAF50',
        'textColor': '#ffffff',
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

    // Show the native incoming call UI
    await FlutterCallkitIncoming.showCallkitIncoming(callKitParams);

    // Auto-remove when status changes in Firestore
    FirebaseFirestore.instance.collection('calls').doc(callId).snapshots().firstWhere((s) {
      final status = s.data()?['status'] as String?;
      return status != 'ringing';
    }).then((_) => _endCallScreen());

    // Auto timeout
    Future.delayed(_callTimeout, () async {
      final doc = await FirebaseFirestore.instance.collection('calls').doc(callId).get();
      if (doc.exists && doc['status'] == 'ringing') {
        await _handleDecline(callId, _userId ?? '');
        _endCallScreen();
      }
    });
  }

  Future<void> _endCallScreen() async {
    await FlutterCallkitIncoming.endAllCalls();
  }

  // CallKit event handler
  void _handleCallKitEvent(dynamic event) async {
    if (event == null) return;

    final data = event.body as Map<String, dynamic>;
    final callId = data['id'] as String? ?? '';
    final callerId = data['handle'] as String? ?? '';
    final extra = data['extra'] as Map<String, dynamic>? ?? {};
    final userId = extra['userId'] as String? ?? '';
    final callType = data['type'] == 1 ? 'video' : 'voice';

    switch (data['event']) {
      case 'ACTION_CALL_ACCEPT':
        await _handleAccept(callId, callerId, callType);
        break;
      case 'ACTION_CALL_DECLINE':
      case 'ACTION_CALL_TIMEOUT':
        await _handleDecline(callId, userId);
        break;
      default:
        break;
    }
  }

  Future<void> _handleAccept(String callId, String callerId, String callType) async {
    // Answer the call at RTC layer
    await RtcManager.answerCall(callId: callId, peerId: _userId ?? '');

    // Fetch caller/receiver data
    Map<String, dynamic>? callerData;
    Map<String, dynamic>? receiverData;
    try {
      final callerDoc = await FirebaseFirestore.instance.collection('users').doc(callerId).get();
      if (callerDoc.exists) callerData = {...callerDoc.data()!, 'id': callerDoc.id};
      final recDoc = await FirebaseFirestore.instance.collection('users').doc(_userId).get();
      if (recDoc.exists) receiverData = {...recDoc.data()!, 'id': recDoc.id};
    } catch (_) {}

    // Navigate to call screen
    if (_navigatorKey?.currentState == null) return;

    if (callType == 'video') {
      _navigatorKey!.currentState!.push(MaterialPageRoute(
        builder: (_) => VideoCallScreen1to1(
          callId: callId,
          callerId: callerId,
          receiverId: _userId ?? '',
          currentUserId: _userId ?? '',
          caller: callerData,
          receiver: receiverData,
        ),
      ));
    } else {
      _navigatorKey!.currentState!.push(MaterialPageRoute(
        builder: (_) => VoiceCallScreen1to1(
          callId: callId,
          callerId: callerId,
          receiverId: _userId ?? '',
          currentUserId: _userId ?? '',
          caller: callerData,
          receiver: receiverData,
        ),
      ));
    }
  }

  Future<void> _handleDecline(String callId, String peerId) async {
    await RtcManager.rejectCall(callId: callId, peerId: peerId);
    await _endCallScreen();
  }

  Future<void> disposeService() async {
    await _sub?.cancel();
    await _endCallScreen();
    _initialized = false;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _endCallScreen();
    super.dispose();
  }
}