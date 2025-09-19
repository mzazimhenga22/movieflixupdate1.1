// lib/components/socialsection/voice_call_screen_group.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:movie_app/webrtc/group_rtc_manager.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:animate_do/animate_do.dart';
import 'package:permission_handler/permission_handler.dart';

class VoiceCallScreen extends StatefulWidget {
  final String callId;
  final String callerId;   // local user id (who's using the screen)
  final String receiverId; // for 1:1 voice calls
  final String? groupId;   // if present, use group manager
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

class _VoiceCallScreenState extends State<VoiceCallScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  bool isMuted = false;
  bool isSpeakerOn = false;
  bool isRinging = false;
  bool isAnswered = false;

  Timer? _durationTimer;
  int _callDuration = 0;
  String _formattedDuration = '00:00';

  AnimationController? _pulseController;
  final Map<String, String> _participantStatus = {};

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _statusSub;

  /// Whether client has already joined (answered) the group
  bool _hasJoined = false;

  String get _groupKey => widget.groupId ?? widget.callId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseController =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))
          ..repeat(reverse: true);

    // initialize participant statuses safely
    if (widget.participants != null && widget.participants!.isNotEmpty) {
      for (final p in widget.participants!) {
        final id = (p['id']?.toString() ?? '');
        if (id.isEmpty) continue;
        if (id == widget.callerId) continue;
        _participantStatus[id] = 'ringing';
      }
    } else {
      if (widget.callerId != widget.receiverId) {
        _participantStatus[widget.receiverId] = 'ringing';
      }
    }

    _initCallState();
    _listenForCallStatus();
  }

  Future<void> _initCallState() async {
    // If group, only join when another participant has joined (host waits for participants)
    if (widget.groupId != null) {
      try {
        final doc = await FirebaseFirestore.instance.collection('groupCalls').doc(widget.callId).get();
        if (doc.exists) {
          final data = doc.data()!;
          final host = data['host']?.toString();
          final isHost = host == widget.callerId;
          final Map<String, dynamic>? statusMap = (data['participantStatus'] as Map?)?.cast<String, dynamic>();

          // populate local statuses
          if (statusMap != null) {
            statusMap.forEach((k, v) {
              if (k == widget.callerId) return;
              _participantStatus[k] = v?.toString() ?? 'ringing';
            });
          }

          final someoneJoined = _anyOtherJoined(statusMap);
          if (someoneJoined) {
            // safe to join now
            await GroupRtcManager.answerGroupCall(groupId: _groupKey, peerId: widget.callerId);
            _hasJoined = true;
            setState(() { isAnswered = true; isRinging = false; });
            _startDurationTimer();
          } else {
            // wait: host shows "calling", others show "ringing" (they can tap to answer)
            setState(() {
              isAnswered = false;
              isRinging = !isHost; // host sees calling overlay (not ringing)
            });
          }
        } else {
          // no doc found — behave as ringing to be safe
          setState(() {
            isAnswered = false;
            isRinging = true;
          });
        }
      } catch (e) {
        debugPrint('[VoiceGroup] initCallState error: $e');
        // fallback to ringing for non-hosts
        setState(() {
          isAnswered = false;
          isRinging = true;
        });
      }
    } else {
      // 1:1 call: show ringing until answered locally
      setState(() {
        isRinging = true;
      });
    }
  }

  bool _anyOtherJoined(Map<String, dynamic>? statusMap) {
    if (statusMap == null) return false;
    for (final entry in statusMap.entries) {
      final id = entry.key;
      final s = entry.value?.toString() ?? '';
      if (id != widget.callerId && s == 'joined') return true;
    }
    return false;
  }

  void _listenForCallStatus() {
    final collection = widget.groupId != null ? 'groupCalls' : 'calls';
    try {
      _statusSub = FirebaseFirestore.instance
          .collection(collection)
          .doc(widget.callId)
          .snapshots()
          .listen((snapshot) async {
        final data = snapshot.data();
        if (!mounted) return;
        if (data == null) return;

        final status = data['status'] as String?;
        if (status == 'ended' || status == 'rejected') {
          // verify terminal state with fresh read to avoid acting on transient snapshots
          final fresh = await FirebaseFirestore.instance.collection(collection).doc(widget.callId).get();
          final freshStatus = fresh.exists ? (fresh.get('status') as String?) : null;
          if (freshStatus == 'ended' || freshStatus == 'rejected') {
            if (mounted) Navigator.of(context).pop();
            return;
          }
        }

        // update participantStatus map safely
        final statusRaw = data['participantStatus'];
        if (statusRaw is Map) {
          final statusMap = statusRaw.cast<String, dynamic>();
          bool shouldSet = false;
          statusMap.forEach((id, s) {
            if (_participantStatus.containsKey(id) && _participantStatus[id] != s) {
              _participantStatus[id] = s?.toString() ?? 'unknown';
              shouldSet = true;
            }
          });
          if (shouldSet && mounted) setState(() {});
          // If we're in a group and haven't joined, and someone else became 'joined' -> join now
          if (widget.groupId != null && !_hasJoined) {
            final someoneJoined = _anyOtherJoined(statusMap);
            if (someoneJoined) {
              try {
                await GroupRtcManager.answerGroupCall(groupId: _groupKey, peerId: widget.callerId);
                _hasJoined = true;
                if (mounted) {
                  setState(() {
                    isAnswered = true;
                    isRinging = false;
                  });
                }
                _startDurationTimer();
              } catch (e) {
                debugPrint('[VoiceGroup] error auto-joining when someone joined: $e');
              }
            }
          }
        }

        if (status == 'answered' && !isAnswered) {
          setState(() {
            isAnswered = true;
            isRinging = false;
          });
          _startDurationTimer();
        }
      }, onError: (err) {
        debugPrint('[VoiceCall] call status listen error: $err');
      });
    } catch (e) {
      debugPrint('[VoiceCall] listenForCallStatus setup failed: $e');
    }
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
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
      // request mic permission UI dialog
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Microphone permission required')));
        }
        return;
      }

      if (widget.groupId != null) {
        // If user explicitly taps "answer", join immediately (even if host was waiting)
        await GroupRtcManager.answerGroupCall(groupId: _groupKey, peerId: widget.callerId);
        _hasJoined = true;
      } else {
        await RtcManager.answerCall(callId: widget.callId, peerId: widget.callerId);
      }

      if (mounted) {
        setState(() {
          isAnswered = true;
          isRinging = false;
        });
      }
      _startDurationTimer();
    } catch (e, st) {
      debugPrint('[VoiceCall] answer error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to answer call')));
      }
    }
  }

  Future<void> _rejectCall() async {
    try {
      if (widget.groupId != null) {
        await GroupRtcManager.rejectGroupCall(groupId: _groupKey, peerId: widget.callerId);
      } else {
        await RtcManager.rejectCall(callId: widget.callId, peerId: widget.callerId);
      }
    } catch (e) {
      debugPrint('[VoiceCall] reject error: $e');
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _hangUp() async {
    try {
      if (widget.groupId != null) {
        await GroupRtcManager.hangUpGroupCall(_groupKey);
      } else {
        await RtcManager.hangUp(widget.callId);
      }
    } catch (e) {
      debugPrint('[VoiceCall] hangUp error: $e');
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // nothing needed for audio-only right now; hook for future improvements
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    try {
      _pulseController?.dispose();
    } catch (_) {}
    _durationTimer?.cancel();
    try {
      _statusSub?.cancel();
    } catch (_) {}

    try {
      if (_hasJoined) {
        if (widget.groupId != null) {
          GroupRtcManager.hangUpGroupCall(_groupKey);
        } else {
          RtcManager.hangUp(widget.callId);
        }
      }
    } catch (e) {
      debugPrint('[VoiceCall] hangUp during dispose error: $e');
    }
    super.dispose();
  }

  Widget _buildRingingScreen() {
    // Resolve caller object safely (from participants list or widget.caller)
    Map<String, dynamic>? callerMap;
    if (widget.participants != null) {
      try {
        final found = widget.participants!.firstWhere(
          (p) => (p['id']?.toString() ?? '') == widget.callerId,
          orElse: () => <String, dynamic>{},
        );
        if (found is Map && found.isNotEmpty) callerMap = Map<String, dynamic>.from(found);
      } catch (_) {}
    }
    callerMap ??= widget.caller;

    final username = (callerMap != null && callerMap['username'] != null) ? callerMap['username'].toString() : 'Unknown';
    final photo = (callerMap != null && callerMap['photoUrl'] != null) ? callerMap['photoUrl'].toString() : null;

    return Center(
      child: FadeIn(
        duration: const Duration(milliseconds: 500),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Pulse(
            controller: (c) => c.repeat(reverse: true),
            child: CircleAvatar(
              radius: 60,
              backgroundImage: photo != null ? NetworkImage(photo) : null,
              child: photo == null ? const Icon(Icons.person, size: 60) : null,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            widget.groupId != null ? 'Incoming Group Call' : 'Incoming Voice Call from $username',
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 40),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
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
          ]),
        ]),
      ),
    );
  }

  Widget _buildCallScreen() {
    final displayName = (widget.caller != null && widget.caller!['username'] != null)
        ? widget.caller!['username'].toString()
        : 'Voice Call';

    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Pulse(
          controller: (c) => c.repeat(reverse: true),
          child: CircleAvatar(
            radius: 60,
            backgroundImage: (widget.caller != null && widget.caller!['photoUrl'] != null)
                ? NetworkImage(widget.caller!['photoUrl'].toString())
                : null,
            child: (widget.caller == null || widget.caller!['photoUrl'] == null) ? const Icon(Icons.person, size: 60) : null,
          ),
        ),
        const SizedBox(height: 20),
        Text(displayName, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Text(_formattedDuration, style: const TextStyle(color: Colors.white70, fontSize: 20)),
        const SizedBox(height: 10),
        Text("Voice Call", style: TextStyle(color: const Color.fromRGBO(158, 158, 158, 1), fontSize: 16)),
        const SizedBox(height: 20),
        if (widget.participants != null)
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: widget.participants!
                .where((p) => (p['id']?.toString() ?? '') != widget.callerId)
                .map((participant) {
              final pid = participant['id']?.toString() ?? '';
              final username = participant['username']?.toString() ?? 'Participant';
              final photo = participant['photoUrl']?.toString();
              final status = _participantStatus[pid] ?? 'ringing';

              final Color backgroundColor = status == 'joined'
                  ? const Color.fromRGBO(76, 175, 80, 0.7) // green 500 with alpha
                  : const Color.fromRGBO(255, 235, 59, 0.7); // yellow 500 with alpha

              return Chip(
                label: Text(username, style: const TextStyle(color: Colors.white)),
                avatar: CircleAvatar(
                  backgroundImage: photo != null ? NetworkImage(photo) : null,
                  child: photo == null ? const Icon(Icons.person) : null,
                ),
                backgroundColor: backgroundColor,
              );
            }).toList(),
          ),
      ]),
    );
  }

  Widget _buildControlButtons() {
    return Positioned(
      bottom: 16,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(30)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: Icon(isMuted ? Icons.mic_off : Icons.mic, color: isMuted ? Colors.red : Colors.white, size: 32),
              onPressed: () {
                setState(() => isMuted = !isMuted);
                if (widget.groupId != null) {
                  GroupRtcManager.toggleMute(_groupKey, isMuted);
                } else {
                  RtcManager.toggleMute(widget.callId, isMuted);
                }
              },
            ),
            IconButton(
              icon: Icon(isSpeakerOn ? Icons.volume_up : Icons.volume_off, color: isSpeakerOn ? Colors.white : Colors.grey, size: 32),
              onPressed: () {
                setState(() => isSpeakerOn = !isSpeakerOn);
                // platform-specific speaker toggle can be implemented if desired
              },
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, shape: const CircleBorder(), padding: const EdgeInsets.all(16)),
              onPressed: _hangUp,
              child: const Icon(Icons.call_end, size: 32, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Colors.blue.shade900, Colors.black]),
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
}
