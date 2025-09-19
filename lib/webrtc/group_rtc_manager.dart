// lib/webrtc/group_rtc_manager.dart
// GroupRtcManager: Manage LiveKit group rooms + Firestore + push notifications.
// Improvements: safer lifecycle, event subscription tracking, robust publish/unpublish,
// reconnect handling, and cautious LiveKit API usage.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, unawaited;
import 'package:flutter_webrtc/flutter_webrtc.dart'; // provides MediaStream
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:uuid/uuid.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:movie_app/services/fcm_sender.dart';

/// Extension for null-safe firstOrNull
extension IterableExt<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// A CancelListenFunc is what livekit_client's `events.listen(...)` returns:
/// a zero-arg function you call to remove the listener.
typedef CancelListenFunc = void Function();

/// GroupRtcManager: Manage LiveKit group rooms + Firestore signaling + push
class GroupRtcManager {
  static final Map<String, lk.Room> _liveKitRooms = {};
  static final Map<String, lk.LocalParticipant?> _localParticipants = {};
  static final Map<String, Map<String, lk.RemoteParticipant>> _remoteParticipants = {};
  static final Map<String, Timer> _callTimers = {};

  // event subscription per room: store cancel functions returned by room.events.listen(...)
  static final Map<String, CancelListenFunc> _roomEventSubs = {};

  // Track reconnect attempts so we don't loop forever
  static final Map<String, int> _reconnectAttempts = {};

  // Track calls explicitly ended by the UI/user so reconnection is not attempted
  static final Set<String> _endedByUser = {};

  // LiveKit server & token (replace with your own values)
  static const String _sfuUrl = 'wss://movieflix-cyn3yzmd.livekit.cloud';
  static const String _devToken =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3NjM0MjYwNzAsImlzcyI6IkFQSTZhVHFkYmFZOWd1ViIsIm5iZiI6MTc1NDQyNjA3MCwic3ViIjoibWF4IiwidmlkZW8iOnsiY2FuUHVibGlzaCI6dHJ1ZSwiY2FuUHVibGlzaERhdGEiOnRydWUsImNhblN1YnNjcmliZSI6dHJ1ZSwicm9vbSI6Imdyb3VwY2FsbCxjaGF0Y2FsbCIsInJvb21Kb2luIjp0cnVlfX0.KAFwOwgRpSMPoZ4xCAN7wSwGBHTq-GBjm_sdMyBMJxU';

  /// Request microphone/camera permissions; UI should call this first when appropriate.
  static Future<bool> _requestPermissions({required bool video}) async {
    final permissions = <Permission>[
      Permission.microphone,
      if (video) Permission.camera,
    ];
    final statuses = await permissions.request();
    return statuses.values.every((status) => status.isGranted);
  }

  /// Connect with a small retry/backoff loop - returns connected room or throws.
  static Future<lk.Room> _connectWithRetry({int attempts = 3, Duration initialDelay = const Duration(milliseconds: 400)}) async {
    int attempt = 0;
    Exception? lastEx;
    Duration delay = initialDelay;
    while (attempt < attempts) {
      attempt++;
      try {
        final room = lk.Room();
        await room.connect(_sfuUrl, _devToken, connectOptions: lk.ConnectOptions(autoSubscribe: true));
        debugPrint('[GroupRtcManager] connected to LiveKit (attempt $attempt)');
        return room;
      } catch (e) {
        lastEx = Exception('Connect attempt $attempt failed: $e');
        debugPrint('[GroupRtcManager] connect attempt $attempt failed: $e');
        await Future.delayed(delay);
        delay *= 2;
      }
    }
    throw lastEx ?? Exception('unknown connect error');
  }

  /// Start a group call (voice/video) — publishes local tracks and creates Firestore call doc.
  static Future<String> startGroupCall({
    required Map<String, dynamic> caller,
    required List<Map<String, dynamic>> participants,
    required bool isVideo,
  }) async {
    final groupId = const Uuid().v4();

    // reset ended flag for this group
    _endedByUser.remove(groupId);

    if (!await _requestPermissions(video: isVideo)) {
      throw Exception("Permissions denied");
    }

    late lk.Room room;
    try {
      room = await _connectWithRetry();
    } catch (e) {
      debugPrint('[GroupRtcManager] failed to connect room: $e');
      rethrow;
    }

    _liveKitRooms[groupId] = room;
    _localParticipants[groupId] = room.localParticipant;
    _remoteParticipants[groupId] = {};

    // register event handling (store cancel function so we can cancel later)
    _registerRoomEvents(groupId, room);

    lk.LocalVideoTrack? videoTrack;
    lk.LocalAudioTrack? audioTrack;

    try {
      if (isVideo) {
        videoTrack = await lk.LocalVideoTrack.createCameraTrack();
        await _safePublishVideo(room, videoTrack);
      }

      audioTrack = await lk.LocalAudioTrack.create();
      await _safePublishAudio(room, audioTrack);
    } catch (e) {
      debugPrint('[GroupRtcManager] publish error: $e');
      await _endCall(groupId, videoTrack: videoTrack, audioTrack: audioTrack, roomOnly: true);
      rethrow;
    }

    // Build participantStatus map - host is joined initially
    final Map<String, dynamic> participantStatus = {caller['id'].toString(): 'joined'};

    try {
      await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).set({
        'groupId': groupId,
        'host': caller['id'],
        'type': isVideo ? 'video' : 'voice',
        'participants': participants.map((p) => p['id']).toList(),
        'status': 'ringing',
        'startedAt': FieldValue.serverTimestamp(),
        'participantStatus': participantStatus,
        'unreadBy': participants.map((p) => p['id']).toList(),
      });
    } catch (e) {
      debugPrint('[GroupRtcManager] Error setting group call doc: $e');
      await _endCall(groupId, videoTrack: videoTrack, audioTrack: audioTrack);
      rethrow;
    }

    // send push notifications asynchronously (don't block)
    try {
      for (final participant in participants) {
        final token = (participant['fcmToken'] ?? participant['token'])?.toString() ?? '';
        if (token.isEmpty) {
          debugPrint('[GroupRtcManager] skip push - no token for ${participant['id'] ?? participant['username']}');
          continue;
        }

        final extra = <String, dynamic>{
          'callId': groupId,
          'callerId': caller['id']?.toString() ?? '',
          'callerName': caller['username'] ?? '',
          'type': isVideo ? 'video' : 'voice',
          'group': 'true',
        };

        unawaited(sendFcmPush(
          fcmToken: token,
          title: 'Incoming ${isVideo ? 'Video' : 'Voice'} Group Call',
          body: '${caller['username'] ?? 'Someone'} is calling',
          extraData: extra,
          notification: true,
          androidChannelId: 'incoming_call',
        ));
      }
    } catch (e, st) {
      debugPrint('[GroupRtcManager] sendFcmPush error: $e\n$st');
    }

    // set a 30s timeout to auto-end ringing calls
    _callTimers[groupId] = Timer(const Duration(seconds: 30), () async {
      if (_liveKitRooms.containsKey(groupId) && !_endedByUser.contains(groupId)) {
        try {
          final doc = await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).get();
          if (doc.exists && doc['status'] == 'ringing') {
            await _endCall(groupId, videoTrack: videoTrack, audioTrack: audioTrack);
            try {
              await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).update({
                'status': 'missed',
                'endedAt': FieldValue.serverTimestamp(),
              });
            } catch (_) {}
          }
        } catch (e) {
          debugPrint('[GroupRtcManager] Error checking call status: $e');
        }
      }
    });

    // start network/connection monitor
    _monitorNetwork(groupId, room);

    return groupId;
  }

  /// Answer an incoming group call — join the same LiveKit room and publish tracks.
  static Future<void> answerGroupCall({
    required String groupId,
    required String peerId,
  }) async {
    try {
      if (_endedByUser.contains(groupId)) {
        debugPrint('[GroupRtcManager] answerGroupCall aborted: call was ended by user for $groupId');
        return;
      }

      final docSnap = await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).get();
      if (!docSnap.exists) {
        throw Exception('Group call not found');
      }
      final data = docSnap.data()!;
      final status = data['status'] as String? ?? 'ended';
      if (status != 'ringing') {
        debugPrint('[GroupRtcManager] answerGroupCall: call not ringing (status=$status)');
        return;
      }
      final isVideo = (data['type'] as String?) == 'video';

      if (!await _requestPermissions(video: isVideo)) {
        throw Exception("Permissions denied");
      }

      // Connect or reuse existing room
      final room = _liveKitRooms[groupId] ?? await _connectWithRetry();
      _liveKitRooms[groupId] = room;
      _localParticipants[groupId] = room.localParticipant;
      _remoteParticipants[groupId] ??= {};

      _registerRoomEvents(groupId, room);

      // publish tracks
      lk.LocalVideoTrack? videoTrack;
      lk.LocalAudioTrack? audioTrack;
      try {
        if (isVideo) {
          videoTrack = await lk.LocalVideoTrack.createCameraTrack();
          await _safePublishVideo(room, videoTrack);
        }
        audioTrack = await lk.LocalAudioTrack.create();
        await _safePublishAudio(room, audioTrack);
      } catch (e) {
        debugPrint('[GroupRtcManager] publish while answering error: $e');
        // not fatal for UI — keep trying
      }

      // update firestore participant status
      try {
        final update = <String, dynamic>{
          'status': 'answered',
          'participantStatus.$peerId': 'joined',
        };
        await FirebaseFirestore.instance.collection('groupCalls').doc(groupId).update(update);
      } catch (e) {
        debugPrint('[GroupRtcManager] Failed to update participantStatus: $e');
      }

      // cancel any ringing timer
      _callTimers[groupId]?.cancel();
      _monitorNetwork(groupId, room);
    } catch (e, st) {
      debugPrint('[GroupRtcManager] answerGroupCall error: $e\n$st');
      rethrow;
    }
  }

  /// Mark a participant as rejected and end call if everyone rejected
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
      if (doc.exists) {
        final statuses = Map<String, dynamic>.from(doc.get('participantStatus') as Map);
        final allRejected = statuses.values.every((s) => s == 'rejected');
        if (allRejected) {
          await _endCall(groupId);
        }
      }
    } catch (e) {
      debugPrint('[GroupRtcManager] rejectGroupCall error: $e');
    }
  }

  /// Internal: register room events (participant/track/connection changes)
  static void _registerRoomEvents(String groupId, lk.Room room) {
    try {
      // If we already have a cancel function for this group, call it to remove the previous listener
      try {
        final prevCancel = _roomEventSubs.remove(groupId);
        try {
          prevCancel?.call();
        } catch (_) {}
      } catch (_) {}

      // LiveKit events.listen returns a CancelListenFunc (callable) rather than a StreamSubscription.
      final CancelListenFunc cancel = room.events.listen((event) {
        try {
          // if ended by user, ignore events that try to reconnect
          if (_endedByUser.contains(groupId)) {
            debugPrint('[GroupRtcManager] ignoring room event for ended call $groupId: ${event.runtimeType}');
            return;
          }

          if (event is lk.ParticipantConnectedEvent) {
            _remoteParticipants[groupId] ??= {};
            _remoteParticipants[groupId]![event.participant.identity] = event.participant;
            debugPrint('[GroupRtcManager] participant connected: ${event.participant.identity}');
          } else if (event is lk.ParticipantDisconnectedEvent) {
            _remoteParticipants[groupId]?.remove(event.participant.identity);
            debugPrint('[GroupRtcManager] participant disconnected: ${event.participant.identity}');
          } else if (event is lk.TrackSubscribedEvent) {
            _remoteParticipants[groupId] ??= {};
            _remoteParticipants[groupId]![event.participant.identity] = event.participant;
            debugPrint('[GroupRtcManager] track subscribed for ${event.participant.identity}');
          } else if (event is lk.TrackUnsubscribedEvent) {
            debugPrint('[GroupRtcManager] track unsubscribed for ${event.participant.identity}');
          } else if (event is lk.RoomDisconnectedEvent) {
            debugPrint('[GroupRtcManager] room disconnected for group $groupId');
            // Kick off a reconnect attempt (limited) only if not ended by user
            if (!_endedByUser.contains(groupId)) {
              _attemptReconnect(groupId);
            } else {
              debugPrint('[GroupRtcManager] not reconnecting because call ended by user: $groupId');
            }
          } else {
            debugPrint('[GroupRtcManager] room event: ${event.runtimeType}');
          }
        } catch (e, st) {
          debugPrint('[GroupRtcManager] room.events handler error: $e\n$st');
        }
      });

      _roomEventSubs[groupId] = cancel;
    } catch (e, st) {
      debugPrint('[GroupRtcManager] _registerRoomEvents error: $e\n$st');
    }
  }

  /// Attempt reconnect with exponential backoff; limited attempts to avoid storms.
  static Future<void> _attemptReconnect(String groupId, {int maxAttempts = 3}) async {
    // If the call was ended by UI, don't attempt reconnects
    if (_endedByUser.contains(groupId)) {
      debugPrint('[GroupRtcManager] _attemptReconnect abort: ended by user for $groupId');
      return;
    }

    final prev = _reconnectAttempts[groupId] ?? 0;
    if (prev >= maxAttempts) {
      debugPrint('[GroupRtcManager] reconnect attempts exhausted for $groupId');
      await _endCall(groupId);
      return;
    }
    _reconnectAttempts[groupId] = prev + 1;
    final backoff = Duration(milliseconds: 300 * (1 << prev));
    debugPrint('[GroupRtcManager] scheduling reconnect for $groupId in ${backoff.inMilliseconds}ms (attempt ${prev + 1})');

    await Future.delayed(backoff);

    // Check again after delay
    if (_endedByUser.contains(groupId)) {
      debugPrint('[GroupRtcManager] reconnect canceled after delay: ended by user for $groupId');
      return;
    }

    try {
      final room = lk.Room();
      await room.connect(_sfuUrl, _devToken, connectOptions: lk.ConnectOptions(autoSubscribe: true));
      // If successful, replace stored room & re-register events & republish tracks if needed
      _liveKitRooms[groupId] = room;
      _localParticipants[groupId] = room.localParticipant;
      _registerRoomEvents(groupId, room);

      // try to republish audio/video if needed
      await ensurePublishedTracks(groupId, wantVideo: true);

      _reconnectAttempts.remove(groupId);
      debugPrint('[GroupRtcManager] reconnect successful for $groupId');
    } catch (e) {
      debugPrint('[GroupRtcManager] reconnect failed for $groupId: $e');
      // try again recursively (will end after maxAttempts)
      await _attemptReconnect(groupId, maxAttempts: maxAttempts);
    }
  }

  /// End and cleanup a call; if roomOnly true we only disconnect the room and skip Firestore updates.
  /// If endedByUser is true the call will be marked as ended by UI and reconnection attempts will be blocked.
  static Future<void> _endCall(String groupId,
      {lk.LocalVideoTrack? videoTrack, lk.LocalAudioTrack? audioTrack, bool roomOnly = false, bool endedByUser = false}) async {
    try {
      if (endedByUser) {
        _endedByUser.add(groupId);
      }

      // cancel timers & reconnect attempts early
      try {
        _callTimers[groupId]?.cancel();
        _callTimers.remove(groupId);
      } catch (_) {}
      try {
        _reconnectAttempts.remove(groupId);
      } catch (_) {}

      final room = _liveKitRooms[groupId];
      if (room != null) {
        try {
          final localParticipant = _localParticipants[groupId];

          // Attempt to disable local mic/camera so remote peers stop receiving audio/video
          try {
            await localParticipant?.setMicrophoneEnabled(false);
          } catch (_) {}
          try {
            await localParticipant?.setCameraEnabled(false);
          } catch (_) {}

          // disconnect room safely
          try {
            if (room.connectionState != lk.ConnectionState.disconnected) {
              await room.disconnect();
            }
          } catch (e) {
            debugPrint('[GroupRtcManager] room.disconnect error: $e');
          }

          // cancel and remove room event subscription (call stored cancel function)
          try {
            final cancel = _roomEventSubs.remove(groupId);
            try {
              cancel?.call();
            } catch (_) {}
          } catch (_) {}
        } catch (e) {
          debugPrint('[GroupRtcManager] error during room cleanup: $e');
        }
      }

      // dispose tracks if present (safe)
      try {
        await videoTrack?.dispose();
      } catch (e) {
        debugPrint('[GroupRtcManager] videoTrack dispose error: $e');
      }
      try {
        await audioTrack?.dispose();
      } catch (e) {
        debugPrint('[GroupRtcManager] audioTrack dispose error: $e');
      }

      // local cleanup maps/timers
      _liveKitRooms.remove(groupId);
      _localParticipants.remove(groupId);
      _remoteParticipants.remove(groupId);
      _callTimers[groupId]?.cancel();
      _callTimers.remove(groupId);
      _reconnectAttempts.remove(groupId);

      // update firestore unless flagged roomOnly
      if (!roomOnly) {
        try {
          final docRef = FirebaseFirestore.instance.collection('groupCalls').doc(groupId);
          final doc = await docRef.get();
          if (doc.exists) {
            final updatePayload = <String, dynamic>{
              'status': 'ended',
              'endedAt': FieldValue.serverTimestamp(),
            };
            if (endedByUser) updatePayload['endedBy'] = 'local_user';
            await docRef.update(updatePayload);
          }
        } catch (e) {
          debugPrint('[GroupRtcManager] firestore end update failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[GroupRtcManager] _endCall error: $e');
    } finally {
      // ensure no reconnection will happen after a short delay
      Future.delayed(const Duration(milliseconds: 50), () {
        _reconnectAttempts.remove(groupId);
      });
    }
  }

  /// Public hang up for group calls (called by UI)
  static Future<void> hangUpGroupCall(String groupId) async {
    await _endCall(groupId, endedByUser: true);

    // Also clear any lingering caches and attempt a final room dispose if available
    try {
      final room = _liveKitRooms[groupId];
      if (room != null) {
        try {
          // attempt a dispose if available on this platform/version; it's safe inside try/catch
          room.dispose();
        } catch (e) {
          debugPrint('[GroupRtcManager] room.dispose error in hangUp: $e');
        }
      }
    } catch (e) {
      debugPrint('[GroupRtcManager] hangUpGroupCall post-clean error: $e');
    } finally {
      _liveKitRooms.remove(groupId);
      _localParticipants.remove(groupId);
      _remoteParticipants.remove(groupId);
      _callTimers[groupId]?.cancel();
      _callTimers.remove(groupId);
      _reconnectAttempts.remove(groupId);
      _endedByUser.remove(groupId); // optional: remove to keep set short-lived
    }
  }

  /// Toggle microphone for local participant
  static Future<void> toggleMute(String groupId, bool isMuted) async {
    final lp = _localParticipants[groupId];
    if (lp != null) {
      try {
        await lp.setMicrophoneEnabled(!isMuted);
      } catch (e) {
        debugPrint('[GroupRtcManager] toggleMute error: $e');
      }
    }
  }

  /// Toggle camera for local participant
  static Future<void> toggleVideo(String groupId, bool isVideoEnabled) async {
    final lp = _localParticipants[groupId];
    if (lp != null) {
      try {
        await lp.setCameraEnabled(isVideoEnabled);
      } catch (e) {
        debugPrint('[GroupRtcManager] toggleVideo error: $e');
      }
    }
  }

  /// Ensure published tracks exist otherwise republish
  static Future<void> ensurePublishedTracks(String groupId, {required bool wantVideo}) async {
    final room = _liveKitRooms[groupId];
    if (room == null) return;
    final lp = room.localParticipant;
    if (lp == null) return;

    // if audio not present, publish it
    final hasAudio = lp.trackPublications.values.any((p) => p.kind == lk.TrackType.AUDIO && p.track != null);
    if (!hasAudio) {
      try {
        final audioTrack = await lk.LocalAudioTrack.create();
        await _safePublishAudio(room, audioTrack);
      } catch (e) {
        debugPrint('[GroupRtcManager] ensurePublishedTracks audio publish failed: $e');
      }
    }

    final hasVideo = lp.trackPublications.values.any((p) => p.kind == lk.TrackType.VIDEO && p.track != null);
    if (wantVideo && !hasVideo) {
      try {
        final videoTrack = await lk.LocalVideoTrack.createCameraTrack();
        await _safePublishVideo(room, videoTrack);
      } catch (e) {
        debugPrint('[GroupRtcManager] ensurePublishedTracks video publish failed: $e');
      }
    }
  }

  /// Network monitor: watch for disconnected connectionState and attempt cleanup
  static void _monitorNetwork(String groupId, lk.Room room) {
    Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!_liveKitRooms.containsKey(groupId)) {
        timer.cancel();
        return;
      }
      try {
        if (_endedByUser.contains(groupId)) {
          timer.cancel();
          return;
        }
        if (room.connectionState == lk.ConnectionState.disconnected) {
          debugPrint('[GroupRtcManager] detected disconnected state for $groupId');
          // schedule reconnect attempt
          await _attemptReconnect(groupId);
        }
      } catch (e) {
        debugPrint('[GroupRtcManager] monitorNetwork error: $e');
      }
    });
  }

  /// Helper: publish audio safely (avoid duplicate publishes)
  static Future<void> _safePublishAudio(lk.Room room, lk.LocalAudioTrack audioTrack) async {
    try {
      final lp = room.localParticipant;
      if (lp == null) {
        // no participant attached — dispose created track to avoid leak
        try {
          await audioTrack.dispose();
        } catch (_) {}
        return;
      }

      final already = lp.trackPublications.values.any((p) => p.kind == lk.TrackType.AUDIO && p.track != null);
      if (!already) {
        await lp.publishAudioTrack(audioTrack);
      } else {
        debugPrint('[GroupRtcManager] audio already published - skipping');
        try {
          await audioTrack.dispose();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[GroupRtcManager] _safePublishAudio error: $e');
      rethrow;
    }
  }

  /// Helper: publish video safely
  static Future<void> _safePublishVideo(lk.Room room, lk.LocalVideoTrack videoTrack) async {
    try {
      final lp = room.localParticipant;
      if (lp == null) {
        try {
          await videoTrack.dispose();
        } catch (_) {}
        return;
      }

      final already = lp.trackPublications.values.any((p) => p.kind == lk.TrackType.VIDEO && p.track != null);
      if (!already) {
        await lp.publishVideoTrack(
          videoTrack,
          publishOptions: const lk.VideoPublishOptions(
            videoEncoding: lk.VideoEncoding(maxBitrate: 2_000_000, maxFramerate: 30),
          ),
        );
      } else {
        debugPrint('[GroupRtcManager] video already published - skipping');
        try {
          await videoTrack.dispose();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[GroupRtcManager] _safePublishVideo error: $e');
      rethrow;
    }
  }

  /// Adjust quality by unpublishing and republishing with different encoding params.
  static Future<void> _adjustQuality(String groupId, {required bool lower}) async {
    final room = _liveKitRooms[groupId];
    if (room == null) return;
    final lp = room.localParticipant;
    if (lp == null) return;

    try {
      // Attempt to disable local tracks and re-publish
      try {
        await lp.setCameraEnabled(false);
        await lp.setMicrophoneEnabled(false);
      } catch (_) {}

      // create new video track with requested profile and publish
      final newVideo = await lk.LocalVideoTrack.createCameraTrack();
      await lp.publishVideoTrack(
        newVideo,
        publishOptions: lk.VideoPublishOptions(
          videoEncoding: lk.VideoEncoding(
            maxBitrate: lower ? 300_000 : 2_000_000,
            maxFramerate: lower ? 15 : 30,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[GroupRtcManager] _adjustQuality error: $e');
    }
  }

  /// Return identity of active speaker if available
  static String? getActiveSpeaker(String groupId) {
    final room = _liveKitRooms[groupId];
    if (room != null) {
      final activeSpeaker = room.activeSpeakers.firstOrNull;
      return activeSpeaker?.identity;
    }
    return null;
  }

  /// Get local audio MediaStream if available
  static MediaStream? getLocalStream(String groupId) {
    final localParticipant = _localParticipants[groupId];
    if (localParticipant == null) return null;
    try {
      for (final pub in localParticipant.trackPublications.values) {
        if (pub.kind == lk.TrackType.AUDIO && pub.track != null) {
          return pub.track?.mediaStream;
        }
      }
    } catch (e) {
      debugPrint('[GroupRtcManager] getLocalStream error: $e');
    }
    return null;
  }

  /// Get remote audio MediaStream for peerId if available
  static MediaStream? getRemoteStream(String groupId, String peerId) {
    final participant = _remoteParticipants[groupId]?[peerId];
    if (participant == null) return null;
    try {
      for (final pub in participant.trackPublications.values) {
        if (pub.kind == lk.TrackType.AUDIO && pub.track != null) {
          return pub.track?.mediaStream;
        }
      }
    } catch (e) {
      debugPrint('[GroupRtcManager] getRemoteStream error: $e');
    }
    return null;
  }

  /// Get any remote audio stream (first available)
  static MediaStream? getAnyRemoteAudioStream(String groupId) {
    final map = _remoteParticipants[groupId];
    if (map == null) return null;
    for (final p in map.values) {
      try {
        for (final pub in p.trackPublications.values) {
          if (pub.kind == lk.TrackType.AUDIO && pub.track != null) {
            return pub.track?.mediaStream;
          }
        }
      } catch (e) {
        debugPrint('[GroupRtcManager] getAnyRemoteAudioStream error: $e');
      }
    }
    return null;
  }

  /// Dispose cached room resources but keep Firestore doc intact (used when leaving view only)
  static void dispose(String groupId) {
    final room = _liveKitRooms[groupId];
    try {
      if (room != null) {
        try {
          room.dispose();
        } catch (e) {
          debugPrint('[GroupRtcManager] room.dispose error: $e');
        }
      }
    } catch (e) {
      debugPrint('[GroupRtcManager] dispose error: $e');
    } finally {
      // cancel room event subscription if present (call stored cancel function)
      try {
        final cancel = _roomEventSubs.remove(groupId);
        try {
          cancel?.call();
        } catch (_) {}
      } catch (_) {}
      _liveKitRooms.remove(groupId);
      _localParticipants.remove(groupId);
      _remoteParticipants.remove(groupId);
      _callTimers[groupId]?.cancel();
      _callTimers.remove(groupId);
      _reconnectAttempts.remove(groupId);
      _endedByUser.remove(groupId);
    }
  }
}
