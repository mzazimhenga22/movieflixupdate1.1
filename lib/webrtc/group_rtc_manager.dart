// lib/webrtc/group_rtc_manager.dart
// Firestore + LiveKit helper for group voice & video flows.
// Mirrors the 1:1 RtcManager API but operates on `groupCalls` collection and
// provides lightweight signalling + LiveKit join helpers.

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:permission_handler/permission_handler.dart';

class GroupRtcManager {
  // ---------- Replaceable defaults ----------
  static const String _sfuUrl = 'wss://movieflix-cyn3yzmd.livekit.cloud';
  static const String _devToken =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3NjM0MjYwNzAsImlzcyI6IkFQSTZhVHFkYmFZOWd1ViIsIm5iZiI6MTc1NDQyNjA3MCwic3ViIjoibWF4IiwidmlkZW8iOnsiY2FuUHVibGlzaCI6dHJ1ZSwiY2FuUHVibGlzaERhdGEiOnRydWUsImNhblN1YnNjcmliZSI6dHJ1ZSwicm9vbSI6Imdyb3VwY2FsbCxjaGF0Y2FsbCIsInJvb21Kb2luIjp0cnVlfX0.KAFwOwgRpSMPoZ4xCAN7wSwGBHTq-GBjm_sdMyBMJxU';

  // ---------- Runtime configuration (override via configure) ----------
  /// Optional server endpoint that issues LiveKit tokens.
  /// Expected to accept JSON { room, identity, name?, metadata? } and return { token, livekitUrl? }
  static String tokenEndpoint = '';
  static Map<String, String> tokenEndpointHeaders = {};
  static String liveKitUrl = _sfuUrl;

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Configure GroupRtcManager at app startup. If you don't call this
  /// the manager will fall back to _devToken/_sfuUrl.
  static void configure({
    String? tokenEndpointUrl,
    Map<String, String>? tokenHeaders,
    String? livekitUrl,
  }) {
    if (tokenEndpointUrl != null && tokenEndpointUrl.isNotEmpty) tokenEndpoint = tokenEndpointUrl;
    if (tokenHeaders != null) tokenEndpointHeaders = tokenHeaders;
    if (livekitUrl != null && livekitUrl.isNotEmpty) GroupRtcManager.liveKitUrl = livekitUrl;
  }

  // -------------------- Signalling (Firestore) --------------------

  /// Create a group call document (status: 'ringing') and return the callId (doc id).
  /// - caller: minimal map containing at least 'id'
  /// - participants: list of member maps (each should contain 'id')
  /// - isVideo: true for video calls
  static Future<String> startGroupCall({
    required Map<String, dynamic> caller,
    required List<Map<String, dynamic>> participants,
    required bool isVideo,
  }) async {
    final callerId = (caller['id'] ?? caller['userId'] ?? caller['uid'])?.toString() ?? '';
    final groupId = (caller['groupId'] ?? caller['chatId'] ?? caller['room'])?.toString();

    final participantIds = participants
        .map((p) => (p['id'] ?? p['userId'] ?? p['uid'])?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();

    if (callerId.isNotEmpty && !participantIds.contains(callerId)) {
      participantIds.insert(0, callerId);
    }

    final docRef = await _firestore.collection('groupCalls').add({
      'type': isVideo ? 'video' : 'voice',
      'callerId': callerId,
      if (groupId != null && groupId.isNotEmpty) 'groupId': groupId,
      'status': 'ringing',
      'participants': participantIds,
      'participantStatus': {if (callerId.isNotEmpty) callerId: 'joined'},
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      // room/livekit fields may be added later by getTokenAndJoin or other server flows
    });

    // Optionally set the room field equal to doc id for convenience
    await docRef.set({'room': docRef.id}, SetOptions(merge: true));

    return docRef.id;
  }

  /// Mark a peer as having accepted / joined the group call.
  /// Adds to participants, sets participantStatus[peerId] = 'joined' and
  /// flips call status to 'ongoing' if it was 'ringing'.
  static Future<void> answerGroupCall({
    required String groupId,
    required String peerId,
  }) async {
    final docRef = _firestore.collection('groupCalls').doc(groupId);

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      if (!snap.exists) throw Exception('Group call not found: $groupId');

      final data = snap.data() ?? <String, dynamic>{};
      final participantsRaw = data['participants'] as List<dynamic>? ?? [];
      final participants = participantsRaw.map((e) => e.toString()).toList();
      if (!participants.contains(peerId)) participants.add(peerId);

      final psRaw = (data['participantStatus'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      psRaw[peerId] = 'joined';

      final currStatus = (data['status'] as String?) ?? 'ringing';
      final newStatus = currStatus == 'ringing' ? 'ongoing' : currStatus;

      tx.update(docRef, {
        'participants': participants,
        'participantStatus': psRaw,
        'status': newStatus,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  /// Mark a peer as rejected for the group call.
  /// Sets participantStatus[peerId] = 'rejected', and records rejection meta.
  static Future<void> rejectGroupCall({
    required String groupId,
    required String peerId,
    String? reason,
  }) async {
    final docRef = _firestore.collection('groupCalls').doc(groupId);

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      if (!snap.exists) return;

      final data = snap.data() ?? <String, dynamic>{};
      final psRaw = (data['participantStatus'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      psRaw[peerId] = 'rejected';

      final rejectedMap = (data['rejections'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      rejectedMap[peerId] = {
        'at': FieldValue.serverTimestamp(),
        'reason': reason ?? '',
      };

      tx.update(docRef, {
        'participantStatus': psRaw,
        'rejections': rejectedMap,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  /// End the group call (mark status 'ended' and set endedAt).
  static Future<void> endGroupCall({
    required String groupId,
    String? endedBy,
  }) async {
    final docRef = _firestore.collection('groupCalls').doc(groupId);
    try {
      await docRef.update({
        'status': 'ended',
        'endedBy': endedBy ?? FieldValue.delete(),
        'endedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // best-effort; ignore if doc missing
    }
  }

  /// Add a participant (arrayUnion)
  static Future<void> addParticipant({
    required String groupId,
    required String userId,
  }) async {
    final docRef = _firestore.collection('groupCalls').doc(groupId);
    await docRef.set({
      'participants': FieldValue.arrayUnion([userId]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Remove a participant (arrayRemove)
  static Future<void> removeParticipant({
    required String groupId,
    required String userId,
  }) async {
    final docRef = _firestore.collection('groupCalls').doc(groupId);
    await docRef.set({
      'participants': FieldValue.arrayRemove([userId]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Stream for group call doc changes.
  static Stream<DocumentSnapshot<Map<String, dynamic>>> groupCallStream(String groupId) {
    return _firestore.collection('groupCalls').doc(groupId).snapshots();
  }

  /// Fetch the group call doc once.
  static Future<DocumentSnapshot<Map<String, dynamic>>> fetchGroupCall(String groupId) {
    return _firestore.collection('groupCalls').doc(groupId).get();
  }

  // -------------------- Token & LiveKit join (optional) --------------------

  /// If tokenEndpoint is configured, request token from server.
  /// Otherwise fall back to _devToken/_sfuUrl.
  static Future<Map<String, dynamic>> getTokenForGroup({
    required String groupId,
    required String userId,
    String? userName,
    Map<String, dynamic>? metadata,
  }) async {
    if (tokenEndpoint.isEmpty) {
      return {'token': _devToken, 'livekitUrl': _sfuUrl};
    }

    try {
      final body = {
        'room': groupId,
        'identity': userId,
        'name': userName ?? userId,
        if (metadata != null) 'metadata': metadata,
      };

      final resp = await http.post(
        Uri.parse(tokenEndpoint),
        headers: {
          'content-type': 'application/json',
          ...tokenEndpointHeaders,
        },
        body: jsonEncode(body),
      );

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('Token endpoint error: ${resp.statusCode} ${resp.body}');
      }

      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      if (!decoded.containsKey('token')) throw Exception('Token endpoint response missing "token"');
      return decoded;
    } catch (e) {
      rethrow;
    }
  }

  // --------------------
  // Embedded permission helper (no separate utils file)
  static Future<bool> _ensureMediaPermissions({bool audio = true, bool video = true}) async {
    if (kIsWeb) return true; // browser will prompt automatically
    final List<Permission> toRequest = [];
    if (audio) toRequest.add(Permission.microphone);
    if (video) toRequest.add(Permission.camera);
    if (toRequest.isEmpty) return true;

    for (final p in toRequest) {
      final status = await p.request();
      if (!status.isGranted) {
        return false;
      }
    }
    return true;
  }

  /// Connects to a LiveKit room using the provided token and server URL.
  static Future<Room> joinRoom({
    required String token,
    required String url,
    bool enableAudio = true,
    bool enableVideo = true,
    RoomOptions? roomOptions,
  }) async {
    final options = roomOptions ?? RoomOptions(adaptiveStream: true, dynacast: true);
    final room = Room(roomOptions: options);
    try {
      await room.connect(url, token);

      final lp = room.localParticipant;
      if (lp != null) {
        if (enableAudio) await lp.setMicrophoneEnabled(true);
        if (enableVideo) await lp.setCameraEnabled(true);
      }
      return room;
    } catch (e) {
      try {
        await room.disconnect();
      } catch (_) {}
      rethrow;
    }
  }

  /// Convenience: get token from server (or dev token) and join.
  /// This method now performs an embedded permission check before attempting to join the room.
  static Future<Room> getTokenAndJoinGroup({
    required String groupId,
    required String userId,
    String? userName,
    bool enableAudio = true,
    bool enableVideo = true,
    RoomOptions? roomOptions,
  }) async {
    // Embedded permission check
    final permsOk = await _ensureMediaPermissions(audio: enableAudio, video: enableVideo);
    if (!permsOk) {
      throw Exception('Required media permissions not granted');
    }

    final resp = await getTokenForGroup(groupId: groupId, userId: userId, userName: userName);
    final token = resp['token'] as String;
    final serverUrl = (resp['livekitUrl'] as String?) ?? liveKitUrl;
    if (serverUrl.isEmpty) throw Exception('No LiveKit URL provided');

    final room = await joinRoom(
      token: token,
      url: serverUrl,
      enableAudio: enableAudio,
      enableVideo: enableVideo,
      roomOptions: roomOptions,
    );

    // Best-effort updates to Firestore participants/status
    try {
      await addParticipant(groupId: groupId, userId: userId);
    } catch (_) {}

    try {
      final callRef = _firestore.collection('groupCalls').doc(groupId);
      await callRef.set({'status': 'ongoing', 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    } catch (_) {}

    return room;
  }

  /// Gracefully leave the LiveKit room and optionally update Firestore participants.
  static Future<void> leaveRoom(Room room, {String? groupId, String? userId}) async {
    try {
      final lp = room.localParticipant;
      if (lp != null) {
        await lp.setCameraEnabled(false);
      }
    } catch (_) {}
    try {
      final lp = room.localParticipant;
      if (lp != null) {
        await lp.setMicrophoneEnabled(false);
      }
    } catch (_) {}

    try {
      await room.disconnect();
    } catch (_) {}

    if (groupId != null && userId != null) {
      try {
        await removeParticipant(groupId: groupId, userId: userId);
      } catch (_) {}
    }
  }

  // ---------- Convenience toggles (same semantics as RtcManager) ----------
  static Future<bool> toggleMic(Room room) async {
    final lp = room.localParticipant;
    if (lp == null) throw Exception('Local participant not available');
    final bool enabled = (lp.isMicrophoneEnabled == true);
    final bool newVal = !enabled;
    await lp.setMicrophoneEnabled(newVal);
    return newVal;
  }

  static Future<bool> toggleCamera(Room room) async {
    final lp = room.localParticipant;
    if (lp == null) throw Exception('Local participant not available');
    final bool enabled = (lp.isCameraEnabled == true);
    final bool newVal = !enabled;
    await lp.setCameraEnabled(newVal);
    return newVal;
  }

  static Future<void> setMicEnabled(Room room, bool enabled) async {
    final lp = room.localParticipant;
    if (lp == null) throw Exception('Local participant not available');
    await lp.setMicrophoneEnabled(enabled);
  }

  static Future<void> setCameraEnabled(Room room, bool enabled) async {
    final lp = room.localParticipant;
    if (lp == null) throw Exception('Local participant not available');
    await lp.setCameraEnabled(enabled);
  }
}
