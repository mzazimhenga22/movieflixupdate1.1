// lib/webrtc/rtc_manager.dart
// RtcManager with dual-mode operation (LiveKit preferred, Firestore P2P fallback).
// Fixed analyzer issues: removed StreamZip, cleaned candidate subscriptions,
// removed unnecessary casts/unused vars, and made onError handlers void.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import 'package:movie_app/services/fcm_sender.dart';

class RtcManager {
  // -------- LiveKit state (existing) --------
  static final Map<String, lk.Room> _liveKitRooms = {};
  static final Map<String, lk.LocalParticipant?> _localParticipants = {};
  static final Map<String, Map<String, lk.RemoteParticipant>> _remoteParticipants = {};
  static final Map<String, Timer> _callTimers = {};
  static final Map<String, int> _reconnectAttempts = {};

  // -------- P2P (Firestore signaling) state --------
  static final Map<String, RTCPeerConnection> _p2pPeerConnections = {};
  static final Map<String, MediaStream?> _p2pLocalStreams = {};
  static final Map<String, MediaStream?> _p2pRemoteStreams = {};
  // store candidate subscriptions as a list (we listen to two subcollections per call)
  static final Map<String, List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>> _p2pCandidateSubs = {};
  static final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?> _p2pDocSubs = {};

  // LiveKit config (preferably set server-side)
  static const String _sfuUrl = 'wss://movieflix-cyn3yzmd.livekit.cloud';
  static const String _devToken = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3NjM0MjYwNzAsImlzcyI6IkFQSTZhVHFkYmFZOWd1ViIsIm5iZiI6MTc1NDQyNjA3MCwic3ViIjoibWF4IiwidmlkZW8iOnsiY2FuUHVibGlzaCI6dHJ1ZSwiY2FuUHVibGlzaERhdGEiOnRydWUsImNhblN1YnNjcmliZSI6dHJ1ZSwicm9vbSI6Imdyb3VwY2FsbCxjaGF0Y2FsbCIsInJvb21Kb2luIjp0cnVlfX0.KAFwOwgRpSMPoZ4xCAN7wSwGBHTq-GBjm_sdMyBMJxU';

  static String _presencePath(String userId) => 'presence/$userId';

  static Future<bool> _userIsOnline(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance.doc(_presencePath(userId)).get();
      if (!doc.exists) return false;
      final data = doc.data();
      return (data?['state'] == 'online');
    } catch (e) {
      debugPrint('[RtcManager] presence check error: $e');
      return true; // optimistic fallback
    }
  }

  static bool _hasLiveKitToken() {
    final t = _devToken.trim();
    if (t.isEmpty) return false;
    if (t.contains('<REPLACE') || t.toLowerCase().contains('replace')) return false;
    return true;
  }

  // ------------------- Public API -------------------

  static Future<String> startVideoCall({required Map<String, dynamic> caller, required Map<String, dynamic> receiver}) async {
    if (_hasLiveKitToken()) {
      return _startVideoCallLiveKit(caller: caller, receiver: receiver);
    } else {
      return _startP2PCall(caller: caller, receiver: receiver, isVideo: true);
    }
  }

  static Future<String> startVoiceCall({required Map<String, dynamic> caller, required Map<String, dynamic> receiver}) async {
    if (_hasLiveKitToken()) {
      return _startVoiceCallLiveKit(caller: caller, receiver: receiver);
    } else {
      return _startP2PCall(caller: caller, receiver: receiver, isVideo: false);
    }
  }

  static Future<void> answerCall({required String callId, required String peerId}) async {
    if (_hasLiveKitToken()) {
      return _answerCallLiveKit(callId: callId, peerId: peerId);
    } else {
      return _answerP2PCall(callId: callId, peerId: peerId);
    }
  }

  static Future<void> rejectCall({required String callId, required String peerId}) async {
    try {
      await FirebaseFirestore.instance.collection('calls').doc(callId).update({
        'status': 'rejected',
        'participantStatus.$peerId': 'rejected',
        'endedAt': FieldValue.serverTimestamp(),
        'unreadBy': FieldValue.arrayRemove([peerId]),
      });
    } catch (e) {
      debugPrint('[RtcManager] rejectCall error: $e');
    }
    await _endCall(callId);
  }

  static Future<void> hangUp(String callId) async {
    await _endCall(callId);
  }

  static Future<void> toggleMute(String callId, bool isMuted) async {
    final lp = _localParticipants[callId];
    if (lp != null) {
      try {
        await lp.setMicrophoneEnabled(!isMuted);
        return;
      } catch (e) {
        debugPrint('[RtcManager] LiveKit toggleMute error: $e');
      }
    }
    final pc = _p2pPeerConnections[callId];
    if (pc != null) {
      try {
        final tracks = _p2pLocalStreams[callId]?.getAudioTracks();
        for (final t in tracks ?? []) {
          t.enabled = !isMuted;
        }
      } catch (e) {
        debugPrint('[RtcManager] P2P toggleMute error: $e');
      }
    }
  }

  static Future<void> toggleVideo(String callId, bool isVideoEnabled) async {
    final lp = _localParticipants[callId];
    if (lp != null) {
      try {
        await lp.setCameraEnabled(isVideoEnabled);
        return;
      } catch (e) {
        debugPrint('[RtcManager] LiveKit toggleVideo error: $e');
      }
    }
    final stream = _p2pLocalStreams[callId];
    if (stream != null) {
      try {
        final tracks = stream.getVideoTracks();
        for (final t in tracks) t.enabled = isVideoEnabled;
      } catch (e) {
        debugPrint('[RtcManager] P2P toggleVideo error: $e');
      }
    }
  }

  static Future<void> setSpeakerphone(String callId, bool enabled) async {
    debugPrint('[RtcManager] setSpeakerphone($enabled) called (stub). Implement platform channel for routing.');
  }

  // -------------------- LiveKit implementation --------------------

  static Future<String> _startVideoCallLiveKit({required Map<String, dynamic> caller, required Map<String, dynamic> receiver}) async {
    final callId = const Uuid().v4();
    final receiverOnline = await _userIsOnline(receiver['id']?.toString() ?? '');

    final room = lk.Room();
    try {
      await room.connect(_sfuUrl, _devToken, connectOptions: lk.ConnectOptions(autoSubscribe: true));
    } catch (e, st) {
      debugPrint('[RtcManager] connect error (startVideoCall): $e\n$st');
      rethrow;
    }

    _liveKitRooms[callId] = room;
    _localParticipants[callId] = room.localParticipant;
    _registerParticipantsAndEvents(callId, room);

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
        'receiverOnline': receiverOnline,
      });
    } catch (e) {
      debugPrint('[RtcManager] error creating call doc: $e');
      await _endCall(callId);
      rethrow;
    }

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
        sendFcmPush(
          fcmToken: token,
          title: 'Incoming Video Call',
          body: '${caller['username'] ?? 'Someone'} is calling',
          extraData: extra,
          notification: true,
          androidChannelId: 'incoming_call',
        ).catchError((e, st) {
          debugPrint('[RtcManager] sendFcmPush error: $e\n$st');
        });
      }
    } catch (e, st) {
      debugPrint('[RtcManager] sendFcmPush wrapper error: $e\n$st');
    }

    _callTimers[callId] = Timer(const Duration(seconds: 35), () async {
      if (_liveKitRooms.containsKey(callId)) {
        try {
          final doc = await FirebaseFirestore.instance.collection('calls').doc(callId).get();
          if (doc.exists && doc['status'] == 'ringing') {
            await FirebaseFirestore.instance.collection('calls').doc(callId).update({'status': 'missed', 'endedAt': FieldValue.serverTimestamp()});
            await _endCall(callId);
          }
        } catch (e) {
          debugPrint('[RtcManager] call timeout handler error: $e');
        }
      }
    });

    _monitorNetwork(callId, room);
    return callId;
  }

  static Future<String> _startVoiceCallLiveKit({required Map<String, dynamic> caller, required Map<String, dynamic> receiver}) async {
    final callId = const Uuid().v4();
    final receiverOnline = await _userIsOnline(receiver['id']?.toString() ?? '');

    final room = lk.Room();
    try {
      await room.connect(_sfuUrl, _devToken, connectOptions: lk.ConnectOptions(autoSubscribe: true));
    } catch (e, st) {
      debugPrint('[RtcManager] connect error (startVoiceCall): $e\n$st');
      rethrow;
    }

    _liveKitRooms[callId] = room;
    _localParticipants[callId] = room.localParticipant;
    _registerParticipantsAndEvents(callId, room);

    try {
      final audioTrack = await lk.LocalAudioTrack.create();
      await room.localParticipant?.publishAudioTrack(audioTrack);
    } catch (e) {
      debugPrint('[RtcManager] publish audio during startVoiceCall error: $e');
    }

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
        'receiverOnline': receiverOnline,
      });
    } catch (e) {
      debugPrint('[RtcManager] error creating voice call doc: $e');
      await _endCall(callId);
      rethrow;
    }

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
        sendFcmPush(
          fcmToken: token,
          title: 'Incoming Voice Call',
          body: '${caller['username'] ?? 'Someone'} is calling',
          extraData: extra,
          notification: true,
          androidChannelId: 'incoming_call',
        ).catchError((e, st) {
          debugPrint('[RtcManager] sendFcmPush error: $e\n$st');
        });
      }
    } catch (e, st) {
      debugPrint('[RtcManager] sendFcmPush wrapper error: $e\n$st');
    }

    _callTimers[callId] = Timer(const Duration(seconds: 35), () async {
      if (_liveKitRooms.containsKey(callId)) {
        try {
          final doc = await FirebaseFirestore.instance.collection('calls').doc(callId).get();
          if (doc.exists && doc['status'] == 'ringing') {
            await FirebaseFirestore.instance.collection('calls').doc(callId).update({'status': 'missed', 'endedAt': FieldValue.serverTimestamp()});
            await _endCall(callId);
          }
        } catch (e) {
          debugPrint('[RtcManager] voice call timeout handler error: $e');
        }
      }
    });

    _monitorNetwork(callId, room);
    return callId;
  }

  static Future<void> _answerCallLiveKit({required String callId, required String peerId}) async {
    try {
      final docSnapshot = await FirebaseFirestore.instance.collection('calls').doc(callId).get();
      if (!docSnapshot.exists) return;
      final doc = docSnapshot.data()!;
      if (doc['status'] != 'ringing') return;

      final isVideo = doc['type'] == 'video';

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

      if (isVideo) {
        try {
          final videoTrack = await lk.LocalVideoTrack.createCameraTrack();
          await room.localParticipant?.publishVideoTrack(
            videoTrack,
            publishOptions: const lk.VideoPublishOptions(videoEncoding: lk.VideoEncoding(maxBitrate: 2000000, maxFramerate: 30)),
          );
        } catch (e) {
          debugPrint('[RtcManager] publish video during answer error: $e');
        }
      }
      try {
        final audioTrack = await lk.LocalAudioTrack.create();
        await room.localParticipant?.publishAudioTrack(audioTrack);
      } catch (e) {
        debugPrint('[RtcManager] publish audio during answer error: $e');
      }

      await FirebaseFirestore.instance.collection('calls').doc(callId).update({
        'status': 'answered',
        'participantStatus.$peerId': 'joined',
        'unreadBy': FieldValue.arrayRemove([peerId]),
      });

      _callTimers[callId]?.cancel();
      _callTimers.remove(callId);

      _monitorNetwork(callId, room);
    } catch (e, st) {
      debugPrint('[RtcManager] answerCall error: $e\n$st');
      rethrow;
    }
  }

  // -------------------- Firestore P2P signaling implementation --------------------

  static final Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ]
  };

  static Future<String> _startP2PCall({required Map<String, dynamic> caller, required Map<String, dynamic> receiver, required bool isVideo}) async {
    final callId = const Uuid().v4();
    final callRef = FirebaseFirestore.instance.collection('calls').doc(callId);

    final receiverOnline = await _userIsOnline(receiver['id']?.toString() ?? '');

    try {
      await callRef.set({
        'type': isVideo ? 'video' : 'voice',
        'callerId': caller['id'],
        'receiverId': receiver['id'],
        'callerName': caller['username'] ?? 'Unknown',
        'status': 'ringing',
        'startedAt': FieldValue.serverTimestamp(),
        'participantStatus': {caller['id']: 'joined', receiver['id']: 'ringing'},
        'unreadBy': [receiver['id']],
        'receiverOnline': receiverOnline,
      });
    } catch (e) {
      debugPrint('[RtcManager] _startP2PCall set doc error: $e');
      rethrow;
    }

    try {
      final token = (receiver['fcmToken'] ?? receiver['token'])?.toString() ?? '';
      if (token.isNotEmpty) {
        final extra = {
          'callId': callId,
          'callerId': caller['id']?.toString() ?? '',
          'callerName': caller['username'] ?? '',
          'callType': isVideo ? 'video' : 'voice',
          'type': 'incoming_call',
          'receiverId': receiver['id']?.toString() ?? '',
        };
        sendFcmPush(
          fcmToken: token,
          title: 'Incoming ${isVideo ? 'Video' : 'Voice'} Call',
          body: '${caller['username'] ?? 'Someone'} is calling',
          extraData: extra,
          notification: true,
          androidChannelId: 'incoming_call',
        ).catchError((e, st) {
          debugPrint('[RtcManager] sendFcmPush error: $e\n$st');
        });
      }
    } catch (e, st) {
      debugPrint('[RtcManager] sendFcmPush wrapper error: $e\n$st');
    }

    try {
      final pc = await _createPeerConnection(callId, isCaller: true, enableVideo: isVideo);
      _p2pPeerConnections[callId] = pc;

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      final offerMap = {'sdp': offer.sdp, 'type': offer.type};
      await callRef.update({'offer': offerMap});

      // subscribe to candidate streams (both caller and callee collections)
      _subscribeP2PCandidates(callId);

      // listen for answer and remote end
      _p2pDocSubs[callId] = callRef.snapshots().listen((snap) async {
        final data = snap.data();
        if (data == null) return;
        if (data.containsKey('answer') && data['answer'] != null) {
          final ans = data['answer'] as Map<String, dynamic>;
          final desc = RTCSessionDescription(ans['sdp'] as String?, ans['type'] as String?);
          try {
            await pc.setRemoteDescription(desc);
            debugPrint('[RtcManager] P2P offer set & remote answer applied for $callId');
          } catch (e) {
            debugPrint('[RtcManager] P2P setRemoteDescription answer error: $e');
          }
        }
        if (data['status'] != null && (data['status'] == 'ended' || data['status'] == 'rejected' || data['status'] == 'missed')) {
          await _endCall(callId);
        }
      }, onError: (e) {
        debugPrint('[RtcManager] p2p doc snap listen error: $e');
      });
    } catch (e) {
      debugPrint('[RtcManager] _startP2PCall error: $e');
      await _endCall(callId);
      rethrow;
    }

    _callTimers[callId] = Timer(const Duration(seconds: 35), () async {
      try {
        final snap = await callRef.get();
        if (snap.exists && snap.data()?['status'] == 'ringing') {
          await callRef.update({'status': 'missed', 'endedAt': FieldValue.serverTimestamp()});
          await _endCall(callId);
        }
      } catch (e) {
        debugPrint('[RtcManager] p2p call timeout error: $e');
      }
    });

    return callId;
  }

  static Future<void> _answerP2PCall({required String callId, required String peerId}) async {
    final callRef = FirebaseFirestore.instance.collection('calls').doc(callId);
    try {
      final snap = await callRef.get();
      if (!snap.exists) return;
      final data = snap.data();
      if (data == null) return;
      if (data['status'] != 'ringing') return;

      final isVideo = (data['type'] == 'video');

      final pc = await _createPeerConnection(callId, isCaller: false, enableVideo: isVideo);
      _p2pPeerConnections[callId] = pc;

      if (data.containsKey('offer') && data['offer'] != null) {
        final offer = data['offer'] as Map<String, dynamic>;
        final desc = RTCSessionDescription(offer['sdp'] as String?, offer['type'] as String?);
        await pc.setRemoteDescription(desc);
      } else {
        debugPrint('[RtcManager] answerP2PCall: no offer present for $callId');
      }

      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      final answerMap = {'sdp': answer.sdp, 'type': answer.type};

      await callRef.update({
        'status': 'answered',
        'answer': answerMap,
        'participantStatus.$peerId': 'joined',
        'unreadBy': FieldValue.arrayRemove([peerId]),
      });

      _subscribeP2PCandidates(callId);

      _p2pDocSubs[callId] = callRef.snapshots().listen((snap) async {
        final d = snap.data();
        if (d == null) return;
        if (d['status'] != null && (d['status'] == 'ended' || d['status'] == 'rejected' || d['status'] == 'missed')) {
          await _endCall(callId);
        }
      }, onError: (e) {
        debugPrint('[RtcManager] p2p answer doc listen error: $e');
      });
    } catch (e) {
      debugPrint('[RtcManager] _answerP2PCall error: $e');
      await _endCall(callId);
      rethrow;
    }
  }

  static Future<RTCPeerConnection> _createPeerConnection(String callId, {required bool isCaller, required bool enableVideo}) async {
    final pc = await createPeerConnection(_rtcConfig, {});

    MediaStream? localStream;
    try {
      final mediaConstraints = <String, dynamic>{
        'audio': true,
        'video': enableVideo
            ? {
                'facingMode': 'user',
                'width': {'ideal': 640},
                'height': {'ideal': 480},
                'frameRate': {'ideal': 30}
              }
            : false
      };
      localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      _p2pLocalStreams[callId] = localStream;

      for (final t in localStream.getTracks()) {
        await pc.addTrack(t, localStream);
      }
    } catch (e) {
      debugPrint('[RtcManager] getUserMedia error: $e');
    }

    pc.onTrack = (RTCTrackEvent event) {
      try {
        if (event.streams.isNotEmpty) {
          _p2pRemoteStreams[callId] = event.streams[0];
          debugPrint('[RtcManager] P2P remote stream set for $callId');
        }
      } catch (e) {
        debugPrint('[RtcManager] onTrack error: $e');
      }
    };

    pc.onIceCandidate = (RTCIceCandidate candidate) async {
      try {
        final callRef = FirebaseFirestore.instance.collection('calls').doc(callId);
        final data = await callRef.get();
        if (!data.exists) return;
        final collectionDoc = isCaller ? 'caller' : 'callee';
        await callRef.collection('candidates').doc(collectionDoc).collection('items').add({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
          'timestamp': FieldValue.serverTimestamp()
        });
      } catch (e) {
        debugPrint('[RtcManager] onIceCandidate push error: $e');
      }
    };

    pc.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('[RtcManager] P2P connection state for $callId: $state');
    };

    return pc;
  }

  static void _subscribeP2PCandidates(String callId) {
    final callRef = FirebaseFirestore.instance.collection('calls').doc(callId);

    final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>> subs = [];

    final subCaller = callRef.collection('candidates').doc('caller').collection('items').snapshots().listen((snap) {
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final d = change.doc.data();
          if (d == null) continue;
          final candidate = d['candidate'] as String?;
          final sdpMid = d['sdpMid'] as String?;
          final sdpMLineIndex = d['sdpMLineIndex'];
          if (candidate != null) {
            final pc = _p2pPeerConnections[callId];
            if (pc != null) {
              try {
                pc.addCandidate(RTCIceCandidate(candidate, sdpMid, sdpMLineIndex is int ? sdpMLineIndex : null));
              } catch (e) {
                debugPrint('[RtcManager] addCandidate caller error: $e');
              }
            }
          }
        }
      }
    }, onError: (e) {
      debugPrint('[RtcManager] candidate sub caller error: $e');
    });
    subs.add(subCaller);

    final subCallee = callRef.collection('candidates').doc('callee').collection('items').snapshots().listen((snap) {
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final d = change.doc.data();
          if (d == null) continue;
          final candidate = d['candidate'] as String?;
          final sdpMid = d['sdpMid'] as String?;
          final sdpMLineIndex = d['sdpMLineIndex'];
          if (candidate != null) {
            final pc = _p2pPeerConnections[callId];
            if (pc != null) {
              try {
                pc.addCandidate(RTCIceCandidate(candidate, sdpMid, sdpMLineIndex is int ? sdpMLineIndex : null));
              } catch (e) {
                debugPrint('[RtcManager] addCandidate callee error: $e');
              }
            }
          }
        }
      }
    }, onError: (e) {
      debugPrint('[RtcManager] candidate sub callee error: $e');
    });
    subs.add(subCallee);

    // Save subs for later cancellation
    _p2pCandidateSubs[callId] = subs;
  }

  // -------------------- Cleanup / monitoring --------------------

  static Future<void> _endCall(String callId) async {
    try {
      final room = _liveKitRooms[callId];
      if (room != null) {
        try {
          await room.disconnect();
        } catch (e) {
          debugPrint('[RtcManager] disconnect error: $e');
        }
      }
    } catch (e) {
      debugPrint('[RtcManager] LiveKit _endCall error: $e');
    }

    _liveKitRooms.remove(callId);
    _localParticipants.remove(callId);
    _remoteParticipants.remove(callId);

    try {
      final pc = _p2pPeerConnections.remove(callId);
      try {
        await pc?.close();
      } catch (_) {}
      final local = _p2pLocalStreams.remove(callId);
      try {
        await local?.dispose();
      } catch (_) {}
      _p2pRemoteStreams.remove(callId);

      final subs = _p2pCandidateSubs.remove(callId);
      if (subs != null) {
        for (final s in subs) {
          try {
            await s.cancel();
          } catch (_) {}
        }
      }

      try {
        await _p2pDocSubs[callId]?.cancel();
      } catch (_) {}
      _p2pDocSubs.remove(callId);
    } catch (e) {
      debugPrint('[RtcManager] P2P cleanup error: $e');
    }

    try {
      _callTimers[callId]?.cancel();
    } catch (_) {}
    _callTimers.remove(callId);

    try {
      final docRef = FirebaseFirestore.instance.collection('calls').doc(callId);
      final snap = await docRef.get();
      if (snap.exists) {
        await docRef.update({'status': 'ended', 'endedAt': FieldValue.serverTimestamp()});
      }
    } catch (_) {}
  }

  static void _monitorNetwork(String callId, lk.Room room) {
    _reconnectAttempts[callId] = 0;
    Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!_liveKitRooms.containsKey(callId)) {
        timer.cancel();
        return;
      }
      try {
        final state = room.connectionState;
        if (state == lk.ConnectionState.reconnecting) {
          debugPrint('[RtcManager] room reconnecting for $callId');
        }
        if (state == lk.ConnectionState.disconnected) {
          timer.cancel();
          await _attemptReconnect(callId);
        }
      } catch (e) {
        debugPrint('[RtcManager] monitorNetwork error: $e');
      }
    });
  }

  static Future<void> _attemptReconnect(String callId) async {
    final attempts = (_reconnectAttempts[callId] ?? 0) + 1;
    _reconnectAttempts[callId] = attempts;
    final int maxBackoff = 30;
    final base = pow(2, attempts).toInt();
    final jitter = Random().nextInt(base + 1);
    final backoffSeconds = (min(maxBackoff, base + jitter)).clamp(2, maxBackoff);
    final backoff = Duration(seconds: backoffSeconds);
    debugPrint('[RtcManager] attempting reconnect #$attempts for $callId after $backoff');
    await Future.delayed(backoff);

    try {
      final docSnapshot = await FirebaseFirestore.instance.collection('calls').doc(callId).get();
      if (!docSnapshot.exists) return;
      final status = docSnapshot['status'] as String?;
      if (status == 'ended' || status == 'missed' || status == 'rejected') return;
    } catch (e) {
      debugPrint('[RtcManager] reconnect check error: $e');
    }

    try {
      final room = lk.Room();
      await room.connect(_sfuUrl, _devToken, connectOptions: lk.ConnectOptions(autoSubscribe: true));
      _liveKitRooms[callId] = room;
      _localParticipants[callId] = room.localParticipant;
      _registerParticipantsAndEvents(callId, room);
      _monitorNetwork(callId, room);
      _reconnectAttempts.remove(callId);
      debugPrint('[RtcManager] reconnect success for $callId');
    } catch (e) {
      debugPrint('[RtcManager] reconnect failed for $callId: $e');
      if ((_reconnectAttempts[callId] ?? 0) < 6) {
        await _attemptReconnect(callId);
      } else {
        debugPrint('[RtcManager] max reconnect attempts reached for $callId - ending call');
        await _endCall(callId);
      }
    }
  }

static void _registerParticipantsAndEvents(String callId, lk.Room room) {
  try {
    _remoteParticipants[callId] ??= {};
    for (final p in room.remoteParticipants.values) {
      _remoteParticipants[callId]![p.identity] = p;
    }

    // LiveKit Room.events exposes a custom listen; keep a single handler and handle errors inside.
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
        debugPrint('[RtcManager] room event handler error: $e\n$st');
      }
    });
  } catch (e, st) {
    debugPrint('[RtcManager] _registerParticipantsAndEvents error: $e\n$st');
  }
}

  // -------------------- Helpers for UI (work for both modes) --------------------

  static lk.LocalParticipant? getLocalParticipant(String callId) => _localParticipants[callId];

  static MediaStream? getLocalVideoStream(String callId) {
    final local = _localParticipants[callId];
    if (local != null) {
      try {
        for (final pub in local.trackPublications.values) {
          if (pub.kind == lk.TrackType.VIDEO && pub.track != null) return pub.track?.mediaStream;
        }
      } catch (_) {}
    }
    final p2p = _p2pLocalStreams[callId];
    if (p2p != null) return p2p;
    return null;
  }

  static MediaStream? getRemoteVideoStream(String callId, String peerId) {
    final map = _remoteParticipants[callId];
    if (map != null) {
      final participant = map[peerId];
      if (participant != null) {
        try {
          for (final pub in participant.trackPublications.values) {
            if (pub.kind == lk.TrackType.VIDEO && pub.track != null) return pub.track?.mediaStream;
          }
        } catch (_) {}
      }
    }
    final p2pRemote = _p2pRemoteStreams[callId];
    if (p2pRemote != null) return p2pRemote;
    return null;
  }

  static MediaStream? getAnyRemoteVideoStream(String callId) {
    final map = _remoteParticipants[callId];
    if (map != null) {
      for (final p in map.values) {
        try {
          for (final pub in p.trackPublications.values) {
            if (pub.kind == lk.TrackType.VIDEO && pub.track != null) return pub.track?.mediaStream;
          }
        } catch (_) {}
      }
    }
    final p2p = _p2pRemoteStreams[callId];
    if (p2p != null) return p2p;
    return null;
  }

  static MediaStream? getRemoteAudioStream(String callId, String peerId) {
    final map = _remoteParticipants[callId];
    if (map != null) {
      final participant = map[peerId];
      if (participant != null) {
        try {
          for (final pub in participant.trackPublications.values) {
            if (pub.kind == lk.TrackType.AUDIO && pub.track != null) return pub.track?.mediaStream;
          }
        } catch (_) {}
      }
    }
    final p2p = _p2pRemoteStreams[callId];
    if (p2p != null) return p2p;
    return null;
  }

  static MediaStream? getAnyRemoteAudioStream(String callId) {
    final map = _remoteParticipants[callId];
    if (map != null) {
      for (final p in map.values) {
        try {
          for (final pub in p.trackPublications.values) {
            if (pub.kind == lk.TrackType.AUDIO && pub.track != null) return pub.track?.mediaStream;
          }
        } catch (_) {}
      }
    }
    final p2p = _p2pRemoteStreams[callId];
    if (p2p != null) return p2p;
    return null;
  }
}
