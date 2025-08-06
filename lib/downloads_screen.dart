import 'dart:async';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/home_screen_main.dart';
import 'package:movie_app/categories_screen.dart';
import 'package:movie_app/interactive_features_screen.dart';
import 'package:movie_app/components/common_widgets.dart';

/// Shared port to receive messages from the background isolate.
final ReceivePort _port = ReceivePort();

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  DownloadsScreenState createState() => DownloadsScreenState();
}

class DownloadsScreenState extends State<DownloadsScreen> {
  late Future<List<DownloadTask>?> _tasksFuture;
  late StreamSubscription _sub;
  int selectedIndex = 2;

  @override
  void initState() {
    super.initState();

    // Bind the ReceivePort to FlutterDownloader
    FlutterDownloader.registerCallback(downloadCallback);

    // Listen to download completion updates
    _sub = _port.listen((dynamic message) {
      final status = message['status'] as DownloadTaskStatus;
      if (status == DownloadTaskStatus.complete) {
        _refresh();
      }
    });

    _loadTasks();
  }

  // Callback for download updates
@pragma('vm:entry-point')
static void downloadCallback(String id, int status, int progress) {
  final SendPort? send = _port.sendPort;
  send?.send({
    'status': DownloadTaskStatus.values[status],
    'progress': progress,
    'id': id,
  });
}

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  /// Loads all tasks from FlutterDownloader.
  void _loadTasks() {
    _tasksFuture = FlutterDownloader.loadTasks();
  }

  /// Refreshes the task list.
  void _refresh() {
    setState(() {
      _loadTasks();
    });
  }

  /// Deletes a download task and its associated file.
  Future<void> _deleteTask(String taskId) async {
    await FlutterDownloader.remove(
      taskId: taskId,
      shouldDeleteContent: true,
    );
    _refresh();
  }

  void onItemTapped(int index) {
    setState(() => selectedIndex = index);
    if (index == 0) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const HomeScreenMain()),
      );
    } else if (index == 1) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const CategoriesScreen()),
      );
    } else if (index == 3) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => InteractiveFeaturesScreen(
            isDarkMode: false,
            onThemeChanged: (bool newValue) {},
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text("Downloads"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<DownloadTask>?>(
        future: _tasksFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text("Error: ${snapshot.error}"));
          }
          final tasks = snapshot.data ?? [];

          final downloadedTasks = tasks
              .where((task) => task.status == DownloadTaskStatus.complete)
              .toList();

          if (downloadedTasks.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  "No downloads yet.",
                  style: TextStyle(fontSize: 18),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return ListView.builder(
            itemCount: downloadedTasks.length,
            itemBuilder: (context, index) {
              final task = downloadedTasks[index];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ListTile(
                  leading: const Icon(Icons.movie),
                  title: Text(task.filename ?? "Unknown"),
                  subtitle: Text("Saved at: ${task.savedDir}"),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () => _deleteTask(task.taskId),
                  ),
                ),
              );
            },
          );
        },
      ),
      bottomNavigationBar: BottomNavBar(
        accentColor: settings.accentColor,
        selectedIndex: selectedIndex,
        onItemTapped: onItemTapped,
        useBlurEffect: true,
      ),
    );
  }
}