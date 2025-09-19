// lib/components/socialsection/video_call_screen_group.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:movie_app/webrtc/group_rtc_manager.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:animate_do/animate_do.dart';

class VideoCallScreenGroup extends StatefulWidget {
  final String callId; // Firestore doc id for the group call
  final String callerId; // local user's id (used earlier in your code)
  final String? groupId; // optional alias, fallback to callId
  final List<Map<String, dynamic>>? participants;

  const VideoCallScreenGroup({
    super.key,
    required this.callId,
    required this.callerId,
    this.groupId,
    this.participants,
  });

  @override
  State<VideoCallScreenGroup> createState() => _VideoCallScreenGroupState();
}

class _VideoCallScreenGroupState extends State<VideoCallScreenGroup>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  final Map<String, bool> _rendererInitialized = {};
  final Map<String, bool> _rendererDisposed = {};

  bool isMuted = false;
  bool isVideoOff = false;
  bool isSpeakerOn = false;

  Timer? _durationTimer;
  int _callDuration = 0;
  String _formattedDuration = '00:00';

  /// Whether this client has actually joined (published tracks / answered)
  bool _hasJoined = false;

  /// Whether the host (caller) started the call (read from Firestore host field)
  bool _isHost = false;

  /// Focused participant id to show large video
  String? _focusedParticipantId;

  AnimationController? _pulseController;

  final Map<String, String> _participantStatus = {};

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callStatusSub;
  Timer? _attachRetryTimer;
  int _attachAttempts = 0;

  bool _localHungUp = false; // prevent duplicate hangups

  String get _groupKey => widget.groupId ?? widget.callId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat(reverse: true);

    _initRenderersAndState();
    _listenForCallStatus(); // keep listening; will trigger join when a participant becomes 'joined'
  }

  Future<void> _initRenderersAndState() async {
    try {
      await _localRenderer.initialize();
      _rendererInitialized['local'] = true;
      _rendererDisposed['local'] = false;
    } catch (e, st) {
      debugPrint('[VideoGroup] local renderer init error: $e\n$st');
    }

    // init small preview renderers for participants list
    if (widget.participants != null) {
      for (final p in widget.participants!) {
        final id = p['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        if (id == widget.callerId) continue;
        final r = RTCVideoRenderer();
        _remoteRenderers[id] = r;
        try {
          await r.initialize();
          _rendererInitialized[id] = true;
          _rendererDisposed[id] = false;
        } catch (e) {
          debugPrint('[VideoGroup] remote renderer init failed for $id: $e');
        }
        _participantStatus[id] = 'ringing';
      }

      // default focused participant = first other participant or local
      _focusedParticipantId = widget.participants!
          .firstWhere((p) => p['id'] != widget.callerId, orElse: () => {'id': widget.callerId})['id'];
    } else {
      _focusedParticipantId = widget.callerId;
    }

    // Attach local stream if available
    await _attachLocalStream();

    // Read Firestore once to decide whether to join right away.
    await _fetchCallDocAndPossiblyJoin();

    // start an attach retry loop to attach remote streams for a short while
    _startAttachRetryLoop();
    // start duration timer when answered/joined
    _maybeStartDurationTimer();
  }

  Future<void> _fetchCallDocAndPossiblyJoin() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('groupCalls').doc(widget.callId).get();
      if (!doc.exists) return;
      final data = doc.data();
      if (data == null) return;
      final host = data['host']?.toString();
      _isHost = (host != null && host == widget.callerId);

      final Map<String, dynamic>? statusMap = (data['participantStatus'] as Map?)?.cast<String, dynamic>();
      if (statusMap != null) {
        // populate local participantStatus map for UI
        statusMap.forEach((k, v) {
          if (k == widget.callerId) return;
          _participantStatus[k] = v?.toString() ?? 'ringing';
        });
      }

      // If any other participant already 'joined', it's safe to join
      final someoneJoined = _anyOtherJoined(statusMap);
      if (someoneJoined && !_hasJoined) {
        await _joinGroupIfNeeded();
      } else {
        // If host, show "Calling..." UI and wait for someone to join (do not join the room yet)
        // If non-host, show ringing/incoming UI and allow user to answer (we don't auto-answer).
        setState(() {}); // refresh participant statuses
      }
    } catch (e) {
      debugPrint('[VideoGroup] fetchCallDocAndPossiblyJoin error: $e');
    }
  }

  bool _anyOtherJoined(Map<String, dynamic>? statusMap) {
    if (statusMap == null) return false;
    for (final entry in statusMap.entries) {
      final id = entry.key;
      final s = entry.value?.toString() ?? '';
      if (id != widget.callerId && s == 'joined') return true;
    }
    return false;
  }

  Future<void> _attachLocalStream() async {
    try {
      final ms = GroupRtcManager.getLocalStream(_groupKey);
      if (ms != null) {
        _localRenderer.srcObject = ms;
      } else {
        debugPrint('[VideoGroup] local stream not available yet for $_groupKey');
      }
    } catch (e) {
      debugPrint('[VideoGroup] attachLocalStream error: $e');
    }
  }

  Future<void> _joinGroupIfNeeded() async {
    if (_localHungUp || _hasJoined) return; // do not join if user already hung up or already joined
    try {
      // Ask manager to ensure published tracks exist (repairs missing publishes)
      await GroupRtcManager.ensurePublishedTracks(_groupKey, wantVideo: true);

      // Only join (answer) when at least one other participant has joined (UI enforces this)
      // But if user is a non-host and chose to answer manually, allow join via UI too.
      final doc = await FirebaseFirestore.instance.collection('groupCalls').doc(widget.callId).get();
      final statusMap = (doc.exists ? (doc.get('participantStatus') as Map?) : null)?.cast<String, dynamic>();
      final someoneJoined = _anyOtherJoined(statusMap);
      if (!someoneJoined && _isHost) {
        // host should wait until someone joins; don't auto-join
        debugPrint('[VideoGroup] host waiting for participants to join before entering room');
        return;
      }

      await GroupRtcManager.answerGroupCall(groupId: _groupKey, peerId: widget.callerId);
      _hasJoined = true;
      if (!mounted) return;
      setState(() {});
      _maybeStartDurationTimer();
    } catch (e) {
      debugPrint('[VideoGroup] join/answer error: $e');
    }
  }

  void _startAttachRetryLoop() {
    _attachRetryTimer?.cancel();
    _attachAttempts = 0;
    _attachRetryTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (_localHungUp) {
        t.cancel();
        return;
      }
      _attachAttempts++;
      _setupRemoteStreams();
      // try to attach local as well
      await _attachLocalStream();

      if (_attachAttempts >= 12) {
        t.cancel();
      }
    });
  }

  void _setupRemoteStreams() {
    if (widget.participants == null) return;
    for (final participant in widget.participants!) {
      final id = participant['id']?.toString();
      if (id == null || id.isEmpty) continue;
      if (id == widget.callerId) continue;

      try {
        final ms = GroupRtcManager.getRemoteStream(_groupKey, id);
        final renderer = _remoteRenderers[id];
        if (ms != null && renderer != null) {
          // attach if not already attached
          if (renderer.srcObject != ms) {
            renderer.srcObject = ms;
            debugPrint('[VideoGroup] attached remote stream for $id');
          }
        }
      } catch (e) {
        debugPrint('[VideoGroup] setupRemoteStreams error for $id: $e');
      }
    }
  }

  void _listenForCallStatus() {
    try {
      _callStatusSub = FirebaseFirestore.instance
          .collection('groupCalls')
          .doc(widget.callId)
          .snapshots()
          .listen((snapshot) async {
        try {
          final data = snapshot.data();
          if (!mounted) return;
          if (data == null) return;

          final status = data['status'] as String?;
          if (status == 'ended' || status == 'rejected') {
            // verify with fresh read to avoid transient snapshot
            final fresh = await FirebaseFirestore.instance.collection('groupCalls').doc(widget.callId).get();
            final freshStatus = fresh.exists ? (fresh.get('status') as String?) : null;
            if (freshStatus == 'ended' || freshStatus == 'rejected') {
              if (mounted && !_localHungUp) {
                // remote ended; just pop UI (manager may have already cleaned)
                Navigator.of(context).pop();
              }
              return;
            }
          }

          // update participant statuses
          final Map<String, dynamic>? statusMap = (data['participantStatus'] as Map?)?.cast<String, dynamic>();
          if (statusMap != null) {
            bool shouldSetState = false;
            statusMap.forEach((id, s) {
              if (id == widget.callerId) return;
              final newS = s?.toString() ?? 'unknown';
              if (_participantStatus[id] != newS) {
                _participantStatus[id] = newS;
                shouldSetState = true;
              }
            });
            if (shouldSetState && mounted) setState(() {});
          }

          // If we haven't joined yet, and someone else just joined, then join now.
          if (!_hasJoined) {
            final someoneJoinedNow = _anyOtherJoined(statusMap);
            if (someoneJoinedNow) {
              await _joinGroupIfNeeded();
            }
          }

          // active speaker handling
          final active = GroupRtcManager.getActiveSpeaker(_groupKey);
          if (active != null && active != _focusedParticipantId && _remoteRenderers.containsKey(active)) {
            setState(() => _focusedParticipantId = active);
          }

          // try to reattach streams when participants change
          _setupRemoteStreams();
        } catch (e, st) {
          debugPrint('[VideoGroup] callStatus handler error: $e\n$st');
        }
      }, onError: (err) {
        debugPrint('[VideoGroup] call status listen error: $err');
      });
    } catch (e) {
      debugPrint('[VideoGroup] listenForCallStatus setup failed: $e');
    }
  }

  void _maybeStartDurationTimer() {
    _durationTimer?.cancel();
    if (_hasJoined) {
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        _callDuration++;
        _formattedDuration = _formatDuration(_callDuration);
        setState(() {});
      });
    }
  }

  String _formatDuration(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$secs';
  }

  void _switchFocusedParticipant(String participantId) {
    setState(() => _focusedParticipantId = participantId);
    _setupRemoteStreams();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.paused) {
      // detach to avoid GL context issues
      try {
        _localRenderer.srcObject = null;
        for (final r in _remoteRenderers.values) {
          r.srcObject = null;
        }
      } catch (_) {}
    } else if (state == AppLifecycleState.resumed) {
      // reattach attempts
      _attachLocalStream();
      _startAttachRetryLoop();
    }
  }

  Future<void> _handleLocalHangup() async {
    if (_localHungUp) return;
    _localHungUp = true;

    // stop UI interactions immediately
    try {
      setState(() {});
    } catch (_) {}

    try {
      // Ask manager to hang up and wait for it to finish
      await GroupRtcManager.hangUpGroupCall(_groupKey);
      // Also ensure manager disposes caches
      GroupRtcManager.dispose(_groupKey);
    } catch (e) {
      debugPrint('[VideoGroup] error during hangUp: $e');
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController?.dispose();

    try {
      _durationTimer?.cancel();
      _attachRetryTimer?.cancel();
      _callStatusSub?.cancel();
    } catch (_) {}

    // dispose renderers safely
    try {
      _localRenderer.srcObject = null;
      _localRenderer.dispose();
      _rendererDisposed['local'] = true;
    } catch (e) {
      debugPrint('[VideoGroup] error disposing local renderer: $e');
    }

    for (final entry in _remoteRenderers.entries) {
      try {
        entry.value.srcObject = null;
        entry.value.dispose();
        _rendererDisposed[entry.key] = true;
      } catch (e) {
        debugPrint('[VideoGroup] error disposing renderer ${entry.key}: $e');
      }
    }
    _remoteRenderers.clear();

    // If user left UI without explicitly hanging up, perform hangup so call doesn't remain
    if (!_localHungUp) {
      try {
        _localHungUp = true;
        GroupRtcManager.hangUpGroupCall(_groupKey).catchError((e) {
          debugPrint('[VideoGroup] hangUp during dispose failed: $e');
        });
      } catch (e) {
        debugPrint('[VideoGroup] hangUp during dispose error: $e');
      }
    }

    try {
      GroupRtcManager.dispose(_groupKey);
    } catch (e) {
      debugPrint('[VideoGroup] manager dispose error: $e');
    }

    super.dispose();
  }

  Widget _buildParticipantTile(Map<String, dynamic> participant) {
    final id = participant['id']?.toString() ?? '';
    final isLocal = id == widget.callerId;
    final renderer = isLocal ? _localRenderer : _remoteRenderers[id];
    final isFocused = id == _focusedParticipantId;
    final status = _participantStatus[id] ?? (isLocal ? 'joined' : 'ringing');

    return GestureDetector(
      onTap: () => _switchFocusedParticipant(id),
      child: Container(
        width: 80,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: isFocused ? Border.all(color: Colors.blue, width: 3) : null,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 3))],
        ),
        child: Stack(
          children: [
            if (renderer != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: RTCVideoView(renderer, mirror: isLocal, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
              )
            else
              Container(
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: Colors.black26),
                child: Center(child: Icon(Icons.person, color: Colors.white70, size: 28)),
              ),
            Positioned(bottom: 4, left: 4, child: Container(padding: const EdgeInsets.all(4), color: Colors.black54, child: Text(participant['username'] ?? 'Participant', style: const TextStyle(color: Colors.white, fontSize: 12),),),),
            Positioned(top: 4, right: 4, child: Container(padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: status == 'joined' ? Colors.green : Colors.yellow, shape: BoxShape.circle), width: 12, height: 12,),),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > constraints.maxHeight;
        return Container(
          decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Colors.blue.shade900, Colors.black])),
          child: SafeArea(
            child: Stack(
              children: [
                _buildCallScreen(isLandscape, constraints),
                _buildControlButtons(isLandscape),
              ],
            ),
          ),
        );
      }),
    );
  }

  Widget _buildCallScreen(bool isLandscape, BoxConstraints constraints) {
    final focusedRenderer = (_focusedParticipantId == widget.callerId) ? _localRenderer : _remoteRenderers[_focusedParticipantId];
    final focusedParticipant = widget.participants?.firstWhere((p) => p['id'] == _focusedParticipantId, orElse: () => {'id': widget.callerId, 'username': 'You'}) ?? {'id': widget.callerId, 'username': 'You'};

    return Stack(
      children: [
        if (focusedRenderer != null)
          Positioned.fill(child: RTCVideoView(focusedRenderer, mirror: _focusedParticipantId == widget.callerId, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover))
        else
          Positioned.fill(child: Container(color: Colors.black)),
        Positioned(top: 16, left: 16, child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)), child: Text(_formattedDuration, style: const TextStyle(color: Colors.white, fontSize: 16)),),),
        if (widget.participants != null)
          Positioned(bottom: isLandscape ? 80 : 120, left: 16, right: 16, child: Container(height: 100, child: ListView.builder(scrollDirection: Axis.horizontal, itemCount: widget.participants!.length, itemBuilder: (context, index) => _buildParticipantTile(widget.participants![index]))),),
        Positioned(top: 16, right: 16, child: Container(width: isLandscape ? 120 : 100, height: isLandscape ? 160 : 140, decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 3))]), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: RTCVideoView(_localRenderer, mirror: true))),),
        // Show an overlay state when host is waiting for participants to join
        if (!_hasJoined && _isHost)
          Positioned.fill(
            child: Container(
              color: Colors.black54,
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Calling…', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Waiting for participants to join', style: TextStyle(color: Colors.white70)),
                ]),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildControlButtons(bool isLandscape) {
    return Positioned(bottom: 16, left: 16, right: 16, child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(30)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      IconButton(icon: Icon(isMuted ? Icons.mic_off : Icons.mic, color: isMuted ? Colors.red : Colors.white, size: 32), onPressed: () { setState(() => isMuted = !isMuted); GroupRtcManager.toggleMute(_groupKey, isMuted); },),
      IconButton(icon: Icon(isVideoOff ? Icons.videocam_off : Icons.videocam, color: isVideoOff ? Colors.red : Colors.white, size: 32), onPressed: () { setState(() => isVideoOff = !isVideoOff); GroupRtcManager.toggleVideo(_groupKey, !isVideoOff); },),
      IconButton(icon: Icon(isSpeakerOn ? Icons.volume_up : Icons.volume_off, color: isSpeakerOn ? Colors.white : Colors.grey, size: 32), onPressed: () { setState(() => isSpeakerOn = !isSpeakerOn); /* implement platform speaker toggle if desired */ },),
      ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red, shape: const CircleBorder(), padding: const EdgeInsets.all(16)), onPressed: () async {
        if (_localHungUp) return;
        // call the hangup handler which awaits manager cleanup before popping
        await _handleLocalHangup();
      }, child: const Icon(Icons.call_end, size: 32, color: Colors.white),),
    ],),),);
  }
}
