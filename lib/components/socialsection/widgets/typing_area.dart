import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';

// Simple in-memory cache for user data
class UserCache {
  static final Map<String, Map<String, dynamic>> _cache = {};

  static Future<Map<String, dynamic>?> getUser(String userId) async {
    if (_cache.containsKey(userId)) {
      return _cache[userId];
    }
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get()
          .timeout(const Duration(seconds: 5));
      if (userDoc.exists) {
        final userData = userDoc.data()! as Map<String, dynamic>;
        userData['id'] = userDoc.id;
        _cache[userId] = userData;
        return userData;
      }
    } catch (e) {
      debugPrint('Error fetching user $userId: $e');
    }
    return null;
  }

  static void clear() {
    _cache.clear();
  }
}

class TypingArea extends StatefulWidget {
  final void Function(String text)? onSendMessage;
  final void Function(File file)? onSendFile;
  final void Function(File audio)? onSendAudio;
  final Color accentColor;
  final bool isGroup;
  final QueryDocumentSnapshot<Object?>? replyingTo;
  final VoidCallback? onCancelReply;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic>? otherUser;

  const TypingArea({
    super.key,
    this.onSendMessage,
    this.onSendFile,
    this.onSendAudio,
    this.accentColor = Colors.blueAccent,
    this.replyingTo,
    required this.isGroup,
    this.onCancelReply,
    required this.currentUser,
    this.otherUser,
  });

  @override
  State<TypingArea> createState() => _TypingAreaState();
}

class _TypingAreaState extends State<TypingArea> {
  final TextEditingController _controller = TextEditingController();
  bool showEmojiPicker = false;
  bool isRecording = false;
  String? recordedPath;
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();

  @override
  void initState() {
    super.initState();
    _initRecorder();
  }

  Future<void> _initRecorder() async {
    try {
      await _recorder.openRecorder();
      final status = await Permission.microphone.request();
      if (status != PermissionStatus.granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to initialize recorder: $e')),
      );
    }
  }

  Future<String> _getSenderName() async {
    if (widget.replyingTo == null) return '';
    final data = widget.replyingTo!.data() as Map<String, dynamic>;
    final senderId = data['senderId'] as String?;

    if (senderId == null) return 'Unknown';

    if (widget.isGroup) {
      final user = await UserCache.getUser(senderId);
      return user?['username'] ?? 'Unknown';
    } else {
      if (senderId == widget.currentUser['id']) {
        return widget.currentUser['username'] ?? 'You';
      } else {
        return widget.otherUser?['username'] ?? 'Unknown';
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _recorder.closeRecorder();
    super.dispose();
  }

  void _toggleEmojiPicker() {
    FocusScope.of(context).unfocus();
    setState(() {
      showEmojiPicker = !showEmojiPicker;
    });
  }

  Future<void> _pickFile() async {
    try {
      final status = await Permission.storage.request();
      if (status != PermissionStatus.granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Storage permission denied')),
        );
        return;
      }
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.custom,
        allowedExtensions: ['jpg', 'png', 'mp4', 'mp3', 'pdf', 'doc'],
      );
      if (result != null && result.files.single.path != null) {
        widget.onSendFile?.call(File(result.files.single.path!));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to pick file: $e')),
      );
    }
  }

  Future<void> _startRecording() async {
    try {
      final status = await Permission.microphone.request();
      if (status != PermissionStatus.granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied')),
        );
        return;
      }
      const path = '/sdcard/Download/recorded_voice.aac';
      await _recorder.startRecorder(toFile: path);
      setState(() {
        isRecording = true;
        recordedPath = null;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start recording: $e')),
      );
    }
  }

  Future<void> _stopRecording() async {
    try {
      String? path = await _recorder.stopRecorder();
      setState(() {
        isRecording = false;
        recordedPath = path;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to stop recording: $e')),
      );
    }
  }

  void _sendRecording() {
    if (recordedPath != null) {
      widget.onSendAudio?.call(File(recordedPath!));
      setState(() {
        recordedPath = null;
      });
    }
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      widget.onSendMessage?.call(text);
      _controller.clear();
      if (showEmojiPicker) {
        setState(() => showEmojiPicker = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Reply Preview UI with Frosted Glass Effect
        if (widget.replyingTo != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Colors.black.withOpacity(0.2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(width: 4, color: widget.accentColor),
                    ),
                  ),
                  child: FutureBuilder<String>(
                    future: _getSenderName(),
                    builder: (context, snapshot) {
                      final senderName = snapshot.connectionState == ConnectionState.done
                          ? snapshot.data ?? 'Unknown'
                          : 'Loading...';
                      return Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  senderName,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: widget.accentColor,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                if (widget.replyingTo!['text'] != null)
                                  Text(
                                    widget.replyingTo!['text'],
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white),
                                  )
                                else if (widget.replyingTo!['type'] == 'image')
                                  const Text(
                                    '[Image]',
                                    style: TextStyle(
                                      fontStyle: FontStyle.italic,
                                      color: Colors.white,
                                    ),
                                  )
                                else if (widget.replyingTo!['type'] == 'audio')
                                  const Text(
                                    '[Voice Message]',
                                    style: TextStyle(
                                      fontStyle: FontStyle.italic,
                                      color: Colors.white,
                                    ),
                                  )
                                else
                                  const Text(
                                    '[Unsupported message]',
                                    style: TextStyle(
                                      fontStyle: FontStyle.italic,
                                      color: Colors.white,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white70),
                            onPressed: widget.onCancelReply,
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),

        // Voice recording preview
        if (recordedPath != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Colors.black.withOpacity(0.2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: ListTile(
                  title: const Text(
                    'Voice message ready to send',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    recordedPath!.split('/').last,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  trailing: IconButton(
                    icon: Icon(Icons.send, color: widget.accentColor),
                    onPressed: _sendRecording,
                  ),
                ),
              ),
            ),
          ),

        // Typing input with Frosted Glass Effect
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: Colors.black.withOpacity(0.2),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: widget.accentColor.withOpacity(0.3)),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.emoji_emotions_outlined),
                      onPressed: _toggleEmojiPicker,
                      color: widget.accentColor,
                    ),
                    IconButton(
                      icon: const Icon(Icons.attach_file),
                      onPressed: _pickFile,
                      color: widget.accentColor,
                    ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'Type a message...',
                          border: InputBorder.none,
                          isDense: true,
                          hintStyle: TextStyle(color: Colors.white70),
                        ),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    if (_controller.text.trim().isNotEmpty)
                      IconButton(
                        icon: Icon(Icons.send, color: widget.accentColor),
                        onPressed: _handleSend,
                      )
                    else if (isRecording)
                      IconButton(
                        icon: const Icon(Icons.stop_circle, color: Colors.red),
                        onPressed: _stopRecording,
                      )
                    else
                      IconButton(
                        icon: Icon(Icons.mic, color: widget.accentColor),
                        onPressed: _startRecording,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Emoji Picker
        if (showEmojiPicker)
          SizedBox(
            height: 250,
            child: EmojiPicker(
              onEmojiSelected: (category, emoji) {
                _controller.text += emoji.emoji;
              },
              config: const Config(),
            ),
          ),
      ],
    );
  }
}