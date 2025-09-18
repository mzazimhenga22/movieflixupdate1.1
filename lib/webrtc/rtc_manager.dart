// rtc_manager.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show unawaited, debugPrint;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:movie_app/services/fcm_sender.dart';

/// RtcManager: LiveKit + Firestore + FCM (via backend sendFcmPush).
class RtcManager {
  static final Map<String, lk.Room> _liveKitRooms = {};
  static final Map<String, lk.LocalParticipant?> _localParticipants = {};
  static final Map<String, Map<String, lk.RemoteParticipant>> _remoteParticipants = {};
  static final Map<String, Timer> _callTimers = {};

  // LiveKit server & token (your values)
  static const String _sfuUrl = 'wss://movieflix-cyn3yzmd.livekit.cloud';
  static const String _devToken =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3NjM0MjYwNzAsImlzcyI6IkFQSTZhVHFkYmFZOWd1ViIsIm5iZiI6MTc1NDQyNjA3MCwic3ViIjoibWF4IiwidmlkZW8iOnsiY2FuUHVibGlzaCI6dHJ1ZSwiY2FuUHVibGlzaERhdGEiOnRydWUsImNhblN1YnNjcmliZSI6dHJ1ZSwicm9vbSI6Imdyb3VwY2FsbCxjaGF0Y2FsbCIsInJvb21Kb2luIjp0cnVlfX0.KAFwOwgRpSMPoZ4xCAN7wSwGBHTq-GBjm_sdMyBMJxU';

  static Future<bool> _requestPermissions({required bool video}) async {
    final permissions = <Permission>[
      Permission.microphone,
      if (video) Permission.camera,
    ];
    final statuses = await permissions.request();
    return statuses.values.every((status) => status.isGranted);
  }

  static Future<bool> _checkPermissionsNoPrompt({required bool video}) async {
    final mic = await Permission.microphone.status;
    if (!mic.isGranted) return false;
    if (video) {
      final cam = await Permission.camera.status;
      if (!cam.isGranted) return false;
    }
    return true;
  }

  // ---------------------------
  // Note: FCM sending is delegated to the backend via sendFcmPush
  // ---------------------------

  // ---------------------------
  // Call / LiveKit logic
  // ---------------------------

  static Future<String> startVoiceCall({
    required Map<String, dynamic> caller,
    required Map<String, dynamic> receiver,
  }) async {
    final callId = const Uuid().v4();

    if (!await _checkPermissionsNoPrompt(video: false)) {
      throw Exception("Microphone permission denied (request via UI first)");
    }

    final room = lk.Room();
    try {
      await room.connect(_sfuUrl, _devToken, connectOptions: lk.ConnectOptions(autoSubscribe: true));
    } catch (e, st) {
      debugPrint('[RtcManager] connect error (voice): $e\n$st');
      rethrow;
    }
    _liveKitRooms[callId] = room;
    _localParticipants[callId] = room.localParticipant;

    _registerParticipantsAndEvents(callId, room);

    final audioTrack = await lk.LocalAudioTrack.create();
    await room.localParticipant?.publishAudioTrack(audioTrack);

    room.events.listen((event) {
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

    // send push via backend
    try {
      final token = (receiver['fcmToken'] ?? receiver['token'])?.toString() ?? '';
      if (token.isNotEmpty) {
        final extra = {
          'callId': callId,
          'callerId': caller['id']?.toString() ?? '',
          'callerName': caller['username'] ?? '',
          'callType': 'voice',
          'type': 'incoming_call',
          'receiverId': receiver['id']?.toString() ?? '',
        };
        unawaited(sendFcmPush(
          fcmToken: token,
          title: 'Incoming Voice Call',
          body: '${caller['username'] ?? 'Someone'} is calling',
          extraData: extra,
          notification: true,
          androidChannelId: 'incoming_call',
        ));
      } else {
        debugPrint('[RtcManager] no fcm token for receiver ${receiver['id']} - skipping push');
      }
    } catch (e, st) {
      debugPrint('[RtcManager] sendFcmPush error (voice): $e\n$st');
    }

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

    if (!await _checkPermissionsNoPrompt(video: true)) {
      throw Exception("Camera or microphone permission denied (request via UI first)");
    }

    final room = lk.Room();
    try {
      await room.connect(_sfuUrl, _devToken, connectOptions: lk.ConnectOptions(autoSubscribe: true));
    } catch (e, st) {
      debugPrint('[RtcManager] connect error (video): $e\n$st');
      rethrow;
    }
    _liveKitRooms[callId] = room;
    _localParticipants[callId] = room.localParticipant;

    _registerParticipantsAndEvents(callId, room);

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

    // send push via backend
    try {
      final token = (receiver['fcmToken'] ?? receiver['token'])?.toString() ?? '';
      if (token.isNotEmpty) {
        final extra = {
          'callId': callId,
          'callerId': caller['id']?.toString() ?? '',
          'callerName': caller['username'] ?? '',
          'callType': 'video',
          'type': 'incoming_call',
          'receiverId': receiver['id']?.toString() ?? '',
        };
        unawaited(sendFcmPush(
          fcmToken: token,
          title: 'Incoming Video Call',
          body: '${caller['username'] ?? 'Someone'} is calling',
          extraData: extra,
          notification: true,
          androidChannelId: 'incoming_call',
        ));
      } else {
        debugPrint('[RtcManager] no fcm token for receiver ${receiver['id']} - skipping push');
      }
    } catch (e, st) {
      debugPrint('[RtcManager] sendFcmPush error (video): $e\n$st');
    }

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
      if (!await _checkPermissionsNoPrompt(video: isVideo)) {
        throw Exception("Permissions denied - request them from UI first");
      }

      final room = lk.Room();
      try {
        await room.connect(_sfuUrl, _devToken, connectOptions: lk.ConnectOptions(autoSubscribe: true));
      } catch (e, st) {
        debugPrint('[RtcManager] connect error during answer: $e\n$st');
        rethrow;
      }
      _liveKitRooms[callId] = room;
      _localParticipants[callId] = room.localParticipant;

      _registerParticipantsAndEvents(callId, room);

      final lk.LocalVideoTrack? videoTrack = isVideo ? await lk.LocalVideoTrack.createCameraTrack() : null;
      final lk.LocalAudioTrack audioTrack = await lk.LocalAudioTrack.create();

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
        'unreadBy': FieldValue.arrayRemove([peerId]),
      });

      await Future.delayed(const Duration(milliseconds: 300));
      _callTimers[callId]?.cancel();
      _monitorNetwork(callId, room);
    } catch (e, st) {
      debugPrint("Error answering call: $e\n$st");
      rethrow;
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
        try {
          await room.disconnect();
        } catch (e) {
          debugPrint('[RtcManager] disconnect error: $e');
        }
        final localParticipant = _localParticipants[callId];
        if (localParticipant != null) {
          try {
            await localParticipant.unpublishAllTracks();
          } catch (e) {
            debugPrint('[RtcManager] unpublishAllTracks error: $e');
          }
        }
      }
      await videoTrack?.dispose();
      await audioTrack?.dispose();
      _liveKitRooms.remove(callId);
      _localParticipants.remove(callId);
      _remoteParticipants.remove(callId);
      _callTimers[callId]?.cancel();
      _callTimers.remove(callId);

      try {
        await FirebaseFirestore.instance.collection('calls').doc(callId).update({
          'status': 'ended',
          'endedAt': FieldValue.serverTimestamp(),
        });
      } catch (_) {}
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
      try {
        if (room.connectionState == lk.ConnectionState.disconnected) {
          await _endCall(callId);
        }
      } catch (e) {
        debugPrint('[RtcManager] monitorNetwork error: $e');
      }
    });
  }

  static Future<void> _adjustQuality(String callId, {required bool lower}) async {
    final room = _liveKitRooms[callId];
    if (room == null) return;
    // implementation left intentionally minimal (device-specific adjustments may be needed)
  }

  static String? getActiveSpeaker(String callId) {
    final room = _liveKitRooms[callId];
    if (room != null) {
      final activeSpeaker = room.activeSpeakers.firstOrNull;
      return activeSpeaker?.identity;
    }
    return null;
  }

  static MediaStream? getLocalVideoStream(String callId) {
    final localParticipant = _localParticipants[callId];
    if (localParticipant == null) return null;
    try {
      for (final pub in localParticipant.trackPublications.values) {
        if (pub.kind == lk.TrackType.VIDEO && pub.track != null) {
          return pub.track?.mediaStream;
        }
      }
    } catch (_) {}
    return null;
  }

  static MediaStream? getLocalAudioStream(String callId) {
    final localParticipant = _localParticipants[callId];
    if (localParticipant == null) return null;
    try {
      for (final pub in localParticipant.trackPublications.values) {
        if (pub.kind == lk.TrackType.AUDIO && pub.track != null) {
          return pub.track?.mediaStream;
        }
      }
    } catch (_) {}
    return null;
  }

  static MediaStream? getLocalStream(String callId) => getLocalVideoStream(callId);

  static MediaStream? getRemoteVideoStream(String callId, String peerId) {
    final participant = _remoteParticipants[callId]?[peerId];
    if (participant == null) return null;
    try {
      for (final pub in participant.trackPublications.values) {
        if (pub.kind == lk.TrackType.VIDEO && pub.track != null) {
          return pub.track?.mediaStream;
        }
      }
    } catch (_) {}
    return null;
  }

  static MediaStream? getRemoteAudioStream(String callId, String peerId) {
    final participant = _remoteParticipants[callId]?[peerId];
    if (participant == null) return null;
    try {
      for (final pub in participant.trackPublications.values) {
        if (pub.kind == lk.TrackType.AUDIO && pub.track != null) {
          return pub.track?.mediaStream;
        }
      }
    } catch (_) {}
    return null;
  }

  static MediaStream? getAnyRemoteVideoStream(String callId) {
    final map = _remoteParticipants[callId];
    if (map == null) return null;
    for (final p in map.values) {
      try {
        for (final pub in p.trackPublications.values) {
          if (pub.kind == lk.TrackType.VIDEO && pub.track != null) {
            return pub.track?.mediaStream;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  static void _registerParticipantsAndEvents(String callId, lk.Room room) {
    try {
      _remoteParticipants[callId] ??= {};
      for (final p in room.remoteParticipants.values) {
        _remoteParticipants[callId]![p.identity] = p;
      }

      debugPrint('[RtcManager] connected to room: ${room.name} local=${room.localParticipant?.identity}');
      debugPrint('[RtcManager] existing participants: ${room.remoteParticipants.keys.toList()}');

      room.events.listen((event) {
        try {
          if (event is lk.ParticipantConnectedEvent) {
            _remoteParticipants[callId] ??= {};
            _remoteParticipants[callId]![event.participant.identity] = event.participant;
            debugPrint('[RtcManager] participant connected: ${event.participant.identity}');
          } else if (event is lk.TrackSubscribedEvent) {
            _remoteParticipants[callId] ??= {};
            _remoteParticipants[callId]![event.participant.identity] = event.participant;
            debugPrint('[RtcManager] track subscribed for participant: ${event.participant.identity}');
          } else if (event is lk.TrackUnsubscribedEvent) {
            debugPrint('[RtcManager] track unsubscribed for participant: ${event.participant.identity}');
          } else if (event is lk.RoomDisconnectedEvent) {
            debugPrint('[RtcManager] room disconnected for call $callId');
            _endCall(callId);
          }
        } catch (e, st) {
          debugPrint('[RtcManager] room.events handler error: $e\n$st');
        }
      });
    } catch (e, st) {
      debugPrint('[RtcManager] _registerParticipantsAndEvents error: $e\n$st');
    }
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

extension IterableFirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
