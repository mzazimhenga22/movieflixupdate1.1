// lib/components/socialsection/video_call_screen_1to1.dart
// Updated: more robust ringtone playback, wakelock_plus, audio session attempt,
// safer remote selection, and defensive lifecycle handling.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:audio_session/audio_session.dart'; // optional - wrapped in try/catch

enum CallUiState { calling, ringing, connecting, connected, reconnecting, ended }

class VideoCallScreen1to1 extends StatefulWidget {
  final String callId;
  final String callerId;
  final String receiverId;
  final String currentUserId;
  final Map<String, dynamic>? caller;
  final Map<String, dynamic>? receiver;

  const VideoCallScreen1to1({
    super.key,
    required this.callId,
    required this.callerId,
    required this.receiverId,
    required this.currentUserId,
    this.caller,
    this.receiver,
  });

  @override
  State<VideoCallScreen1to1> createState() => _VideoCallScreen1to1State();
}

class _VideoCallScreen1to1State extends State<VideoCallScreen1to1>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  bool isMuted = false;
  bool isVideoOff = false;
  bool isSpeakerOn = true;

  Timer? _timer;
  int _callDuration = 0;
  String _formattedDuration = '00:00';

  CallUiState _uiState = CallUiState.calling;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callStatusSubscription;

  bool _isDisposed = false;
  bool _localHungUp = false;

  final FlutterSoundPlayer _ringtonePlayer = FlutterSoundPlayer();
  Uint8List? _ringtoneBuffer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initRenderers();
    _initRingtone();
    _startFlow();
  }

  Future<void> _initRingtone() async {
    try {
      await _ringtonePlayer.openPlayer();
      // load asset to memory so startPlayer(fromDataBuffer: ...) works consistently
      final ByteData bd = await rootBundle.load('assets/ringtone.mp3');
      _ringtoneBuffer = bd.buffer.asUint8List();
    } catch (e, st) {
      debugPrint('[VideoCall] ringtone init error: $e\n$st');
      _ringtoneBuffer = null;
    }
  }

  Future<void> _playRingtone() async {
    try {
      if (_ringtonePlayer.isPlaying) return;
      if (_ringtoneBuffer != null) {
        await _ringtonePlayer.startPlayer(
          fromDataBuffer: _ringtoneBuffer!,
          codec: Codec.mp3,
          whenFinished: () {},
        );
      } else {
        // best-effort: try URI fallback if you had a remote ringtone
        await _ringtonePlayer.startPlayer(fromURI: null);
      }
    } catch (e, st) {
      debugPrint('[VideoCall] ringtone play error: $e\n$st');
    }
  }

  Future<void> _stopRingtone() async {
    try {
      if (_ringtonePlayer.isPlaying) await _ringtonePlayer.stopPlayer();
    } catch (e) {
      debugPrint('[VideoCall] ringtone stop error: $e');
    }
  }

  Future<void> _initRenderers() async {
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
    } catch (e) {
      debugPrint('[VideoCall] renderer init error: $e');
    }
  }

  Future<void> _startFlow() async {
    if (_isDisposed) return;

    if (widget.currentUserId == widget.callerId) {
      setState(() => _uiState = CallUiState.calling);
      await _playRingtone();
    } else {
      setState(() => _uiState = CallUiState.ringing);
      await _playRingtone();
    }

    _listenForCallStatus();
    _attemptAttachLoop();
  }

  Future<void> _attemptAttachLoop() async {
    // try to attach local and remote streams multiple times
    final otherId = (widget.currentUserId == widget.callerId) ? widget.receiverId : widget.callerId;

    for (int i = 0; i < 40 && !_isDisposed; i++) {
      try {
        final local = RtcManager.getLocalVideoStream(widget.callId);
        if (local != null && _localRenderer.srcObject != local) {
          _localRenderer.srcObject = local;
        }

        // prefer explicit otherId, fallback to any remote
        final remote = RtcManager.getRemoteVideoStream(widget.callId, otherId) ??
            RtcManager.getAnyRemoteVideoStream(widget.callId);

        if (remote != null && _remoteRenderer.srcObject != remote) {
          _remoteRenderer.srcObject = remote;
          if (_uiState != CallUiState.connected) {
            setState(() => _uiState = CallUiState.connected);
            await _stopRingtone();
            _startTimer();
            // enable wakelock_plus once connected
            try {
              WakelockPlus.enable();
            } catch (_) {}
          }
          break;
        }
      } catch (e) {
        debugPrint('[VideoCall] attach attempt error: $e');
      }
      await Future.delayed(const Duration(milliseconds: 350));
    }
  }

  void _listenForCallStatus() {
    _callStatusSubscription = FirebaseFirestore.instance
        .collection('calls')
        .doc(widget.callId)
        .snapshots()
        .listen((snapshot) async {
      if (_isDisposed) return;
      final data = snapshot.data();
      if (data == null) return;
      final status = data['status'] as String?;
      debugPrint('[VideoCall] call status: $status');

      if (status == 'ringing') {
        setState(() {
          _uiState =
              widget.currentUserId == widget.callerId ? CallUiState.calling : CallUiState.ringing;
        });
        await _playRingtone();
      } else if (status == 'answered') {
        setState(() => _uiState = CallUiState.connecting);
        await _stopRingtone();
        // Give LiveKit a moment to publish tracks; then attach
        await Future.delayed(const Duration(milliseconds: 400));
        // try attaching right away
        final local = RtcManager.getLocalVideoStream(widget.callId);
        final remote = RtcManager.getAnyRemoteVideoStream(widget.callId);
        if (local != null) _localRenderer.srcObject = local;
        if (remote != null) {
          _remoteRenderer.srcObject = remote;
          setState(() => _uiState = CallUiState.connected);
          _startTimer();
          try {
            WakelockPlus.enable();
          } catch (_) {}
        } else {
          // if remote not yet available keep trying in background
          _attemptAttachLoop();
        }
      } else if (status == 'rejected' || status == 'ended' || status == 'missed') {
        await _stopRingtone();
        if (!_localHungUp && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(status == 'rejected' ? 'Call rejected' : 'Call ended')),
          );
        }
        _endAndClose();
      }
    }, onError: (e) => debugPrint('[VideoCall] call status listen error: $e'));
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
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
      // request microphone and camera; if video is already off, camera permission still needed
      final mic = await Permission.microphone.request();
      final cam = await Permission.camera.request();
      if (!mic.isGranted || !cam.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Camera and microphone required')),
          );
        }
        return;
      }

      setState(() => _uiState = CallUiState.connecting);

      // attempt to configure audio session for voice
      try {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.speech());
        await session.setActive(true);
      } catch (e) {
        // optional package; ignore if not available
        debugPrint('[VideoCall] audio session config error (nonfatal): $e');
      }

      await RtcManager.answerCall(callId: widget.callId, peerId: widget.currentUserId);

      // small delay to let tracks publish and attach
      await Future.delayed(const Duration(milliseconds: 350));

      final local = RtcManager.getLocalVideoStream(widget.callId);
      final remote = RtcManager.getAnyRemoteVideoStream(widget.callId);
      if (local != null) _localRenderer.srcObject = local;
      if (remote != null) {
        _remoteRenderer.srcObject = remote;
        setState(() => _uiState = CallUiState.connected);
        _startTimer();
        try {
          WakelockPlus.enable();
        } catch (_) {}
      } else {
        // remote not yet there; keep trying in background
        _attemptAttachLoop();
      }

      await _stopRingtone();
    } catch (e, st) {
      debugPrint('[VideoCall] answer error: $e\n$st');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to answer')));
    }
  }

  Future<void> _rejectCall() async {
    try {
      await RtcManager.rejectCall(callId: widget.callId, peerId: widget.currentUserId);
    } catch (e) {
      debugPrint('[VideoCall] reject error: $e');
    } finally {
      _endAndClose();
    }
  }

  Future<void> _endAndClose() async {
    if (_isDisposed) return;
    _localHungUp = true;
    try {
      await RtcManager.hangUp(widget.callId);
    } catch (e) {
      debugPrint('[VideoCall] hangUp error: $e');
    }

    await _stopRingtone();
    _timer?.cancel();

    try {
      WakelockPlus.disable();
    } catch (_) {}

    // brief delay so UI can show 'call ended' before popping if you want
    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;
    if (state == AppLifecycleState.paused) {
      // drop renderer.srcObject to release camera when backgrounded if desired
      try {
        _localRenderer.srcObject = null;
      } catch (_) {}
    } else if (state == AppLifecycleState.resumed) {
      final local = RtcManager.getLocalVideoStream(widget.callId);
      if (local != null) _localRenderer.srcObject = local;
      final remote = RtcManager.getAnyRemoteVideoStream(widget.callId);
      if (remote != null) _remoteRenderer.srcObject = remote;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _isDisposed = true;
    _timer?.cancel();
    _callStatusSubscription?.cancel();
    try {
      _localRenderer.srcObject = null;
    } catch (_) {}
    try {
      _remoteRenderer.srcObject = null;
    } catch (_) {}
    try {
      _localRenderer.dispose();
    } catch (_) {}
    try {
      _remoteRenderer.dispose();
    } catch (_) {}
    try {
      _ringtonePlayer.closePlayer();
    } catch (_) {}
    try {
      WakelockPlus.disable();
    } catch (_) {}
    super.dispose();
  }

  Widget _buildRingingUi() {
    final bool isCaller = widget.currentUserId == widget.callerId;

    final Map<String, dynamic>? caller = widget.caller;
    final Map<String, dynamic>? receiver = widget.receiver;

    final String username = isCaller
        ? (receiver != null && receiver['username'] is String ? receiver['username'] as String : 'Unknown')
        : (caller != null && caller['username'] is String ? caller['username'] as String : 'Unknown');

    final String? photoUrl = isCaller
        ? (receiver != null && receiver['photoUrl'] is String ? receiver['photoUrl'] as String : null)
        : (caller != null && caller['photoUrl'] is String ? caller['photoUrl'] as String : null);

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 60,
            backgroundImage: (photoUrl != null && photoUrl.isNotEmpty) ? NetworkImage(photoUrl) : null,
            child: (photoUrl == null || photoUrl.isEmpty) ? const Icon(Icons.person, size: 60) : null,
          ),
          const SizedBox(height: 20),
          Text(username, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          const Text("Ringing...", style: TextStyle(fontSize: 18, color: Colors.grey)),
          const SizedBox(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: _answerCall,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, shape: const CircleBorder(), padding: const EdgeInsets.all(20)),
                child: const Icon(Icons.call, size: 32),
              ),
              const SizedBox(width: 30),
              ElevatedButton(
                onPressed: _rejectCall,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red, shape: const CircleBorder(), padding: const EdgeInsets.all(20)),
                child: const Icon(Icons.call_end, size: 32),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isRingingOrCalling = (_uiState == CallUiState.calling) || (_uiState == CallUiState.ringing);

    Widget backgroundWidget;
    if (isRingingOrCalling) {
      backgroundWidget = const Positioned.fill(child: ColoredBox(color: Colors.black));
    } else {
      backgroundWidget = Positioned.fill(child: RTCVideoView(_remoteRenderer));
    }

    final Widget ringingWidget = isRingingOrCalling ? _buildRingingUi() : const SizedBox.shrink();

    Widget controlsWidget;
    if (!isRingingOrCalling) {
      controlsWidget = Positioned(
        bottom: 16,
        left: 16,
        right: 16,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: Icon(isMuted ? Icons.mic_off : Icons.mic, color: isMuted ? Colors.red : Colors.white),
              onPressed: () {
                setState(() => isMuted = !isMuted);
                RtcManager.toggleMute(widget.callId, isMuted);
              },
            ),
            IconButton(
              icon: Icon(isVideoOff ? Icons.videocam_off : Icons.videocam, color: isVideoOff ? Colors.red : Colors.white),
              onPressed: () {
                setState(() => isVideoOff = !isVideoOff);
                RtcManager.toggleVideo(widget.callId, !isVideoOff);
              },
            ),
            IconButton(
              icon: Icon(isSpeakerOn ? Icons.volume_up : Icons.hearing, color: Colors.white),
              onPressed: () {
                setState(() => isSpeakerOn = !isSpeakerOn);
                RtcManager.setSpeakerphone(widget.callId, isSpeakerOn);
              },
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, shape: const CircleBorder(), padding: const EdgeInsets.all(12)),
              onPressed: _endAndClose,
              child: const Icon(Icons.call_end, color: Colors.white),
            ),
          ],
        ),
      );
    } else {
      controlsWidget = const SizedBox.shrink();
    }

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            backgroundWidget,
            Positioned(
              top: 16,
              left: 16,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                child: Text(_formattedDuration, style: const TextStyle(color: Colors.white)),
              ),
            ),
            Positioned(
                top: 16,
                right: 16,
                child: SizedBox(
                    width: 120,
                    height: 160,
                    child: ClipRRect(borderRadius: BorderRadius.circular(12), child: RTCVideoView(_localRenderer, mirror: true)))),

            ringingWidget,
            controlsWidget,
          ],
        ),
      ),
    );
  }
}
