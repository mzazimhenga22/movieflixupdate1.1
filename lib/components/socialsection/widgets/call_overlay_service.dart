// lib/services/call_overlay_service.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:movie_app/webrtc/group_rtc_manager.dart';
import 'package:movie_app/components/socialsection/VoiceCallScreen_1to1.dart';
import 'package:movie_app/components/socialsection/VideoCallScreen_1to1.dart';
// group UI imports (adjust path/names if your files differ)
import 'package:movie_app/components/socialsection/VoiceCallScreen_Group.dart';
import 'package:movie_app/components/socialsection/VideoCallScreen_Group.dart';
import 'package:uuid/uuid.dart';

/// CallOverlayService: Listens for incoming calls via Firestore and shows native call screen using flutter_callkit_incoming.
/// - Call init(userId, navigatorKey) after user login.
/// - Use debugShowTestBanner(...) to manually show a test call screen.
class CallOverlayService extends ChangeNotifier {
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subCalls;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subGroupCalls;
  StreamSubscription<dynamic>? _callKitEventSub;
  final Duration _callTimeout = const Duration(seconds: 30);
  GlobalKey<NavigatorState>? _navigatorKey;
  String? _userId;
  bool _initialized = false;

  /// Track which callIds we've already shown the native UI for to avoid duplicates.
  final Set<String> _shownCallIds = <String>{};

  Future<void> init(String userId, GlobalKey<NavigatorState> navigatorKey) async {
    debugPrint('[CallOverlayService] init: userId=$userId');

    // Avoid re-registering listeners for the same user repeatedly
    if (_initialized && _userId == userId) return;

    // Clean up prior subscriptions if any (re-init scenario)
    await _callKitEventSub?.cancel();
    _callKitEventSub = null;
    await _subCalls?.cancel();
    _subCalls = null;
    await _subGroupCalls?.cancel();
    _subGroupCalls = null;
    _shownCallIds.clear();

    _initialized = true;
    _userId = userId;
    _navigatorKey = navigatorKey;

    // Initialize CallKit event listener (store subscription so we can cancel on dispose)
    try {
      _callKitEventSub = FlutterCallkitIncoming.onEvent.listen(_handleCallKitEvent, onError: (e, st) {
        debugPrint('[CallOverlayService] CallKit onEvent error: $e\n$st');
      });
    } catch (e, st) {
      debugPrint('[CallOverlayService] Failed to subscribe to CallKit events: $e\n$st');
    }

    // Listen for Firestore 1:1 calls (ringing)
    try {
      _subCalls = FirebaseFirestore.instance
          .collection('calls')
          .where('receiverId', isEqualTo: userId)
          .where('status', isEqualTo: 'ringing')
          .snapshots()
          .listen(_onCallsSnapshot, onError: (e, st) {
        debugPrint('[CallOverlayService] calls snapshots error: $e\n$st');
      });
    } catch (e, st) {
      debugPrint('[CallOverlayService] Failed to subscribe to calls snapshots: $e\n$st');
    }

    // Listen for group calls where the user is a participant and the call is ringing
    // participants must be stored as array of ids in groupCalls docs
    try {
      _subGroupCalls = FirebaseFirestore.instance
          .collection('groupCalls')
          .where('participants', arrayContains: userId)
          .where('status', isEqualTo: 'ringing')
          .snapshots()
          .listen(_onGroupCallsSnapshot, onError: (e, st) {
        debugPrint('[CallOverlayService] groupCalls snapshots error: $e\n$st');
      });
    } catch (e, st) {
      debugPrint('[CallOverlayService] Failed to subscribe to groupCalls snapshots: $e\n$st');
    }
  }

  /// For manual testing from UI
  void debugShowTestBanner({String callerName = 'Tester', String callType = 'voice', bool group = false}) {
    final callId = const Uuid().v4();
    _showNativeCallScreen(
      callId,
      'debug-caller-id',
      callerName,
      callType,
      force: true,
      isGroup: group,
    );
  }

  void _onCallsSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    debugPrint('[CallOverlayService] calls snapshot docCount=${snap.docs.length}');
    if (snap.docs.isEmpty) {
      _endCallScreen();
      return;
    }

    // pick the first ringing call (you may want to pick by startedAt or priority)
    final doc = snap.docs.first;
    final data = doc.data();
    final callId = doc.id;
    final callerId = data['callerId'] as String? ?? '';
    final callType = data['type'] as String? ?? 'voice';
    final callerName = data['callerName'] as String? ?? 'Unknown';

    _showNativeCallScreen(callId, callerId, callerName, callType, isGroup: false);
  }

  void _onGroupCallsSnapshot(QuerySnapshot<Map<String, dynamic>> snap) async {
    debugPrint('[CallOverlayService] groupCalls snapshot docCount=${snap.docs.length}');
    if (snap.docs.isEmpty) {
      // if no ringing group calls found -> end native screens (if nothing else)
      // do not force-kill if there's a 1:1 call active; we rely on dedupe
      _endCallScreen();
      return;
    }

    // choose a suitable doc for this user (first that includes user and participantStatus isn't joined/rejected)
    for (final doc in snap.docs) {
      try {
        final data = doc.data();
        final callId = doc.id;
        final status = data['status'] as String? ?? '';
        if (status != 'ringing') continue;

        // participantStatus may be a map; check this user's entry
        final Map<String, dynamic>? participantStatus = (data['participantStatus'] as Map?)?.cast<String, dynamic>();
        final myStatus = participantStatus?[_userId] as String?;
        if (myStatus == 'joined' || myStatus == 'rejected') {
          // skip if already joined or rejected
          continue;
        }

        // host might be present as 'host'
        final hostId = data['host']?.toString() ?? '';
        final callType = (data['type'] as String?) ?? 'voice';

        // fetch host's username (best-effort)
        String callerName = 'Group Call';
        if (hostId.isNotEmpty) {
          try {
            final userDoc = await FirebaseFirestore.instance.collection('users').doc(hostId).get();
            if (userDoc.exists) {
              callerName = (userDoc.data()?['username'] as String?) ?? 'Group Call';
            }
          } catch (_) {}
        }

        // show native incoming UI for group call
        _showNativeCallScreen(callId, hostId, callerName, callType, isGroup: true);
        // show only first matching doc
        return;
      } catch (e, st) {
        debugPrint('[CallOverlayService] error processing groupCalls doc ${doc.id}: $e\n$st');
      }
    }
  }

  Future<void> _showNativeCallScreen(
    String callId,
    String callerId,
    String callerName,
    String callType, {
    bool force = false,
    bool isGroup = false,
  }) async {
    // Deduplicate: don't show the same callId twice
    if (!force && _shownCallIds.contains(callId)) {
      debugPrint('[CallOverlayService] call $callId already shown - skipping');
      return;
    }

    try {
      // Query active call list first; if there's already a native call UI, skip (unless forced)
      final currentCalls = await FlutterCallkitIncoming.activeCalls();
      if (currentCalls is List && currentCalls.isNotEmpty && !force) {
        debugPrint('[CallOverlayService] native call already active - skipping show for $callId');
        return;
      }
    } catch (e, st) {
      debugPrint('[CallOverlayService] activeCalls check failed: $e\n$st');
      // continue - attempt to show anyway
    }

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
      'extra': {
        'userId': _userId ?? '',
        'callerId': callerId,
        'isGroup': isGroup ? 'true' : 'false',
      },
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

    try {
      debugPrint('[CallOverlayService] showing CallKit incoming for callId=$callId isGroup=$isGroup');
      await FlutterCallkitIncoming.showCallkitIncoming(callKitParams);
      _shownCallIds.add(callId);
    } catch (e, st) {
      debugPrint('[CallOverlayService] showCallkitIncoming failed for $callId: $e\n$st');
    }

    // Auto-remove when status changes in Firestore (works for both calls and groupCalls)
    final collectionName = isGroup ? 'groupCalls' : 'calls';
    FirebaseFirestore.instance.collection(collectionName).doc(callId).snapshots().firstWhere((s) {
      final status = s.data()?['status'] as String?;
      return status != 'ringing';
    }).then((_) {
      _shownCallIds.remove(callId);
      _endCallScreen();
    }).catchError((e, st) {
      debugPrint('[CallOverlayService] status watch error for $callId: $e\n$st');
    });

    // Auto timeout - ensure the call doc is updated if still ringing
    Future.delayed(_callTimeout, () async {
      try {
        final doc = await FirebaseFirestore.instance.collection(collectionName).doc(callId).get();
        if (doc.exists && doc['status'] == 'ringing') {
          await _handleDecline(callId, _userId ?? '', isGroup: isGroup);
          _shownCallIds.remove(callId);
          _endCallScreen();
        }
      } catch (e, st) {
        debugPrint('[CallOverlayService] timeout handling error for $callId: $e\n$st');
      }
    });
  }

  Future<void> _endCallScreen() async {
    try {
      await FlutterCallkitIncoming.endAllCalls();
    } catch (e, st) {
      debugPrint('[CallOverlayService] endAllCalls error: $e\n$st');
    }
  }

  // CallKit event handler
  void _handleCallKitEvent(dynamic event) async {
    if (event == null) return;

    try {
      final data = event.body as Map<String, dynamic>;
      final callId = data['id'] as String? ?? '';
      final callerId = data['handle'] as String? ?? '';
      final extra = (data['extra'] as Map<String, dynamic>?) ?? {};
      final userId = extra['userId'] as String? ?? '';
      final callType = data['type'] == 1 ? 'video' : 'voice';
      final isGroup = (extra['isGroup'] == true) || (extra['isGroup']?.toString() == 'true');

      switch (data['event']) {
        case 'ACTION_CALL_ACCEPT':
          await _handleAccept(callId, callerId, callType, isGroup: isGroup);
          break;
        case 'ACTION_CALL_DECLINE':
        case 'ACTION_CALL_TIMEOUT':
          await _handleDecline(callId, userId, isGroup: isGroup);
          break;
        default:
          break;
      }
    } catch (e, st) {
      debugPrint('[CallOverlayService] CallKit event processing error: $e\n$st');
    }
  }

  Future<void> _handleAccept(String callId, String callerId, String callType, {bool isGroup = false}) async {
    debugPrint('[CallOverlayService] accept: callId=$callId isGroup=$isGroup callType=$callType');

    // Answer at the RTC layer (group vs 1:1)
    try {
      if (isGroup) {
        await GroupRtcManager.answerGroupCall(groupId: callId, peerId: _userId ?? '');
      } else {
        await RtcManager.answerCall(callId: callId, peerId: _userId ?? '');
      }
    } catch (e, st) {
      debugPrint('[CallOverlayService] Answer failed (proceeding to navigate): $e\n$st');
    }

    // Fetch caller/receiver data (best-effort)
    Map<String, dynamic>? callerData;
    Map<String, dynamic>? receiverData;
    List<Map<String, dynamic>>? participants;
    try {
      if (isGroup) {
        final doc = await FirebaseFirestore.instance.collection('groupCalls').doc(callId).get();
        if (doc.exists) {
          final data = doc.data()!;
          final hostId = data['host']?.toString() ?? callerId;
          // fetch host info
          try {
            final hostDoc = await FirebaseFirestore.instance.collection('users').doc(hostId).get();
            if (hostDoc.exists) callerData = {...?hostDoc.data(), 'id': hostDoc.id};
          } catch (_) {}
          // collect participants list (IDs). Try to fetch user docs for nicer UI
          final partIds = (data['participants'] as List?)?.map((e) => e.toString()).toList() ?? [];
          participants = [];
          for (final pid in partIds) {
            try {
              final pDoc = await FirebaseFirestore.instance.collection('users').doc(pid).get();
              if (pDoc.exists) participants.add({...?pDoc.data(), 'id': pDoc.id});
              else participants.add({'id': pid, 'username': 'Unknown'});
            } catch (_) {
              participants.add({'id': pid, 'username': 'Unknown'});
            }
          }
          // receiver info (local)
          final recDoc = await FirebaseFirestore.instance.collection('users').doc(_userId).get();
          if (recDoc.exists) receiverData = {...?recDoc.data(), 'id': recDoc.id};
        }
      } else {
        final callerDoc = await FirebaseFirestore.instance.collection('users').doc(callerId).get();
        if (callerDoc.exists) callerData = {...?callerDoc.data(), 'id': callerDoc.id};
        final recDoc = await FirebaseFirestore.instance.collection('users').doc(_userId).get();
        if (recDoc.exists) receiverData = {...?recDoc.data(), 'id': recDoc.id};
      }
    } catch (_) {}

    // Navigate to call screen if navigator available
    if (_navigatorKey?.currentState == null) return;

    try {
      if (isGroup) {
        // For group calls navigate to group UI (use VideoCallScreenGroup / VoiceCallScreen)
        if (callType == 'video') {
          _navigatorKey!.currentState!.push(MaterialPageRoute(
            builder: (_) => VideoCallScreenGroup(
              callId: callId,
              callerId: callerId,
              groupId: callId,
              participants: participants,
            ),
          ));
        } else {
          _navigatorKey!.currentState!.push(MaterialPageRoute(
            builder: (_) => VoiceCallScreen(
              callId: callId,
              callerId: callerId,
              receiverId: _userId ?? '',
              groupId: callId,
              participants: participants,
              caller: callerData,
            ),
          ));
        }
      } else {
        // 1:1
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
    } catch (e, st) {
      debugPrint('[CallOverlayService] navigation after accept failed: $e\n$st');
    }
  }

  Future<void> _handleDecline(String callId, String peerId, {bool isGroup = false}) async {
    debugPrint('[CallOverlayService] decline: callId=$callId peerId=$peerId isGroup=$isGroup');
    try {
      if (isGroup) {
        await GroupRtcManager.rejectGroupCall(groupId: callId, peerId: peerId);
      } else {
        await RtcManager.rejectCall(callId: callId, peerId: peerId);
      }
    } catch (e) {
      debugPrint('[CallOverlayService] reject failed: $e');
    } finally {
      await _endCallScreen();
      _shownCallIds.remove(callId);
    }
  }

  Future<void> disposeService() async {
    await _subCalls?.cancel();
    _subCalls = null;
    await _subGroupCalls?.cancel();
    _subGroupCalls = null;
    await _callKitEventSub?.cancel();
    _callKitEventSub = null;
    await _endCallScreen();
    _initialized = false;
    _shownCallIds.clear();
  }

  @override
  void dispose() {
    _subCalls?.cancel();
    _subGroupCalls?.cancel();
    _callKitEventSub?.cancel();
    _endCallScreen();
    super.dispose();
  }
}
