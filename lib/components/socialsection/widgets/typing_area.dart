import 'dart:io';
import 'package:flutter/material.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';

class TypingArea extends StatefulWidget {
  final void Function(String text)? onSendMessage;
  final void Function(File file)? onSendFile;
  final void Function(File audio)? onSendAudio;
  final Color accentColor;
  final Map<String, dynamic>? replyingTo; // NEW
  final VoidCallback? onCancelReply; // NEW

  const TypingArea({
    super.key,
    this.onSendMessage,
    this.onSendFile,
    this.onSendAudio,
    this.accentColor = Colors.blueAccent,
    this.replyingTo,
    this.onCancelReply,
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
    await _recorder.openRecorder();
    await Permission.microphone.request();
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
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['jpg', 'png', 'mp4', 'mp3', 'pdf', 'doc'],
    );
    if (result != null && result.files.single.path != null) {
      widget.onSendFile?.call(File(result.files.single.path!));
    }
  }

  Future<void> _startRecording() async {
    const path = '/sdcard/Download/recorded_voice.aac';
    await _recorder.startRecorder(toFile: path);
    setState(() {
      isRecording = true;
      recordedPath = null;
    });
  }

  Future<void> _stopRecording() async {
    String? path = await _recorder.stopRecorder();
    setState(() {
      isRecording = false;
      recordedPath = path;
    });
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 🔁 Reply Preview UI (Improved)
        if (widget.replyingTo != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: widget.accentColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border(
                left: BorderSide(width: 4, color: widget.accentColor),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.replyingTo!['senderName'] ?? 'Someone',
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
                        )
                      else if (widget.replyingTo!['type'] == 'image')
                        const Text('[Image]',
                            style: TextStyle(fontStyle: FontStyle.italic))
                      else
                        const Text('[Unsupported message]'),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: widget.onCancelReply,
                  color: Colors.grey,
                ),
              ],
            ),
          ),

        // 🔊 Voice recording preview
        if (recordedPath != null)
          ListTile(
            title: const Text('Voice message ready to send'),
            subtitle: Text(recordedPath!),
            trailing: IconButton(
              icon: const Icon(Icons.send, color: Colors.blue),
              onPressed: _sendRecording,
            ),
          ),

        // ✍️ Typing input
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: widget.accentColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: widget.accentColor.withOpacity(0.3)),
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
                  ),
                ),
              ),
              if (_controller.text.trim().isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _handleSend,
                  color: widget.accentColor,
                )
              else if (isRecording)
                IconButton(
                  icon: const Icon(Icons.stop_circle),
                  onPressed: _stopRecording,
                  color: Colors.red,
                )
              else
                IconButton(
                  icon: const Icon(Icons.mic),
                  onPressed: _startRecording,
                  color: widget.accentColor,
                ),
            ],
          ),
        ),

        // 😄 Emoji Picker
        if (showEmojiPicker)
          SizedBox(
            height: 250,
            child: EmojiPicker(
              onEmojiSelected: (category, emoji) {
                _controller.text += emoji.emoji;
              },
              config: Config(),
            ),
          ),
      ],
    );
  }
}
