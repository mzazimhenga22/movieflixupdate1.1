import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_waveform/just_waveform.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

class VoicePlayer extends StatefulWidget {
  final String audioUrl;

  const VoicePlayer({super.key, required this.audioUrl});

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  Waveform? _waveform;
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Download audio to file
    final tempDir = await getTemporaryDirectory();
    final audioFile = File('${tempDir.path}/${widget.audioUrl.hashCode}.mp3');

    if (!await audioFile.exists()) {
      final response = await http.get(Uri.parse(widget.audioUrl));
      await audioFile.writeAsBytes(response.bodyBytes);
    }

    // Load waveform
    final waveformFile = File('${audioFile.path}.waveform');
    if (waveformFile.existsSync()) {
      // Load existing waveform
      setState(() {
        _isGenerating = true;
      });
      final stream = JustWaveform.extract(
        audioInFile: audioFile,
        waveOutFile: waveformFile,
      );
      stream.listen((progress) {
        if (progress.waveform != null) {
          setState(() {
            _waveform = progress.waveform;
            _isGenerating = false;
          });
        }
      });
    } else {
      setState(() => _isGenerating = true);
      final stream = JustWaveform.extract(
        audioInFile: audioFile,
        waveOutFile: waveformFile,
      );
      stream.listen((progress) {
        if (progress.waveform != null) {
          setState(() {
            _waveform = progress.waveform;
            _isGenerating = false;
          });
        }
      });
    }

    await _player.setFilePath(audioFile.path);
    _duration = _player.duration ?? Duration.zero;

    _player.positionStream.listen((pos) {
      setState(() => _position = pos);
    });
  }

  void _togglePlayPause() async {
    if (_isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
    setState(() => _isPlaying = !_isPlaying);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
          onPressed: _togglePlayPause,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_isGenerating)
                const LinearProgressIndicator()
              else if (_waveform != null)
                CustomPaint(
                  painter: _WaveformPainter(_waveform!, _position, _duration),
                  size: const Size(double.infinity, 40),
                )
              else
                const Text("Generating waveform..."),
              Slider(
                value: _position.inMilliseconds.toDouble(),
                max: _duration.inMilliseconds.toDouble(),
                onChanged: (value) async {
                  final newPos = Duration(milliseconds: value.toInt());
                  await _player.seek(newPos);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final Waveform waveform;
  final Duration position;
  final Duration duration;

  _WaveformPainter(this.waveform, this.position, this.duration);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 1.5;

    final sampleCount = waveform.data.length;
    final barWidth = size.width / sampleCount;

    for (int i = 0; i < sampleCount; i++) {
      final norm = waveform.data[i] / 32768.0;
      final height = size.height * norm.abs();
      final x = i * barWidth;
      final y1 = (size.height - height) / 2;
      final y2 = y1 + height;

      canvas.drawLine(Offset(x, y1), Offset(x, y2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}