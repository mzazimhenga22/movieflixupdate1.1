// lib/components/socialsection/VideoCallScreen_1to1.dart
// Sleek 1:1 video call UI wired to RtcManager (LiveKit + Firestore signalling).
// Updated: caller no longer auto-joins, added ring timeout, listener-driven join.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';

class VideoCallScreen1to1 extends StatefulWidget {
  final String callId;
  final String callerId;
  final String receiverId;
  final String currentUserId;
  final Map<String, dynamic> caller;
  final Map<String, dynamic> receiver;

  const VideoCallScreen1to1({
    super.key,
    required this.callId,
    required this.callerId,
    required this.receiverId,
    required this.currentUserId,
    required this.caller,
    required this.receiver,
  });

  @override
  State<VideoCallScreen1to1> createState() => _VideoCallScreen1to1State();
}

/// Small frosted glass helper from the categories example — reused locally
class _FrostedContainer extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsets? padding;
  final double elevation;
  const _FrostedContainer({
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.padding,
    this.elevation = 12,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary.withOpacity(0.18);
    return ClipRRect(
      borderRadius: borderRadius,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          gradient: LinearGradient(
            colors: [Colors.white.withOpacity(0.03), Colors.white.withOpacity(0.01)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.45),
              blurRadius: elevation.toDouble(),
              offset: Offset(0, elevation / 3),
            ),
            BoxShadow(
              color: accent.withOpacity(0.025),
              blurRadius: elevation.toDouble() * 1.6,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Stack(children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withOpacity(0.012),
                      Colors.transparent,
                      Colors.white.withOpacity(0.008)
                    ],
                    stops: const [0.0, 0.6, 1.0],
                  ),
                ),
              ),
            ),
          ),
          child,
        ]),
      ),
    );
  }
}

class _VideoCallScreen1to1State extends State<VideoCallScreen1to1> with SingleTickerProviderStateMixin {
  Room? _room;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callSub;
  CancelListenFunc? _roomEventsCancel;

  bool _joined = false;
  bool _micEnabled = true;
  bool _camEnabled = true;
  Timer? _durationTimer;
  Duration _callDuration = Duration.zero;

  // Ring timeout for caller
  Timer? _ringTimeout;
  static const int _defaultRingSeconds = 60;

  // small animation for accept/reject buttons & appearing controls
  late final AnimationController _controlsAnim;

  @override
  void initState() {
    super.initState();
    _controlsAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
    _listenToCallDoc();

    // If this device is the caller, mark call as 'ringing' and start timeout.
    final amCaller = widget.currentUserId == widget.callerId;
    if (amCaller) {
      _markCallRinging();
      _startRingTimeout(seconds: _defaultRingSeconds);
    }
    // IMPORTANT: do NOT auto-join here. Joining is driven by call doc status -> 'ongoing'.
  }

  // -------------------------
  // Helpers to safely handle user fields
  String _displayNameForOther(bool amCaller) {
    final other = amCaller ? widget.receiver : widget.caller;
    final name = other['username'];
    if (name is String && name.isNotEmpty) return name;
    return 'Contact';
  }

  String? _avatarUrlForOther(bool amCaller) {
    final other = amCaller ? widget.receiver : widget.caller;
    final avatar = other['avatarUrl'];
    if (avatar is String && avatar.isNotEmpty) return avatar;
    return null;
  }

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

  Future<void> _markCallRinging() async {
    try {
      await FirebaseFirestore.instance.collection('calls').doc(widget.callId).set({
        'status': 'ringing',
        'callerId': widget.callerId,
        'receiverId': widget.receiverId,
        'startedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('failed to mark call ringing: $e');
    }
  }

  Future<void> _setCallStatus(String status, {Map<String, dynamic>? extra}) async {
    try {
      final data = <String, dynamic>{'status': status};
      if (extra != null) data.addAll(extra);
      await FirebaseFirestore.instance.collection('calls').doc(widget.callId).set(data, SetOptions(merge: true));
    } catch (e) {
      debugPrint('failed to set call status to $status: $e');
    }
  }

  // -------------------------

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

  Future<void> _listenToCallDoc() async {
    _callSub = RtcManager.callStream(widget.callId).listen((snap) async {
      if (!snap.exists) return;
      final data = snap.data() ?? {};
      final status = (data['status'] as String?) ?? '';

      // Remote ended or rejected or no_answer -> leave + pop
      if (status == 'ended' || status == 'rejected' || status == 'no_answer') {
        await _leaveAndClose();
        return;
      }

      // If call moved to ongoing and we haven't joined yet, join now.
      if (!_joined && status == 'ongoing') {
        _cancelRingTimeout();
        await _joinRoom();
      }

      // Other statuses (e.g. 'ringing') are fine — UI will reflect calling/incoming.
    }, onError: (err) {
      debugPrint('call doc listen error: $err');
    });
  }

  Future<void> _joinRoom() async {
    if (_joined) return;
    try {
      final room = await RtcManager.getTokenAndJoin(
        callId: widget.callId,
        userId: widget.currentUserId,
        userName: (widget.currentUserId == widget.callerId ? widget.caller['username'] : widget.receiver['username']) ?? widget.currentUserId,
        enableAudio: true,
        enableVideo: true,
      );

      try {
        _roomEventsCancel = room.events.listen((event) {
          if (mounted) setState(() {
            // update mirrored local mic/cam states defensively
            _micEnabled = _isLocalMicEnabledFromRoom(room);
            _camEnabled = _isLocalCamEnabledFromRoom(room);
          });
        });
      } catch (e) {
        debugPrint('room.events.listen binding failed: $e');
      }

      if (!mounted) {
        // if unmounted while joining, leave to avoid leaks
        try {
          await RtcManager.leaveRoom(room, callId: widget.callId, userId: widget.currentUserId);
        } catch (_) {}
        return;
      }

      setState(() {
        _room = room;
        _joined = true;
        _micEnabled = _isLocalMicEnabledFromRoom(room);
        _camEnabled = _isLocalCamEnabledFromRoom(room);
      });

      _startDurationTimer();
      _controlsAnim.forward();
    } catch (e, st) {
      debugPrint('Failed to join room: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to join call')));
        Navigator.of(context).maybePop();
      }
    }
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _callDuration = Duration.zero;
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _callDuration = _callDuration + const Duration(seconds: 1);
      });
    });
  }

  Future<void> _leaveAndClose() async {
    _durationTimer?.cancel();
    _cancelRingTimeout();

    if (_roomEventsCancel != null) {
      try {
        await _roomEventsCancel!();
      } catch (_) {}
      _roomEventsCancel = null;
    }

    if (_room != null) {
      try {
        await RtcManager.leaveRoom(_room!, callId: widget.callId, userId: widget.currentUserId);
      } catch (_) {}
      _room = null;
    }

    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _endCall() async {
    try {
      await RtcManager.endCall(callId: widget.callId, endedBy: widget.currentUserId);
    } catch (_) {}
    await _leaveAndClose();
  }

  Future<void> _toggleMic() async {
    if (_room == null) return;
    try {
      final enabled = await RtcManager.toggleMic(_room!);
      if (enabled != null) {
        setState(() => _micEnabled = enabled);
      } else {
        setState(() => _micEnabled = _isLocalMicEnabledFromRoom(_room));
      }
    } catch (e) {
      debugPrint('toggle mic error: $e');
      setState(() => _micEnabled = _isLocalMicEnabledFromRoom(_room));
    }
  }

  Future<void> _toggleCamera() async {
    if (_room == null) return;
    try {
      final enabled = await RtcManager.toggleCamera(_room!);
      if (enabled != null) {
        setState(() => _camEnabled = enabled);
      } else {
        setState(() => _camEnabled = _isLocalCamEnabledFromRoom(_room));
      }
    } catch (e) {
      debugPrint('toggle camera error: $e');
      setState(() => _camEnabled = _isLocalCamEnabledFromRoom(_room));
    }
  }

  // -------------------------
  // Ring timeout helpers (caller side)
  void _startRingTimeout({int seconds = _defaultRingSeconds}) {
    _ringTimeout?.cancel();
    _ringTimeout = Timer(Duration(seconds: seconds), () async {
      try {
        final doc = await FirebaseFirestore.instance.collection('calls').doc(widget.callId).get();
        final data = doc.data();
        final status = (data?['status'] as String?) ?? '';
        if (status == 'ringing') {
          await FirebaseFirestore.instance.collection('calls').doc(widget.callId).set({
            'status': 'no_answer',
            'endedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No answer')));
            Navigator.of(context).maybePop();
          }
        }
      } catch (e) {
        debugPrint('ring timeout handling error: $e');
      }
    });
  }

  void _cancelRingTimeout() {
    _ringTimeout?.cancel();
    _ringTimeout = null;
  }

  @override
  void dispose() {
    _ringTimeout?.cancel();
    _durationTimer?.cancel();
    _callSub?.cancel();

    if (_roomEventsCancel != null) {
      try {
        _roomEventsCancel!();
      } catch (_) {}
      _roomEventsCancel = null;
    }

    if (_room != null) {
      final r = _room;
      Future.microtask(() async {
        try {
          await RtcManager.leaveRoom(r!, callId: widget.callId, userId: widget.currentUserId);
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
    if (hh > 0) return '$hh:$mm:$ss';
    return '$mm:$ss';
  }

  Widget _buildTopBar() {
    final amCaller = widget.currentUserId == widget.callerId;
    final name = _displayNameForOther(amCaller);
    final avatarUrl = _avatarUrlForOther(amCaller);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        child: Row(
          children: [
            InkWell(
              onTap: () {
                Navigator.of(context).maybePop();
              },
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.28), shape: BoxShape.circle),
                child: const Icon(Icons.arrow_back, size: 20),
              ),
            ),
            const SizedBox(width: 12),
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.grey[800],
              backgroundImage: avatarUrl != null ? CachedNetworkImageProvider(avatarUrl) : null,
              child: avatarUrl == null ? Text((name.isNotEmpty ? name[0] : 'U'), style: const TextStyle(color: Colors.white)) : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(_joined ? _formatDuration(_callDuration) : 'Connecting...', style: const TextStyle(fontSize: 12, color: Colors.white70)),
              ]),
            ),
            IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)),
          ],
        ),
      ),
    );
  }

  Widget _buildIncomingCard(bool amCaller) {
    final other = amCaller ? widget.receiver : widget.caller;
    final avatarUrl = other['avatarUrl'] as String?;
    final displayName = (other['username'] as String?) ?? 'Contact';

    // For caller: show Cancel + Message similar to voice UI
    if (amCaller) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: _FrostedContainer(
            borderRadius: BorderRadius.circular(18),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (avatarUrl != null)
                  CircleAvatar(radius: 54, backgroundImage: CachedNetworkImageProvider(avatarUrl))
                else
                  CircleAvatar(radius: 54, backgroundColor: Colors.grey[800], child: Text(displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U', style: const TextStyle(fontSize: 36))),
                const SizedBox(height: 14),
                Text(displayName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const Text('Calling...', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 18),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _endCall,
                      icon: const Icon(Icons.call_end),
                      label: const Text('Cancel'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
                    ),
                    const SizedBox(width: 12),
                    TextButton(onPressed: () {}, child: const Text('Message', style: TextStyle(color: Colors.white70))),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    // For callee: Accept / Decline
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: _FrostedContainer(
          borderRadius: BorderRadius.circular(18),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (avatarUrl != null)
                CircleAvatar(radius: 54, backgroundImage: CachedNetworkImageProvider(avatarUrl))
              else
                CircleAvatar(radius: 54, backgroundColor: Colors.grey[800], child: Text(displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U', style: const TextStyle(fontSize: 36))),
              const SizedBox(height: 14),
              Text(displayName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text('Video Call', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 18),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ScaleTransition(
                    scale: CurvedAnimation(parent: _controlsAnim, curve: Curves.easeOutBack),
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        try {
                          // Let RtcManager perform any accept-side work (permissions etc.)
                          await RtcManager.acceptCall(callId: widget.callId, userId: widget.currentUserId);

                          // Mark call doc as 'ongoing' so listeners (both sides) will join via _listenToCallDoc.
                          await _setCallStatus('ongoing', extra: {
                            'acceptedAt': FieldValue.serverTimestamp(),
                            'acceptedBy': widget.currentUserId
                          });

                          // Optionally you could call _joinRoom() here directly for faster receiver join,
                          // but the listener will trigger _joinRoom() when it sees 'ongoing'.
                        } catch (e) {
                          debugPrint('accept error: $e');
                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to accept call')));
                        }
                      },
                      icon: const Icon(Icons.call),
                      label: const Text('Accept'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ScaleTransition(
                    scale: Tween<double>(begin: 0.6, end: 1.0).animate(CurvedAnimation(parent: _controlsAnim, curve: Curves.elasticOut)),
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        try {
                          await RtcManager.rejectCall(callId: widget.callId, rejectedBy: widget.currentUserId);
                          await _setCallStatus('rejected', extra: {
                            'rejectedAt': FieldValue.serverTimestamp(),
                            'rejectedBy': widget.currentUserId
                          });
                        } catch (e) {
                          debugPrint('reject error: $e');
                        } finally {
                          if (mounted) Navigator.of(context).maybePop();
                        }
                      },
                      icon: const Icon(Icons.call_end),
                      label: const Text('Decline'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoArea() {
    final List<RemoteParticipant> remoteParticipants = _room?.remoteParticipants.values.toList() ?? <RemoteParticipant>[];

    if (!_joined) {
      final amCaller = widget.currentUserId == widget.callerId;
      return _buildIncomingCard(amCaller);
    }

    // When joined, show remote participant preview (renderer)
    Widget remoteView;
    if (remoteParticipants.isEmpty) {
      remoteView = Container(
        color: Colors.black,
        child: const Center(child: Text('Waiting for participant...', style: TextStyle(color: Colors.white70))),
      );
    } else {
      final p = remoteParticipants.first;
      final videoTrack = _getRemoteVideoTrack(p);

      if (videoTrack != null) {
        // Use LiveKit's VideoTrackRenderer to show remote video.
        remoteView = ClipRRect(
          borderRadius: BorderRadius.zero,
          child: VideoTrackRenderer(videoTrack),
        );
      } else {
        // fallback placeholder if remote has no attached/subscribed video track yet
        remoteView = Container(
          color: Colors.black,
          child: Center(
            child: Container(
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: Colors.black87),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(radius: 46, backgroundColor: Colors.grey[850], child: Text(remoteParticipants.first.identity.isNotEmpty ? remoteParticipants.first.identity[0].toUpperCase() : 'U', style: const TextStyle(fontSize: 28))),
                    const SizedBox(height: 10),
                    Text(remoteParticipants.first.identity, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    const Text('Remote participant video placeholder', style: TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    }

    // Local preview (draggable small window). Use local published video track if available.
    final localVideoTrack = _getLocalVideoTrack();
    final localPreview = Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 14.0, bottom: 90.0),
        child: GestureDetector(
          onTap: () {},
          child: Hero(
            tag: 'local_preview_${widget.callId}',
            child: Container(
              width: 120,
              height: 160,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.grey[900],
                border: Border.all(color: Colors.white24),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 10, offset: const Offset(0, 4))],
              ),
              clipBehavior: Clip.hardEdge,
              child: localVideoTrack != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: VideoTrackRenderer(localVideoTrack),
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.person, size: 36),
                          const SizedBox(height: 8),
                          Text('You', style: TextStyle(color: Colors.white.withOpacity(0.9))),
                          const SizedBox(height: 6),
                          Icon(_camEnabled ? Icons.videocam : Icons.videocam_off, size: 18, color: _camEnabled ? Colors.white70 : Colors.redAccent),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );

    return Stack(children: [
      Positioned.fill(child: remoteView),
      localPreview,
    ]);
  }

  Widget _buildControls() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 12.0),
        child: _FrostedContainer(
          borderRadius: BorderRadius.circular(14),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(
                onPressed: _toggleMic,
                icon: Icon(_micEnabled ? Icons.mic : Icons.mic_off),
                color: _micEnabled ? Colors.white : Colors.redAccent,
                tooltip: _micEnabled ? 'Mute' : 'Unmute',
              ),
              IconButton(
                onPressed: _toggleCamera,
                icon: Icon(_camEnabled ? Icons.videocam : Icons.videocam_off),
                color: _camEnabled ? Colors.white : Colors.redAccent,
                tooltip: _camEnabled ? 'Camera On' : 'Camera Off',
              ),
              // big center hangup
              ElevatedButton(
                onPressed: _endCall,
                style: ElevatedButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(14),
                  backgroundColor: Colors.red,
                  elevation: 8,
                ),
                child: const Icon(Icons.call_end, size: 26),
              ),
              IconButton(
                onPressed: () {
                  debugPrint('switch camera tapped');
                },
                icon: const Icon(Icons.cameraswitch),
                color: Colors.white,
              ),
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.more_vert),
                color: Colors.white70,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // background gradient + subtle animated radial accents
  Widget _buildBackground() {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF070707), Color(0xFF0D0F14)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        Positioned(
          left: -120,
          top: -160,
          child: Transform.rotate(
            angle: -0.4,
            child: Container(
              width: 380,
              height: 380,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Colors.deepPurple.withOpacity(0.18), Colors.transparent],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: -120,
          bottom: -150,
          child: Container(
            width: 320,
            height: 320,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Colors.teal.withOpacity(0.12), Colors.transparent],
              ),
            ),
          ),
        ),
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
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                  child: _FrostedContainer(
                    borderRadius: BorderRadius.circular(14),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    child: _buildTopBar(),
                  ),
                ),
                Expanded(child: _buildVideoArea()),
                FadeTransition(
                  opacity: CurvedAnimation(parent: _controlsAnim, curve: Curves.easeIn),
                  child: _buildControls(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
