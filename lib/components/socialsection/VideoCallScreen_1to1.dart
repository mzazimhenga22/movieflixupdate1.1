// video_call_screen_1to1.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:animate_do/animate_do.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_sound/flutter_sound.dart';

class VideoCallScreen1to1 extends StatefulWidget {
  final String callId;
  final String callerId;
  final String receiverId;
  final String currentUserId;
  final Map<String, dynamic>? caller;
  final Map<String, dynamic>? receiver;

  const VideoCallScreen1to1({
    Key? key,
    required this.callId,
    required this.callerId,
    required this.receiverId,
    required this.currentUserId,
    this.caller,
    this.receiver,
  }) : super(key: key);

  @override
  State<VideoCallScreen1to1> createState() => _VideoCallScreen1to1State();
}

class _VideoCallScreen1to1State extends State<VideoCallScreen1to1>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  final Map<RTCVideoRenderer, bool> _rendererInitialized = {};
  final Map<RTCVideoRenderer, bool> _rendererDisposed = {};

  bool isMuted = false;
  bool isVideoOff = false;
  bool isSpeakerOn = false;
  Timer? _timer;
  int _callDuration = 0;
  String _formattedDuration = '00:00';
  bool isRinging = false;
  bool isAnswered = false;
  String? _focusedParticipantId;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callStatusSubscription;

  bool _isDisposed = false;
  bool _localHungUp = false;

  // small recorder helper instance (we won't open session here)
  final FlutterSoundRecorder _recorderProbe = FlutterSoundRecorder();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _createAndInitRenderer(_localRenderer);

    _remoteRenderers[widget.callerId] = RTCVideoRenderer();
    _remoteRenderers[widget.receiverId] = RTCVideoRenderer();
    _createAndInitRenderer(_remoteRenderers[widget.callerId]!);
    _createAndInitRenderer(_remoteRenderers[widget.receiverId]!);

    _focusedParticipantId = widget.receiverId;

    _startOrAnswerCall();
    _listenForCallStatus();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[VideoCall] app resumed - reinitializing renderers/streams');
      _reinitializeRenderersAndAttach();
    } else if (state == AppLifecycleState.paused) {
      // On pause, detach renderers to reduce risk of EGL/GL context issues
      _detachAllRendererSrcObjects();
    }
  }

  Future<void> _safelyStopRecorderIfAny() async {
    // Try to close any recorder session gracefully to avoid audio conflicts.
    // This will often log "Recorder already close" which is fine.
    try {
      await _recorderProbe.closeRecorder();
    } catch (e, st) {
      debugPrint('[VideoCall] recorder close attempt failed (likely already closed): $e\n$st');
    }
  }

  Future<void> _pauseRenderersBeforePermission() async {
    // Detach srcObject so the renderer isn't actively holding GL resources while the permission dialog is shown.
    try {
      _localRenderer.srcObject = null;
    } catch (_) {}
    for (final r in _remoteRenderers.values) {
      try {
        r.srcObject = null;
      } catch (_) {}
    }
  }

  Future<void> _reinitializeRenderersAndAttach() async {
    if (_isDisposed) return;
    try {
      await _createAndInitRenderer(_localRenderer);
      for (final r in _remoteRenderers.values) {
        await _createAndInitRenderer(r);
      }

      final local = RtcManager.getLocalVideoStream(widget.callId);
      if (local != null) await _setRendererSrcObject(_localRenderer, local);

      await _setupRemoteStreams();
    } catch (e, st) {
      debugPrint('[VideoCall] reinit error: $e\n$st');
    }
  }

  Future<void> _createAndInitRenderer(RTCVideoRenderer renderer) async {
    if (_rendererInitialized[renderer] == true) return;
    try {
      await renderer.initialize();
      _rendererInitialized[renderer] = true;
      _rendererDisposed[renderer] = false;
      debugPrint('[VideoCall] Renderer initialized: $renderer');
    } catch (e, st) {
      debugPrint('[VideoCall] Renderer init error: $e\n$st');
      _rendererInitialized[renderer] = false;
    }
  }

  Future<void> _setRendererSrcObject(RTCVideoRenderer renderer, MediaStream stream) async {
    if (_isDisposed) return;
    try {
      if (_rendererInitialized[renderer] != true) {
        await _createAndInitRenderer(renderer);
      }
      if (_rendererDisposed[renderer] == true) {
        debugPrint('[VideoCall] Trying to set srcObject on disposed renderer - skipping.');
        return;
      }
      renderer.srcObject = stream;
    } catch (e, st) {
      debugPrint('[VideoCall] Failed to set srcObject: $e\n$st');
    }
  }

  void _detachAllRendererSrcObjects() {
    try {
      _localRenderer.srcObject = null;
    } catch (_) {}
    for (final r in _remoteRenderers.values) {
      try {
        r.srcObject = null;
      } catch (_) {}
    }
  }

  Future<void> _startOrAnswerCall() async {
    try {
      if (widget.currentUserId == widget.callerId) {
        MediaStream? localStream;
        for (int i = 0; i < 8; i++) {
          localStream = RtcManager.getLocalVideoStream(widget.callId);
          if (localStream != null) break;
          await Future.delayed(const Duration(milliseconds: 200));
        }
        if (localStream != null) {
          await _setRendererSrcObject(_localRenderer, localStream);
        } else {
          debugPrint('[VideoCall] caller local stream not available yet');
        }

        _setupRemoteStreams();
        setState(() => isRinging = true);
      } else if (widget.currentUserId == widget.receiverId) {
        setState(() => isRinging = true);
      }
    } catch (e, st) {
      debugPrint('[VideoCall] _startOrAnswerCall error: $e\n$st');
    }
  }

  Future<void> _setupRemoteStreams() async {
    if (_isDisposed) return;

    MediaStream? remoteStream;

    if (_focusedParticipantId != null && _focusedParticipantId!.isNotEmpty) {
      remoteStream = RtcManager.getRemoteVideoStream(widget.callId, _focusedParticipantId!);
    }

    if (remoteStream == null) {
      remoteStream = RtcManager.getRemoteVideoStream(widget.callId, widget.receiverId);
    }
    if (remoteStream == null) {
      remoteStream = RtcManager.getRemoteVideoStream(widget.callId, widget.callerId);
    }

    if (remoteStream == null) {
      remoteStream = RtcManager.getAnyRemoteVideoStream(widget.callId);
    }

    if (remoteStream != null) {
      RTCVideoRenderer? targetRenderer = _remoteRenderers[_focusedParticipantId];
      if (targetRenderer == null) {
        targetRenderer = _remoteRenderers.isNotEmpty ? _remoteRenderers.values.first : null;
      }
      if (targetRenderer != null) {
        await _setRendererSrcObject(targetRenderer, remoteStream);
      } else {
        debugPrint('[VideoCall] no remote renderer available to attach stream');
      }
    } else {
      debugPrint('[VideoCall] no remote video stream available yet for call ${widget.callId}');
    }

    final localStream = RtcManager.getLocalVideoStream(widget.callId);
    if (localStream != null) {
      await _setRendererSrcObject(_localRenderer, localStream);
    }
  }

  void _listenForCallStatus() {
    _callStatusSubscription = FirebaseFirestore.instance
        .collection('calls')
        .doc(widget.callId)
        .snapshots()
        .listen((snapshot) async {
      final data = snapshot.data();
      debugPrint('[VideoCall] call doc update: ${snapshot.id} -> $data');
      if (data == null || !mounted) return;

      final status = data['status'] as String?;
      if ((status == 'ended' || status == 'rejected')) {
        if (_localHungUp) {
          debugPrint('[VideoCall] local hung up - ignoring remote ended snapshot');
          return;
        }

        await Future.delayed(const Duration(milliseconds: 350));
        final fresh = await FirebaseFirestore.instance.collection('calls').doc(widget.callId).get();
        final freshStatus = fresh.exists ? fresh.get('status') as String? : null;
        if (freshStatus == 'ended' || freshStatus == 'rejected') {
          if (mounted) {
            try {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(freshStatus == 'ended' ? 'Call ended' : 'Call rejected')));
            } catch (_) {}
            await Future.delayed(const Duration(milliseconds: 300));
            if (mounted) Navigator.of(context).pop();
          }
        } else {
          debugPrint('[VideoCall] ended/rejected snapshot appears transient - ignoring');
        }
      } else if (status == 'answered' && !isAnswered) {
        setState(() {
          isAnswered = true;
          isRinging = false;
        });
        _startTimer();
        _setupRemoteStreams();
      }
    }, onError: (err) {
      debugPrint('[VideoCall] call status listen error: $err');
    });
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      _callDuration++;
      _formattedDuration = _formatDuration(_callDuration);
      setState(() {});
    });
  }

  String _formatDuration(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _answerCall() async {
    try {
      // Stop any recorder sessions that might clash with WebRTC audio.
      await _safelyStopRecorderIfAny();

      // Detach renderers while permission dialog shows (helps reduce EGL races)
      await _pauseRenderersBeforePermission();

      // Request permissions in UI layer (this shows system dialog)
      final micStatus = await Permission.microphone.request();
      final camStatus = await Permission.camera.request();
      if (!micStatus.isGranted || !camStatus.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Camera & microphone permissions are required')));
        }
        // reinit renderers so preview can continue if user returns
        await _reinitializeRenderersAndAttach();
        return;
      }

      // After permissions are granted, call manager to answer
      await RtcManager.answerCall(callId: widget.callId, peerId: widget.currentUserId);

      // retry loop to get local stream after publish
      MediaStream? localStream;
      for (int attempt = 0; attempt < 10; attempt++) {
        localStream = RtcManager.getLocalVideoStream(widget.callId);
        if (localStream != null) break;
        await Future.delayed(const Duration(milliseconds: 250));
      }

      if (localStream != null) {
        await _setRendererSrcObject(_localRenderer, localStream);
      } else {
        debugPrint('[VideoCall] local stream not available after answer - continuing');
      }

      await _setupRemoteStreams();

      if (mounted) {
        setState(() {
          isRinging = false;
          isAnswered = true;
        });
      }
      _startTimer();
    } catch (e, st) {
      debugPrint('[VideoCall] answer error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to answer call')),
        );
      }
      // attempt to reinit renderers so UI doesn't hang
      await _reinitializeRenderersAndAttach();
    }
  }

  Future<void> _rejectCall() async {
    try {
      await RtcManager.rejectCall(callId: widget.callId, peerId: widget.currentUserId);
    } catch (e) {
      debugPrint('[VideoCall] reject error: $e');
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  void _toggleFocusedParticipant() {
    setState(() {
      if (_focusedParticipantId == widget.receiverId) {
        _focusedParticipantId = widget.callerId;
      } else {
        _focusedParticipantId = widget.receiverId;
      }
    });
    _setupRemoteStreams();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _isDisposed = true;

    _timer?.cancel();
    _callStatusSubscription?.cancel();

    if (isAnswered && !_localHungUp) {
      try {
        RtcManager.hangUp(widget.callId);
      } catch (e) {
        debugPrint('[VideoCall] hangUp error during dispose: $e');
      }
    }

    _localHungUp = true;

    try {
      _rendererDisposed[_localRenderer] = true;
      _localRenderer.dispose();
    } catch (e) {
      debugPrint('[VideoCall] error disposing local renderer: $e');
    }

    for (final renderer in _remoteRenderers.values) {
      try {
        _rendererDisposed[renderer] = true;
        renderer.dispose();
      } catch (e) {
        debugPrint('[VideoCall] error disposing remote renderer: $e');
      }
    }

    _remoteRenderers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isLandscape = constraints.maxWidth > constraints.maxHeight;
          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.blue.shade900, Colors.black],
              ),
            ),
            child: SafeArea(
              child: Stack(
                children: [
                  if (isRinging)
                    _buildRingingScreen()
                  else
                    GestureDetector(
                      onTap: _toggleFocusedParticipant,
                      child: _buildCallScreen(isLandscape),
                    ),
                  if (!isRinging) _buildControlButtons(isLandscape),
                  Positioned(
                    top: 40,
                    right: 20,
                    child: IconButton(
                      icon: Icon(Icons.swap_calls, color: Colors.white),
                      onPressed: _toggleFocusedParticipant,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRingingScreen() {
    final bool isCaller = widget.currentUserId == widget.callerId;
    final String username = isCaller
        ? (widget.receiver?['username'] as String? ?? 'Unknown')
        : (widget.caller?['username'] as String? ?? 'Unknown');
    final String? photoUrl = isCaller
        ? (widget.receiver?['photoUrl'] as String?)
        : (widget.caller?['photoUrl'] as String?);

    return Center(
      child: FadeIn(
        duration: const Duration(milliseconds: 500),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 60,
              backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
              child: photoUrl == null ? const Icon(Icons.person, size: 60) : null,
            ),
            const SizedBox(height: 20),
            Text(
              isCaller ? 'Calling $username...' : 'Incoming Video Call from $username',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 40),
            if (isCaller)
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(20),
                ),
                onPressed: () {
                  _localHungUp = true;
                  RtcManager.hangUp(widget.callId);
                  if (mounted) Navigator.of(context).pop();
                },
                child: const Icon(Icons.call_end, size: 30, color: Colors.white),
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(20),
                    ),
                    onPressed: _answerCall,
                    child: const Icon(Icons.call, size: 30, color: Colors.white),
                  ),
                  const SizedBox(width: 40),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(20),
                    ),
                    onPressed: _rejectCall,
                    child: const Icon(Icons.call_end, size: 30, color: Colors.white),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallScreen(bool isLandscape) {
    final renderer = _focusedParticipantId != null ? _remoteRenderers[_focusedParticipantId] : null;

    return Stack(
      children: [
        if (renderer != null)
          Positioned.fill(
            child: RTCVideoView(
              renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          )
        else
          Positioned.fill(
            child: Container(color: Colors.black),
          ),
        Positioned(
          top: 16,
          left: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _formattedDuration,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
        Positioned(
          top: 16,
          right: 16,
          child: Container(
            width: isLandscape ? 120 : 100,
            height: isLandscape ? 160 : 140,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: RTCVideoView(_localRenderer, mirror: true),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControlButtons(bool isLandscape) {
    return Positioned(
      bottom: 16,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: Icon(
                isMuted ? Icons.mic_off : Icons.mic,
                color: isMuted ? Colors.red : Colors.white,
                size: 32,
              ),
              onPressed: () {
                setState(() => isMuted = !isMuted);
                RtcManager.toggleMute(widget.callId, isMuted);
              },
            ),
            IconButton(
              icon: Icon(
                isVideoOff ? Icons.videocam_off : Icons.videocam,
                color: isVideoOff ? Colors.red : Colors.white,
                size: 32,
              ),
              onPressed: () {
                setState(() => isVideoOff = !isVideoOff);
                RtcManager.toggleVideo(widget.callId, !isVideoOff);
              },
            ),
            IconButton(
              icon: Icon(
                isSpeakerOn ? Icons.volume_up : Icons.volume_off,
                color: isSpeakerOn ? Colors.white : Colors.grey,
                size: 32,
              ),
              onPressed: () {
                setState(() => isSpeakerOn = !isSpeakerOn);
                // implement audio routing if needed
              },
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(16),
              ),
              onPressed: () {
                _localHungUp = true;
                RtcManager.hangUp(widget.callId);
                if (mounted) Navigator.of(context).pop();
              },
              child: const Icon(Icons.call_end, size: 32, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
