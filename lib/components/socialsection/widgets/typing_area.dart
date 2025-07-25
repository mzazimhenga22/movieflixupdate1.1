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

  const TypingArea({
    super.key,
    this.onSendMessage,
    this.onSendFile,
    this.onSendAudio,
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
        if (recordedPath != null)
          ListTile(
            title: const Text('Voice message ready to send'),
            subtitle: Text(recordedPath!),
            trailing: IconButton(
              icon: const Icon(Icons.send, color: Colors.blue),
              onPressed: _sendRecording,
            ),
          ),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.emoji_emotions_outlined),
              onPressed: _toggleEmojiPicker,
            ),
            IconButton(
              icon: const Icon(Icons.attach_file),
              onPressed: _pickFile,
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Type a message...',
                  border: InputBorder.none,
                ),
              ),
            ),
            if (_controller.text.trim().isNotEmpty)
              IconButton(
                icon: const Icon(Icons.send, color: Colors.blue),
                onPressed: _handleSend,
              )
            else if (isRecording)
              IconButton(
                icon: const Icon(Icons.stop_circle, color: Colors.red),
                onPressed: _stopRecording,
              )
            else
              IconButton(
                icon: const Icon(Icons.mic),
                onPressed: _startRecording,
              ),
          ],
        ),
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