// lib/webrtc/rtc_manager.dart
// Firestore + LiveKit helper for 1:1 voice & video flows.
// Uses provided development LiveKit URL and token by default when no token endpoint is configured.

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:permission_handler/permission_handler.dart';

/// NOTE:
/// - This file expects `livekit_client`, `cloud_firestore`, `http` and `permission_handler` in pubspec.yaml.
/// - You can configure a production token endpoint via RtcManager.configure().
/// - For quick development/testing the _devToken and _sfuUrl below will be returned when
///   no token endpoint is configured.
class RtcManager {
  // ---------- Replaceable defaults (you provided these) ----------
  static const String _sfuUrl = 'wss://movieflix-cyn3yzmd.livekit.cloud';
  static const String _devToken =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3NjM0MjYwNzAsImlzcyI6IkFQSTZhVHFkYmFZOWd1ViIsIm5iZiI6MTc1NDQyNjA3MCwic3ViIjoibWF4IiwidmlkZW8iOnsiY2FuUHVibGlzaCI6dHJ1ZSwiY2FuUHVibGlzaERhdGEiOnRydWUsImNhblN1YnNjcmliZSI6dHJ1ZSwicm9vbSI6Imdyb3VwY2FsbCxjaGF0Y2FsbCIsInJvb21Kb2luIjp0cnVlfX0.KAFwOwgRpSMPoZ4xCAN7wSwGBHTq-GBjm_sdMyBMJxU';

  // ---------- Runtime configuration (override via configure) ----------
  /// Optional server endpoint that issues LiveKit tokens.
  /// Expected to accept JSON { room, identity, name?, metadata? } and return { token, livekitUrl? }
  static String tokenEndpoint = '';
  static Map<String, String> tokenEndpointHeaders = {};
  static String liveKitUrl = _sfuUrl; // will default to provided SFU url

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Configure RtcManager at app startup. If you don't call this
  /// the manager will fall back to the embedded _devToken/_sfuUrl.
  static void configure({
    String? tokenEndpointUrl,
    Map<String, String>? tokenHeaders,
    String? livekitUrl,
  }) {
    if (tokenEndpointUrl != null && tokenEndpointUrl.isNotEmpty) {
      tokenEndpoint = tokenEndpointUrl;
    }
    if (tokenHeaders != null) {
      tokenEndpointHeaders = tokenHeaders;
    }
    if (livekitUrl != null && livekitUrl.isNotEmpty) {
      RtcManager.liveKitUrl = livekitUrl; // assign to static field explicitly
    }
  }

  // -------------------- Signalling (Firestore) --------------------
  /// Create a call document (status: 'ringing') and return the callId (doc id).
  static Future<String> startVideoCall({
    required Map<String, dynamic> caller,
    required Map<String, dynamic> receiver,
  }) async {
    return _startCall(type: 'video', caller: caller, receiver: receiver);
  }

  static Future<String> startVoiceCall({
    required Map<String, dynamic> caller,
    required Map<String, dynamic> receiver,
  }) async {
    return _startCall(type: 'voice', caller: caller, receiver: receiver);
  }

  static Future<String> _startCall({
    required String type,
    required Map<String, dynamic> caller,
    required Map<String, dynamic> receiver,
  }) async {
    final callRef = await _firestore.collection('calls').add({
      'type': type,
      'callerId': caller['id'],
      'caller': caller,
      'receiverId': receiver['id'],
      'receiver': receiver,
      'status': 'ringing',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'room': null,
      'participants': [caller['id']],
    });

    // Use document id as the room name for simplicity
    await callRef.set({'room': callRef.id}, SetOptions(merge: true));

    return callRef.id;
  }

  static Future<void> acceptCall({
    required String callId,
    required String userId,
  }) async {
    final callRef = _firestore.collection('calls').doc(callId);

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(callRef);
      if (!snap.exists) throw Exception('Call not found');

      final data = snap.data() as Map<String, dynamic>;
      final participants = List<String>.from(data['participants'] ?? []);
      if (!participants.contains(userId)) participants.add(userId);

      tx.update(callRef, {
        'status': 'ongoing',
        'participants': participants,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  static Future<void> rejectCall({
    required String callId,
    required String rejectedBy,
    String? reason,
  }) async {
    final callRef = _firestore.collection('calls').doc(callId);
    await callRef.update({
      'status': 'rejected',
      'rejectedBy': rejectedBy,
      'rejectedReason': reason,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> endCall({
    required String callId,
    String? endedBy,
  }) async {
    final callRef = _firestore.collection('calls').doc(callId);
    await callRef.update({
      'status': 'ended',
      'endedBy': endedBy,
      'endedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> addParticipant({
    required String callId,
    required String userId,
  }) async {
    final callRef = _firestore.collection('calls').doc(callId);
    await callRef.update({
      'participants': FieldValue.arrayUnion([userId]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> removeParticipant({
    required String callId,
    required String userId,
  }) async {
    final callRef = _firestore.collection('calls').doc(callId);
    await callRef.update({
      'participants': FieldValue.arrayRemove([userId]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Stream<DocumentSnapshot<Map<String, dynamic>>> callStream(String callId) {
    return _firestore.collection('calls').doc(callId).snapshots();
  }

  // -------------------- Token & LiveKit join --------------------

  /// If tokenEndpoint is configured, request token from server.
  /// Otherwise fall back to _devToken/_sfuUrl that were provided for development.
  static Future<Map<String, dynamic>> getTokenForCall({
    required String callId,
    required String userId,
    String? userName,
    Map<String, dynamic>? metadata,
  }) async {
    if (tokenEndpoint.isEmpty) {
      // Development fallback — return provided dev token and SFU URL
      return {'token': _devToken, 'livekitUrl': _sfuUrl};
    }

    try {
      final body = {
        'room': callId,
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
  /// Returns the connected Room instance. Caller is responsible for rendering tracks & managing lifecycle.
  static Future<Room> joinRoom({
    required String token,
    required String url,
    bool enableAudio = true,
    bool enableVideo = true,
    RoomOptions? roomOptions,
  }) async {
    final options = roomOptions ?? RoomOptions(adaptiveStream: true, dynacast: true);

    // Use the Room constructor to provide room options (avoid deprecated connect param).
    final room = Room(roomOptions: options);
    try {
      await room.connect(url, token);

      // Try to enable mic/camera if requested — these may throw if permissions denied
      final lp = room.localParticipant;
      if (lp != null) {
        if (enableAudio) {
          // setMicrophoneEnabled may return Future<void> or Future<bool> depending on SDK; await to surface errors
          await lp.setMicrophoneEnabled(true);
        }
        if (enableVideo) {
          await lp.setCameraEnabled(true);
        }
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
  static Future<Room> getTokenAndJoin({
    required String callId,
    required String userId,
    String? userName,
    bool enableAudio = true,
    bool enableVideo = true,
    RoomOptions? roomOptions,
  }) async {
    // Embedded permission check (defensive)
    final permsOk = await _ensureMediaPermissions(audio: enableAudio, video: enableVideo);
    if (!permsOk) {
      throw Exception('Required media permissions not granted');
    }

    final resp = await getTokenForCall(callId: callId, userId: userId, userName: userName);
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

    // Best-effort updates to Firestore
    try {
      await addParticipant(callId: callId, userId: userId);
    } catch (_) {}

    try {
      final callRef = _firestore.collection('calls').doc(callId);
      await callRef.set({'status': 'ongoing', 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    } catch (_) {}

    return room;
  }

  static Future<void> leaveRoom(Room room, {String? callId, String? userId}) async {
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

    if (callId != null && userId != null) {
      try {
        await removeParticipant(callId: callId, userId: userId);
      } catch (_) {}
    }
  }

  // ---------- Convenience toggles ----------
  static Future<bool> toggleMic(Room room) async {
    final lp = room.localParticipant;
    if (lp == null) throw Exception('Local participant not available');

    // coerce to bool (in case the SDK exposes a dynamic/nullable value)
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

  // ---------- Utilities ----------
  static Future<DocumentSnapshot<Map<String, dynamic>>> fetchCall(String callId) {
    return _firestore.collection('calls').doc(callId).get();
  }
}
