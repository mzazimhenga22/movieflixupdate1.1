// downloads_screen_optimized.dart
import 'dart:async';
import 'dart:isolate';
import 'dart:ui';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/main_videoplayer.dart';
import 'package:path/path.dart' as p;

final ReceivePort _port = ReceivePort();

/// Background callback MUST be a top-level or static function and
/// be annotated as an entry-point for background isolates.
@pragma('vm:entry-point')
void downloadCallback(String id, int status, int progress) {
  // send simple primitives across the port (no enums)
  final SendPort? send =
      IsolateNameServer.lookupPortByName('downloader_send_port');
  send?.send({
    'id': id,
    'status': status, // integer
    'progress': progress,
  });
}

/// ---------------------- UI Helpers reused ----------------------
/// AnimatedBackground and FrostedContainer provide the same sleek UI
/// used in other optimized screens so Downloads matches the app look.
/// ----------------------------------------------------------------

class AnimatedBackground extends StatelessWidget {
  const AnimatedBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.redAccent, Colors.blueAccent],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SizedBox.expand(),
      ),
    );
  }
}

/// Reusable frosted container: faux frosted glass without real-time blur.
class FrostedContainer extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final Color accentColor;
  final EdgeInsetsGeometry? padding;

  const FrostedContainer({
    required this.child,
    required this.borderRadius,
    required this.accentColor,
    this.padding,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: RepaintBoundary(
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.035),
                Colors.white.withOpacity(0.02),
              ],
            ),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.45),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: accentColor.withOpacity(0.03),
                blurRadius: 22,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Stack(
            children: [
              // faint sheen overlay
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white.withOpacity(0.012),
                          Colors.transparent,
                          Colors.white.withOpacity(0.008),
                        ],
                        stops: const [0.0, 0.5, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// ---------------------- Downloads screen logic ----------------------
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  DownloadsScreenState createState() => DownloadsScreenState();
}

class DownloadsScreenState extends State<DownloadsScreen> {
  late Future<List<DownloadTask>?> _tasksFuture;
  StreamSubscription? _sub;

  // maps keyed by flutter_downloader taskId
  final Map<String, int> _progress = {};
  final Map<String, DownloadTaskStatus> _status = {};

  // local app-managed downloads saved in SharedPreferences
  List<Map<String, dynamic>> _localRecords = [];

  @override
  void initState() {
    super.initState();

    // Register callback for flutter_downloader
    FlutterDownloader.registerCallback(downloadCallback);

    // Register SendPort only once
    if (IsolateNameServer.lookupPortByName('downloader_send_port') == null) {
      IsolateNameServer.registerPortWithName(
          _port.sendPort, 'downloader_send_port');
      _sub = _port.listen(_isolateMessageHandler);
    }

    _loadTasksAndRecords();
  }

  @override
  void dispose() {
    _sub?.cancel();
    try {
      IsolateNameServer.removePortNameMapping('downloader_send_port');
    } catch (_) {}
    super.dispose();
  }

  void _isolateMessageHandler(dynamic message) {
    if (message == null) return;
    try {
      final String taskId = message['id'] as String;
      final int statusInt = (message['status'] is int)
          ? message['status'] as int
          : int.tryParse(message['status'].toString()) ?? 0;
      final int progress = (message['progress'] is int)
          ? message['progress'] as int
          : int.tryParse(message['progress'].toString()) ?? 0;

      final DownloadTaskStatus statusEnum =
          (statusInt >= 0 && statusInt < DownloadTaskStatus.values.length)
              ? DownloadTaskStatus.values[statusInt]
              : DownloadTaskStatus.undefined;

      if (mounted) {
        setState(() {
          _status[taskId] = statusEnum;
          _progress[taskId] = progress;
        });
      }

      // optionally refresh completed tasks to update the list
      if (statusEnum == DownloadTaskStatus.complete ||
          statusEnum == DownloadTaskStatus.failed) {
        _loadTasksAndRecords();
      }
    } catch (e, st) {
      // ignore malformed messages but log if needed
      // debugPrint('isolate handler error: $e\n$st');
    }
  }

  Future<void> _loadTasksAndRecords() async {
    setState(() {
      _tasksFuture = FlutterDownloader.loadTasks();
    });
    await _loadLocalRecords();
  }

  Future<void> _loadLocalRecords() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList('downloads') ?? [];
      final parsed = list
          .map<Map<String, dynamic>>((s) {
            try {
              final m = jsonDecode(s);
              if (m is Map<String, dynamic>) return m;
            } catch (_) {}
            return <String, dynamic>{};
          })
          .where((m) => m.isNotEmpty)
          .toList();
      if (mounted) {
        setState(() {
          _localRecords = parsed;
        });
      }
    } catch (e) {
      // ignore
    }
  }

  Future<void> _deleteTask(String taskId) async {
    await FlutterDownloader.remove(taskId: taskId, shouldDeleteContent: true);
    setState(() {
      _status.remove(taskId);
      _progress.remove(taskId);
    });
    await _loadTasksAndRecords();
  }

  Future<void> _cancelTask(String taskId) async {
    try {
      await FlutterDownloader.cancel(taskId: taskId);
      setState(() {
        _status[taskId] = DownloadTaskStatus.canceled;
        _progress[taskId] = 0;
      });
    } catch (_) {}
    await _loadTasksAndRecords();
  }

  Future<void> _deleteLocalRecord(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList('downloads') ?? [];
      final kept = list.where((s) {
        try {
          final m = jsonDecode(s) as Map<String, dynamic>;
          return m['id']?.toString() != id;
        } catch (_) {
          return true;
        }
      }).toList();
      await prefs.setStringList('downloads', kept);
    } catch (_) {}
    await _loadLocalRecords();
  }

  void _playVideoFromTask(DownloadTask task) {
    if (task.status == DownloadTaskStatus.complete) {
      final videoPath =
          "${task.savedDir}${Platform.pathSeparator}${task.filename}";
      _pushPlayerForLocalFile(videoPath, task.filename ?? "Downloaded Video",
          isHlsFromRecord: false);
    } else {
      // handle paused / enqueued states maybe by showing a message
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Download not finished yet.')),
      );
    }
  }

  void _playVideoFromRecord(Map<String, dynamic> record) {
    final path = record['path']?.toString() ?? '';
    if (path.isEmpty) return;
    _pushPlayerForLocalFile(path, record['title']?.toString() ?? "Downloaded",
        isHlsFromRecord: record['type'] == 'm3u8');
  }

  void _pushPlayerForLocalFile(String path, String title,
      {bool isHlsFromRecord = false}) {
    // if path is a playlist (.m3u8) we treat as HLS
    final isHls = isHlsFromRecord || path.toLowerCase().endsWith('.m3u8');
    // guard: file exists
    final file = File(path);
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('File not found (it may have been removed).'))); 
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MainVideoPlayer(
          videoPath: path,
          title: title,
          releaseYear: DateTime.now().year,
          isLocal: true,
          isHls: isHls,
          enableOffline: true,
        ),
      ),
    );
  }

  String _cleanTitle(String filename) {
    return filename
        .replaceAll(
            RegExp(r'\.mp4$|\.mkv$|\.avi$|\.ts$|\.m3u8$', caseSensitive: false),
            '')
        .replaceAll(RegExp(r'[._-]'), ' ')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    // Use Selector to only rebuild UI when accentColor changes
    return Selector<SettingsProvider, Color>(
      selector: (_, s) => s.accentColor,
      builder: (context, accentColor, child) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: Text('Downloads', style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
            actions: [
              IconButton(
                icon: Icon(Icons.refresh, color: accentColor),
                onPressed: _loadTasksAndRecords,
              ),
            ],
          ),
          body: Stack(
            children: [
              const AnimatedBackground(),
              // radial overlays for depth (keeps look consistent)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(-0.06, -0.34),
                      radius: 1.0,
                      colors: [accentColor.withOpacity(0.5), const Color(0xFF000000)],
                      stops: const [0.0, 0.59],
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0.64, 0.3),
                      radius: 1.0,
                      colors: [accentColor.withOpacity(0.28), Colors.transparent],
                      stops: const [0.0, 0.55],
                    ),
                  ),
                ),
              ),

              // foreground frosted panel placed below the app bar
              Positioned.fill(
                top: kToolbarHeight + MediaQuery.of(context).padding.top,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.all(Radius.circular(18)),
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: 1.6,
                        colors: [accentColor.withOpacity(0.12), Colors.transparent],
                        stops: const [0.0, 1.0],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.6),
                          blurRadius: 18,
                          spreadRadius: 2,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: FrostedContainer(
                      borderRadius: BorderRadius.circular(18),
                      accentColor: accentColor,
                      padding: const EdgeInsets.all(0),
                      child: FutureBuilder<List<DownloadTask>?>(
                        future: _tasksFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return Center(child: CircularProgressIndicator(color: accentColor));
                          }
                          if (snapshot.hasError) {
                            return Center(
                                child: Text("Error: ${snapshot.error}",
                                    style: const TextStyle(color: Colors.white)));
                          }

                          final tasks = snapshot.data ?? [];

                          // Build sections: Active tasks (flutter_downloader) + App saved downloads
                          return RefreshIndicator(
                            onRefresh: _loadTasksAndRecords,
                            color: accentColor,
                            child: ListView(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  child: Text('Active/Platform Downloads',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16)),
                                ),
                                if (tasks.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    child: Text('No active downloads.', style: TextStyle(color: Colors.white70)),
                                  )
                                else
                                  ...tasks.map((task) {
                                    final taskId = task.taskId;
                                    final progress = _progress[taskId] ?? task.progress;
                                    final status = _status[taskId] ?? task.status;
                                    final title = _cleanTitle(task.filename ?? 'Unknown');

                                    return Card(
                                      color: Colors.grey[900],
                                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                      child: ListTile(
                                        leading: Icon(
                                          status == DownloadTaskStatus.complete ? Icons.check_circle : Icons.movie,
                                          color: status == DownloadTaskStatus.complete ? Colors.green : accentColor,
                                        ),
                                        title: Text(title,
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                        subtitle: status == DownloadTaskStatus.running || status == DownloadTaskStatus.paused
                                            ? Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  const SizedBox(height: 8),
                                                  LinearProgressIndicator(
                                                    value: progress / 100,
                                                    backgroundColor: Colors.grey[800],
                                                    valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                                                  ),
                                                  Text("$progress% • ${_statusLabel(status)}",
                                                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                                ],
                                              )
                                            : Text(_statusLabel(status), style: const TextStyle(color: Colors.white70)),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (status == DownloadTaskStatus.running)
                                              IconButton(
                                                icon: const Icon(Icons.cancel, color: Colors.red),
                                                onPressed: () => _cancelTask(taskId),
                                              ),
                                            IconButton(
                                              icon: const Icon(Icons.delete, color: Colors.white70),
                                              onPressed: () => _deleteTask(taskId),
                                            ),
                                          ],
                                        ),
                                        onTap: () => _playVideoFromTask(task),
                                      ),
                                    );
                                  }).toList(),
                                const SizedBox(height: 8),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  child: Text('Saved Downloads',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16)),
                                ),
                                if (_localRecords.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    child: Text('No saved downloads.', style: TextStyle(color: Colors.white70)),
                                  )
                                else
                                  ..._localRecords.map((rec) {
                                    final title = (rec['title']?.toString() ?? _cleanTitle(rec['path']?.toString() ?? 'Downloaded')).toString();
                                    final path = rec['path']?.toString() ?? '';
                                    final exists = path.isNotEmpty ? File(path).existsSync() : false;
                                    final sizeText = exists ? _humanFileSize(File(path).lengthSync()) : 'Missing';

                                    return Card(
                                      color: Colors.grey[900],
                                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                      child: ListTile(
                                        leading: Icon(Icons.save, color: exists ? accentColor : Colors.redAccent),
                                        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                        subtitle: Text('$sizeText • ${rec['resolution'] ?? ''}', style: const TextStyle(color: Colors.white70)),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              icon: const Icon(Icons.delete, color: Colors.white70),
                                              onPressed: () async {
                                                await _deleteLocalRecord(rec['id']?.toString() ?? '');
                                                if (rec['path'] != null && rec['path'].toString().isNotEmpty) {
                                                  try {
                                                    final f = File(rec['path'].toString());
                                                    if (await f.exists()) await f.delete();
                                                  } catch (_) {}
                                                }
                                              },
                                            ),
                                          ],
                                        ),
                                        onTap: exists ? () => _playVideoFromRecord(rec) : null,
                                      ),
                                    );
                                  }).toList(),
                                const SizedBox(height: 24),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _statusLabel(DownloadTaskStatus status) {
    switch (status) {
      case DownloadTaskStatus.undefined:
        return 'Undefined';
      case DownloadTaskStatus.enqueued:
        return 'Queued';
      case DownloadTaskStatus.running:
        return 'Downloading';
      case DownloadTaskStatus.paused:
        return 'Paused';
      case DownloadTaskStatus.complete:
        return 'Complete';
      case DownloadTaskStatus.canceled:
        return 'Canceled';
      case DownloadTaskStatus.failed:
        return 'Failed';
      default:
        return status.toString();
    }
  }

  String _humanFileSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(2)} ${suffixes[i]}';
  }
}
