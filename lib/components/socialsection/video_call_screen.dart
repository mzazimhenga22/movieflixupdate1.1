import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';

class VideoCallScreen extends StatefulWidget {
  final Map<String, dynamic> caller;
  final Map<String, dynamic> receiver;
  final String? callId;

  const VideoCallScreen({
    super.key,
    required this.caller,
    required this.receiver,
    this.callId,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  String? callId;
  bool isMuted = false;
  bool isVideoOff = false;
  late Timer _timer;
  int _callDuration = 0;
  String _formattedDuration = '00:00';

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _remoteRenderer.initialize();
    _startOrAnswerCall();
    _startTimer();
  }

  Future<void> _startOrAnswerCall() async {
    if (widget.callId == null) {
      final id = await RtcManager.startVideoCall(
        caller: widget.caller,
        receiver: widget.receiver,
      );
      final stream = RtcManager.getLocalStream(id);
      if (stream != null) _localRenderer.srcObject = stream;
      setState(() => callId = id);
    } else {
      callId = widget.callId;
      await RtcManager.answerCall(callId!);
      final localStream = RtcManager.getLocalStream(callId!);
      if (localStream != null) _localRenderer.srcObject = localStream;
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
    _localRenderer.dispose();
    _remoteRenderer.dispose();
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
      body: Stack(
        children: [
          Center(
            child: RTCVideoView(_remoteRenderer),
          ),
          Positioned(
            top: 20,
            right: 20,
            child: SizedBox(
              width: 150,
              height: 200,
              child: RTCVideoView(_localRenderer, mirror: true),
            ),
          ),
          Positioned(
            top: 20,
            left: 20,
            child: Text(
              _formattedDuration,
              style: const TextStyle(color: Colors.white, fontSize: 20),
            ),
          ),
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Row(
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
                  icon: Icon(isVideoOff ? Icons.videocam_off : Icons.videocam, size: 40, color: Colors.white),
                  onPressed: () {
                    setState(() => isVideoOff = !isVideoOff);
                    // Add video toggle logic
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.call_end, size: 50, color: Colors.red),
                  onPressed: () {
                    if (callId != null) {
                      RtcManager.hangUp(callId!);
                    }
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}