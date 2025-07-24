import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_sound/public/flutter_sound_recorder.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'dart:io' show File;
import 'dart:typed_data';
import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'chat_settings_screen.dart';
import 'stories.dart';
import 'chat_app_bar.dart';
import 'message_list.dart';
import 'typing_area.dart';
import 'package:movie_app/database/auth_database.dart';
import 'message_query.dart';

// Top-level function for decryption in an isolate
Future<Map<String, dynamic>> _decryptDoc(List<dynamic> args) async {
  final Map<String, dynamic> data = args[0];
  final String docId = args[1];
  final String base64Iv = args[2];
  final List<int> keyBytes = args[3];
  final encrypter = encrypt.Encrypter(
    encrypt.AES(encrypt.Key(Uint8List.fromList(keyBytes))),
  );
  final iv = encrypt.IV.fromBase64(base64Iv);
  final decrypted = encrypter.decrypt64(data['message'], iv: iv);
  data['message'] = decrypted;
  data['firestore_id'] = docId;
  return data;
}

// WebRTCCallWidget remains unchanged
class WebRTCCallWidget extends StatefulWidget {
  final MediaStream? localStream;
  final MediaStream? remoteStream;
  final bool isVideo;
  final VoidCallback onEnd;

  const WebRTCCallWidget({
    super.key,
    required this.localStream,
    required this.remoteStream,
    required this.isVideo,
    required this.onEnd,
  });

  @override
  State<WebRTCCallWidget> createState() => _WebRTCCallWidgetState();
}

class _WebRTCCallWidgetState extends State<WebRTCCallWidget> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _isMuted = false;
  bool _isCameraOn = true;

  @override
  void initState() {
    super.initState();
    _initRenderers();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (widget.localStream != null) {
      _localRenderer.srcObject = widget.localStream;
    }
    if (widget.remoteStream != null) {
      _remoteRenderer.srcObject = widget.remoteStream;
    }
  }

  @override
  void didUpdateWidget(covariant WebRTCCallWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.localStream != oldWidget.localStream) {
      _localRenderer.srcObject = widget.localStream;
    }
    if (widget.remoteStream != oldWidget.remoteStream) {
      _remoteRenderer.srcObject = widget.remoteStream;
    }
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      widget.localStream?.getAudioTracks().forEach((track) {
        track.enabled = !_isMuted;
      });
    });
  }

  void _toggleCamera() {
    setState(() {
      _isCameraOn = !_isCameraOn;
      widget.localStream?.getVideoTracks().forEach((track) {
        track.enabled = _isCameraOn;
      });
    });
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          if (widget.isVideo && widget.remoteStream != null)
            RTCVideoView(
              _remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          if (widget.isVideo && widget.localStream != null)
            Align(
              alignment: Alignment.topLeft,
              child: Container(
                width: 120,
                height: 160,
                margin: const EdgeInsets.all(16),
                child: RTCVideoView(
                  _localRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(
                      _isMuted ? Icons.mic_off : Icons.mic,
                      color: Colors.white,
                    ),
                    onPressed: _toggleMute,
                  ),
                  if (widget.isVideo)
                    IconButton(
                      icon: Icon(
                        _isCameraOn ? Icons.videocam : Icons.videocam_off,
                        color: Colors.white,
                      ),
                      onPressed: _toggleCamera,
                    ),
                  ElevatedButton(
                    onPressed: widget.onEnd,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                    ),
                    child: const Text(
                      'End Call',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class IndividualChatScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;
  final List<Map<String, dynamic>> storyInteractions;

  const IndividualChatScreen({
    super.key,
    required this.currentUser,
    required this.otherUser,
    this.storyInteractions = const [],
  });

  @override
  State<IndividualChatScreen> createState() => _IndividualChatScreenState();
}

class _IndividualChatScreenState extends State<IndividualChatScreen>
    with SingleTickerProviderStateMixin {
  Future<void>? _bootstrapping;
  String? _conversationId;

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String? _replyingToMessageId;
  Color _chatBgColor = Colors.white;
  String? _chatBgImage;
  String? _cinematicTheme;
  String _searchTerm = "";
  bool _showSearch = false;
  final TextEditingController _searchController = TextEditingController();
  FlutterSoundRecorder? _recorder;
  bool _isRecording = false;
  String? _audioPath;
  AnimationController? _animationController;
  Animation<double>? _pulseAnimation;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  StreamSubscription<QuerySnapshot>? _callsSubscription;
  StreamSubscription<DocumentSnapshot>? _callSubscription;
  StreamSubscription<QuerySnapshot>? _candidatesSubscription;
  String? _currentCallId;
  bool _isInCall = false;
  bool _isVideoCall = false;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final SupabaseClient _supabase = Supabase.instance.client;
  StreamSubscription<DocumentSnapshot>? _typingSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _showEmojiPicker = false;
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _currentlyPlayingId;
  Timer? _typingTimer;
  bool _isTyping = false;
  bool _isOtherTyping = false;
  late encrypt.Key _encryptionKey;
  late encrypt.Encrypter _encrypter;
  Database? _localDb;
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  String? _draftMessage;
  bool _isSending = false;
  final FocusNode _focusNode = FocusNode();
  DocumentSnapshot? _lastMessageDoc;
  late final StreamSubscription<List<Map<String, dynamic>>> _messageSub;

  @override
  void initState() {
    super.initState();
    _bootstrapping = _bootstrap().then((_) {
      _messageSub = decryptedMessageStream.listen((messages) {
        for (var msg in messages) {
          if (msg['sender_id'] == widget.otherUser['id'] && !msg['is_read']) {
            _markMessageAsRead(msg['id'], msg['firestore_id']);
          }
        }
      });
    });
    _initializeAnimation();
    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        setState(() => _currentlyPlayingId = null);
      }
    });
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 300), _scrollToBottom);
      }
    });
    _scrollController.addListener(_handleScroll);
  }

  // Stream for decrypted messages
 Stream<List<Map<String, dynamic>>> get decryptedMessageStream async* {
  final keyBytes = _encryptionKey.bytes;

  await for (var snap in getMessageQuery(conversationId: _conversationId!).snapshots()) {
    final futures = snap.docs.map((d) async {
      final data = d.data();
      final iv = data['iv'];

      if (iv == null || iv is! String || iv.isEmpty) {
        debugPrint("⚠️ Skipping decryption for message ${d.id} due to missing or invalid IV");
        data['message'] = data['message'] ?? '[Message Unavailable]'; // Fallback
        return data;
      }

      return await compute(_decryptDoc, [data, d.id, iv, keyBytes]);
    });

    final decrypted = (await Future.wait(futures))
        .where((m) => m.isNotEmpty)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    if (snap.docs.isNotEmpty) {
      _lastMessageDoc = snap.docs.last;
    }

    yield decrypted;
  }
}

  Future<void> _bootstrap() async {
    await _initializeLocalDatabase();
    _initializeEncryption();
    _conversationId = await _getConversationId();
    await _initializeNotifications();
    await _loadBackgroundSettings();
    await _loadDraft();
    _setupListeners();
    _monitorConnectivity();
  }

  Future<void> _initializeAnimation() async {
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.5).animate(
      CurvedAnimation(parent: _animationController!, curve: Curves.easeInOut),
    );
  }

  void _initializeEncryption() {
    final keyString = "${widget.currentUser['id']}_${widget.otherUser['id']}";
    final keyBytes = sha256.convert(utf8.encode(keyString)).bytes;
    _encryptionKey = encrypt.Key(Uint8List.fromList(keyBytes));
    _encrypter = encrypt.Encrypter(encrypt.AES(_encryptionKey));
  }

  Future<String> _getConversationId() async {
    final currentUserId = widget.currentUser['id']?.toString();
    final otherUserId = widget.otherUser['id']?.toString();
    if (currentUserId == null || otherUserId == null) {
      throw Exception('Invalid user IDs');
    }
    final sortedIds = [currentUserId, otherUserId]..sort();
    final conversationId = sortedIds.join('_');
    final exists = await AuthDatabase.instance.conversationExists(
      conversationId,
    );
    if (!exists) {
      await _ensureConversationExists(conversationId);
    }
    return conversationId;
  }

  Future<void> _ensureConversationExists(String conversationId) async {
    final conversation = {
      'id': conversationId,
      'participants': [
        widget.currentUser['id'].toString(),
        widget.otherUser['id'].toString(),
      ],
      'last_message': '',
      'timestamp': DateTime.now().toIso8601String(),
    };
    await AuthDatabase.instance.insertConversation(conversation);
    await _firestore
        .collection('conversations')
        .doc(conversationId)
        .set(conversation, SetOptions(merge: true));
  }

  Future<void> _initializeLocalDatabase() async {
    _localDb = await openDatabase(
      'chat.db',
      version: 1,
      onCreate: (db, version) {
        db.execute(
          'CREATE TABLE offline_messages (id TEXT PRIMARY KEY, data TEXT)',
        );
        db.execute(
          'CREATE TABLE drafts (conversation_id TEXT PRIMARY KEY, content TEXT)',
        );
        db.execute(
          'CREATE TABLE chat_settings (conversation_id TEXT PRIMARY KEY, bg_color INTEGER, bg_image TEXT, cinematic_theme TEXT)',
        );
      },
    );
  }

  Future<Database> getLocalDb() async {
    if (_localDb == null) {
      await _initializeLocalDatabase();
    }
    return _localDb!;
  }

  Future<void> _initializeNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
    await _notificationsPlugin.initialize(initializationSettings);
  }

  Future<void> _initializeRecorder() async {
    _recorder = FlutterSoundRecorder();
    await _recorder!.openRecorder();
    await Permission.microphone.request();
  }

  void _monitorConnectivity() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) async {
      if (results.any((result) => result != ConnectivityResult.none)) {
        await _syncOfflineMessages();
      }
    });
  }

  Future<void> _handleStoryInteraction(
    String type,
    Map<String, dynamic> data,
  ) async {
    if (type == 'reply') {
      final replyText = data['content'];
      final storyId = data['storyId'];
      final iv = encrypt.IV.fromSecureRandom(16);
      final encryptedText = _encrypter.encrypt(replyText, iv: iv).base64;
      final newMessage = {
        'id': const Uuid().v4(),
        'sender_id': widget.currentUser['id'].toString(),
        'receiver_id': data['storyUserId'].toString(),
        'conversation_id': _conversationId,
        'message': encryptedText,
        'iv': base64Encode(iv.bytes),
        'created_at': DateTime.now().toIso8601String(),
        'is_read': false,
        'is_pinned': false,
        'replied_to': null,
        'type': 'text',
        'reactions': {},
        'is_story_reply': true,
        'story_id': storyId,
        'status': 'pending',
        'delivered_at': null,
        'read_at': null,
      };
      await _sendMessageToBoth(newMessage);
    }
  }

  Future<void> _loadDraft() async {
    final db = await getLocalDb();
    final drafts = await db.query(
      'drafts',
      where: 'conversation_id = ?',
      whereArgs: [_conversationId],
    );
    if (drafts.isNotEmpty) {
      setState(() => _draftMessage = drafts.first['content'] as String?);
      _controller.text = _draftMessage ?? '';
    }
  }

  void _saveDraft(String text) async {
    final db = await getLocalDb();
    await db.insert('drafts', {
      'conversation_id': _conversationId,
      'content': text,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _draftMessage = text;
  }

  Future<void> _sendMessage() async {
    if (_isSending) return;
    _isSending = true;
    final plaintext = _controller.text.trim();
    if (plaintext.isEmpty) {
      _isSending = false;
      return;
    }
    await _ensureConversationExists(_conversationId!);
    final iv = encrypt.IV.fromSecureRandom(16);
    final encryptedText = _encrypter.encrypt(plaintext, iv: iv).base64;
    final message = {
      'id': const Uuid().v4(),
      'sender_id': widget.currentUser['id'].toString(),
      'receiver_id': widget.otherUser['id'].toString(),
      'conversation_id': _conversationId,
      'message': encryptedText,
      'iv': base64Encode(iv.bytes),
      'created_at': DateTime.now().toIso8601String(),
      'is_read': false,
      'is_pinned': false,
      'replied_to': _replyingToMessageId,
      'type': 'text',
      'reactions': {},
      'status': 'pending',
      'delivered_at': null,
      'read_at': null,
    };
    await _sendMessageToBoth(message);
    _controller.clear();
    _saveDraft('');
    setState(() => _replyingToMessageId = null);
    _isSending = false;
  }

  Future<void> _sendMessageToBoth(Map<String, dynamic> message) async {
    final connectivityResult = await Connectivity().checkConnectivity();
    bool isOffline =
        !connectivityResult.contains(ConnectivityResult.wifi) &&
        !connectivityResult.contains(ConnectivityResult.mobile);
    if (isOffline) {
      final db = await getLocalDb();
      await db.insert('offline_messages', {
        'id': message['id'],
        'data': jsonEncode(message),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message queued due to no internet')),
        );
      }
      return;
    }
    try {
      final conversationId = message['conversation_id'];
      final batch = _firestore.batch();
      final messageRef = _firestore
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .doc(message['id']);
      final convoRef = _firestore
          .collection('conversations')
          .doc(conversationId);
      batch.set(messageRef, {
        'id': message['id'],
        'sender_id': message['sender_id'],
        'receiver_id': message['receiver_id'],
        'conversation_id': conversationId,
        'message': message['message'],
        'iv': message['iv'],
        'timestamp': FieldValue.serverTimestamp(),
        'is_read': message['is_read'],
        'is_pinned': message['is_pinned'],
        'replied_to': message['replied_to'],
        'type': message['type'],
        'reactions': message['reactions'],
        'delivered_at': message['delivered_at'],
        'read_at': message['read_at'],
        'scheduled_at': message['scheduled_at'],
        'delete_after': message['delete_after'],
        'is_story_reply': message['is_story_reply'] ?? false,
        'story_id': message['story_id'],
      });
      batch.set(convoRef, {
        'participants': [
          widget.currentUser['id'].toString(),
          widget.otherUser['id'].toString(),
        ],
        'last_message':
            message['type'] == 'text' ? '[Encrypted]' : message['type'],
        'timestamp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await batch.commit();
      await AuthDatabase.instance.createMessage(message);
      await AuthDatabase.instance.updateMessage({
        'id': message['id'],
        'conversation_id': message['conversation_id'],
        'firestore_id': message['id'],
        'delivered_at': DateTime.now().toIso8601String(),
        'status': 'sent',
      });
      _showNotification(message);
    } catch (e) {
      final db = await getLocalDb();
      await db.insert('offline_messages', {
        'id': message['id'],
        'data': jsonEncode(message),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Message queued for sending: $e')),
        );
      }
    }
  }

  Future<void> _startRecording() async {
    if (_recorder == null) {
      await _initializeRecorder();
    }
    if (await Permission.microphone.isGranted) {
      final dir = await getTemporaryDirectory();
      _audioPath = '${dir.path}/${const Uuid().v4()}.aac';
      await _recorder!.startRecorder(toFile: _audioPath);
      setState(() => _isRecording = true);
      _animationController?.forward();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied')),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    await _recorder!.stopRecorder();
    setState(() => _isRecording = false);
    _animationController?.reset();
    if (_audioPath != null) {
      final audioUrl = await _uploadFile(File(_audioPath!), 'audio');
      final message = {
        'id': const Uuid().v4(),
        'sender_id': widget.currentUser['id'].toString(),
        'receiver_id': widget.otherUser['id'].toString(),
        'conversation_id': _conversationId,
        'message': audioUrl,
        'created_at': DateTime.now().toIso8601String(),
        'is_read': false,
        'is_pinned': false,
        'replied_to': _replyingToMessageId,
        'type': 'audio',
        'reactions': {},
        'status': 'pending',
        'delivered_at': null,
        'read_at': null,
      };
      await _ensureConversationExists(_conversationId!);
      await _sendMessageToBoth(message);
      _scrollToBottom();
    }
  }

  Future<void> _uploadAttachment() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'png', 'mp4', 'pdf'],
    );
    if (result != null && result.files.isNotEmpty) {
      final file = result.files.first;
      String fileUrl;
      final fileType =
          file.extension == 'jpg' || file.extension == 'png'
              ? 'image'
              : file.extension == 'mp4'
              ? 'video'
              : 'document';
      if (kIsWeb && file.bytes != null) {
        fileUrl = await _uploadFile(file.bytes!, fileType, isBytes: true);
      } else if (file.path != null) {
        fileUrl = await _uploadFile(File(file.path!), fileType);
      } else {
        return;
      }
      final message = {
        'id': const Uuid().v4(),
        'sender_id': widget.currentUser['id'].toString(),
        'receiver_id': widget.otherUser['id'].toString(),
        'conversation_id': _conversationId,
        'message': fileUrl,
        'created_at': DateTime.now().toIso8601String(),
        'is_read': false,
        'is_pinned': false,
        'replied_to': _replyingToMessageId,
        'type': fileType,
        'reactions': {},
        'status': 'pending',
        'delivered_at': null,
        'read_at': null,
      };
      await _ensureConversationExists(_conversationId!);
      await _sendMessageToBoth(message);
      _scrollToBottom();
    }
  }

  Future<String> _uploadFile(
    dynamic file,
    String type, {
    bool isBytes = false,
  }) async {
    try {
      final fileId = const Uuid().v4();
      final filePath =
          'chat_media/$fileId.${type == 'image'
              ? 'jpg'
              : type == 'video'
              ? 'mp4'
              : type == 'audio'
              ? 'aac'
              : 'pdf'}';
      if (isBytes) {
        await _supabase.storage
            .from('media-bucket')
            .uploadBinary(filePath, file as Uint8List);
      } else {
        await _supabase.storage
            .from('media-bucket')
            .upload(filePath, file as File);
      }
      return _supabase.storage.from('media-bucket').getPublicUrl(filePath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error uploading file: $e')));
      }
      return '';
    }
  }

  Future<void> _startCall({required bool isVideo}) async {
    if (await Permission.microphone.isGranted &&
        (!isVideo || await Permission.camera.isGranted)) {
      setState(() {
        _isInCall = true;
        _isVideoCall = isVideo;
      });
      _peerConnection = await createPeerConnection({
        'iceServers': [
          {'url': 'stun:stun.l.google.com:19302'},
        ],
      });
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': isVideo,
      });
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });
      RTCSessionDescription offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);
      final callId = const Uuid().v4();
      _currentCallId = callId;
      await _firestore.collection('calls').doc(callId).set({
        'caller_id': widget.currentUser['id'].toString(),
        'receiver_id': widget.otherUser['id'].toString(),
        'offer': offer.toMap(),
        'is_video': isVideo,
        'status': 'ringing',
        'timestamp': FieldValue.serverTimestamp(),
      });
      _callSubscription = _firestore
          .collection('calls')
          .doc(callId)
          .snapshots()
          .listen((snapshot) async {
            final data = snapshot.data();
            if (data != null) {
              if (data['answer'] != null) {
                RTCSessionDescription answer = RTCSessionDescription(
                  data['answer']['sdp'],
                  data['answer']['type'],
                );
                await _peerConnection!.setRemoteDescription(answer);
              } else if (data['status'] == 'ended') {
                _endCall();
              }
            }
          });
      _peerConnection!.onIceCandidate = (candidate) {
        _firestore.collection('calls').doc(callId).collection('candidates').add(
          {'candidate': candidate.toMap(), 'is_caller': true},
        );
      };
      _candidatesSubscription = _firestore
          .collection('calls')
          .doc(callId)
          .collection('candidates')
          .where('is_caller', isEqualTo: false)
          .snapshots()
          .listen((snapshot) {
            for (var doc in snapshot.docChanges) {
              if (doc.type == DocumentChangeType.added) {
                RTCIceCandidate candidate = RTCIceCandidate(
                  doc.doc['candidate']['candidate'],
                  doc.doc['candidate']['sdpMid'],
                  doc.doc['candidate']['sdpMLineIndex'],
                );
                _peerConnection!.addCandidate(candidate);
              }
            }
          });
      _peerConnection!.onAddStream = (stream) {
        setState(() => _remoteStream = stream);
      };
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permissions denied for call')),
        );
      }
    }
  }

  void _showCallDialog(String callId, Map<String, dynamic> data) {
    if (mounted) {
      showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text(
                'Incoming ${data['is_video'] ? 'Video' : 'Audio'} Call',
              ),
              content: Text('From ${widget.otherUser['username']}'),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _firestore.collection('calls').doc(callId).update({
                      'status': 'ended',
                    });
                  },
                  child: const Text('Reject'),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    await _acceptCall(callId, data['offer'], data['is_video']);
                  },
                  child: const Text('Accept'),
                ),
              ],
            ),
      );
    }
  }

  Future<void> _acceptCall(
    String callId,
    Map<String, dynamic> offerData,
    bool isVideo,
  ) async {
    setState(() {
      _isInCall = true;
      _isVideoCall = isVideo;
      _currentCallId = callId;
    });
    _peerConnection = await createPeerConnection({
      'iceServers': [
        {'url': 'stun:stun.l.google.com:19302'},
      ],
    });
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': isVideo,
    });
    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });
    RTCSessionDescription offer = RTCSessionDescription(
      offerData['sdp'],
      offerData['type'],
    );
    await _peerConnection!.setRemoteDescription(offer);
    RTCSessionDescription answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);
    await _firestore.collection('calls').doc(callId).update({
      'answer': answer.toMap(),
      'status': 'connected',
    });
    _peerConnection!.onIceCandidate = (candidate) {
      _firestore.collection('calls').doc(callId).collection('candidates').add({
        'candidate': candidate.toMap(),
        'is_caller': false,
      });
    };
    _candidatesSubscription = _firestore
        .collection('calls')
        .doc(_currentCallId)
        .collection('candidates')
        .where('is_caller', isEqualTo: true)
        .snapshots()
        .listen((snapshot) {
          for (var doc in snapshot.docChanges) {
            if (doc.type == DocumentChangeType.added) {
              RTCIceCandidate candidate = RTCIceCandidate(
                doc.doc['candidate']['candidate'],
                doc.doc['candidate']['sdpMid'],
                doc.doc['candidate']['sdpMLineIndex'],
              );
              _peerConnection!.addCandidate(candidate);
            }
          }
        });
    _peerConnection!.onAddStream = (stream) {
      setState(() => _remoteStream = stream);
    };
    _callSubscription = _firestore
        .collection('calls')
        .doc(callId)
        .snapshots()
        .listen((snapshot) {
          final data = snapshot.data();
          if (data != null && data['status'] == 'ended') {
            _endCall();
          }
        });
  }

  void _endCall() async {
    await _peerConnection?.close();
    await _localStream?.dispose();
    await _remoteStream?.dispose();
    if (_currentCallId != null) {
      await _firestore.collection('calls').doc(_currentCallId).update({
        'status': 'ended',
      });
    }
    _callSubscription?.cancel();
    _candidatesSubscription?.cancel();
    setState(() {
      _isInCall = false;
      _localStream = null;
      _remoteStream = null;
      _currentCallId = null;
    });
  }

  Future<void> _markMessageAsRead(String messageId, String firestoreId) async {
    try {
      await AuthDatabase.instance.updateMessage({
        'id': messageId,
        'conversation_id': _conversationId,
        'is_read': true,
        'read_at': DateTime.now().toIso8601String(),
      });
      await _firestore
          .collection('conversations')
          .doc(_conversationId)
          .collection('messages')
          .doc(firestoreId)
          .update({'is_read': true, 'read_at': FieldValue.serverTimestamp()});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error marking message as read: $e')),
        );
      }
    }
  }

  Future<void> _syncOfflineMessages() async {
    final db = await getLocalDb();
    final offlineMessages = await db.query('offline_messages');
    if (offlineMessages.isEmpty) return;
    for (var msg in offlineMessages) {
      final message = jsonDecode(msg['data'] as String) as Map<String, dynamic>;
      try {
        final connectivityResult = await Connectivity().checkConnectivity();
        if (!connectivityResult.contains(ConnectivityResult.none)) {
          await _sendMessageToBoth(message);
          await db.delete(
            'offline_messages',
            where: 'id = ?',
            whereArgs: [msg['id']],
          );
        }
      } catch (e) {
        debugPrint('Failed to sync offline message ${msg['id']}: $e');
      }
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _handleScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 100) {
      _loadMoreMessages();
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_lastMessageDoc == null || _conversationId == null) return;
    final nextQuery = getMessageQuery(
      conversationId: _conversationId!,
      lastDoc: _lastMessageDoc,
    );
    final snapshot = await nextQuery.get();
    if (snapshot.docs.isNotEmpty) {
      setState(() {
        _lastMessageDoc = snapshot.docs.last;
      });
    }
  }

  Future<void> _loadBackgroundSettings() async {
    final db = await getLocalDb();
    final settings = await db.query(
      'chat_settings',
      where: 'conversation_id = ?',
      whereArgs: [_conversationId],
    );
    if (settings.isNotEmpty) {
      final setting = settings.first;
      setState(() {
        if (setting['bg_color'] != null) {
          _chatBgColor = Color(setting['bg_color'] as int);
        }
        _chatBgImage = setting['bg_image'] as String?;
        _cinematicTheme = setting['cinematic_theme'] as String?;
      });
    }
  }

  void _updateChatBackground({
    Color? color,
    String? imageUrl,
    String? cinematicTheme,
  }) async {
    final db = await getLocalDb();
    final currentSettings = await db.query(
      'chat_settings',
      where: 'conversation_id = ?',
      whereArgs: [_conversationId],
    );
    Map<String, dynamic> settings =
        currentSettings.isNotEmpty
            ? currentSettings.first
            : {'conversation_id': _conversationId};
    if (color != null) {
      settings['bg_color'] = color.value; // Changed to use Color.value
      setState(() => _chatBgColor = color);
    }
    if (imageUrl != null) {
      settings['bg_image'] = imageUrl;
      setState(() => _chatBgImage = imageUrl);
    }
    if (cinematicTheme != null) {
      settings['cinematic_theme'] = cinematicTheme;
      setState(() => _cinematicTheme = cinematicTheme);
    }
    await db.insert(
      'chat_settings',
      settings,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  void _deleteMessage(String messageId, String? firestoreId) async {
    try {
      await AuthDatabase.instance.deleteMessage(messageId);
      if (firestoreId != null) {
        await _firestore
            .collection('conversations')
            .doc(_conversationId)
            .collection('messages')
            .doc(firestoreId)
            .delete();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error deleting message: $e')));
      }
    }
  }

  void _toggleReadStatus(
    String messageId,
    String? firestoreId,
    bool isRead,
  ) async {
    try {
      await AuthDatabase.instance.updateMessage({
        'id': messageId,
        'conversation_id': _conversationId,
        'is_read': !isRead,
        'read_at': !isRead ? DateTime.now().toIso8601String() : null,
      });
      if (firestoreId != null) {
        await _firestore
            .collection('conversations')
            .doc(_conversationId)
            .collection('messages')
            .doc(firestoreId)
            .update({
              'is_read': !isRead,
              'read_at': !isRead ? FieldValue.serverTimestamp() : null,
            });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating read status: $e')),
        );
      }
    }
  }

  void _replyToMessage(String messageId) {
    setState(() => _replyingToMessageId = messageId);
  }

  void _pinMessage(String messageId, String? firestoreId, bool isPinned) async {
    try {
      await AuthDatabase.instance.updateMessage({
        'id': messageId,
        'conversation_id': _conversationId,
        'is_pinned': !isPinned,
      });
      if (firestoreId != null) {
        await _firestore
            .collection('conversations')
            .doc(_conversationId)
            .collection('messages')
            .doc(firestoreId)
            .update({'is_pinned': !isPinned});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error pinning message: $e')));
      }
    }
  }

  void _addReaction(
    String messageId,
    String? firestoreId,
    String reaction,
  ) async {
    final userId = widget.currentUser['id'].toString();
    try {
      final doc =
          await _firestore
              .collection('conversations')
              .doc(_conversationId)
              .collection('messages')
              .doc(firestoreId)
              .get();
      final reactions = Map<String, List<String>>.from(
        doc.data()?['reactions'] ?? {},
      );
      reactions[reaction] = reactions[reaction] ?? [];
      if (!reactions[reaction]!.contains(userId)) {
        reactions[reaction]!.add(userId);
      } else {
        reactions[reaction]!.remove(userId);
      }
      await AuthDatabase.instance.updateMessage({
        'id': messageId,
        'conversation_id': _conversationId,
        'reactions': reactions,
      });
      if (firestoreId != null) {
        await _firestore
            .collection('conversations')
            .doc(_conversationId)
            .collection('messages')
            .doc(firestoreId)
            .update({'reactions': reactions});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error adding reaction: $e')));
      }
    }
  }

  void _forwardMessage(Map<String, dynamic> message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Forwarding message: ${message['message']}')),
      );
    }
  }

  void _showNotification(Map<String, dynamic> message) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'chat_channel',
          'Chat Notifications',
          importance: Importance.max,
          priority: Priority.high,
        );
    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
    );
    String notificationText = 'New ${message['type']} message';
    String title = 'New Message from ${widget.otherUser['username']}';
    await _notificationsPlugin.show(
      0,
      title,
      notificationText,
      notificationDetails,
    );
  }

  void _updateTypingStatus(bool isTyping) async {
    final userId = widget.currentUser['id'].toString();
    if (isTyping) {
      await _firestore.collection('conversations').doc(_conversationId).set({
        'typing_users': FieldValue.arrayUnion([userId]),
      }, SetOptions(merge: true));
    } else {
      await _firestore.collection('conversations').doc(_conversationId).update({
        'typing_users': FieldValue.arrayRemove([userId]),
      });
    }
  }

  void _setupListeners() {
    _typingSubscription = _firestore
        .collection('conversations')
        .doc(_conversationId)
        .snapshots()
        .listen((doc) {
          final typingUsers =
              (doc.data()?['typing_users'] as List?)
                  ?.map((e) => e.toString())
                  .toList() ??
              [];
          setState(
            () =>
                _isOtherTyping = typingUsers.contains(
                  widget.otherUser['id'].toString(),
                ),
          );
        });
    _callsSubscription = _firestore
        .collection('calls')
        .where('receiver_id', isEqualTo: widget.currentUser['id'].toString())
        .where('answer', isNull: true)
        .snapshots()
        .listen((snapshot) async {
          for (var doc in snapshot.docChanges) {
            if (doc.type == DocumentChangeType.added) {
              final data = doc.doc.data() as Map<String, dynamic>;
              if (mounted) {
                _showCallDialog(doc.doc.id, data);
              }
            }
          }
        });
  }

  List<Map<String, dynamic>> _searchMessages(
    List<Map<String, dynamic>> messages,
  ) {
    if (_searchTerm.isEmpty) return messages;
    return messages.where((message) {
      final msgText = message['message'].toString().toLowerCase();
      return msgText.contains(_searchTerm.toLowerCase());
    }).toList();
  }

  void _openStoryScreen() {
    final otherUserStories = [
      {
        'id': const Uuid().v4(),
        'user': widget.otherUser['username']?.toString() ?? 'Unknown',
        'userId': widget.otherUser['id'].toString(),
        'type': 'image',
        'media': 'https://via.placeholder.com/300',
        'timestamp': DateTime.now().toIso8601String(),
      },
    ];
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => StoryScreen(
              stories: otherUserStories,
              currentUserId: widget.currentUser['id'].toString(),
              onStoryInteraction: _handleStoryInteraction,
            ),
      ),
    );
  }

  @override
  void dispose() {
    _messageSub.cancel();
    _typingSubscription?.cancel();
    _recorder?.closeRecorder();
    _connectivitySubscription?.cancel();
    _callsSubscription?.cancel();
    _callSubscription?.cancel();
    _candidatesSubscription?.cancel();
    _peerConnection?.close();
    _localStream?.dispose();
    _remoteStream?.dispose();
    _controller.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    _animationController?.dispose();
    _audioPlayer.dispose();
    _typingTimer?.cancel();
    _localDb?.close();
    _focusNode.dispose();
    super.dispose();
  }

  BoxDecoration _buildChatDecoration() {
    if (_chatBgImage != null && _chatBgImage!.isNotEmpty) {
      return BoxDecoration(
        image: DecorationImage(
          image: NetworkImage(_chatBgImage!),
          fit: BoxFit.cover,
        ),
      );
    } else if (_cinematicTheme != null) {
      switch (_cinematicTheme) {
        case "Classic Film":
          return const BoxDecoration(color: Colors.black87);
        case "Modern Blockbuster":
          return const BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.blueGrey, Colors.black],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          );
        case "Indie Vibes":
          return BoxDecoration(color: Colors.brown.shade200);
        case "Sci-Fi Adventure":
          return const BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.deepPurple, Colors.black],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          );
        case "Noir":
          return BoxDecoration(color: Colors.grey.shade900);
        default:
          return BoxDecoration(color: _chatBgColor);
      }
    }
    return BoxDecoration(color: _chatBgColor);
  }

  void _showMessageOptions(BuildContext context, Map<String, dynamic> message) {
    showModalBottomSheet(
      context: context,
      builder:
          (context) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.pop(context);
                  _replyToMessage(message['id']);
                },
              ),
              ListTile(
                leading: Icon(
                  message['is_read']
                      ? Icons.check_circle
                      : Icons.check_circle_outline,
                ),
                title: Text(
                  message['is_read'] ? 'Mark as unread' : 'Mark as read',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _toggleReadStatus(
                    message['id'],
                    message['firestore_id'],
                    message['is_read'],
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete),
                title: const Text('Delete'),
                onTap: () {
                  Navigator.pop(context);
                  _deleteMessage(message['id'], message['firestore_id']);
                },
              ),
              ListTile(
                leading: Icon(
                  message['is_pinned']
                      ? Icons.push_pin
                      : Icons.push_pin_outlined,
                ),
                title: Text(message['is_pinned'] ? 'Unpin' : 'Pin'),
                onTap: () {
                  Navigator.pop(context);
                  _pinMessage(
                    message['id'],
                    message['firestore_id'],
                    message['is_pinned'],
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.add_reaction),
                title: const Text('Add Reaction'),
                onTap: () {
                  Navigator.pop(context);
                  _showReactionPicker(message['id'], message['firestore_id']);
                },
              ),
              ListTile(
                leading: const Icon(Icons.forward),
                title: const Text('Forward'),
                onTap: () {
                  Navigator.pop(context);
                  _forwardMessage(message);
                },
              ),
            ],
          ),
    );
  }

  void _showReactionPicker(String messageId, String? firestoreId) {
    showModalBottomSheet(
      context: context,
      builder:
          (context) => Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.thumb_up),
                title: const Text('Like'),
                onTap: () {
                  _addReaction(messageId, firestoreId, 'like');
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.favorite),
                title: const Text('Heart'),
                onTap: () {
                  _addReaction(messageId, firestoreId, 'heart');
                  Navigator.pop(context);
                },
              ),
            ],
          ),
    );
  }

  Color _getTextColor() {
    if (_chatBgImage != null || _cinematicTheme != null) {
      return Colors.white;
    }
    final luminance = _chatBgColor.computeLuminance();
    return luminance > 0.5 ? Colors.black : Colors.white;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootstrapping,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Text(
                'Initialization Error: ${snapshot.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red, fontSize: 16),
              ),
            ),
          );
        }
        return Scaffold(
          resizeToAvoidBottomInset: true,
          appBar: ChatAppBar(
            otherUser: widget.otherUser,
            onBack: () => Navigator.pop(context),
            onSearch: () {
              setState(() {
                _showSearch = !_showSearch;
                if (!_showSearch) {
                  _searchTerm = "";
                  _searchController.clear();
                }
              });
            },
            onStories: _openStoryScreen,
            onChangeBackground: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (context) => ChatSettingsScreen(
                        currentColor: _chatBgColor,
                        currentImage: _chatBgImage,
                      ),
                ),
              );
              if (result != null && result is Map<String, dynamic>) {
                _updateChatBackground(
                  color: result['color'],
                  imageUrl: result['image'],
                  cinematicTheme: result['cinematicTheme'],
                );
              }
            },
            onCall: () => _startCall(isVideo: false),
            onVideoCall: () => _startCall(isVideo: true),
          ),
          body: Stack(
            children: [
              Container(decoration: _buildChatDecoration()),
              if (_isInCall)
                WebRTCCallWidget(
                  localStream: _localStream,
                  remoteStream: _remoteStream,
                  isVideo: _isVideoCall,
                  onEnd: _endCall,
                ),
              SafeArea(
                child: Column(
                  children: [
                    if (_showSearch)
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: 'Search messages...',
                            prefixIcon: const Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          onChanged:
                              (value) => setState(() => _searchTerm = value),
                        ),
                      ),
                    Expanded(
                      child: StreamBuilder<List<Map<String, dynamic>>>(
                        stream: decryptedMessageStream,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          if (!snapshot.hasData) {
                            return const Center(child: Text("No messages"));
                          }
                          final messages = snapshot.data!;
                          final filteredMessages = _searchMessages(messages);
                          return MessageList(
                            messages: filteredMessages,
                            interactions: widget.storyInteractions,
                            scrollController: _scrollController,
                            onReply:
                                (int index) => _replyToMessage(
                                  filteredMessages[index]['id'],
                                ),
                            onShare: _forwardMessage,
                            onLongPress:
                                (message) =>
                                    _showMessageOptions(context, message),
                            onTapOriginal: (int index) {
                              final message = filteredMessages[index];
                              final originalMessage = messages.firstWhere(
                                (m) => m['id'] == message['replied_to'],
                                orElse: () => {},
                              );
                              if (originalMessage.isNotEmpty) {
                                final originalIndex = messages.indexOf(
                                  originalMessage,
                                );
                                if (originalIndex != -1) {
                                  _scrollController.animateTo(
                                    originalIndex * 100.0,
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeInOut,
                                  );
                                }
                              }
                            },
                            onDelete:
                                (int index) => _deleteMessage(
                                  filteredMessages[index]['id'],
                                  filteredMessages[index]['firestore_id'],
                                ),
                            audioPlayer: _audioPlayer,
                            setCurrentlyPlaying:
                                (id) =>
                                    setState(() => _currentlyPlayingId = id),
                            currentlyPlayingId: _currentlyPlayingId,
                            encrypter: _encrypter,
                            textColor: _getTextColor(),
                            currentUserId: widget.currentUser['id'].toString(),
                          );
                        },
                      ),
                    ),
                    if (_isOtherTyping)
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Row(
                          children: [
                            const SizedBox(width: 8),
                            const CircularProgressIndicator(),
                            const SizedBox(width: 8),
                            Text(
                              '${widget.otherUser['username']} is typing...',
                              style: TextStyle(color: _getTextColor()),
                            ),
                          ],
                        ),
                      ),
                    TypingArea(
                      controller: _controller,
                      isSending: _isSending,
                      onSend: _sendMessage,
                      onAttach: _uploadAttachment,
                      onEmoji: () {
                        setState(() {
                          _showEmojiPicker = !_showEmojiPicker;
                          if (_showEmojiPicker) {
                            FocusScope.of(context).unfocus();
                          } else {
                            FocusScope.of(context).requestFocus(_focusNode);
                          }
                        });
                      },
                      showEmojiPicker: _showEmojiPicker,
                      onTextChanged: (text) {
                        _saveDraft(text);
                        if (!_isTyping) {
                          setState(() => _isTyping = true);
                          _updateTypingStatus(true);
                        }
                        _typingTimer?.cancel();
                        _typingTimer = Timer(const Duration(seconds: 2), () {
                          setState(() => _isTyping = false);
                          _updateTypingStatus(false);
                        });
                      },
                      isRecording: _isRecording,
                      onStartRecording: _startRecording,
                      onStopRecording: _stopRecording,
                      pulseAnimation: _pulseAnimation,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
