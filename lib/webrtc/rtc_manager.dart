// rtc_manager.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart' show unawaited, debugPrint;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:livekit_client/livekit_client.dart' as lk;

extension IterableExt<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// RtcManager: LiveKit + Firestore + FCM (HTTP v1) push sender.
/// - Uses a service account JSON at assets/service-account.json to obtain OAuth2 access token for FCM HTTP v1.
/// - Make sure to add that file to pubspec.yaml under flutter.assets.
///
/// NOTE: This implementation sends the "incoming_call" data payload to the receiver's FCM token.
/// The client app should handle the incoming payload (show native call screen / overlay / flutter_callkit_incoming).
class RtcManager {
  static final Map<String, lk.Room> _liveKitRooms = {};
  static final Map<String, lk.LocalParticipant?> _localParticipants = {};
  static final Map<String, Map<String, lk.RemoteParticipant>> _remoteParticipants = {};
  static final Map<String, Timer> _callTimers = {};

  // LiveKit server & token (your values)
  static const String _sfuUrl = 'wss://movieflix-cyn3yzmd.livekit.cloud';
  static const String _devToken =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3NjM0MjYwNzAsImlzcyI6IkFQSTZhVHFkYmFZOWd1ViIsIm5iZiI6MTc1NDQyNjA3MCwic3ViIjoibWF4IiwidmlkZW8iOnsiY2FuUHVibGlzaCI6dHJ1ZSwiY2FuUHVibGlzaERhdGEiOnRydWUsImNhblN1YnNjcmliZSI6dHJ1ZSwicm9vbSI6Imdyb3VwY2FsbCxjaGF0Y2FsbCIsInJvb21Kb2luIjp0cnVlfX0.KAFwOwgRpSMPoZ4xCAN7wSwGBHTq-GBjm_sdMyBMJxU';

  // NOTE: No legacy server key here. The FCM HTTP v1 call uses an OAuth2 access token created from the service account.

  static Future<bool> _requestPermissions({required bool video}) async {
    final permissions = <Permission>[
      Permission.microphone,
      if (video) Permission.camera,
    ];
    final statuses = await permissions.request();
    return statuses.values.every((status) => status.isGranted);
  }

  // ---------------------------
  // FCM HTTP v1 helpers
  // ---------------------------

  /// Loads the service account JSON from assets and returns the decoded map.
  static Future<Map<String, dynamic>> _loadServiceAccountJson() async {
    final jsonStr = await rootBundle.loadString('assets/service-account.json');
    final map = json.decode(jsonStr) as Map<String, dynamic>;
    return map;
  }

  /// Returns an OAuth2 access token string using googleapis_auth client for the FCM scope.
  static Future<String> _getAccessToken() async {
    final serviceAccount = await _loadServiceAccountJson();
    final accountCredentials = auth.ServiceAccountCredentials.fromJson(serviceAccount);
    final scopes = ['https://www.googleapis.com/auth/firebase.messaging'];

    final client = await auth.clientViaServiceAccount(accountCredentials, scopes);
    final token = client.credentials.accessToken.data;
    client.close();
    return token;
  }

  /// Sends an FCM HTTP v1 push using the service account access token.
  /// Returns true when HTTP status is 200 (OK).
  static Future<bool> _sendPushNotification(
    String callId,
    Map<String, dynamic> receiver,
    String callType,
    String callerName,
  ) async {
    final token = receiver['fcmToken'] as String?;
    if (token == null || token.isEmpty) {
      debugPrint('Push not sent: receiver FCM token is null/empty for ${receiver['id'] ?? receiver['username']}');
      return false;
    }

    try {
      final serviceAccount = await _loadServiceAccountJson();
      final projectId = serviceAccount['project_id'] as String?;
      if (projectId == null || projectId.isEmpty) {
        debugPrint('Service account JSON missing project_id');
        return false;
      }

      final accessToken = await _getAccessToken();
      final url = 'https://fcm.googleapis.com/v1/projects/$projectId/messages:send';

      final payload = {
        'message': {
          'token': token,
          'data': {
            'callId': callId,
            'callerId': receiver['id']?.toString() ?? '',
            'callerName': callerName,
            'callType': callType.toLowerCase(),
            'type': 'incoming_call',
          },
          'notification': {
            'title': 'Incoming ${callType[0].toUpperCase()}${callType.substring(1)} Call',
            'body': 'Call from $callerName',
          },
          // Android/APNs configuration blocks are optional — include as needed
          'android': {
            'priority': 'high',
            'notification': {
              'channel_id': 'calls_channel',
              'sound': 'default',
              'priority': 'high',
              // 'click_action', 'tag', etc. can be added here
            },
          },
          'apns': {
            'headers': {
              'apns-priority': '10',
            },
            'payload': {
              'aps': {
                'sound': 'default',
                'category': 'CALL',
                'content-available': 1,
              },
            },
          },
        },
      };

      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode(payload),
      );

      debugPrint('FCM HTTP v1 response: ${response.statusCode} - ${response.body}');
      return response.statusCode == 200;
    } catch (e, st) {
      debugPrint('Error sending FCM HTTP v1 push: $e\n$st');
      return false;
    }
  }

  // ---------------------------
  // Call / LiveKit logic
  // ---------------------------

  static Future<String> startVoiceCall({
    required Map<String, dynamic> caller,
    required Map<String, dynamic> receiver,
  }) async {
    final callId = const Uuid().v4();

    if (!await _requestPermissions(video: false)) {
      throw Exception("Microphone permission denied");
    }

    final room = lk.Room();
    await room.connect(_sfuUrl, _devToken, connectOptions: lk.ConnectOptions(autoSubscribe: true));
    _liveKitRooms[callId] = room;
    _localParticipants[callId] = room.localParticipant;

    final audioTrack = await lk.LocalAudioTrack.create();
    await room.localParticipant?.publishAudioTrack(audioTrack);

    room.events.listen((event) {
      if (event is lk.ParticipantConnectedEvent) {
        _remoteParticipants[callId] ??= {};
        _remoteParticipants[callId]![event.participant.identity] = event.participant;
      }
      if (event is lk.RoomDisconnectedEvent) {
        _endCall(callId, audioTrack: audioTrack);
      }
    });

    try {
      await FirebaseFirestore.instance.collection('calls').doc(callId).set({
        'type': 'voice',
        'callerId': caller['id'],
        'receiverId': receiver['id'],
        'callerName': caller['username'] ?? 'Unknown',
        'status': 'ringing',
        'startedAt': FieldValue.serverTimestamp(),
        'participantStatus': {caller['id']: 'joined', receiver['id']: 'ringing'},
        'unreadBy': [receiver['id']],
      });
    } catch (e) {
      debugPrint("Error setting call doc: $e");
      await _endCall(callId, audioTrack: audioTrack);
      throw Exception("Failed to initiate call");
    }

    // Non-blocking push send (do not await to avoid slowing UX)
    unawaited(_sendPushNotification(callId, receiver, 'voice', caller['username'] ?? 'Unknown'));

    _callTimers[callId] = Timer(const Duration(seconds: 30), () async {
      if (_liveKitRooms.containsKey(callId)) {
        try {
          final doc = await FirebaseFirestore.instance.collection('calls').doc(callId).get();
          if (doc.exists && doc['status'] == 'ringing') {
            await _endCall(callId, audioTrack: audioTrack);
            try {
              await FirebaseFirestore.instance.collection('calls').doc(callId).update({
                'status': 'missed',
                'endedAt': FieldValue.serverTimestamp(),
              });
            } catch (_) {}
          }
        } catch (e) {
          debugPrint("Error checking call status: $e");
        }
      }
    });

    _monitorNetwork(callId, room);
    return callId;
  }

  static Future<String> startVideoCall({
    required Map<String, dynamic> caller,
    required Map<String, dynamic> receiver,
  }) async {
    final callId = const Uuid().v4();

    if (!await _requestPermissions(video: true)) {
      throw Exception("Camera or microphone permission denied");
    }

    final room = lk.Room();
    await room.connect(_sfuUrl, _devToken, connectOptions: lk.ConnectOptions(autoSubscribe: true));
    _liveKitRooms[callId] = room;
    _localParticipants[callId] = room.localParticipant;

    final videoTrack = await lk.LocalVideoTrack.createCameraTrack();
    final audioTrack = await lk.LocalAudioTrack.create();
    await room.localParticipant?.publishVideoTrack(
      videoTrack,
      publishOptions: const lk.VideoPublishOptions(
        videoEncoding: lk.VideoEncoding(
          maxBitrate: 2000000,
          maxFramerate: 30,
        ),
      ),
    );
    await room.localParticipant?.publishAudioTrack(audioTrack);

    room.events.listen((event) {
      if (event is lk.ParticipantConnectedEvent) {
        _remoteParticipants[callId] ??= {};
        _remoteParticipants[callId]![event.participant.identity] = event.participant;
      }
      if (event is lk.RoomDisconnectedEvent) {
        _endCall(callId, videoTrack: videoTrack, audioTrack: audioTrack);
      }
    });

    try {
      await FirebaseFirestore.instance.collection('calls').doc(callId).set({
        'type': 'video',
        'callerId': caller['id'],
        'receiverId': receiver['id'],
        'callerName': caller['username'] ?? 'Unknown',
        'status': 'ringing',
        'startedAt': FieldValue.serverTimestamp(),
        'participantStatus': {caller['id']: 'joined', receiver['id']: 'ringing'},
        'unreadBy': [receiver['id']],
      });
    } catch (e) {
      debugPrint("Error setting call doc: $e");
      await _endCall(callId, videoTrack: videoTrack, audioTrack: audioTrack);
      throw Exception("Failed to initiate call");
    }

    unawaited(_sendPushNotification(callId, receiver, 'video', caller['username'] ?? 'Unknown'));

    _callTimers[callId] = Timer(const Duration(seconds: 30), () async {
      if (_liveKitRooms.containsKey(callId)) {
        try {
          final doc = await FirebaseFirestore.instance.collection('calls').doc(callId).get();
          if (doc.exists && doc['status'] == 'ringing') {
            await _endCall(callId, videoTrack: videoTrack, audioTrack: audioTrack);
            try {
              await FirebaseFirestore.instance.collection('calls').doc(callId).update({
                'status': 'missed',
                'endedAt': FieldValue.serverTimestamp(),
              });
            } catch (_) {}
          }
        } catch (e) {
          debugPrint("Error checking call status: $e");
        }
      }
    });

    _monitorNetwork(callId, room);
    return callId;
  }

  static Future<void> answerCall({
    required String callId,
    required String peerId,
  }) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('calls').doc(callId).get();
      if (!doc.exists || doc['status'] != 'ringing') return;

      final isVideo = doc['type'] == 'video';
      if (!await _requestPermissions(video: isVideo)) {
        throw Exception("Permissions denied");
      }

      final room = _liveKitRooms[callId] ?? lk.Room();
      await room.connect(_sfuUrl, _devToken, connectOptions: lk.ConnectOptions(autoSubscribe: true));
      _liveKitRooms[callId] = room;
      _localParticipants[callId] = room.localParticipant;

      final videoTrack = isVideo ? await lk.LocalVideoTrack.createCameraTrack() : null;
      final audioTrack = await lk.LocalAudioTrack.create();
      if (videoTrack != null) {
        await room.localParticipant?.publishVideoTrack(
          videoTrack,
          publishOptions: const lk.VideoPublishOptions(
            videoEncoding: lk.VideoEncoding(
              maxBitrate: 2000000,
              maxFramerate: 30,
            ),
          ),
        );
      }
      await room.localParticipant?.publishAudioTrack(audioTrack);

      room.events.listen((event) {
        if (event is lk.ParticipantConnectedEvent) {
          _remoteParticipants[callId] ??= {};
          _remoteParticipants[callId]![event.participant.identity] = event.participant;
        }
      });

      // Update call doc: set status answered and participant joined; remove peer from unreadBy
      await FirebaseFirestore.instance.collection('calls').doc(callId).update({
        'status': 'answered',
        'participantStatus.$peerId': 'joined',
        'unreadBy': FieldValue.arrayRemove([peerId]),
      });

      _callTimers[callId]?.cancel();
      _monitorNetwork(callId, room);
    } catch (e) {
      debugPrint("Error answering call: $e");
      throw Exception("Failed to answer call");
    }
  }

  static Future<void> rejectCall({
    required String callId,
    required String peerId,
  }) async {
    try {
      await FirebaseFirestore.instance.collection('calls').doc(callId).update({
        'status': 'rejected',
        'participantStatus.$peerId': 'rejected',
        'endedAt': FieldValue.serverTimestamp(),
        'unreadBy': FieldValue.arrayRemove([peerId]),
      });
    } catch (e) {
      debugPrint("Error rejecting call: $e");
    }
  }

  static Future<void> _endCall(String callId, {lk.LocalVideoTrack? videoTrack, lk.LocalAudioTrack? audioTrack}) async {
    try {
      final room = _liveKitRooms[callId];
      if (room != null) {
        await room.disconnect();
        final localParticipant = _localParticipants[callId];
        if (localParticipant != null) {
          await localParticipant.unpublishAllTracks();
        }
      }
      await videoTrack?.dispose();
      await audioTrack?.dispose();
      _liveKitRooms.remove(callId);
      _localParticipants.remove(callId);
      _remoteParticipants.remove(callId);
      _callTimers[callId]?.cancel();
      _callTimers.remove(callId);

      // Update Firestore doc if it still exists
      try {
        await FirebaseFirestore.instance.collection('calls').doc(callId).update({
          'status': 'ended',
          'endedAt': FieldValue.serverTimestamp(),
        });
      } catch (_) {
        // Doc may not exist or could already be updated — ignore
      }
    } catch (e) {
      debugPrint("Error ending call: $e");
    }
  }

  static Future<void> hangUp(String callId) async {
    await _endCall(callId);
  }

  static Future<void> toggleMute(String callId, bool isMuted) async {
    final lp = _localParticipants[callId];
    if (lp != null) {
      await lp.setMicrophoneEnabled(!isMuted);
    }
  }

  static Future<void> toggleVideo(String callId, bool isVideoEnabled) async {
    final lp = _localParticipants[callId];
    if (lp != null) {
      await lp.setCameraEnabled(isVideoEnabled);
    }
  }

  static Future<void> _monitorNetwork(String callId, lk.Room room) async {
    Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!_liveKitRooms.containsKey(callId)) {
        timer.cancel();
        return;
      }
      if (room.connectionState == lk.ConnectionState.disconnected) {
        await _endCall(callId);
      }
    });
  }

  static Future<void> _adjustQuality(String callId, {required bool lower}) async {
    final room = _liveKitRooms[callId];
    if (room == null) return;

    final params = lk.VideoParameters(
      dimensions: lk.VideoDimensions(640, 480),
      encoding: lk.VideoEncoding(
        maxBitrate: lower ? 300_000 : 2_000_000,
        maxFramerate: lower ? 15 : 30,
      ),
    );

    final pubs = room.localParticipant!.trackPublications.values.where((pub) => pub.kind == lk.TrackType.VIDEO);
    // Implement quality adjustments if needed with LiveKit API (not shown here)
  }

  static String? getActiveSpeaker(String callId) {
    final room = _liveKitRooms[callId];
    if (room != null) {
      final activeSpeaker = room.activeSpeakers.firstOrNull;
      return activeSpeaker?.identity;
    }
    return null;
  }

  static MediaStream? getLocalStream(String callId) {
    final localParticipant = _localParticipants[callId];
    if (localParticipant != null) {
      final audioPub = localParticipant.trackPublications.values
          .where((pub) => pub.kind == lk.TrackType.AUDIO)
          .cast<lk.LocalTrackPublication?>()
          .firstOrNull;
      return audioPub?.track?.mediaStream;
    }
    return null;
  }

  static MediaStream? getRemoteStream(String callId, String peerId) {
    final remoteParticipant = _remoteParticipants[callId]?[peerId];
    if (remoteParticipant != null) {
      final audioPub = remoteParticipant.trackPublications.values
          .where((pub) => pub.kind == lk.TrackType.AUDIO)
          .cast<lk.RemoteTrackPublication<lk.RemoteTrack>?>()
          .firstOrNull;
      return audioPub?.track?.mediaStream;
    }
    return null;
  }

  static void dispose(String callId) {
    final room = _liveKitRooms[callId];
    if (room != null) {
      room.dispose();
    }
    _liveKitRooms.remove(callId);
    _localParticipants.remove(callId);
    _remoteParticipants.remove(callId);
    _callTimers[callId]?.cancel();
    _callTimers.remove(callId);
  }
}
