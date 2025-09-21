// lib/components/socialsection/VoiceCallScreen_1to1.dart
// Sleek 1:1 voice call UI wired to RtcManager (LiveKit + Firestore signalling).
// Updated: caller no longer auto-joins, added ring timeout, listener-driven join.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:cached_network_image/cached_network_image.dart';

class VoiceCallScreen1to1 extends StatefulWidget {
  final String callId;
  final String callerId;
  final String receiverId;
  final String currentUserId;
  final Map<String, dynamic> caller;
  final Map<String, dynamic> receiver;

  const VoiceCallScreen1to1({
    super.key,
    required this.callId,
    required this.callerId,
    required this.receiverId,
    required this.currentUserId,
    required this.caller,
    required this.receiver,
  });

  @override
  State<VoiceCallScreen1to1> createState() => _VoiceCallScreen1to1State();
}

/// Local frosted container for consistent look & feel
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
    final accent = Theme.of(context).colorScheme.secondary.withOpacity(0.14);
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
              blurRadius: elevation,
              offset: Offset(0, elevation / 3),
            ),
            BoxShadow(
              color: accent.withOpacity(0.03),
              blurRadius: elevation * 1.6,
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
                    colors: [Colors.white.withOpacity(0.012), Colors.transparent, Colors.white.withOpacity(0.008)],
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

class _VoiceCallScreen1to1State extends State<VoiceCallScreen1to1> with TickerProviderStateMixin {
  Room? _room;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callSub;
  CancelListenFunc? _roomEventsCancel;

  bool _joined = false;
  bool _micEnabled = true;
  Timer? _durationTimer;
  Duration _callDuration = Duration.zero;

  Timer? _ringTimeout;
  static const int _defaultRingSeconds = 60;

  late final AnimationController _controlsAnim;
  late final AnimationController _pulseAnim;

  @override
  void initState() {
    super.initState();
    _controlsAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
    _pulseAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

    // Start listening to call document immediately.
    _listenToCallDoc();

    // If this device is the caller, mark call as 'ringing' (if not already) and start timeout.
    final amCaller = widget.currentUserId == widget.callerId;
    if (amCaller) {
      _markCallRinging();
      _startRingTimeout(seconds: _defaultRingSeconds);
    }
    // Important: do NOT auto-join here. Joining is driven by call doc status -> 'ongoing'.
  }

  // -------------------------
  // Small helpers
  String _displayNameForOther() {
    final other = widget.currentUserId == widget.callerId ? widget.receiver : widget.caller;
    final name = other['username'];
    if (name is String && name.isNotEmpty) return name;
    return 'Contact';
  }

  String? _avatarUrlForOther() {
    final other = widget.currentUserId == widget.callerId ? widget.receiver : widget.caller;
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

  Future<void> _listenToCallDoc() async {
    _callSub = RtcManager.callStream(widget.callId).listen((snap) async {
      if (!snap.exists) return;
      final data = snap.data() ?? {};
      final status = (data['status'] as String?) ?? '';

      // If call ended or rejected or no_answer, leave/close.
      if (status == 'ended' || status == 'rejected' || status == 'no_answer') {
        await _leaveAndClose();
        return;
      }

      // If call moved to ongoing and we haven't joined yet, join now.
      if (!_joined && status == 'ongoing') {
        // If caller had ring timeout running, cancel it
        _cancelRingTimeout();
        await _joinVoice();
      }

      // Additional states (optional): could show 'ringing' UI, etc.
      // We keep the UI reactive to the _joined boolean and the call doc status.
    }, onError: (err) {
      debugPrint('call doc listen error: $err');
    });
  }

  Future<void> _joinVoice() async {
    if (_joined) return;
    try {
      final room = await RtcManager.getTokenAndJoin(
        callId: widget.callId,
        userId: widget.currentUserId,
        userName: (widget.currentUserId == widget.callerId ? widget.caller['username'] : widget.receiver['username']) ?? widget.currentUserId,
        enableAudio: true,
        enableVideo: false,
      );

      try {
        _roomEventsCancel = room.events.listen((event) {
          if (mounted) setState(() {
            _micEnabled = _isLocalMicEnabledFromRoom(room);
          });
        });
      } catch (_) {
        _roomEventsCancel = null;
      }

      if (!mounted) {
        // If widget unmounted while joining, ensure we still leave to avoid resource leak.
        try {
          await RtcManager.leaveRoom(room, callId: widget.callId, userId: widget.currentUserId);
        } catch (_) {}
        return;
      }

      setState(() {
        _room = room;
        _joined = true;
        final lp = room.localParticipant;
        _micEnabled = (lp?.isMicrophoneEnabled == true) || _isLocalMicEnabledFromRoom(room);
      });

      _startTimer();
      _controlsAnim.forward();
      _pulseAnim.stop();
    } catch (e, st) {
      debugPrint('join voice failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to join voice call')));
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

    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _endCall() async {
    try {
      await RtcManager.endCall(callId: widget.callId, endedBy: widget.currentUserId);
    } catch (_) {}
    await _leaveAndClose();
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
    _pulseAnim.dispose();
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
    final name = _displayNameForOther();
    final avatarUrl = _avatarUrlForOther();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        child: Row(
          children: [
            InkWell(
              onTap: () => Navigator.of(context).maybePop(),
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

  Widget _buildPulseAvatar(String? avatarUrl, String displayName) {
    return SizedBox(
      width: 160,
      height: 160,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulseAnim,
            builder: (context, child) {
              final t = _pulseAnim.value;
              final scale1 = 1.0 + t * 0.9;
              final opacity1 = (1.0 - t).clamp(0.0, 1.0);
              return Stack(
                alignment: Alignment.center,
                children: [
                  Transform.scale(
                    scale: scale1,
                    child: Container(width: 140, height: 140, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.blue.withOpacity(0.06 * opacity1))),
                  ),
                  Transform.scale(
                    scale: 1.0 + (t * 0.4),
                    child: Container(width: 110, height: 110, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.blue.withOpacity(0.03 * opacity1))),
                  ),
                ],
              );
            },
          ),
          CircleAvatar(
            radius: 46,
            backgroundColor: Colors.grey[850],
            backgroundImage: avatarUrl != null ? CachedNetworkImageProvider(avatarUrl) : null,
            child: avatarUrl == null ? Text(displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U', style: const TextStyle(fontSize: 32)) : null,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final other = widget.currentUserId == widget.callerId ? widget.receiver : widget.caller;
    final avatarUrl = (other['avatarUrl'] as String?);
    final displayName = (other['username'] as String?) ?? 'Contact';

    if (!_joined) {
      final amCaller = widget.currentUserId == widget.callerId;
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildPulseAvatar(avatarUrl, displayName),
          const SizedBox(height: 14),
          Text(displayName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(amCaller ? 'Calling...' : 'Incoming voice call', style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 20),
          _FrostedContainer(
            borderRadius: BorderRadius.circular(14),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: amCaller
                ? Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    ElevatedButton.icon(
                      onPressed: _endCall,
                      icon: const Icon(Icons.call_end),
                      label: const Text('Cancel'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
                    ),
                    TextButton(onPressed: () {}, child: const Text('Message', style: TextStyle(color: Colors.white70))),
                  ])
                : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    ScaleTransition(
                      scale: CurvedAnimation(parent: _controlsAnim, curve: Curves.elasticOut),
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          try {
                            // Prefer RtcManager.acceptCall to handle signaling, but ensure call doc is set to 'ongoing'
                            await RtcManager.acceptCall(callId: widget.callId, userId: widget.currentUserId);

                            // Update call doc status to 'ongoing' so listeners join the room (idempotent)
                            await _setCallStatus('ongoing', extra: {
                              'acceptedAt': FieldValue.serverTimestamp(),
                              'acceptedBy': widget.currentUserId
                            });

                            // Listener will call _joinVoice() when it sees 'ongoing', so no immediate _joinVoice() here.
                            // If you prefer the receiver to join instantly, you can call _joinVoice() here as well;
                            // but keep the listener/join flow to avoid race conditions.
                          } catch (e) {
                            debugPrint('accept error: $e');
                            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to accept call')));
                          }
                        },
                        icon: const Icon(Icons.call),
                        label: const Text('Accept'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ScaleTransition(
                      scale: CurvedAnimation(parent: _controlsAnim, curve: Curves.easeOutBack),
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
                        label: const Text('Reject'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
                      ),
                    ),
                  ]),
          ),
        ],
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildPulseAvatar(avatarUrl, displayName),
        const SizedBox(height: 14),
        Text(displayName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(_formatDuration(_callDuration), style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 20),
        _FrostedContainer(
          borderRadius: BorderRadius.circular(14),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            ElevatedButton.icon(
              onPressed: _toggleMic,
              icon: Icon(_micEnabled ? Icons.mic : Icons.mic_off),
              label: Text(_micEnabled ? 'Mute' : 'Unmute'),
              style: ElevatedButton.styleFrom(backgroundColor: _micEnabled ? Colors.orange : Colors.grey[700], padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
            ),
            const SizedBox(width: 14),
            ElevatedButton(
              onPressed: _endCall,
              style: ElevatedButton.styleFrom(shape: const CircleBorder(), padding: const EdgeInsets.all(16), backgroundColor: Colors.red, elevation: 8),
              child: const Icon(Icons.call_end, size: 28),
            ),
            const SizedBox(width: 14),
            IconButton(onPressed: () {}, icon: const Icon(Icons.more_horiz), color: Colors.white70),
          ]),
        ),
      ],
    );
  }

  Widget _buildBackground() {
    return Stack(
      children: [
        Positioned.fill(child: Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF060606), Color(0xFF0D0F14)], begin: Alignment.topLeft, end: Alignment.bottomRight)))),
        Positioned(left: -120, top: -120, child: Container(width: 300, height: 300, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [Colors.deepPurple.withOpacity(0.14), Colors.transparent])))),
        Positioned(right: -120, bottom: -120, child: Container(width: 260, height: 260, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [Colors.teal.withOpacity(0.10), Colors.transparent])))),
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
                  padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                  child: _FrostedContainer(borderRadius: BorderRadius.circular(14), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6), child: _buildTopBar()),
                ),
                Expanded(child: Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18.0), child: _buildBody()))),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 14.0), child: FadeTransition(opacity: CurvedAnimation(parent: _controlsAnim, curve: Curves.easeIn), child: const SizedBox(height: 0))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
