import 'dart:async';
import 'package:flutter/material.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:animate_do/animate_do.dart';

class VoiceCallScreen extends StatefulWidget {
  final String callId;
  final String callerId;
  final String receiverId;
  final String? groupId;
  final List<Map<String, dynamic>>? participants;
  final Map<String, dynamic>? caller;

  const VoiceCallScreen({
    super.key,
    required this.callId,
    required this.callerId,
    required this.receiverId,
    this.groupId,
    this.participants,
    this.caller,
  });

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen> with SingleTickerProviderStateMixin {
  bool isMuted = false;
  bool isSpeakerOn = false;
  bool isRinging = false;
  bool isAnswered = false;
  late Timer _timer;
  int _callDuration = 0;
  String _formattedDuration = '00:00';
  late AnimationController _pulseController;
  final Map<String, String> _participantStatus = {};

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    
    if (widget.participants != null) {
      for (var participant in widget.participants!) {
        if (participant['id'] != widget.callerId) {
          _participantStatus[participant['id']] = 'ringing';
        }
      }
    } else {
      if (widget.callerId != widget.receiverId) {
        _participantStatus[widget.receiverId] = 'ringing';
      }
    }
    
    initCall();
    _startTimer();
    _listenForCallStatus();
  }

  Future<void> initCall() async {
    if (widget.groupId == null) {
      setState(() {
        isRinging = true;
      });
    } else {
      setState(() {
        isAnswered = true;
      });
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _callDuration++;
          _formattedDuration = _formatDuration(_callDuration);
        });
      }
    });
  }

  String _formatDuration(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$secs';
  }

  void _listenForCallStatus() {
    final collection = widget.groupId != null ? 'groupCalls' : 'calls';
    FirebaseFirestore.instance
        .collection(collection)
        .doc(widget.callId)
        .snapshots()
        .listen((snapshot) {
      final data = snapshot.data();
      if (data != null && data['status'] == 'ended') {
        if (mounted) Navigator.pop(context);
      }
      if (data != null && mounted) {
        setState(() {
          final statusMap = Map<String, String>.from(data['participantStatus'] ?? {});
          statusMap.forEach((id, status) {
            if (_participantStatus.containsKey(id)) {
              _participantStatus[id] = status;
            }
          });
        });
      }
    });
  }

  Future<void> _answerCall() async {
    await RtcManager.answerCall(callId: widget.callId, peerId: widget.callerId);
    setState(() {
      isRinging = false;
      isAnswered = true;
    });
  }

  Future<void> _rejectCall() async {
    await RtcManager.rejectCall(callId: widget.callId, peerId: widget.callerId);
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _timer.cancel();
    if (isAnswered) {
      RtcManager.hangUp(widget.callId);
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
              if (isRinging) _buildRingingScreen() else _buildCallScreen(),
              _buildControlButtons(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRingingScreen() {
    final caller = widget.participants?.firstWhere((p) => p['id'] == widget.callerId, orElse: () => {}) ?? {'username': 'Unknown'};
    return Center(
      child: FadeIn(
        duration: const Duration(milliseconds: 500),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Pulse(
              controller: (controller) => controller.repeat(reverse: true),
              child: CircleAvatar(
                radius: 60,
                backgroundImage: caller['photoUrl'] != null
                    ? NetworkImage(caller['photoUrl'])
                    : null,
                child: caller['photoUrl'] == null
                    ? const Icon(Icons.person, size: 60)
                    : null,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Incoming Voice Call from ${caller['username'] ?? 'Unknown'}',
              style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 40),
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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Pulse(
            controller: (controller) => controller.repeat(reverse: true),
            child: CircleAvatar(
              radius: 60,
              backgroundImage: widget.caller?['photoUrl'] != null
                  ? NetworkImage(widget.caller!['photoUrl'])
                  : null,
              child: widget.caller?['photoUrl'] == null
                  ? const Icon(Icons.person, size: 60)
                  : null,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            widget.caller?['username'] ?? 'Group Call',
            style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Text(
            _formattedDuration,
            style: const TextStyle(color: Colors.white70, fontSize: 20),
          ),
          const SizedBox(height: 10),
          Text(
            "Voice Call",
            style: TextStyle(color: Colors.grey.shade400, fontSize: 16),
          ),
          const SizedBox(height: 20),
          if (widget.participants != null)
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: widget.participants!
                  .where((p) => p['id'] != widget.callerId)
                  .map((participant) {
                final status = _participantStatus[participant['id']] ?? 'ringing';
                return Chip(
                  label: Text(
                    participant['username'] ?? 'Participant',
                    style: const TextStyle(color: Colors.white),
                  ),
                  avatar: CircleAvatar(
                    backgroundImage: participant['photoUrl'] != null ? NetworkImage(participant['photoUrl']) : null,
                    child: participant['photoUrl'] == null ? const Icon(Icons.person) : null,
                  ),
                  backgroundColor: status == 'joined' ? Colors.green.withOpacity(0.7) : Colors.yellow.withOpacity(0.7),
                );
              }).toList(),
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
                // Implement speaker toggle logic if supported by platform
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
                if (mounted) Navigator.pop(context);
              },
              child: const Icon(Icons.call_end, size: 32, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}