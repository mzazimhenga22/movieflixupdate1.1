// voice_call_screen_1to1.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:animate_do/animate_do.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_sound/flutter_sound.dart';

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

class _VoiceCallScreen1to1State extends State<VoiceCallScreen1to1>
    with SingleTickerProviderStateMixin {
  bool isMuted = false;
  bool isSpeakerOn = false;
  bool isRinging = false;
  bool isAnswered = false;

  Timer? _timer;
  int _callDuration = 0;
  String _formattedDuration = '00:00';

  AnimationController? _pulseController;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callStatusSubscription;

  // Small recorder probe to safely close any recorder sessions that might exist
  // elsewhere in the app (prevents "recorder already close" crashes).
  final FlutterSoundRecorder _recorderProbe = FlutterSoundRecorder();

  bool _isDisposed = false;
  bool _localHungUp = false;

  @override
  void initState() {
    super.initState();
    // Initially both caller and receiver see ringing UI
    _startOrAnswerCall();
    _listenForCallStatus();
  }

  Future<void> _safelyStopRecorderIfAny() async {
    // Close recorder if it's open; swallow expected errors like "already closed".
    try {
      // open/close calls can throw depending on underlying platform state.
      await _recorderProbe.closeRecorder();
    } catch (e, st) {
      debugPrint('[VoiceCall] recorder close attempt failed (likely already closed): $e\n$st');
    }
  }

  Future<void> _startOrAnswerCall() async {
    if (widget.currentUserId == widget.callerId ||
        widget.currentUserId == widget.receiverId) {
      setState(() => isRinging = true);
    }
  }

  void _listenForCallStatus() {
    _callStatusSubscription = FirebaseFirestore.instance
        .collection('calls')
        .doc(widget.callId)
        .snapshots()
        .listen((snapshot) async {
      try {
        final data = snapshot.data();
        if (data == null || !mounted) return;
        final status = data['status'] as String?;

        // Handle terminal states conservatively by verifying with a fresh read
        if (status == 'ended' || status == 'rejected') {
          try {
            final fresh = await FirebaseFirestore.instance.collection('calls').doc(widget.callId).get();
            final freshStatus = fresh.exists ? (fresh.get('status') as String?) : null;
            if (freshStatus == 'ended' || freshStatus == 'rejected') {
              if (!_localHungUp && mounted) {
                try {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(freshStatus == 'ended' ? 'Call ended' : 'Call rejected')),
                  );
                } catch (_) {}
                await Future.delayed(const Duration(milliseconds: 300));
                if (mounted) Navigator.of(context).pop();
              } else {
                if (mounted) Navigator.of(context).pop();
              }
            } else {
              debugPrint('[VoiceCall] Terminal snapshot transient - ignoring');
            }
          } catch (e) {
            debugPrint('[VoiceCall] Error verifying terminal status: $e');
          }
          return;
        }

        if (status == 'answered' && !isAnswered) {
          setState(() {
            isAnswered = true;
            isRinging = false;
          });
          _startTimer();
        }
      } catch (e, st) {
        debugPrint('[VoiceCall] call status handler error: $e\n$st');
      }
    }, onError: (err) {
      debugPrint('[VoiceCall] call status listen error: $err');
    });
  }

  void _startTimer() {
    _timer?.cancel();
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
      // Stop/close any recorder session that might conflict with WebRTC audio
      await _safelyStopRecorderIfAny();

      // Request microphone permission (UI prompt)
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission is required to answer the call')),
          );
        }
        return;
      }

      await RtcManager.answerCall(
        callId: widget.callId,
        peerId: widget.currentUserId,
      );

      if (mounted) {
        setState(() {
          isRinging = false;
          isAnswered = true;
        });
      }

      _startTimer();
    } catch (e, st) {
      debugPrint('[VoiceCall] answer error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to answer call')));
      }
    }
  }

  Future<void> _rejectCall() async {
    try {
      await _safelyStopRecorderIfAny();
      await RtcManager.rejectCall(
        callId: widget.callId,
        peerId: widget.currentUserId,
      );
    } catch (e, st) {
      debugPrint('[VoiceCall] reject error: $e\n$st');
    } finally {
      if (mounted) Navigator.of(context).pop();
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
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;

    try {
      // Stop & dispose pulse controller if we created it
      if (_pulseController != null) {
        try {
          _pulseController!.stop();
        } catch (_) {}
        try {
          _pulseController!.dispose();
        } catch (_) {}
      }

      _timer?.cancel();
      _callStatusSubscription?.cancel();

      // Ensure recorder is closed (safe)
      try {
        _safelyStopRecorderIfAny();
      } catch (e) {
        debugPrint('[VoiceCall] recorder safe close error during dispose: $e');
      }

      // Hang up the call if active and we didn't already hang up locally
      if (isAnswered && !_localHungUp) {
        try {
          RtcManager.hangUp(widget.callId);
        } catch (e) {
          debugPrint('[VoiceCall] hangUp error during dispose: $e');
        }
      }
    } catch (e) {
      debugPrint('[VoiceCall] dispose error: $e');
    }

    super.dispose();
  }

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
              isRinging ? _buildRingingScreen() : _buildCallScreen(),
              if (!isRinging) _buildControlButtons(),
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
              isCaller ? 'Calling $username…' : 'Incoming Voice Call from $username',
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
          Text(
            'Voice Call',
            style: TextStyle(color: Colors.grey.withOpacity(0.6), fontSize: 16),
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
                RtcManager.toggleMute(widget.callId, isMuted);
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
                // TODO: Implement platform-specific audio routing (Android/iOS MethodChannel or plugin)
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

