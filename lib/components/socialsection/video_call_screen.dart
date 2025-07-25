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
  String? callId;

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _startOrAnswerCall();
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
    final stream = RtcManager.getLocalStream(callId!);
    if (stream != null) _localRenderer.srcObject = stream;
  }
}


  @override
  void dispose() {
    _localRenderer.dispose();
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
          RTCVideoView(_localRenderer, mirror: true),
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: IconButton(
                icon: const Icon(Icons.call_end, size: 50, color: Colors.red),
                onPressed: () {
                  if (callId != null) {
                    RtcManager.hangUp(callId!);
                  }
                  Navigator.pop(context);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
