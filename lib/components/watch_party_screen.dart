// watch_party_screen.dart
// Watch party UI + controller logic (accepts an optional `post` parameter)

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/settings_provider.dart';
import 'watch_party_components.dart';
import 'watch_party_utils.dart';
import 'watch_party_flow.dart';

class WatchPartyScreen extends StatefulWidget {
  /// Optional post data that initiated the watch party (may contain title, media url, etc).
  final Map<String, dynamic>? post;

  const WatchPartyScreen({super.key, this.post});

  @override
  WatchPartyScreenState createState() => WatchPartyScreenState();
}

class WatchPartyScreenState extends State<WatchPartyScreen>
    with TickerProviderStateMixin {
  final TextEditingController _chatController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  List<String> _messages = []; // Changed from final to non-final so we can mutate
  String _videoPath = "";
  String _title = "Watch Party Video";
  String? _subtitleUrl;
  bool _isHls = false;
  bool _isPlaying = false; // Track playback state

  bool _controlsVisible = true;
  bool _isLoading = false;
  bool _isSearching = false;
  List<Map<String, dynamic>> _searchResults = [];
  Timer? _hideTimer;
  Timer? _partyTimer;

  String? _partyCode;
  bool _isAuthorized = false;
  bool _isCreator = false; // Track if user is party creator
  int _inviteJoinCount = 0;
  DateTime? _partyStartTime;
  int _remainingMinutes = 0;
  bool _isDirectStreamMode = false;
  bool _secretBypass = false;
  bool _chatMuted = false;
  bool _cinemaSoundEnabled = true;

  // Trial and Premium Features
  int _trialTickets = 3;
  bool _isPremium = false;
  late AnimationController _curtainController;
  late AnimationController _doorsController;

  // Social and Engagement
  final Map<String, String> _userSeats = {};
  final List<Map<String, dynamic>> _emojiReactions = [];

  // Firestore instance
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Create flow cancellation flags & state
  bool _creating = false;
  bool _createCancelled = false;

  // Getters
  bool get isSearching => _isSearching;
  List<Map<String, dynamic>> get searchResults => _searchResults;
  bool get isLoading => _isLoading;
  String? get partyCode => _partyCode;
  int get inviteJoinCount => _inviteJoinCount;
  String get videoPath => _videoPath;
  String get title => _title;
  bool get isHls => _isHls;
  String? get subtitleUrl => _subtitleUrl;
  bool get controlsVisible => _controlsVisible;
  int get trialTickets => _trialTickets;
  DateTime? get partyStartTime => _partyStartTime;
  int get remainingMinutes => _remainingMinutes;
  bool get secretBypass => _secretBypass;
  bool get chatMuted => _chatMuted;
  bool get cinemaSoundEnabled => _cinemaSoundEnabled;
  bool get isDirectStreamMode => _isDirectStreamMode;
  bool get isAuthorized => _isAuthorized;
  Timer? get partyTimer => _partyTimer;
  AnimationController get curtainController => _curtainController;
  AnimationController get doorsController => _doorsController;
  bool get isPremium => _isPremium;
  List<String> get messages => _messages;
  TextEditingController get chatController => _chatController;
  Map<String, String> get userSeats => _userSeats;
  List<Map<String, dynamic>> get emojiReactions => _emojiReactions;
  bool get isPlaying => _isPlaying;
  bool get isCreator => _isCreator;

  @override
  void initState() {
    super.initState();
    _curtainController =
        AnimationController(vsync: this, duration: const Duration(seconds: 2));
    _doorsController =
        AnimationController(vsync: this, duration: const Duration(seconds: 2));

    // If a post was supplied, initialize some fields from it (title / video).
    if (widget.post != null) {
      final p = widget.post!;
      // Safely extract title and video/media url if present
      final suppliedTitle =
          (p['title'] as String?) ?? (p['movieTitle'] as String?);
      final suppliedMedia = (p['media'] as String?) ??
          (p['mediaUrl'] as String?) ??
          (p['video'] as String?);
      if (suppliedTitle != null && suppliedTitle.isNotEmpty) {
        _title = suppliedTitle;
      }
      if (suppliedMedia != null && suppliedMedia.isNotEmpty) {
        _videoPath = suppliedMedia;
      }
    }

    // Show role selection after first frame (this helper expected in watch_party_components.dart)
    WidgetsBinding.instance.addPostFrameCallback((_) => showRoleSelection(context, this));

    // Start auto-hide controls timer (helper in watch_party_utils.dart)
    startControlsTimer(this);

    // IMPORTANT: do NOT attach Party listeners here.
    // They will be attached once a party code exists (after create or join).
  }

  // Save party to Firestore (used by schedule flow)
  Future<void> savePartyToFirestore(
      String code, Map<String, dynamic> movie, int delayMinutes) async {
    if (_createCancelled) return; // respect cancellation
    final partyData = {
      'code': code,
      'movieTitle': movie['title'] ?? "Untitled",
      'startTime':
          DateTime.now().add(Duration(minutes: delayMinutes)).toIso8601String(),
      'participants': 1,
      'maxParticipants': 5,
      'createdAt': FieldValue.serverTimestamp(),
      'isActive': true,
      'expiryTime':
          DateTime.now().add(const Duration(hours: 24)).toIso8601String(),
    };
    await _firestore.collection('watch_parties').doc(code).set(partyData);
  }

  // Listen to participant updates and messages (attach after partyCode is assigned)
  void _listenToParticipants() {
    if (_partyCode == null) return;
    // participants summary doc
    _firestore.collection('watch_parties').doc(_partyCode).snapshots().listen(
      (snapshot) {
        if (snapshot.exists && mounted) {
          setState(() {
            _inviteJoinCount = snapshot.data()?['participants'] ?? 0;
          });
        }
      },
      onError: (error) =>
          showError(context, "Error syncing participants: $error"),
    );

    // messages subcollection
    _firestore
        .collection('watch_parties')
        .doc(_partyCode)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .listen(
      (snapshot) {
        if (mounted) {
          setState(() {
            _messages =
                snapshot.docs.map((doc) => doc['message'] as String).toList();
          });
        }
      },
      onError: (error) => showError(context, "Error syncing messages: $error"),
    );
  }

  // Listen to playback state (attach after partyCode is assigned)
  void _listenToPlaybackState() {
    if (_partyCode == null) return;
    _firestore.collection('watch_parties').doc(_partyCode).snapshots().listen(
      (snapshot) {
        if (snapshot.exists && mounted) {
          final playbackState = snapshot.data()?['playbackState'];
          setState(() {
            _isPlaying = playbackState == 'playing';
            if (_isPlaying) {
              _curtainController.forward();
            } else {
              _curtainController.reverse();
            }
          });
        }
      },
      onError: (error) => showError(context, "Error syncing playback: $error"),
    );
  }

  void startMoviePlayback(Map<String, dynamic> movie) {
    if (_trialTickets <= 0 && !_isPremium) {
      _doorsController.forward();
      return;
    }
    setState(() {
      _trialTickets = _trialTickets > 0 ? _trialTickets - 1 : 0;
      _partyStartTime = DateTime.now();
      _remainingMinutes = 60;
      _title = movie['title'] as String? ?? "Direct Stream";
      _isSearching = false;
      _searchResults = [];
    });
    fetchStreamingLinks(movie, this).then((_) {
      if (!mounted) return;
      _curtainController.forward();
      _isPlaying = true;
      if (_partyCode != null) {
        _firestore.collection('watch_parties').doc(_partyCode).update({
          'playbackState': 'playing',
          'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
        });
      }
      startPartyTimer(() {
        if (mounted && _remainingMinutes <= 0) {
          endParty();
        }
      });
      showSuccess(context, "Starting $_title");
    }).catchError((e) {
      if (mounted) showError(context, "Failed to start playback: $e");
    });
  }

  void addEmojiReaction(String emoji) {
    setState(() {
      _emojiReactions.add({
        'emoji': emoji,
        'offset': Offset(0, MediaQuery.of(context).size.height),
        'time': DateTime.now(),
      });
    });
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        if (_emojiReactions.isNotEmpty) {
          setState(() => _emojiReactions.removeAt(0));
        }
      }
    });
  }

  void sendMessage(String value) {
    if (value.isNotEmpty) {
      final userId = "User$_inviteJoinCount";
      final message = "$userId: $value";
      setState(() {
        _messages.add(message);
      });
      _chatController.clear();
      if (_partyCode != null) {
        _firestore
            .collection('watch_parties')
            .doc(_partyCode)
            .collection('messages')
            .add({
          'message': message,
          'timestamp': FieldValue.serverTimestamp(),
        });
      }
    }
  }

  void playVideo() {
    if (!_isCreator) {
      showError(context, "Only the host can control playback");
      return;
    }
    setState(() {
      _isPlaying = true;
      _curtainController.forward();
    });
    if (_partyCode != null) {
      _firestore.collection('watch_parties').doc(_partyCode).update({
        'playbackState': 'playing',
        'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
      });
    }
  }

  void pauseVideo() {
    if (!_isCreator) {
      showError(context, "Only the host can control playback");
      return;
    }
    setState(() {
      _isPlaying = false;
      _curtainController.reverse();
    });
    if (_partyCode != null) {
      _firestore.collection('watch_parties').doc(_partyCode).update({
        'playbackState': 'paused',
        'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
      });
    }
  }

  void toggleChatMute() {
    setState(() {
      _chatMuted = !_chatMuted;
    });
  }

  void toggleCinemaSound() {
    setState(() {
      _cinemaSoundEnabled = !_cinemaSoundEnabled;
    });
  }

  void resetStream() {
    setState(() {
      _partyStartTime = null;
      _videoPath = "";
      _subtitleUrl = null;
      _isHls = false;
      _isPlaying = false;
    });
    _partyTimer?.cancel();
    if (_partyCode != null) {
      _firestore.collection('watch_parties').doc(_partyCode).update({
        'playbackState': 'paused',
        'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
      });
    }
  }

  void upgradeToPremium() {
    setState(() {
      _isPremium = true;
      _doorsController.reverse();
    });
  }

  void hideControlsTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void clearSearchResults() {
    setState(() => _searchResults = []);
  }

  void startSearching() {
    setState(() => _isSearching = true);
  }

  void stopSearching() {
    setState(() => _isSearching = false);
  }

  void updateSearchResults(List<Map<String, dynamic>> results) {
    setState(() {
      _searchResults = results;
      _isSearching = false;
    });
  }

  void updateStreamInfo({
    required String videoPath,
    required String title,
    String? subtitleUrl,
    required bool isHls,
  }) {
    setState(() {
      _videoPath = videoPath;
      _title = title;
      _subtitleUrl = subtitleUrl;
      _isHls = isHls;
    });
  }

  void addTrialTicket() {
    setState(() => _trialTickets++);
  }

  void addTriviaMessage(String answer) {
    final message = "Trivia: $answer";
    setState(() => _messages.add(message));
    if (_partyCode != null) {
      _firestore
          .collection('watch_parties')
          .doc(_partyCode)
          .collection('messages')
          .add({
        'message': message,
        'timestamp': FieldValue.serverTimestamp(),
      });
    }
  }

  /// Cancelable create flow:
  /// This shows a confirmation then a cancellable progress dialog while the party doc is being created.
  void authorizeCreator() async {
    if (!mounted) return;

    // Ask the user for confirmation first (so they can cancel before starting)
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final settings = Provider.of<SettingsProvider>(ctx, listen: false);
        return AlertDialog(
          backgroundColor: Colors.black87,
          title: const Text('Create Watch Party'),
          content: const Text('Create a new watch party? You can cancel while creating.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: settings.accentColor),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create', style: TextStyle(color: Colors.black)),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    // Start creating
    setState(() {
      _isLoading = true;
      _creating = true;
      _createCancelled = false;
    });

    // Show progress dialog with cancel option
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(builder: (context, setStateDialog) {
          return AlertDialog(
            backgroundColor: Colors.black87,
            title: const Text('Creating party...'),
            content: const SizedBox(height: 48, child: Center(child: CircularProgressIndicator())),
            actions: [
              TextButton(
                onPressed: () {
                  // set cancellation flag; the ongoing create logic will respect this
                  _createCancelled = true;
                  setStateDialog(() {});
                  try {
                    Navigator.of(ctx).pop(); // dismiss progress dialog
                  } catch (_) {}
                },
                child: const Text('Cancel', style: TextStyle(color: Colors.red)),
              ),
            ],
          );
        });
      },
    );

    // Attempt creation (generate code, ensure non-collision); respect cancel flag
    try {
      final codeAttempt = generateSecurePartyCode();
      if (_createCancelled) throw Exception('Create cancelled');

      final existing = await _firestore.collection('watch_parties').doc(codeAttempt).get();
      if (_createCancelled) throw Exception('Create cancelled');

      if (existing.exists) {
        // If collision, try up to a few times
        String? successCode;
        for (var i = 0; i < 5 && !_createCancelled; i++) {
          final next = generateSecurePartyCode();
          final existsNext = await _firestore.collection('watch_parties').doc(next).get();
          if (!existsNext.exists) {
            successCode = next;
            break;
          }
        }
        if (_createCancelled) throw Exception('Create cancelled');
        if (successCode == null) {
          throw Exception('Failed to generate unique code. Try again.');
        } else {
          // use successCode
          await _firestore.collection('watch_parties').doc(successCode).set({
            'code': successCode,
            'movieTitle': _title,
            'startTime': DateTime.now().toIso8601String(),
            'participants': 1,
            'maxParticipants': 5,
            'createdAt': FieldValue.serverTimestamp(),
            'isActive': true,
            'expiryTime': DateTime.now().add(const Duration(hours: 24)).toIso8601String(),
          });
          if (_createCancelled) throw Exception('Create cancelled');
          if (!mounted) return;
          setState(() {
            _isAuthorized = true;
            _isCreator = true;
            _partyCode = successCode;
          });
          // attach listeners now that partyCode exists
          _listenToParticipants();
          _listenToPlaybackState();
          showSuccess(context, "Party created! Code: $successCode");
        }
      } else {
        // use codeAttempt
        await _firestore.collection('watch_parties').doc(codeAttempt).set({
          'code': codeAttempt,
          'movieTitle': _title,
          'startTime': DateTime.now().toIso8601String(),
          'participants': 1,
          'maxParticipants': 5,
          'createdAt': FieldValue.serverTimestamp(),
          'isActive': true,
          'expiryTime': DateTime.now().add(const Duration(hours: 24)).toIso8601String(),
        });
        if (_createCancelled) throw Exception('Create cancelled');
        if (!mounted) return;
        setState(() {
          _isAuthorized = true;
          _isCreator = true;
          _partyCode = codeAttempt;
        });
        _listenToParticipants();
        _listenToPlaybackState();
        showSuccess(context, "Party created! Code: $codeAttempt");
      }
    } catch (e) {
      if (!_createCancelled && mounted) {
        showError(context, e.toString());
      }
    } finally {
      // Ensure progress dialog is dismissed
      try {
        Navigator.of(context, rootNavigator: true).pop(); // pop possible progress dialog
      } catch (_) {}
      if (mounted) {
        setState(() {
          _isLoading = false;
          _creating = false;
        });
      }
    }
  }

  /// Cancel an already-created party (creator only).
  Future<void> cancelCreatedParty() async {
    if (_partyCode == null || !_isCreator) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.black87,
        title: const Text('Cancel Party'),
        content: const Text('Are you sure you want to cancel and delete this party?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
        ],
      ),
    );

    if (confirm != true) return;
    try {
      await _firestore.collection('watch_parties').doc(_partyCode).delete();
    } catch (e) {
      debugPrint('Failed to delete party doc: $e');
    } finally {
      if (!mounted) return;
      setState(() {
        _partyCode = null;
        _isCreator = false;
        _isAuthorized = false;
        _inviteJoinCount = 0;
        _messages = [];
      });
      showSuccess(context, 'Party cancelled');
    }
  }

  void authorizeAdmin() {
    setState(() {
      _secretBypass = true;
      _isAuthorized = true;
      _isCreator = true;
      _isPremium = true;
    });
  }

  void authorizeDirectStream() {
    setState(() {
      _isAuthorized = true;
      _isCreator = true;
      _secretBypass = true;
      _isDirectStreamMode = true;
    });
  }

  void joinParty(String partyCode, String seat) async {
    setState(() => _isLoading = true);
    try {
      final partyDoc =
          await _firestore.collection('watch_parties').doc(partyCode).get();
      if (partyDoc.exists && partyDoc.data()?['isActive'] == true) {
        final currentParticipants = partyDoc.data()?['participants'] ?? 0;
        final maxParticipants = partyDoc.data()?['maxParticipants'] ?? 5;
        if (currentParticipants < maxParticipants) {
          await _firestore.collection('watch_parties').doc(partyCode).update({
            'participants': FieldValue.increment(1),
          });
          if (!mounted) return;
          setState(() {
            _isAuthorized = true;
            _partyCode = partyCode;
            _userSeats["User$_inviteJoinCount"] = seat;
            _inviteJoinCount = currentParticipants + 1;
          });
          // Attach listeners now
          _listenToParticipants();
          _listenToPlaybackState();
          showSuccess(context, "Joined party successfully!");
        } else {
          showError(context, "Party is full!");
        }
      } else {
        showError(context, "Invalid or expired party code!");
      }
    } catch (e) {
      showError(context, "Failed to join party: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void startPartyScheduling(int delayMinutes) {
    setState(() {
      _isLoading = true;
      _partyStartTime = DateTime.now().add(Duration(minutes: delayMinutes));
      _remainingMinutes = delayMinutes;
      _trialTickets = _trialTickets > 0 ? _trialTickets - 1 : 0;
    });
  }

  void stopPartyScheduling() {
    setState(() => _isLoading = false);
  }

  void startPartyTimer(VoidCallback onTick) {
    _partyTimer?.cancel();
    _partyTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      setState(() => _remainingMinutes--);
      onTick();
    });
  }

  void endParty() async {
    if (_partyCode != null) {
      try {
        await _firestore.collection('watch_parties').doc(_partyCode).update({
          'isActive': false,
          'playbackState': 'paused',
        });
      } catch (e) {
        debugPrint('Failed to mark party inactive: $e');
      }
    }
    if (!mounted) return;
    setState(() {
      _partyStartTime = null;
      _videoPath = "";
      _title = "Watch Party Video";
      _subtitleUrl = null;
      _isHls = false;
      _isPlaying = false;
      _isDirectStreamMode = false;
    });
  }

  void setMovieTitle(String title) {
    setState(() => _title = title);
  }

  @override
  void dispose() {
    _chatController.dispose();
    _searchController.dispose();
    _hideTimer?.cancel();
    _partyTimer?.cancel();
    _curtainController.dispose();
    _doorsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, child) {
        if (!_isAuthorized) {
          return const Scaffold(
            backgroundColor: Colors.black,
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (_isCreator && _partyStartTime == null) {
          return _isDirectStreamMode
              ? buildDirectStreamSearchView(context, this, _searchController)
              : buildCreatorSetupView(context, this, _searchController);
        }

        if (!_isCreator && _partyStartTime == null) {
          return buildInviteeWaitingView(context, this);
        }

        return buildPartyView(context, this);
      },
    );
  }
}
