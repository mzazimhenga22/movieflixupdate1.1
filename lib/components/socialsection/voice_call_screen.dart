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

  @override
  void initState() {
    super.initState();
    initCall();
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

  @override
  void dispose() {
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
              widget.receiver['username'],
              style: const TextStyle(color: Colors.white, fontSize: 24),
            ),
            const SizedBox(height: 10),
            const Text("Voice Call", style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 40),
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
      ),
    );
  }
}
