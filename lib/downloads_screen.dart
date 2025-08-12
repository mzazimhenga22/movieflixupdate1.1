import 'dart:async';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/main_videoplayer.dart';
import 'dart:io';

final ReceivePort _port = ReceivePort();

@pragma('vm:entry-point')
void downloadCallback(String id, int status, int progress) {
  final SendPort? send = IsolateNameServer.lookupPortByName('downloader_send_port');
  send?.send({
    'id': id,
    'status': DownloadTaskStatus.values[status],
    'progress': progress,
  });
}

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  DownloadsScreenState createState() => DownloadsScreenState();
}

class DownloadsScreenState extends State<DownloadsScreen> {
  late Future<List<DownloadTask>?> _tasksFuture;
  static VoidCallback? refreshCallback;
  StreamSubscription? _sub;
  Map<String, int> _progress = {};
  Map<String, DownloadTaskStatus> _status = {};

  @override
  void initState() {
    super.initState();
    refreshCallback = _refresh;

    // Register callback first
    FlutterDownloader.registerCallback(downloadCallback);

    // Setup ReceivePort
    if (IsolateNameServer.lookupPortByName('downloader_send_port') == null) {
      IsolateNameServer.registerPortWithName(_port.sendPort, 'downloader_send_port');
      _sub = _port.listen((dynamic message) {
        final taskId = message['id'] as String;
        final status = message['status'] as DownloadTaskStatus;
        final progress = message['progress'] as int;
        if (mounted) {
          setState(() {
            _status[taskId] = status;
            _progress[taskId] = progress;
            if (status == DownloadTaskStatus.complete) _refresh();
          });
        }
      });
    }

    _loadTasks();
  }

  @override
  void dispose() {
    _sub?.cancel();
    IsolateNameServer.removePortNameMapping('downloader_send_port');
    refreshCallback = null;
    super.dispose();
  }

  void _loadTasks() {
    setState(() {
      _tasksFuture = FlutterDownloader.loadTasks();
    });
  }

  void _refresh() {
    _loadTasks();
  }

  Future<void> _deleteTask(String taskId) async {
    await FlutterDownloader.remove(taskId: taskId, shouldDeleteContent: true);
    setState(() {
      _status.remove(taskId);
      _progress.remove(taskId);
    });
    _refresh();
  }

  Future<void> _cancelTask(String taskId) async {
    await FlutterDownloader.cancel(taskId: taskId);
    setState(() {
      _status[taskId] = DownloadTaskStatus.canceled;
      _progress[taskId] = 0;
    });
    _refresh();
  }

  void _playVideo(DownloadTask task) {
    if (task.status == DownloadTaskStatus.complete) {
      final videoPath = "${task.savedDir}${Platform.pathSeparator}${task.filename}";
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => MainVideoPlayer(
            videoPath: videoPath,
            title: _cleanTitle(task.filename ?? "Downloaded Video"),
            releaseYear: DateTime.now().year,
            isLocal: true,
            isHls: false,
            enableOffline: true,
          ),
        ),
      );
    }
  }

  String _cleanTitle(String filename) {
    return filename.replaceAll(RegExp(r'\.mp4$|\.mkv$|\.avi$', caseSensitive: false), '').replaceAll(RegExp(r'[._-]'), ' ').trim();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text("Downloads", style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<DownloadTask>?>(
        future: _tasksFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Colors.white));
          }
          if (snapshot.hasError) {
            return Center(
                child: Text("Error: ${snapshot.error}", style: const TextStyle(color: Colors.white)));
          }
          final tasks = snapshot.data ?? [];
          if (tasks.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  "No downloads yet.",
                  style: TextStyle(fontSize: 18, color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return ListView.builder(
            itemCount: tasks.length,
            itemBuilder: (context, index) {
              final task = tasks[index];
              final taskId = task.taskId;
              final progress = _progress[taskId] ?? task.progress;
              final status = _status[taskId] ?? task.status;
              return Card(
                color: Colors.grey[900],
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ListTile(
                  leading: Icon(
                    status == DownloadTaskStatus.complete
                        ? Icons.check_circle
                        : Icons.movie,
                    color: status == DownloadTaskStatus.complete
                        ? Colors.green
                        : settings.accentColor,
                  ),
                  title: Text(
                    _cleanTitle(task.filename ?? "Unknown"),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  subtitle: status == DownloadTaskStatus.running
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: progress / 100,
                              backgroundColor: Colors.grey[800],
                              valueColor: AlwaysStoppedAnimation<Color>(settings.accentColor),
                            ),
                            Text(
                              "$progress% • ${status == DownloadTaskStatus.running ? 'Downloading' : 'Paused'}",
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        )
                      : null,
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
                  onTap: () => _playVideo(task),
                ),
              );
            },
          );
        },
      ),
    );
  }
}