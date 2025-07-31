import 'dart:async';
import 'package:flutter/material.dart';
import 'package:movie_app/webrtc/rtc_manager.dart'; 

class VoiceCallScreen extends StatefulWidget {
  final Map<String, dynamic> caller;
  final Map<String, dynamic> receiver;
  final String? callId;

  const VoiceCallScreen({
    super.key,
    required this.caller,
    required this.receiver,
    this.callId,
  });

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen> {
  String? callId;
  bool isCaller = false;
  bool isMuted = false;
  late Timer _timer;
  int _callDuration = 0;
  String _formattedDuration = '00:00';

  @override
  void initState() {
    super.initState();
    initCall();
    _startTimer();
  }

  Future<void> initCall() async {
    if (widget.callId == null) {
      final id = await RtcManager.startVoiceCall(
        caller: widget.caller,
        receiver: widget.receiver,
      );
      setState(() {
        callId = id;
        isCaller = true;
      });
    } else {
      setState(() {
        callId = widget.callId;
      });
      await RtcManager.answerCall(widget.callId!);
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
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

  @override
  void dispose() {
    _timer.cancel();
    if (callId != null) {
      RtcManager.hangUp(callId!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 60,
              backgroundImage: NetworkImage(widget.receiver['photoUrl']),
            ),
            const SizedBox(height: 20),
            Text(
              _formattedDuration,
              style: const TextStyle(color: Colors.white, fontSize: 20),
            ),
            const SizedBox(height: 10),
            Text(
              widget.receiver['username'],
              style: const TextStyle(color: Colors.white, fontSize: 24),
            ),
            const SizedBox(height: 10),
            const Text("Voice Call", style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 40),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: Icon(isMuted ? Icons.mic_off : Icons.mic, size: 40, color: Colors.white),
                  onPressed: () {
                    setState(() => isMuted = !isMuted);
                    if (callId != null) RtcManager.toggleMute(callId!, isMuted);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.call_end, size: 40, color: Colors.red),
                  onPressed: () {
                    if (callId != null) {
                      RtcManager.hangUp(callId!);
                    }
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}