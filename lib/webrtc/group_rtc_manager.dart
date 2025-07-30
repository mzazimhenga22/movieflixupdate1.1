import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';

class GroupRtcManager {
  static final Map<String, Map<String, RTCPeerConnection>> _groupPeerConnections = {};
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

  static Future<String> startGroupCall({
    required Map<String, dynamic> caller,
    required List<Map<String, dynamic>> participants,
    required bool isVideo,
  }) async {
    final groupId = const Uuid().v4();

    if (!await _requestPermissions(video: isVideo)) {
      throw Exception("Permissions denied");
    }

    final localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': isVideo,
    });
    _localStreams[groupId] = localStream;

    for (final participant in participants) {
      final peerId = participant['id'];
      final pc = await createPeerConnection(_iceServers);
      _groupPeerConnections[groupId] ??= {};
      _groupPeerConnections[groupId]![peerId] = pc;

      localStream.getTracks().forEach((track) {
        pc.addTrack(track, localStream);
      });

      pc.onIceCandidate = (candidate) async {
        if (candidate != null) {
          await FirebaseFirestore.instance
              .collection('groupCalls')
              .doc(groupId)
              .collection('participants')
              .doc(peerId)
              .collection('callerCandidates')
              .add(candidate.toMap());
        }
      };

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      await FirebaseFirestore.instance
          .collection('groupCalls')
          .doc(groupId)
          .collection('participants')
          .doc(peerId)
          .set({
        'callerId': caller['id'],
        'peerId': peerId,
        'sdp': offer.sdp,
        'sdpType': offer.type,
        'status': 'invited',
        'timestamp': FieldValue.serverTimestamp(),
      });
    }

    await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).set({
      'groupId': groupId,
      'host': caller['id'],
      'type': isVideo ? 'video' : 'voice',
      'participants': participants.map((p) => p['id']).toList(),
      'status': 'ongoing',
      'startedAt': FieldValue.serverTimestamp(),
    });

    return groupId;
  }

  static Future<void> answerGroupCall({
    required String groupId,
    required String peerId,
  }) async {
    final localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': true, // Could be dynamically fetched
    });
    _localStreams[groupId] = localStream;

    final pc = await createPeerConnection(_iceServers);
    _groupPeerConnections[groupId] ??= {};
    _groupPeerConnections[groupId]![peerId] = pc;

    localStream.getTracks().forEach((track) {
      pc.addTrack(track, localStream);
    });

    final peerDoc = await FirebaseFirestore.instance
        .collection('groupCalls')
        .doc(groupId)
        .collection('participants')
        .doc(peerId)
        .get();

    final offer = RTCSessionDescription(peerDoc['sdp'], peerDoc['sdpType']);
    await pc.setRemoteDescription(offer);

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    await FirebaseFirestore.instance
        .collection('groupCalls')
        .doc(groupId)
        .collection('participants')
        .doc(peerId)
        .update({
      'calleeSdp': answer.sdp,
      'calleeSdpType': answer.type,
      'status': 'joined',
    });

    FirebaseFirestore.instance
        .collection('groupCalls')
        .doc(groupId)
        .collection('participants')
        .doc(peerId)
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

  static MediaStream? getLocalStream(String groupId) {
    return _localStreams[groupId];
  }

  static Future<void> hangUpGroupCall(String groupId) async {
    _localStreams[groupId]?.getTracks().forEach((track) => track.stop());
    _localStreams.remove(groupId);

    final pcs = _groupPeerConnections[groupId];
    if (pcs != null) {
      for (final pc in pcs.values) {
        await pc.close();
      }
    }
    _groupPeerConnections.remove(groupId);

    await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).update({
      'status': 'ended',
      'endedAt': FieldValue.serverTimestamp(),
    });
  }
}
