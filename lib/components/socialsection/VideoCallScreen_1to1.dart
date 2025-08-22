import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:animate_do/animate_do.dart';

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
    with SingleTickerProviderStateMixin {
  // Renderers
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};

  // Renderer state tracking
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

  @override
  void initState() {
    super.initState();
    // Create & initialize renderers asynchronously (non-blocking).
    _createAndInitRenderer(_localRenderer);

    // Prepare remote renderers for both participants (create now; init later if needed)
    _remoteRenderers[widget.callerId] = RTCVideoRenderer();
    _remoteRenderers[widget.receiverId] = RTCVideoRenderer();
    _createAndInitRenderer(_remoteRenderers[widget.callerId]!);
    _createAndInitRenderer(_remoteRenderers[widget.receiverId]!);

    _focusedParticipantId = widget.receiverId; // Default focus

    // Start or prepare call state
    _startOrAnswerCall();
    _listenForCallStatus();
  }

  /// Create and initialize renderer and track its state
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

  /// Safely set renderer.srcObject after ensuring the renderer is initialized and not disposed
  Future<void> _setRendererSrcObject(RTCVideoRenderer renderer, MediaStream stream) async {
    if (_isDisposed) return;
    try {
      // Ensure renderer initialized (will no-op if already handled)
      if (_rendererInitialized[renderer] != true) {
        await _createAndInitRenderer(renderer);
      }

      // Check disposed flag again
      if (_rendererDisposed[renderer] == true) {
        debugPrint('[VideoCall] Trying to set srcObject on disposed renderer - skipping.');
        return;
      }

      renderer.srcObject = stream;
    } catch (e, st) {
      // Guard against the "renderer disposed" exception or other race
      debugPrint('[VideoCall] Failed to set srcObject: $e\n$st');
    }
  }

  Future<void> _startOrAnswerCall() async {
    // Caller: we may already have published local tracks via RtcManager.start*Call earlier.
    if (widget.currentUserId == widget.callerId) {
      final localStream = RtcManager.getLocalStream(widget.callId);
      if (localStream != null) {
        await _setRendererSrcObject(_localRenderer, localStream);
      }
      _setupRemoteStreams();
      setState(() => isRinging = true);
    } else if (widget.currentUserId == widget.receiverId) {
      // Receiver sees ringing UI until answered
      setState(() => isRinging = true);
    }
  }

Future<void> _setupRemoteStreams() async {

    if (_isDisposed) return;

    // Setup remote stream for the focused participant (receiverId/callerId)
    final remoteForReceiver = RtcManager.getRemoteStream(widget.callId, widget.receiverId);
    if (remoteForReceiver != null && _remoteRenderers[widget.receiverId] != null) {
      await _setRendererSrcObject(_remoteRenderers[widget.receiverId]!, remoteForReceiver);
    }

    final remoteForCaller = RtcManager.getRemoteStream(widget.callId, widget.callerId);
    if (remoteForCaller != null && _remoteRenderers[widget.callerId] != null) {
      await _setRendererSrcObject(_remoteRenderers[widget.callerId]!, remoteForCaller);
    }
  }

  void _listenForCallStatus() {
    _callStatusSubscription = FirebaseFirestore.instance
        .collection('calls')
        .doc(widget.callId)
        .snapshots()
        .listen((snapshot) {
      final data = snapshot.data();
      if (data == null || !mounted) return;

      final status = data['status'] as String?;
      if (status == 'ended' || status == 'rejected') {
        if (mounted) Navigator.of(context).pop();
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
      await RtcManager.answerCall(callId: widget.callId, peerId: widget.currentUserId);

      // get local stream AFTER answering (RtcManager creates/publishes it)
      final localStream = RtcManager.getLocalStream(widget.callId);
      if (localStream != null) {
        await _setRendererSrcObject(_localRenderer, localStream);
      }

      // attach remote streams if any
      await _setupRemoteStreams();

      if (mounted) {
        setState(() {
          isRinging = false;
          isAnswered = true;
        });
      }
    } catch (e, st) {
      debugPrint('[VideoCall] answer error: $e\n$st');
      // show a soft error but don't crash
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to answer call')),
        );
      }
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
  }

  @override
  void dispose() {
    _isDisposed = true;

    // Cancel timer and subscription first
    _timer?.cancel();
    _callStatusSubscription?.cancel();

    // Hang up if call was answered (attempt cleanup on server)
    if (isAnswered) {
      try {
        RtcManager.hangUp(widget.callId);
      } catch (e) {
        debugPrint('[VideoCall] hangUp error during dispose: $e');
      }
    }

    // Dispose renderers and mark disposed
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
