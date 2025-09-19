// lib/components/socialsection/voice_call_screen_1to1.dart
// Updated for robust WhatsApp-like voice calling behavior.
// - Ringtone playback from assets
// - Wakelock via wakelock_plus while connected
// - Audio session attempt on answer (wrapped in try/catch)
// - Defensive lifecycle and error handling
// - Safer attach loop and fallback behavior

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:animate_do/animate_do.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:audio_session/audio_session.dart'; // optional, non-fatal if missing

class VoiceCallScreen1to1 extends StatefulWidget {
  final String callId;
  final String callerId;
  final String receiverId;
  final String currentUserId;
  final Map<String, dynamic>? caller;
  final Map<String, dynamic>? receiver;

  const VoiceCallScreen1to1({
    super.key,
    required this.callId,
    required this.callerId,
    required this.receiverId,
    required this.currentUserId,
    this.caller,
    this.receiver,
  });

  @override
  State<VoiceCallScreen1to1> createState() => _VoiceCallScreen1to1State();
}

enum VoiceCallUiState { ringing, connecting, connected, ended }

class _VoiceCallScreen1to1State extends State<VoiceCallScreen1to1>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool isMuted = false;
  bool isSpeakerOn = false;

  VoiceCallUiState _uiState = VoiceCallUiState.ringing;

  Timer? _timer;
  int _callDuration = 0;
  String _formattedDuration = '00:00';

  AnimationController? _pulseController;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callStatusSubscription;

  final FlutterSoundRecorder _recorderProbe = FlutterSoundRecorder();

  // ringtone player
  final FlutterSoundPlayer _ringtonePlayer = FlutterSoundPlayer();
  Uint8List? _ringtoneBuffer;

  bool _isDisposed = false;
  bool _localHungUp = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prepareRecorderProbe();
    _initRingtone();
    // initial UI based on call doc (useful if reopening screen mid-call)
    _initFromCallDoc().whenComplete(() {
      if (!_isDisposed) {
        _listenForCallStatus();
        _attemptAttachLoop();
      }
    });
  }

  Future<void> _prepareRecorderProbe() async {
    try {
      await _recorderProbe.openRecorder();
      // we don't start recording; this is only to ensure the recorder is ready/closed safely later
    } catch (e) {
      // ignore - just a probe
      debugPrint('[VoiceCall] recorder probe open error: $e');
    } finally {
      try {
        await _recorderProbe.closeRecorder();
      } catch (_) {}
    }
  }

  Future<void> _initRingtone() async {
    try {
      await _ringtonePlayer.openPlayer();
      final ByteData bd = await rootBundle.load('assets/ringtone.mp3');
      _ringtoneBuffer = bd.buffer.asUint8List();
    } catch (e, st) {
      debugPrint('[VoiceCall] ringtone init error: $e\n$st');
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
        // fallback - start silent URI to avoid exceptions (platform-dependent)
        await _ringtonePlayer.startPlayer(fromURI: null);
      }
    } catch (e, st) {
      debugPrint('[VoiceCall] ringtone play error: $e\n$st');
    }
  }

  Future<void> _stopRingtone() async {
    try {
      if (_ringtonePlayer.isPlaying) await _ringtonePlayer.stopPlayer();
    } catch (e) {
      debugPrint('[VoiceCall] ringtone stop error: $e');
    }
  }

  Future<void> _initFromCallDoc() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('calls').doc(widget.callId).get();
      if (!doc.exists) {
        // no call doc — show ended state and pop
        if (mounted) {
          setState(() => _uiState = VoiceCallUiState.ended);
          Navigator.of(context).maybePop();
        }
        return;
      }
      final status = doc.data()?['status'] as String?;
      if (status == 'answered') {
        if (mounted) setState(() => _uiState = VoiceCallUiState.connecting);
      } else if (status == 'ringing') {
        if (mounted) setState(() => _uiState = VoiceCallUiState.ringing);
        // play ringtone if we're the receiver
        if (widget.currentUserId != widget.callerId) {
          await _playRingtone();
        }
      } else {
        // ended/rejected/missed -> close
        if (mounted) Navigator.of(context).maybePop();
      }
    } catch (e) {
      debugPrint('[VoiceCall] initFromCallDoc error: $e');
    }
  }

  Future<void> _safelyStopRecorderIfAny() async {
    try {
      await _recorderProbe.closeRecorder();
    } catch (e, st) {
      debugPrint('[VoiceCall] recorder close attempt failed (likely already closed): $e\n$st');
    }
  }

  void _listenForCallStatus() {
    _callStatusSubscription = FirebaseFirestore.instance
        .collection('calls')
        .doc(widget.callId)
        .snapshots()
        .listen((snapshot) async {
      if (_isDisposed) return;
      try {
        final data = snapshot.data();
        if (data == null) return;
        final status = data['status'] as String?;
        debugPrint('[VoiceCall] status snapshot: $status');

        if (status == 'ringing') {
          if (mounted) setState(() => _uiState = VoiceCallUiState.ringing);
          // start ringtone only if we are a callee
          if (widget.currentUserId != widget.callerId) {
            await _playRingtone();
          }
        } else if (status == 'answered') {
          if (mounted) setState(() => _uiState = VoiceCallUiState.connecting);
          await _stopRingtone();
          // configure audio session (best-effort)
          try {
            final session = await AudioSession.instance;
            await session.configure(const AudioSessionConfiguration.speech());
            await session.setActive(true);
          } catch (e) {
            debugPrint('[VoiceCall] audio session configure non-fatal error: $e');
          }
          await _attemptAttachLoop();
        } else if (status == 'rejected' || status == 'ended' || status == 'missed') {
          await _stopRingtone();
          if (!_localHungUp && mounted) {
            final String msg = status == 'rejected' ? 'Call rejected' : 'Call ended';
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
          }
          // ensure we pop only once
          if (mounted) Navigator.of(context).maybePop();
        }
      } catch (e, st) {
        debugPrint('[VoiceCall] call status handler error: $e\n$st');
      }
    }, onError: (err) {
      debugPrint('[VoiceCall] call status listen error: $err');
    });
  }

  /// Try to find remote audio stream. If found, mark connected. If not found after attempts,
  /// still progress to connected to avoid UI stuckness (WhatsApp-like).
  Future<void> _attemptAttachLoop({int maxAttempts = 20, Duration delay = const Duration(milliseconds: 300)}) async {
    for (int i = 0; i < maxAttempts && !_isDisposed; i++) {
      try {
        final remote = RtcManager.getAnyRemoteAudioStream(widget.callId);
        if (remote != null) {
          if (mounted) {
            setState(() {
              _uiState = VoiceCallUiState.connected;
            });
            _startTimerIfNeeded();
            // ensure wakelock while connected
            try {
              WakelockPlus.enable();
            } catch (_) {}
          }
          return;
        }
      } catch (e) {
        debugPrint('[VoiceCall] attach attempt error: $e');
      }
      await Future.delayed(delay);
    }

    // fallback to connected even if no stream found
    if (!_isDisposed && mounted) {
      setState(() => _uiState = VoiceCallUiState.connected);
      _startTimerIfNeeded();
      try {
        WakelockPlus.enable();
      } catch (_) {}
    }
  }

  void _startTimerIfNeeded() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _callDuration++;
      _formattedDuration = _formatDuration(_callDuration);
      setState(() {});
    });
  }

  String _formatDuration(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$secs';
  }

  Future<void> _answerCall() async {
    try {
      await _safelyStopRecorderIfAny();

      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission is required to answer the call')),
          );
        }
        return;
      }

      if (mounted) setState(() => _uiState = VoiceCallUiState.connecting);

      try {
        await RtcManager.answerCall(callId: widget.callId, peerId: widget.currentUserId);
      } catch (e) {
        debugPrint('[VoiceCall] RtcManager.answerCall error: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to answer call')));
          setState(() => _uiState = VoiceCallUiState.ended);
          Navigator.of(context).maybePop();
        }
        return;
      }

      // small delay and then attempt to attach
      await Future.delayed(const Duration(milliseconds: 300));
      await _attemptAttachLoop();
      await _stopRingtone();
    } catch (e, st) {
      debugPrint('[VoiceCall] answer error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to answer call')));
        setState(() => _uiState = VoiceCallUiState.ended);
        Navigator.of(context).maybePop();
      }
    }
  }

  Future<void> _rejectCall() async {
    try {
      await _safelyStopRecorderIfAny();
      await RtcManager.rejectCall(callId: widget.callId, peerId: widget.currentUserId);
    } catch (e, st) {
      debugPrint('[VoiceCall] reject error: $e\n$st');
    } finally {
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  Future<void> _hangUpLocal() async {
    try {
      _localHungUp = true;
      await _safelyStopRecorderIfAny();
      await RtcManager.hangUp(widget.callId);
    } catch (e, st) {
      debugPrint('[VoiceCall] hangUp error: $e\n$st');
    } finally {
      // stop timer + wakelock
      _timer?.cancel();
      try {
        WakelockPlus.disable();
      } catch (_) {}
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;
    // if backgrounded, it's fine to leave audio running (CallKit/PushKit handles wake).
    // We avoid heavy resource usage here.
    super.didChangeAppLifecycleState(state);
  }

  @override
  void dispose() {
    if (_isDisposed) {
      super.dispose();
      return;
    }
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);

    try {
      _pulseController?.stop();
    } catch (_) {}
    try {
      _pulseController?.dispose();
    } catch (_) {}

    _timer?.cancel();
    _callStatusSubscription?.cancel();

    // stop ringtone and recorder safely
    _stopRingtone().catchError((_) {});
    _safelyStopRecorderIfAny().catchError((_) {});

    // if connected and we didn't hang up locally, attempt to hang up to keep server state consistent
    if (_uiState == VoiceCallUiState.connected && !_localHungUp) {
      RtcManager.hangUp(widget.callId).catchError((e) => debugPrint('[VoiceCall] hangUp during dispose error: $e'));
    }

    try {
      WakelockPlus.disable();
    } catch (_) {}

    super.dispose();
  }

  // UI builders
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
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
              if (_uiState == VoiceCallUiState.ringing) _buildRingingScreen() else _buildCallScreen(),
              if (_uiState != VoiceCallUiState.ringing) _buildControlButtons(),
              if (_uiState == VoiceCallUiState.connecting)
                Positioned(
                  top: 20,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration:
                          BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(20)),
                      child: const Text('Connecting...', style: TextStyle(color: Colors.white70)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRingingScreen() {
    final bool isCaller = widget.currentUserId == widget.callerId;
    final String username = isCaller
        ? (widget.receiver?['username'] as String? ?? 'Unknown')
        : (widget.caller?['username'] as String? ?? 'Unknown');
    final String? photoUrl = isCaller ? (widget.receiver?['photoUrl'] as String?) : (widget.caller?['photoUrl'] as String?);

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
              isCaller ? 'Calling $username…' : 'Incoming Voice Call from $username',
              style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 40),
            if (isCaller)
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(20),
                ),
                onPressed: () async {
                  _localHungUp = true;
                  try {
                    await RtcManager.hangUp(widget.callId);
                  } catch (e) {
                    debugPrint('[VoiceCall] caller hangUp error: $e');
                  } finally {
                    if (mounted) Navigator.of(context).maybePop();
                  }
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

  Widget _buildCallScreen() {
    final String username = widget.currentUserId == widget.callerId
        ? (widget.receiver?['username'] as String? ?? 'Unknown')
        : (widget.caller?['username'] as String? ?? 'Unknown');
    final String? photoUrl = widget.currentUserId == widget.callerId
        ? (widget.receiver?['photoUrl'] as String?)
        : (widget.caller?['photoUrl'] as String?);

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Pulse(
            manualTrigger: false,
            controller: (controller) {
              _pulseController = controller;
              try {
                controller.repeat(reverse: true);
              } catch (_) {}
            },
            child: CircleAvatar(
              radius: 60,
              backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
              child: photoUrl == null ? const Icon(Icons.person, size: 60) : null,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            username,
            style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Text(
            _formattedDuration,
            style: const TextStyle(color: Colors.white70, fontSize: 20),
          ),
          const SizedBox(height: 10),
          const Text(
            'Voice Call',
            style: TextStyle(color: Colors.grey, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildControlButtons() {
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
                try {
                  RtcManager.toggleMute(widget.callId, isMuted);
                } catch (e) {
                  debugPrint('[VoiceCall] toggleMute error: $e');
                }
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
                try {
                  RtcManager.setSpeakerphone(widget.callId, isSpeakerOn);
                } catch (e) {
                  debugPrint('[VoiceCall] setSpeakerphone error: $e');
                }
              },
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(16),
              ),
              onPressed: _hangUpLocal,
              child: const Icon(Icons.call_end, size: 32, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
