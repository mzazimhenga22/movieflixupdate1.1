// typing_area.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

/// Simple in-memory cache for user data
class UserCache {
  static final Map<String, Map<String, dynamic>> _cache = {};

  static Future<Map<String, dynamic>?> getUser(String userId) async {
    if (_cache.containsKey(userId)) return _cache[userId];
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

  static void clear() => _cache.clear();
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
  bool _recorderInitialized = false;

  @override
  void initState() {
    super.initState();
    _initRecorder();
  }

  Future<void> _initRecorder() async {
    try {
      // microphone permission upfront; no openAudioSession call for recent flutter_sound versions
      final micStatus = await Permission.microphone.request();
      if (micStatus != PermissionStatus.granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission denied')),
          );
        }
        return;
      }
      _recorderInitialized = true;
    } catch (e) {
      debugPrint('Failed to init recorder: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to initialize recorder: $e')),
        );
      }
    }
  }

  Future<String> _getTempFilePath() async {
    final dir = await getTemporaryDirectory();
    final fileName = 'record_${DateTime.now().millisecondsSinceEpoch}.aac';
    return '${dir.path}/$fileName';
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
    try {
      if (_recorderInitialized) {
        _recorder.closeRecorder();
      }
    } catch (e) {
      debugPrint('Error closing recorder: $e');
    }
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
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Storage permission denied')),
          );
        }
        return;
      }
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.custom,
        allowedExtensions: ['jpg', 'png', 'mp4', 'mp3', 'pdf', 'doc'],
      );
      if (result != null && result.files.single.path != null) {
        widget.onSendFile?.call(File(result.files.single.path!));
      }
    } catch (e) {
      debugPrint('Failed to pick file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to pick file: $e')));
      }
    }
  }

  Future<void> _startRecording() async {
    try {
      if (!_recorderInitialized) {
        await _initRecorder();
        if (!_recorderInitialized) return;
      }

      final status = await Permission.microphone.request();
      if (status != PermissionStatus.granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission denied')),
          );
        }
        return;
      }

      final path = await _getTempFilePath();
      await _recorder.startRecorder(toFile: path, codec: Codec.aacMP4);
      if (mounted) {
        setState(() {
          isRecording = true;
          recordedPath = null;
        });
      }
    } catch (e) {
      debugPrint('Failed to start recording: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to start recording: $e')));
      }
    }
  }

  Future<void> _stopRecording() async {
    try {
      final path = await _recorder.stopRecorder();
      if (mounted) {
        setState(() {
          isRecording = false;
          recordedPath = path;
        });
      }
    } catch (e) {
      debugPrint('Failed to stop recording: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to stop recording: $e')));
      }
    }
  }

  void _sendRecording() {
    if (recordedPath != null) {
      widget.onSendAudio?.call(File(recordedPath!));
      setState(() => recordedPath = null);
    }
  }

  void _insertEmoji(String emoji) {
    final text = _controller.text;
    final selection = _controller.selection;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? text.length : selection.end;
    final newText = text.replaceRange(start, end, emoji);
    _controller.text = newText;
    final newPos = start + emoji.length;
    _controller.selection = TextSelection.fromPosition(TextPosition(offset: newPos));
    // update UI
    setState(() {});
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
    // Use semi-transparent containers instead of BackdropFilter for interactive areas to ensure taps pass through.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Reply Preview (lightweight, non-blocking)
        if (widget.replyingTo != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Colors.black.withOpacity(0.28),
              border: Border(left: BorderSide(width: 4, color: widget.accentColor)),
            ),
            child: FutureBuilder<String>(
              future: _getSenderName(),
              builder: (context, snapshot) {
                final senderName = snapshot.connectionState == ConnectionState.done ? (snapshot.data ?? 'Unknown') : 'Loading...';
                return Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            senderName,
                            style: TextStyle(fontWeight: FontWeight.bold, color: widget.accentColor),
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
                            const Text('[Image]', style: TextStyle(fontStyle: FontStyle.italic, color: Colors.white))
                          else if (widget.replyingTo!['type'] == 'audio')
                            const Text('[Voice Message]', style: TextStyle(fontStyle: FontStyle.italic, color: Colors.white))
                          else
                            const Text('[Unsupported message]', style: TextStyle(fontStyle: FontStyle.italic, color: Colors.white)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: widget.onCancelReply,
                      tooltip: 'Cancel reply',
                    ),
                  ],
                );
              },
            ),
          ),

        // Voice recording preview (non-blocking)
        if (recordedPath != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Colors.black.withOpacity(0.28),
            ),
            child: ListTile(
              title: const Text('Voice message ready to send', style: TextStyle(color: Colors.white)),
              subtitle: Text(recordedPath!.split('/').last, style: const TextStyle(color: Colors.white70)),
              trailing: IconButton(
                icon: Icon(Icons.send, color: widget.accentColor),
                onPressed: _sendRecording,
                tooltip: 'Send voice message',
              ),
            ),
          ),

        // Typing input area (interactive, no people icon here to avoid blocking)
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: Colors.black.withOpacity(0.22),
            border: Border.all(color: widget.accentColor.withOpacity(0.18)),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.emoji_emotions_outlined),
                onPressed: _toggleEmojiPicker,
                color: widget.accentColor,
                tooltip: 'Emoji',
              ),
              IconButton(
                icon: const Icon(Icons.attach_file),
                onPressed: _pickFile,
                color: widget.accentColor,
                tooltip: 'Attach',
              ),
              // Text input
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40, maxHeight: 120),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.vertical,
                    reverse: true,
                    child: TextField(
                      controller: _controller,
                      onChanged: (_) {
                        // small rebuild only
                        if (mounted) setState(() {});
                      },
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        border: InputBorder.none,
                        isDense: true,
                        hintStyle: TextStyle(color: Colors.white70),
                      ),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),

              // Send / Mic buttons (kept free from other icons)
              if (_controller.text.trim().isNotEmpty)
                IconButton(
                  icon: Icon(Icons.send, color: widget.accentColor),
                  onPressed: _handleSend,
                  tooltip: 'Send message',
                )
              else if (isRecording)
                IconButton(
                  icon: const Icon(Icons.stop_circle, color: Colors.red),
                  onPressed: _stopRecording,
                  tooltip: 'Stop recording',
                )
              else
                IconButton(
                  icon: Icon(Icons.mic, color: widget.accentColor),
                  onPressed: _startRecording,
                  tooltip: 'Record voice',
                ),
            ],
          ),
        ),

        // Emoji Picker
        if (showEmojiPicker)
          SizedBox(
            height: 250,
            child: EmojiPicker(
              onEmojiSelected: (category, emoji) {
                _insertEmoji(emoji.emoji);
              },
              config: const Config(),
            ),
          ),
      ],
    );
  }
}
