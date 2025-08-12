import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:movie_app/webrtc/group_rtc_manager.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:animate_do/animate_do.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

class VideoCallScreenGroup extends StatefulWidget {
  final String callId;
  final String callerId;
  final String? groupId;
  final List<Map<String, dynamic>>? participants;

  const VideoCallScreenGroup({
    super.key,
    required this.callId,
    required this.callerId,
    this.groupId,
    this.participants,
  });

  @override
  State<VideoCallScreenGroup> createState() => _VideoCallScreenGroupState();
}

class _VideoCallScreenGroupState extends State<VideoCallScreenGroup> with SingleTickerProviderStateMixin {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  bool isMuted = false;
  bool isVideoOff = false;
  bool isSpeakerOn = false;
  late Timer _timer;
  int _callDuration = 0;
  String _formattedDuration = '00:00';
  bool isAnswered = false;
  String? _focusedParticipantId;
  late AnimationController _pulseController;
  final Map<String, String> _participantStatus = {};

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _localRenderer.initialize();
    
    if (widget.participants != null) {
      for (var participant in widget.participants!) {
        if (participant['id'] != widget.callerId) {
          _remoteRenderers[participant['id']] = RTCVideoRenderer()..initialize();
          _participantStatus[participant['id']] = 'ringing';
        }
      }
      _focusedParticipantId = widget.participants!
          .firstWhere((p) => p['id'] != widget.callerId, orElse: () => {'id': widget.callerId})['id'];
    }
    
    _startOrAnswerCall();
    _startTimer();
    _listenForCallStatus();
  }

  Future<void> _startOrAnswerCall() async {
    final stream = GroupRtcManager.getLocalStream(widget.callId);
    if (stream != null) _localRenderer.srcObject = stream;
    setState(() {
      isAnswered = true;
    });
    await GroupRtcManager.answerGroupCall(groupId: widget.callId, peerId: widget.callerId);
    _setupRemoteStreams(widget.callId);
  }

  void _setupRemoteStreams(String callId) {
    if (widget.participants != null) {
      for (var participant in widget.participants!) {
        if (participant['id'] != widget.callerId) {
          final stream = GroupRtcManager.getRemoteStream(callId, participant['id']);
          if (stream != null) {
            _remoteRenderers[participant['id']]?.srcObject = stream;
          }
        }
      }
    }
  }

  void _listenForCallStatus() {
    FirebaseFirestore.instance
        .collection('groupCalls')
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
          final activeSpeaker = GroupRtcManager.getActiveSpeaker(widget.callId);
          if (activeSpeaker != null && _remoteRenderers.containsKey(activeSpeaker)) {
            _focusedParticipantId = activeSpeaker;
          }
        });
      }
    });
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

  void _switchFocusedParticipant(String participantId) {
    setState(() => _focusedParticipantId = participantId);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _localRenderer.dispose();
    _remoteRenderers.forEach((_, renderer) => renderer.dispose());
    _timer.cancel();
    if (isAnswered) {
      GroupRtcManager.hangUpGroupCall(widget.callId);
    }
    GroupRtcManager.dispose(widget.callId);
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
                  _buildCallScreen(isLandscape, constraints),
                  _buildControlButtons(isLandscape),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCallScreen(bool isLandscape, BoxConstraints constraints) {
    final focusedRenderer = _focusedParticipantId == widget.callerId
        ? _localRenderer
        : _remoteRenderers[_focusedParticipantId];
    final focusedParticipant = widget.participants?.firstWhere(
          (p) => p['id'] == _focusedParticipantId,
          orElse: () => {'id': widget.callerId, 'username': 'You'},
        ) ?? {'id': widget.callerId, 'username': 'You'};

    return Stack(
      children: [
        if (focusedRenderer != null)
          Positioned.fill(
            child: RTCVideoView(
              focusedRenderer,
              mirror: _focusedParticipantId == widget.callerId,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
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
        if (widget.participants != null)
          Positioned(
            bottom: isLandscape ? 80 : 120,
            left: 16,
            right: 16,
            child: Container(
              height: 100,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: widget.participants!.length,
                itemBuilder: (context, index) {
                  final participant = widget.participants![index];
                  final isLocal = participant['id'] == widget.callerId;
                  final renderer = isLocal ? _localRenderer : _remoteRenderers[participant['id']];
                  final isFocused = participant['id'] == _focusedParticipantId;
                  final status = _participantStatus[participant['id']] ?? 'ringing';

                  return GestureDetector(
                    onTap: () => _switchFocusedParticipant(participant['id']),
                    child: Container(
                      width: 80,
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        border: isFocused ? Border.all(color: Colors.blue, width: 3) : null,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 6,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Stack(
                        children: [
                          if (renderer != null)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: RTCVideoView(
                                renderer,
                                mirror: isLocal,
                                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                              ),
                            ),
                          Positioned(
                            bottom: 4,
                            left: 4,
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              color: Colors.black54,
                              child: Text(
                                participant['username'] ?? 'Participant',
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: status == 'joined' ? Colors.green : Colors.yellow,
                                shape: BoxShape.circle,
                              ),
                              width: 12,
                              height: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
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
                GroupRtcManager.toggleMute(widget.callId, isMuted);
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
                GroupRtcManager.toggleVideo(widget.callId, !isVideoOff);
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
              },
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(16),
              ),
              onPressed: () {
                GroupRtcManager.hangUpGroupCall(widget.callId);
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