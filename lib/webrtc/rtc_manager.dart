import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';
import 'package:livekit_client/livekit_client.dart' as lk;

extension IterableExt<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class RtcManager {
  static final Map<String, lk.Room> _liveKitRooms = {};
  static final Map<String, lk.LocalParticipant?> _localParticipants = {};
  static final Map<String, Map<String, lk.RemoteParticipant>> _remoteParticipants = {};
  static final Map<String, Timer> _callTimers = {};
  static const String _sfuUrl = 'wss://movieflix-cyn3yzmd.livekit.cloud';
  static const String _devToken = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3NjM0MjYwNzAsImlzcyI6IkFQSTZhVHFkYmFZOWd1ViIsIm5iZiI6MTc1NDQyNjA3MCwic3ViIjoibWF4IiwidmlkZW8iOnsiY2FuUHVibGlzaCI6dHJ1ZSwiY2FuUHVibGlzaERhdGEiOnRydWUsImNhblN1YnNjcmliZSI6dHJ1ZSwicm9vbSI6Imdyb3VwY2FsbCxjaGF0Y2FsbCIsInJvb21Kb2luIjp0cnVlfX0.KAFwOwgRpSMPoZ4xCAN7wSwGBHTq-GBjm_sdMyBMJxU';
  static const String _pushySecretKey = 'cbfb2627ea2ff4c7aae398ab3d8ebb350b7afc57fc2aa7323d1d9200ba585644';

  static Future<bool> _requestPermissions({required bool video}) async {
    final permissions = <Permission>[
      Permission.microphone,
      if (video) Permission.camera,
    ];
    final statuses = await permissions.request();
    return statuses.values.every((status) => status.isGranted);
  }

  static Future<void> _sendPushNotification(String callId, Map<String, dynamic> receiver, String callType, String callerName) async {
    const pushyUrl = 'https://api.pushy.me/push';
    final token = receiver['token'];

    final response = await http.post(
      Uri.parse(pushyUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Secret $_pushySecretKey',
      },
      body: jsonEncode({
        'to': token,
        'data': {
          'callId': callId,
          'callType': callType,
          'callerName': callerName,
          'action': 'incoming_call',
        },
        'notification': {
          'title': 'Incoming $callType Call',
          'body': 'Call from $callerName',
          'sound': 'ringtone.caf',
          'priority': 'high',
          'content_available': true,
          'mutable_content': true,
        },
        'ios': {
          'badge': 1,
          'sound': 'ringtone.caf',
          'category': 'call',
        },
        'android': {
          'priority': 'high',
          'sound': 'raw/ringtone',
        },
      }),
    );

    if (response.statusCode != 200) {
      debugPrint('Failed to send Pushy notification to ${receiver['username']}: ${response.body}');
    }
  }

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
        'status': 'ringing',
        'startedAt': FieldValue.serverTimestamp(),
        'participantStatus': {caller['id']: 'joined'},
      });
    } catch (e) {
      debugPrint("Error setting call: $e");
      await _endCall(callId, audioTrack: audioTrack);
      throw Exception("Failed to initiate call");
    }

    _sendPushNotification(callId, receiver, 'Voice', caller['username'] ?? 'Unknown');

    _callTimers[callId] = Timer(const Duration(seconds: 30), () async {
      if (_liveKitRooms.containsKey(callId)) {
        try {
          final doc = await FirebaseFirestore.instance.collection('calls').doc(callId).get();
          if (doc.exists && doc['status'] == 'ringing') {
            await _endCall(callId, audioTrack: audioTrack);
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
        'status': 'ringing',
        'startedAt': FieldValue.serverTimestamp(),
        'participantStatus': {caller['id']: 'joined'},
      });
    } catch (e) {
      debugPrint("Error setting call: $e");
      await _endCall(callId, videoTrack: videoTrack, audioTrack: audioTrack);
      throw Exception("Failed to initiate call");
    }

    _sendPushNotification(callId, receiver, 'Video', caller['username'] ?? 'Unknown');

    _callTimers[callId] = Timer(const Duration(seconds: 30), () async {
      if (_liveKitRooms.containsKey(callId)) {
        try {
          final doc = await FirebaseFirestore.instance.collection('calls').doc(callId).get();
          if (doc.exists && doc['status'] == 'ringing') {
            await _endCall(callId, videoTrack: videoTrack, audioTrack: audioTrack);
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

      await FirebaseFirestore.instance.collection('calls').doc(callId).update({
        'status': 'answered',
        'participantStatus.$peerId': 'joined',
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

      await FirebaseFirestore.instance.collection('calls').doc(callId).update({
        'status': 'ended',
        'endedAt': FieldValue.serverTimestamp(),
      });
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

    final pubs = room.localParticipant!.trackPublications.values
        .where((pub) => pub.kind == lk.TrackType.VIDEO);
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