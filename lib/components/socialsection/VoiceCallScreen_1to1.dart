import 'dart:async';
import 'package:flutter/material.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:animate_do/animate_do.dart';

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
  late StreamSubscription<DocumentSnapshot> _callStatusSubscription;

  @override
  void initState() {
    super.initState();
      _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat(reverse: true);
    _startOrAnswerCall();
    _listenForCallStatus();
  }

  Future<void> _startOrAnswerCall() async {
    // both caller & receiver initially see ringing UI
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
        .listen((snapshot) {
      final data = snapshot.data();
      if (data == null || !mounted) return;

      switch (data['status'] as String) {
        case 'ended':
          if (mounted) Navigator.of(context).pop();
          break;
        case 'answered':
          if (!isAnswered) {
            setState(() {
              isAnswered = true;
              isRinging = false;
            });
            _startTimer();
          }
          break;
        case 'rejected':
          if (mounted) Navigator.of(context).pop();
          break;
      }
    });
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _callDuration++;
        _formattedDuration = _formatDuration(_callDuration);
      });
    });
  }

  String _formatDuration(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$secs';
  }

  Future<void> _answerCall() async {
    await RtcManager.answerCall(
      callId: widget.callId,
      peerId: widget.currentUserId,
    );
    setState(() {
      isRinging = false;
      isAnswered = true;
    });
  }

  Future<void> _rejectCall() async {
    await RtcManager.rejectCall(
      callId: widget.callId,
      peerId: widget.currentUserId,
    );
    if (mounted) Navigator.of(context).pop();
  }

bool _isDisposed = false;

@override
void dispose() {
  if (_isDisposed) return;
  _isDisposed = true;

  try {
    // ✅ Stop and dispose the AnimationController first
    if (_pulseController != null) {
      _pulseController!.stop();
      _pulseController!.dispose(); // This disposes the ticker
    }

    // Cancel timers and streams
    _timer?.cancel();
    _callStatusSubscription.cancel();

    // Hang up the call if active
    if (isAnswered) {
      RtcManager.hangUp(widget.callId);
    }
  } catch (e) {
    debugPrint("Dispose error: $e");
  }

  // ✅ Call super.dispose() last
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
              isRinging
                  ? _buildRingingScreen()
                  : _buildCallScreen(),
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
              backgroundImage:
                  photoUrl != null ? NetworkImage(photoUrl) : null,
              child: photoUrl == null
                  ? const Icon(Icons.person, size: 60)
                  : null,
            ),
            const SizedBox(height: 20),
            Text(
              isCaller
                  ? 'Calling $username…'
                  : 'Incoming Voice Call from $username',
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
                child:
                    const Icon(Icons.call_end, size: 30, color: Colors.white),
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
                    child:
                        const Icon(Icons.call, size: 30, color: Colors.white),
                  ),
                  const SizedBox(width: 40),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(20),
                    ),
                    onPressed: _rejectCall,
                    child: const Icon(Icons.call_end,
                        size: 30, color: Colors.white),
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
  manualTrigger: true,
  animate: true,
  controller: (controller) {
    _pulseController = controller;
    controller.repeat(reverse: true);
  },
  child: CircleAvatar(
    radius: 60,
    backgroundImage:
        photoUrl != null ? NetworkImage(photoUrl) : null,
    child: photoUrl == null
        ? const Icon(Icons.person, size: 60)
        : null,
  ),
),

          const SizedBox(height: 20),
          Text(
            username,
            style: const TextStyle(
                color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
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
                // TODO: Implement audio routing (platform-specific)
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
              child:
                  const Icon(Icons.call_end, size: 32, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
