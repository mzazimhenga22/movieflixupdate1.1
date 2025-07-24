import 'package:flutter/material.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

class TypingArea extends StatefulWidget {
  final TextEditingController controller;
  final bool isSending;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onEmoji;
  final bool showEmojiPicker;
  final Function(String) onTextChanged;
  final bool isRecording;
  final VoidCallback onStartRecording;
  final VoidCallback onStopRecording;
  final Animation<double>? pulseAnimation;

  const TypingArea({
    super.key,
    required this.controller,
    required this.isSending,
    required this.onSend,
    required this.onAttach,
    required this.onEmoji,
    required this.showEmojiPicker,
    required this.onTextChanged,
    required this.isRecording,
    required this.onStartRecording,
    required this.onStopRecording,
    this.pulseAnimation,
  });

  @override
  State<TypingArea> createState() => _TypingAreaState();
}

class _TypingAreaState extends State<TypingArea> {
  late final ValueNotifier<String> _textValue;

  @override
  void initState() {
    super.initState();
    _textValue = ValueNotifier(widget.controller.text);
    widget.controller.addListener(_handleTextChange);
  }

  void _handleTextChange() {
    _textValue.value = widget.controller.text;
    widget.onTextChanged(widget.controller.text);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleTextChange);
    _textValue.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.red[900],
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.emoji_emotions, color: Colors.white),
                onPressed: widget.onEmoji,
              ),
              IconButton(
                icon: const Icon(Icons.attach_file, color: Colors.white),
                onPressed: widget.onAttach,
              ),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "Type a message...",
                    hintStyle: const TextStyle(color: Colors.white54),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Colors.black26,
                    suffixIcon: widget.isSending
                        ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => widget.onSend(),
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<String>(
                valueListenable: _textValue,
                builder: (_, text, __) {
                  final isEmpty = text.trim().isEmpty;
                  if (isEmpty) {
                    if (widget.pulseAnimation != null) {
                      return AnimatedBuilder(
                        animation: widget.pulseAnimation!,
                        builder: (_, child) => Transform.scale(
                          scale: widget.isRecording
                              ? widget.pulseAnimation!.value
                              : 1.0,
                          child: child,
                        ),
                        child: _buildMicButton(),
                      );
                    }
                    return _buildMicButton();
                  } else {
                    return IconButton(
                      icon: const Icon(Icons.send, color: Colors.white),
                      onPressed: widget.isSending ? null : widget.onSend,
                    );
                  }
                },
              ),
            ],
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: widget.showEmojiPicker
                ? SizedBox(
                    key: const ValueKey("emoji_picker"),
                    height: 250,
                    child: EmojiPicker(
                      onEmojiSelected: (category, emoji) {
                        widget.controller.text += emoji.emoji;
                        widget.controller.selection = TextSelection.fromPosition(
                          TextPosition(offset: widget.controller.text.length),
                        );
                      },
                      config: const Config(
                        emojiViewConfig: EmojiViewConfig(
                          backgroundColor: Colors.white,
                        ),
                        categoryViewConfig: CategoryViewConfig(
                          iconColorSelected: Colors.deepPurple,
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey("no_emoji_picker")),
          ),
        ],
      ),
    );
  }

  Widget _buildMicButton() {
    return IconButton(
      icon: Icon(
        widget.isRecording ? Icons.stop : Icons.mic,
        color: Colors.white,
      ),
      onPressed:
          widget.isRecording ? widget.onStopRecording : widget.onStartRecording,
    );
  }
}
