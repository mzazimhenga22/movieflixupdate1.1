import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';
import 'package:livekit_client/livekit_client.dart' as lk;

// Extension for null-safe firstOrNull
extension IterableExt<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class GroupRtcManager {
  static final Map<String, lk.Room> _liveKitRooms = {};
  static final Map<String, lk.LocalParticipant?> _localParticipants = {};
  static final Map<String, Map<String, lk.RemoteParticipant>> _remoteParticipants = {};
  static final Map<String, Timer> _callTimers = {};
  static const String _sfuUrl = 'wss://movieflix-cyn3yzmd.livekit.cloud';
  static const String _devToken = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3NjM0MjYwNzAsImlzcyI6IkFQSTZhVHFkYmFZOWd1ViIsIm5iZiI6MTc1NDQyNjA3MCwic3ViIjoibWF4IiwidmlkZW8iOnsiY2FuUHVibGlzaCI6dHJ1ZSwiY2FuUHVibGlzaERhdGEiOnRydWUsImNhblN1YnNjcmliZSI6dHJ1ZSwicm9vbSI6Imdyb3VwY2FsbCxjaGF0Y2FsbCIsInJvb21Kb2luIjp0cnVlfX0.KAFwOwgRpSMPoZ4xCAN7wSwGBHTq-GBjm_sdMyBMJxU'; // Replace with a pre-generated JWT from LiveKit Console
  static const String _pushySecretKey = 'cbfb2627ea2ff4c7aae398ab3d8ebb350b7afc57fc2aa7323d1d9200ba585644';

  static Future<bool> _requestPermissions({required bool video}) async {
    final permissions = <Permission>[
      Permission.microphone,
      if (video) Permission.camera,
    ];
    final statuses = await permissions.request();
    return statuses.values.every((status) => status.isGranted);
  }

  static Future<void> _sendPushNotification(String groupId, List<Map<String, dynamic>> participants) async {
    const pushyUrl = 'https://api.pushy.me/push';

    for (var participant in participants) {
      final token = participant['token'];
      final username = participant['username'];

      final response = await http.post(
        Uri.parse(pushyUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Secret $_pushySecretKey',
        },
        body: jsonEncode({
          'to': token,
          'data': {
            'title': 'Incoming Group Call',
            'message': 'You have an incoming call from $username',
            'groupId': groupId,
          },
          'notification': {
            'title': 'Incoming Group Call',
            'body': 'You have an incoming call from $username',
          },
        }),
      );

      if (response.statusCode != 200) {
        debugPrint('Failed to send Pushy notification to $username: ${response.body}');
      }
    }
  }

  static Future<String> startGroupCall({
    required Map<String, dynamic> caller,
    required List<Map<String, dynamic>> participants,
    required bool isVideo,
  }) async {
    final groupId = const Uuid().v4();

    if (!await _requestPermissions(video: isVideo)) {
      throw Exception("Permissions denied");
    }

    final room = lk.Room();
    await room.connect(_sfuUrl, _devToken, connectOptions: lk.ConnectOptions(autoSubscribe: true));
    _liveKitRooms[groupId] = room;
    _localParticipants[groupId] = room.localParticipant;

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
        _remoteParticipants[groupId] ??= {};
        _remoteParticipants[groupId]![event.participant.identity] = event.participant;
      }
      if (event is lk.RoomDisconnectedEvent) {
        _endCall(groupId, videoTrack: videoTrack, audioTrack: audioTrack);
      }
    });

    try {
      await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).set({
        'groupId': groupId,
        'host': caller['id'],
        'type': isVideo ? 'video' : 'voice',
        'participants': participants.map((p) => p['id']).toList(),
        'status': 'ringing',
        'startedAt': FieldValue.serverTimestamp(),
        'participantStatus': {caller['id']: 'joined'},
      });
    } catch (e) {
      debugPrint("Error setting group call: $e");
      await _endCall(groupId, videoTrack: videoTrack, audioTrack: audioTrack);
      throw Exception("Failed to initiate call");
    }

    _sendPushNotification(groupId, participants);

    _callTimers[groupId] = Timer(const Duration(seconds: 30), () async {
      if (_liveKitRooms.containsKey(groupId)) {
        try {
          final doc = await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).get();
          if (doc.exists && doc['status'] == 'ringing') {
            await _endCall(groupId, videoTrack: videoTrack, audioTrack: audioTrack);
          }
        } catch (e) {
          debugPrint("Error checking call status: $e");
        }
      }
    });

    _monitorNetwork(groupId, room);
    return groupId;
  }

  static Future<void> answerGroupCall({
    required String groupId,
    required String peerId,
  }) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).get();
      if (!doc.exists || doc['status'] != 'ringing') return;

      final isVideo = doc['type'] == 'video';
      if (!await _requestPermissions(video: isVideo)) {
        throw Exception("Permissions denied");
      }

      final room = _liveKitRooms[groupId] ?? lk.Room();
      await room.connect(_sfuUrl, _devToken, connectOptions: lk.ConnectOptions(autoSubscribe: true));
      _liveKitRooms[groupId] = room;
      _localParticipants[groupId] = room.localParticipant;

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
          _remoteParticipants[groupId] ??= {};
          _remoteParticipants[groupId]![event.participant.identity] = event.participant;
        }
      });

      await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).update({
        'status': 'answered',
        'participantStatus.$peerId': 'joined',
      });

      _callTimers[groupId]?.cancel();
      _monitorNetwork(groupId, room);
    } catch (e) {
      debugPrint("Error answering group call: $e");
      throw Exception("Failed to answer call");
    }
  }

  static Future<void> rejectGroupCall({
    required String groupId,
    required String peerId,
  }) async {
    try {
      await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).update({
        'participantStatus.$peerId': 'rejected',
        'endedAt': FieldValue.serverTimestamp(),
      });
      final doc = await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).get();
      if (doc.exists && doc['participantStatus'].values.every((status) => status == 'rejected')) {
        await _endCall(groupId);
      }
    } catch (e) {
      debugPrint("Error rejecting group call: $e");
    }
  }

  static Future<void> _endCall(String groupId, {lk.LocalVideoTrack? videoTrack, lk.LocalAudioTrack? audioTrack}) async {
    try {
      final room = _liveKitRooms[groupId];
      if (room != null) {
        await room.disconnect();
        final localParticipant = _localParticipants[groupId];
        if (localParticipant != null) {
          await localParticipant.unpublishAllTracks();
        }
      }
      await videoTrack?.dispose();
      await audioTrack?.dispose();
      _liveKitRooms.remove(groupId);
      _localParticipants.remove(groupId);
      _remoteParticipants.remove(groupId);
      _callTimers[groupId]?.cancel();
      _callTimers.remove(groupId);

      await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).update({
        'status': 'ended',
        'endedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint("Error ending call: $e");
    }
  }

  static Future<void> hangUpGroupCall(String groupId) async {
    await _endCall(groupId);
  }

  static Future<void> toggleMute(String groupId, bool isMuted) async {
    final lp = _localParticipants[groupId];
    if (lp != null) {
      await lp.setMicrophoneEnabled(!isMuted);
    }
  }

  static Future<void> toggleVideo(String groupId, bool isVideoEnabled) async {
    final lp = _localParticipants[groupId];
    if (lp != null) {
      await lp.setCameraEnabled(isVideoEnabled);
    }
  }

  static Future<void> _monitorNetwork(String groupId, lk.Room room) async {
    Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!_liveKitRooms.containsKey(groupId)) {
        timer.cancel();
        return;
      }
      if (room.connectionState == lk.ConnectionState.disconnected) {
        await _endCall(groupId);
      }
    });
  }

  static Future<void> _adjustQuality(String groupId, {required bool lower}) async {
    // LiveKit doesn't support dynamic encoding updates post-publish.
    // To change quality, unpublish + republish the track.
    final room = _liveKitRooms[groupId];
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

  static String? getActiveSpeaker(String groupId) {
    final room = _liveKitRooms[groupId];
    if (room != null) {
      final activeSpeaker = room.activeSpeakers.firstOrNull;
      return activeSpeaker?.identity;
    }
    return null;
  }

  static MediaStream? getLocalStream(String groupId) {
    final localParticipant = _localParticipants[groupId];
    if (localParticipant != null) {
      final audioPub = localParticipant.trackPublications.values
          .where((pub) => pub.kind == lk.TrackType.AUDIO)
          .cast<lk.LocalTrackPublication?>()
          .firstOrNull;

      return audioPub?.track?.mediaStream;
    }
    return null;
  }

  static MediaStream? getRemoteStream(String groupId, String peerId) {
    final remoteParticipant = _remoteParticipants[groupId]?[peerId];
    if (remoteParticipant != null) {
      final audioPub = remoteParticipant.trackPublications.values
          .where((pub) => pub.kind == lk.TrackType.AUDIO)
          .cast<lk.RemoteTrackPublication<lk.RemoteTrack>?>()
          .firstOrNull;

      return audioPub?.track?.mediaStream;
    }
    return null;
  }

  static void dispose(String groupId) {
    final room = _liveKitRooms[groupId];
    if (room != null) {
      room.dispose();
    }
    _liveKitRooms.remove(groupId);
    _localParticipants.remove(groupId);
    _remoteParticipants.remove(groupId);
    _callTimers[groupId]?.cancel();
    _callTimers.remove(groupId);
  }
}