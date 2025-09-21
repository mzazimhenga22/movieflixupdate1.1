// lib/components/socialsection/VoiceCallScreen_Group.dart
// Group voice call UI wired to GroupRtcManager (LiveKit + Firestore signalling).
// Named `VoiceCallScreen` so it matches the call sites in Group_chat_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:movie_app/webrtc/group_rtc_manager.dart';

class VoiceCallScreen extends StatefulWidget {
  final String callId;
  final String callerId;
  final String groupId;
  final String receiverId;
  final List<Map<String, dynamic>>? participants;

  const VoiceCallScreen({
    super.key,
    required this.callId,
    required this.callerId,
    required this.groupId,
    required this.receiverId,
    this.participants,
  });

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen> with SingleTickerProviderStateMixin {
  Room? _room;

  /// This can be either:
  ///  - a StreamSubscription<RoomEvent> (if room.events is a Stream and .listen() was used),
  ///  - or a CancelListenFunc / callable (some LiveKit bindings return a cancel function).
  dynamic _roomEventsSub;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callSub;

  bool _joined = false;
  bool _micEnabled = true;
  Timer? _durationTimer;
  Duration _callDuration = Duration.zero;

  late final AnimationController _controlsAnim;
  late final AnimationController _pulseAnim;

  @override
  void initState() {
    super.initState();
    _controlsAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
    _pulseAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
    _listenToCallDoc();

    // If caller is the current local user we auto-join (caller invited).
    // Keep as-is unless you want to pass currentUserId into the widget.
    if (widget.receiverId == widget.callerId) {
      _joinVoice();
    }
  }

  Future<void> _listenToCallDoc() async {
    try {
      _callSub = GroupRtcManager.groupCallStream(widget.callId).listen((snap) async {
        if (!snap.exists) return;
        final data = snap.data() ?? {};
        final status = data['status'] as String? ?? '';
        if (status == 'ended' || status == 'rejected') {
          await _leaveAndClose();
        }
        if (!_joined && status == 'ongoing') {
          await _joinVoice();
        }
      }, onError: (err) {
        debugPrint('voice call doc listen error: $err');
      });
    } catch (e) {
      debugPrint('listenToCallDoc error: $e');
    }
  }

  Future<void> _joinVoice() async {
    if (_joined) return;
    try {
      final room = await GroupRtcManager.getTokenAndJoinGroup(
        groupId: widget.callId,
        userId: widget.receiverId,
        userName: widget.receiverId,
        enableAudio: true,
        enableVideo: false,
      );

      // Subscribe to room events. Different LiveKit bindings may expose events differently:
      // - some expose a Stream<RoomEvent> in `room.events`, so .listen(...) returns StreamSubscription
      // - others return a CancelListenFunc (callable) when you attach a listener
      try {
        final eventsObj = room.events;
        // try the common case: eventsObj is a Stream
        if (eventsObj is Stream<RoomEvent>) {
          _roomEventsSub = eventsObj.listen((event) {
            if (!mounted) return;
            setState(() {
              final lp = room.localParticipant;
              try {
                _micEnabled = lp?.isMicrophoneEnabled() ?? _micEnabled;
              } catch (_) {}
            });
          });
        } else {
          // fallback: attempt to call .listen if available
          try {
            _roomEventsSub = (eventsObj as dynamic).listen((event) {
              if (!mounted) return;
              setState(() {
                final lp = room.localParticipant;
                try {
                  _micEnabled = lp?.isMicrophoneEnabled() ?? _micEnabled;
                } catch (_) {}
              });
            });
          } catch (_) {
            // last-resort: if eventsObj is a function that accepts a callback and returns a cancel function
            try {
              final cancelFunc = (eventsObj as dynamic)((RoomEvent event) {
                if (!mounted) return;
                setState(() {
                  final lp = room.localParticipant;
                  try {
                    _micEnabled = lp?.isMicrophoneEnabled() ?? _micEnabled;
                  } catch (_) {}
                });
              });
              _roomEventsSub = cancelFunc; // store cancel function to call later
            } catch (err) {
              debugPrint('unable to subscribe to room.events: $err');
              _roomEventsSub = null;
            }
          }
        }
      } catch (e) {
        debugPrint('room events listen error: $e');
        _roomEventsSub = null;
      }

      setState(() {
        _room = room;
        _joined = true;
        final lp = room.localParticipant;
        try {
          _micEnabled = lp?.isMicrophoneEnabled() ?? true;
        } catch (_) {}
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
      setState(() => _callDuration += const Duration(seconds: 1));
    });
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

Future<void> _cancelRoomEventsSubscription() async {
  final sub = _roomEventsSub;
  if (sub == null) return;

  try {
    if (sub is StreamSubscription) {
      await sub.cancel();
    } else {
      try {
        await (sub as dynamic)(); // no need to store result
      } catch (_) {
        // ignore errors from cancel function
      }
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
        await GroupRtcManager.leaveRoom(_room!, groupId: widget.callId, userId: widget.receiverId);
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

  @override
  void dispose() {
    _durationTimer?.cancel();
    _callSub?.cancel();

    // Cancel room events safely (do not await long-running tasks in dispose).
    if (_roomEventsSub is StreamSubscription) {
      try {
        (_roomEventsSub as StreamSubscription).cancel();
      } catch (_) {}
    } else if (_roomEventsSub != null) {
      // If it's a cancel function, call it but don't await.
      try {
        final c = _roomEventsSub;
        (c as dynamic)();
      } catch (_) {}
    }
    _roomEventsSub = null;

    if (_room != null) {
      // best-effort leave; do not await in dispose
      try {
        GroupRtcManager.leaveRoom(_room!, groupId: widget.callId, userId: widget.receiverId);
      } catch (_) {}
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
    if (hh > 0) {
      final hStr = hh.toString().padLeft(2, '0');
      return '$hStr:$mm:$ss';
    }
    return '$mm:$ss';
  }

  Map<String, dynamic>? _metaForParticipant(String id) {
    final parts = widget.participants;
    if (parts == null) return null;
    try {
      final casted = parts.cast<Map<String, dynamic>>();
      final found = casted.firstWhere((m) => (m['id']?.toString() ?? '') == id, orElse: () => <String, dynamic>{});
      return found.isEmpty ? null : found;
    } catch (_) {
      return null;
    }
  }

  Widget _buildTopBar(String displayName, String? avatarUrl) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        child: Row(
          children: [
            InkWell(
                onTap: () => Navigator.of(context).maybePop(),
                child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black.withOpacity(0.28), shape: BoxShape.circle), child: const Icon(Icons.arrow_back, size: 20))),
            const SizedBox(width: 12),
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.grey[800],
              backgroundImage: avatarUrl != null && avatarUrl.isNotEmpty ? CachedNetworkImageProvider(avatarUrl) : null,
              child: (avatarUrl == null || avatarUrl.isEmpty) ? Text(displayName.isNotEmpty ? displayName[0] : 'U', style: const TextStyle(color: Colors.white)) : null,
            ),
            const SizedBox(width: 10),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(displayName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(_joined ? _formatDuration(_callDuration) : 'Connecting...', style: const TextStyle(fontSize: 12, color: Colors.white70))
            ])),
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
                  Transform.scale(scale: scale1, child: Container(width: 140, height: 140, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.blue.withOpacity(0.06 * opacity1)))),
                  Transform.scale(scale: 1.0 + (t * 0.4), child: Container(width: 110, height: 110, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.blue.withOpacity(0.03 * opacity1)))),
                ],
              );
            },
          ),
          CircleAvatar(
            radius: 46,
            backgroundColor: Colors.grey[850],
            backgroundImage: avatarUrl != null && avatarUrl.isNotEmpty ? CachedNetworkImageProvider(avatarUrl) : null,
            child: (avatarUrl == null || avatarUrl.isEmpty) ? Text(displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U', style: const TextStyle(fontSize: 32)) : null,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final meta = _metaForParticipant(widget.callerId) ?? {};
    final avatar = (meta['avatarUrl'] as String?) ?? '';
    final displayName = (meta['username'] as String?) ?? widget.callerId;

    if (!_joined) {
      final isCaller = widget.receiverId == widget.callerId;
      return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        _buildPulseAvatar(avatar.isNotEmpty ? avatar : null, displayName),
        const SizedBox(height: 14),
        Text(displayName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(isCaller ? 'Calling...' : 'Incoming voice call', style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: Colors.black.withOpacity(0.35), borderRadius: BorderRadius.circular(12)),
          child: isCaller
              ? Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  ElevatedButton.icon(onPressed: _endCall, icon: const Icon(Icons.call_end), label: const Text('Cancel'), style: ElevatedButton.styleFrom(backgroundColor: Colors.red)),
                  TextButton(onPressed: () {}, child: const Text('Message', style: TextStyle(color: Colors.white70))),
                ])
              : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  ElevatedButton.icon(
                    onPressed: () async {
                      try {
                        await GroupRtcManager.answerGroupCall(groupId: widget.callId, peerId: widget.receiverId);
                        await _joinVoice();
                      } catch (e) {
                        debugPrint('accept voice error: $e');
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
                      await GroupRtcManager.rejectGroupCall(groupId: widget.callId, peerId: widget.receiverId);
                      if (mounted) Navigator.of(context).maybePop();
                    },
                    icon: const Icon(Icons.call_end),
                    label: const Text('Reject'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  ),
                ]),
        ),
      ]);
    }

    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      _buildPulseAvatar(avatar.isNotEmpty ? avatar : null, displayName),
      const SizedBox(height: 14),
      Text(displayName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text(_formatDuration(_callDuration), style: const TextStyle(fontSize: 16)),
      const SizedBox(height: 20),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: Colors.black.withOpacity(0.35), borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          ElevatedButton.icon(
            onPressed: _toggleMic,
            icon: Icon(_micEnabled ? Icons.mic : Icons.mic_off),
            label: Text(_micEnabled ? 'Mute' : 'Unmute'),
            style: ElevatedButton.styleFrom(backgroundColor: _micEnabled ? Colors.orange : Colors.grey[700]),
          ),
          const SizedBox(width: 14),
          ElevatedButton(
            onPressed: _endCall,
            style: ElevatedButton.styleFrom(shape: const CircleBorder(), padding: const EdgeInsets.all(16), backgroundColor: Colors.red),
            child: const Icon(Icons.call_end, size: 28),
          ),
          const SizedBox(width: 14),
          IconButton(onPressed: () {}, icon: const Icon(Icons.more_horiz), color: Colors.white70),
        ]),
      ),
      const SizedBox(height: 18),
      _participantsStrip(),
    ]);
  }

  Widget _participantsStrip() {
    final members = widget.participants ?? [];
    if (members.isEmpty) return const SizedBox.shrink();
    final visible = members.take(12).toList();
    return SizedBox(
      height: 86,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        scrollDirection: Axis.horizontal,
        itemBuilder: (context, idx) {
          final m = visible[idx];
          final avatar = (m['avatarUrl'] as String?) ?? '';
          final name = (m['username'] as String?) ?? 'User';
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.grey[850],
                backgroundImage: avatar.isNotEmpty ? CachedNetworkImageProvider(avatar) : null,
                child: avatar.isEmpty ? Text(name.isNotEmpty ? name[0].toUpperCase() : 'U') : null,
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: 60,
                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ),
            ],
          );
        },
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemCount: visible.length,
      ),
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
    final meta = _metaForParticipant(widget.callerId) ?? {};
    final displayName = (meta['username'] as String?) ?? 'Contact';
    final avatar = (meta['avatarUrl'] as String?) ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          _buildBackground(),
          SafeArea(
            child: Column(
              children: [
                Padding(padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0), child: _buildTopBar(displayName, avatar)),
                Expanded(child: Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18.0), child: _buildBody()))),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 14.0), child: FadeTransition(opacity: CurvedAnimation(parent: _controlsAnim, curve: Curves.easeIn), child: const SizedBox.shrink())),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
