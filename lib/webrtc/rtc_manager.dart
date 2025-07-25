import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';

class RtcManager {
  static final Map<String, RTCPeerConnection> _peerConnections = {};
  static final Map<String, MediaStream> _localStreams = {};
  static final _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ]
  };

  static Future<bool> _requestPermissions({required bool video}) async {
    final permissions = <Permission>[
      Permission.microphone,
      if (video) Permission.camera,
    ];

    final statuses = await permissions.request();
    return statuses.values.every((status) => status.isGranted);
  }

  static Future<String> startVoiceCall({
    required Map<String, dynamic> caller,
    required Map<String, dynamic> receiver,
  }) async {
    final callId = const Uuid().v4();

    if (!await _requestPermissions(video: false)) {
      throw Exception("Microphone permission denied");
    }

    final localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    _localStreams[callId] = localStream;

    final pc = await createPeerConnection(_iceServers);
    _peerConnections[callId] = pc;

    localStream.getTracks().forEach((track) {
      pc.addTrack(track, localStream);
    });

    pc.onIceCandidate = (candidate) async {
      if (candidate != null) {
        await FirebaseFirestore.instance
            .collection('calls')
            .doc(callId)
            .collection('callerCandidates')
            .add(candidate.toMap());
      }
    };

    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _endCall(callId);
      }
    };

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    await FirebaseFirestore.instance.collection('calls').doc(callId).set({
      'type': 'voice',
      'callerId': caller['id'],
      'receiverId': receiver['id'],
      'timestamp': FieldValue.serverTimestamp(),
      'status': 'ongoing',
      'sdp': offer.sdp,
      'sdpType': offer.type,
    });

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

    final localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': true,
    });
    _localStreams[callId] = localStream;

    final pc = await createPeerConnection(_iceServers);
    _peerConnections[callId] = pc;

    localStream.getTracks().forEach((track) {
      pc.addTrack(track, localStream);
    });

    pc.onIceCandidate = (candidate) async {
      if (candidate != null) {
        await FirebaseFirestore.instance
            .collection('calls')
            .doc(callId)
            .collection('callerCandidates')
            .add(candidate.toMap());
      }
    };

    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _endCall(callId);
      }
    };

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    await FirebaseFirestore.instance.collection('calls').doc(callId).set({
      'type': 'video',
      'callerId': caller['id'],
      'receiverId': receiver['id'],
      'timestamp': FieldValue.serverTimestamp(),
      'status': 'ongoing',
      'sdp': offer.sdp,
      'sdpType': offer.type,
    });

    return callId;
  }

  static Future<void> answerCall(String callId) async {
    final doc = await FirebaseFirestore.instance.collection('calls').doc(callId).get();
    final data = doc.data();
    if (data == null) return;

    final isVideo = data['type'] == 'video';

    if (!await _requestPermissions(video: isVideo)) {
      throw Exception("Permission denied for answering call");
    }

    final pc = await createPeerConnection(_iceServers);
    _peerConnections[callId] = pc;

    final localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': isVideo,
    });
    _localStreams[callId] = localStream;

    localStream.getTracks().forEach((track) {
      pc.addTrack(track, localStream);
    });

    pc.onIceCandidate = (candidate) async {
      if (candidate != null) {
        await FirebaseFirestore.instance
            .collection('calls')
            .doc(callId)
            .collection('calleeCandidates')
            .add(candidate.toMap());
      }
    };

    final offer = RTCSessionDescription(data['sdp'], data['sdpType']);
    await pc.setRemoteDescription(offer);

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    await FirebaseFirestore.instance.collection('calls').doc(callId).update({
      'calleeSdp': answer.sdp,
      'calleeSdpType': answer.type,
    });

    FirebaseFirestore.instance
        .collection('calls')
        .doc(callId)
        .collection('callerCandidates')
        .snapshots()
        .listen((snapshot) {
      for (var doc in snapshot.docChanges) {
        final data = doc.doc.data();
        if (data != null) {
          final candidate = RTCIceCandidate(
            data['candidate'],
            data['sdpMid'],
            data['sdpMLineIndex'],
          );
          pc.addCandidate(candidate);
        }
      }
    });
  }

  static MediaStream? getLocalStream(String callId) {
    return _localStreams[callId];
  }

  static Future<void> _endCall(String callId) async {
    try {
      _localStreams[callId]?.getTracks().forEach((track) => track.stop());
      _localStreams.remove(callId);

      await _peerConnections[callId]?.close();
      _peerConnections.remove(callId);

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
}
