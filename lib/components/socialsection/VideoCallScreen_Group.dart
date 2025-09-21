// lib/components/socialsection/VideoCallScreen_Group.dart
// Group video call UI wired to GroupRtcManager (LiveKit + Firestore signalling).
// NOTE: This shows placeholders for participant video; when available uses VideoTrackRenderer.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:movie_app/webrtc/group_rtc_manager.dart';

class VideoCallScreenGroup extends StatefulWidget {
  final String callId;
  final String callerId;
  final String groupId;
  final List<Map<String, dynamic>>? participants;

  const VideoCallScreenGroup({
    super.key,
    required this.callId,
    required this.callerId,
    required this.groupId,
    this.participants,
  });

  @override
  State<VideoCallScreenGroup> createState() => _VideoCallScreenGroupState();
}

class _VideoCallScreenGroupState extends State<VideoCallScreenGroup> with SingleTickerProviderStateMixin {
  Room? _room;

  /// Can be StreamSubscription<RoomEvent> or CancelListenFunc (callable)
  dynamic _roomEventsSub;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callSub;

  bool _joined = false;
  bool _micEnabled = true;
  bool _camEnabled = true;
  Duration _callDuration = Duration.zero;
  Timer? _durationTimer;

  String? _pinnedIdentity;
  late final AnimationController _controlsAnim;

  @override
  void initState() {
    super.initState();
    _controlsAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _listenToCallDoc();
  }

  Future<void> _listenToCallDoc() async {
    try {
      _callSub = GroupRtcManager.groupCallStream(widget.callId).listen((snap) async {
        if (!snap.exists) return;
        final data = snap.data() ?? {};
        final status = data['status'] as String? ?? '';

        if (status == 'ended' || status == 'rejected') {
          await _leaveAndClose();
        } else if (!_joined && status == 'ongoing') {
          await _joinRoom();
        }
      }, onError: (err) {
        debugPrint('group call listen error: $err');
      });
    } catch (e) {
      debugPrint('listenToCallDoc error: $e');
    }
  }

  Future<void> _joinRoom() async {
    if (_joined) return;
    try {
      final room = await GroupRtcManager.getTokenAndJoinGroup(
        groupId: widget.callId,
        userId: widget.callerId,
        userName: widget.callerId,
        enableAudio: true,
        enableVideo: true,
      );

      // Subscribe to room events (Stream or CancelListenFunc)
      try {
        final eventsObj = room.events;
        if (eventsObj is Stream<RoomEvent>) {
          _roomEventsSub = eventsObj.listen((event) {
            if (!mounted) return;
            setState(() {
              _micEnabled = _isLocalMicEnabledFromRoom(room);
              _camEnabled = _isLocalCamEnabledFromRoom(room);
            });
          });
        } else {
          try {
            _roomEventsSub = (eventsObj as dynamic).listen((event) {
              if (!mounted) return;
              setState(() {
                _micEnabled = _isLocalMicEnabledFromRoom(room);
                _camEnabled = _isLocalCamEnabledFromRoom(room);
              });
            });
          } catch (_) {
            try {
              final cancelFunc = (eventsObj as dynamic)((RoomEvent event) {
                if (!mounted) return;
                setState(() {
                  _micEnabled = _isLocalMicEnabledFromRoom(room);
                  _camEnabled = _isLocalCamEnabledFromRoom(room);
                });
              });
              _roomEventsSub = cancelFunc;
            } catch (err) {
              debugPrint('unable to subscribe to room.events: $err');
              _roomEventsSub = null;
            }
          }
        }
      } catch (e) {
        debugPrint('room.events subscribe error: $e');
        _roomEventsSub = null;
      }

      setState(() {
        _room = room;
        _joined = true;
        _micEnabled = _isLocalMicEnabledFromRoom(room);
        _camEnabled = _isLocalCamEnabledFromRoom(room);
      });

      _startTimer();
      _controlsAnim.forward();
    } catch (e, st) {
      debugPrint('join group room failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to join group call')));
        Navigator.of(context).maybePop();
      }
    }
  }

  void _startTimer() {
    _durationTimer?.cancel();
    _callDuration = Duration.zero;
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _callDuration = _callDuration + const Duration(seconds: 1));
    });
  }

  Future<void> _cancelRoomEventsSubscription() async {
    final sub = _roomEventsSub;
    if (sub == null) return;
    try {
      if (sub is StreamSubscription) {
        await sub.cancel();
      } else {
        try {
          await (sub as dynamic)();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('error cancelling room events subscription: $e');
    } finally {
      _roomEventsSub = null;
    }
  }

  Future<void> _leaveAndClose() async {
    _durationTimer?.cancel();

    await _cancelRoomEventsSubscription();

    if (_room != null) {
      try {
        await GroupRtcManager.leaveRoom(_room!, groupId: widget.callId, userId: widget.callerId);
      } catch (_) {}
      _room = null;
    }

    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _endCall() async {
    try {
      await GroupRtcManager.endGroupCall(groupId: widget.callId, endedBy: widget.callerId);
    } catch (_) {}
    await _leaveAndClose();
  }

  Future<void> _toggleMic() async {
    if (_room == null) return;
    try {
      final enabled = await GroupRtcManager.toggleMic(_room!);
      setState(() => _micEnabled = enabled);
    } catch (e) {
      debugPrint('toggle mic error: $e');
    }
  }

  Future<void> _toggleCamera() async {
    if (_room == null) return;
    try {
      final enabled = await GroupRtcManager.toggleCamera(_room!);
      setState(() => _camEnabled = enabled);
    } catch (e) {
      debugPrint('toggle cam error: $e');
    }
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _callSub?.cancel();

    if (_roomEventsSub is StreamSubscription) {
      try {
        (_roomEventsSub as StreamSubscription).cancel();
      } catch (_) {}
      _roomEventsSub = null;
    } else if (_roomEventsSub != null) {
      try {
        (_roomEventsSub as dynamic)();
      } catch (_) {}
      _roomEventsSub = null;
    }

    if (_room != null) {
      final r = _room;
      Future.microtask(() async {
        try {
          await GroupRtcManager.leaveRoom(r!, groupId: widget.callId, userId: widget.callerId);
        } catch (_) {}
      });
      _room = null;
    }

    _controlsAnim.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hh = d.inHours;
    if (hh > 0) {
      final hStr = hh.toString().padLeft(2, '0');
      return '$hStr:$mm:$ss';
    }
    return '$mm:$ss';
  }

  // -------------------------
  // Defensive helpers (compat with different livekit_client versions)

  bool _isLocalMicEnabledFromRoom(Room? room) {
    try {
      final lp = room?.localParticipant;
      if (lp == null) return true;
      final dyn = (lp as dynamic).isMicrophoneEnabled;
      if (dyn is bool) return dyn;
      final res = (lp as dynamic).isMicrophoneEnabled();
      if (res is bool) return res;
    } catch (_) {}
    return true;
  }

  bool _isLocalCamEnabledFromRoom(Room? room) {
    try {
      final lp = room?.localParticipant;
      if (lp == null) return true;
      final dyn = (lp as dynamic).isCameraEnabled;
      if (dyn is bool) return dyn;
      final res = (lp as dynamic).isCameraEnabled();
      if (res is bool) return res;
    } catch (_) {}
    return true;
  }

  /// Return the first available VideoTrack for a remote participant, or null.
  VideoTrack? _getRemoteVideoTrack(RemoteParticipant p) {
    try {
      for (final pub in p.trackPublications.values) {
        try {
          final track = (pub as dynamic).track;
          if (track is VideoTrack) return track as VideoTrack;
        } catch (_) {}
      }
    } catch (_) {}
    return null;
  }

  /// Return the first available local VideoTrack (published by our localParticipant), or null.
  VideoTrack? _getLocalVideoTrack() {
    try {
      final lp = _room?.localParticipant;
      if (lp == null) return null;
      for (final pub in lp.trackPublications.values) {
        try {
          final track = (pub as dynamic).track;
          if (track is VideoTrack) return track as VideoTrack;
        } catch (_) {}
      }
    } catch (_) {}
    return null;
  }

  // -------------------------

  /// Helper to map a participant identity to the provided participants metadata
  Map<String, dynamic>? _metaForIdentity(String id) {
    if (widget.participants == null) return null;
    try {
      final found = widget.participants!.firstWhere((m) => (m['id']?.toString() ?? '') == id, orElse: () => <String, dynamic>{});
      return found.isEmpty ? null : found;
    } catch (_) {
      return null;
    }
  }

  Widget _participantTile(RemoteParticipant p, {bool large = false}) {
    final identity = p.identity;
    final meta = _metaForIdentity(identity) ?? {};
    final displayName = (meta['username'] as String?) ?? identity;
    final avatar = (meta['avatarUrl'] as String?) ?? '';

    // speaking detection (best-effort, may not exist on all SDK bindings)
    bool isSpeaking = false;
    try {
      final dyn = p as dynamic;
      final val = dyn.isSpeaking;
      if (val is bool) isSpeaking = val;
    } catch (_) {}

    // attempt to show renderer when available
    final videoTrack = _getRemoteVideoTrack(p);

    return GestureDetector(
      onTap: () {
        setState(() {
          _pinnedIdentity = (_pinnedIdentity == identity) ? null : identity;
        });
      },
      child: Container(
        margin: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          children: [
            Positioned.fill(
              child: videoTrack != null
                  ? VideoTrackRenderer(videoTrack)
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: large ? 48 : 36,
                            backgroundColor: Colors.grey[850],
                            backgroundImage: avatar.isNotEmpty ? CachedNetworkImageProvider(avatar) : null,
                            child: avatar.isEmpty ? Text(displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U', style: const TextStyle(fontSize: 20)) : null,
                          ),
                          const SizedBox(height: 8),
                          Text(displayName, style: const TextStyle(color: Colors.white)),
                          if (!large) const SizedBox(height: 6),
                        ],
                      ),
                    ),
            ),

            // speaking indicator / metadata
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.32), borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Icon(isSpeaking ? Icons.volume_up : Icons.person, size: 14, color: isSpeaking ? Colors.greenAccent : Colors.white70),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 120,
                    child: Text(identity, style: const TextStyle(fontSize: 12, color: Colors.white70), overflow: TextOverflow.ellipsis),
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGridArea() {
    final remoteParticipants = _room?.remoteParticipants.values.toList() ?? <RemoteParticipant>[];

    if (!_joined) {
      final callerName = widget.participants?.firstWhere((p) => p['id'] == widget.callerId, orElse: () => {'username': 'Host'})['username'] as String? ?? 'Host';
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(radius: 48, child: Text((callerName.isNotEmpty) ? callerName[0].toUpperCase() : 'G')),
            const SizedBox(height: 12),
            Text(callerName, style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 6),
            const Text('Incoming group video call', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 18),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      await GroupRtcManager.answerGroupCall(groupId: widget.callId, peerId: widget.callerId);
                      await _joinRoom();
                    } catch (e) {
                      debugPrint('accept group call error: $e');
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to accept call')));
                    }
                  },
                  icon: const Icon(Icons.call),
                  label: const Text('Accept'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: () async {
                    await GroupRtcManager.rejectGroupCall(groupId: widget.callId, peerId: widget.callerId);
                    if (mounted) Navigator.of(context).maybePop();
                  },
                  icon: const Icon(Icons.call_end),
                  label: const Text('Reject'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                ),
              ],
            )
          ],
        ),
      );
    }

    if (remoteParticipants.isEmpty) {
      return const Center(child: Text('Waiting for participants...', style: TextStyle(color: Colors.white70)));
    }

    if (_pinnedIdentity != null) {
      final pinned = remoteParticipants.firstWhere((p) => p.identity == _pinnedIdentity, orElse: () => remoteParticipants.first);
      final others = remoteParticipants.where((p) => p.identity != pinned.identity).toList();
      return Column(
        children: [
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.all(10), child: _participantTile(pinned, large: true))),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: GridView.count(
                crossAxisCount: (others.length <= 2) ? 2 : (others.length <= 4 ? 3 : 4),
                children: others.map((p) => _participantTile(p)).toList(),
              ),
            ),
          ),
        ],
      );
    }

    final count = remoteParticipants.length;
    final int cols = count == 1 ? 1 : (count == 2 ? 2 : (count <= 4 ? 2 : 3));
    return GridView.count(
      padding: const EdgeInsets.all(8),
      crossAxisCount: cols,
      childAspectRatio: 3 / 4,
      children: remoteParticipants.map((p) => _participantTile(p)).toList(),
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        child: Row(
          children: [
            InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black.withOpacity(0.28), shape: BoxShape.circle), child: const Icon(Icons.close, size: 20)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Group Call', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)), const SizedBox(height: 2), Text(_formatDuration(_callDuration), style: const TextStyle(fontSize: 12, color: Colors.white70))])),
            IconButton(onPressed: () {}, icon: const Icon(Icons.people), color: Colors.white70),
            IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 12.0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: Colors.black.withOpacity(0.35), border: Border.all(color: Colors.white10)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(onPressed: _toggleMic, icon: Icon(_micEnabled ? Icons.mic : Icons.mic_off), color: _micEnabled ? Colors.white : Colors.redAccent),
              IconButton(onPressed: _toggleCamera, icon: Icon(_camEnabled ? Icons.videocam : Icons.videocam_off), color: _camEnabled ? Colors.white : Colors.redAccent),
              ElevatedButton(
                onPressed: _endCall,
                style: ElevatedButton.styleFrom(shape: const CircleBorder(), padding: const EdgeInsets.all(14), backgroundColor: Colors.red),
                child: const Icon(Icons.call_end, size: 26),
              ),
              IconButton(onPressed: () {}, icon: const Icon(Icons.chat_bubble_outline), color: Colors.white),
              IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert), color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBackground() {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFF070707), Color(0xFF0D0F14)], begin: Alignment.topLeft, end: Alignment.bottomRight),
            ),
          ),
        ),
        Positioned(left: -120, top: -160, child: Container(width: 380, height: 380, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [Colors.deepPurple.withOpacity(0.16), Colors.transparent])))),
        Positioned(right: -120, bottom: -150, child: Container(width: 320, height: 320, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [Colors.teal.withOpacity(0.12), Colors.transparent])))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          _buildBackground(),
          Column(
            children: [
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0), child: _buildTopBar()),
              Expanded(child: _buildGridArea()),
              _buildControls(),
            ],
          ),
        ],
      ),
    );
  }
}
