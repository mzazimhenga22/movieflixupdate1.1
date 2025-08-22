import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io' show File;
import 'dart:ui';
import 'package:universal_html/html.dart' as html;
import 'package:uuid/uuid.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:path/path.dart' as p;
import 'dart:typed_data';

class PostReviewScreen extends StatefulWidget {
  final Color accentColor;
  final Map<String, dynamic>? currentUser;
  /// Optional callback. If supplied, it will be called with the assembled review data.
  /// If omitted, this screen will upload media (if any) and write the review to Firestore itself.
  final Future<void> Function(Map<String, dynamic>)? onPostReview;

  const PostReviewScreen({
    super.key,
    required this.accentColor,
    required this.currentUser,
    this.onPostReview,
  });

  @override
  _PostReviewScreenState createState() => _PostReviewScreenState();
}

class _PostReviewScreenState extends State<PostReviewScreen> with SingleTickerProviderStateMixin {
  bool isTVShow = false;
  final movieController = TextEditingController();
  final reviewController = TextEditingController();
  final seasonController = TextEditingController();
  final episodeController = TextEditingController();
  dynamic mediaFile;
  String? mediaType;
  late AnimationController _animationController;
  late Animation<double> _buttonScaleAnimation;
  bool _isPosting = false;

  final SupabaseClient _supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _buttonScaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    movieController.dispose();
    reviewController.dispose();
    seasonController.dispose();
    episodeController.dispose();
    super.dispose();
  }

  Future<dynamic> pickFile(String type) async {
    if (kIsWeb) {
      final html.FileUploadInputElement input = html.FileUploadInputElement();
      input.accept = type == 'photo' ? 'image/jpeg,image/png' : 'video/mp4';
      input.click();
      await input.onChange.first;
      if (input.files != null && input.files!.isNotEmpty) {
        return input.files!.first;
      }
    } else {
      final picker = ImagePicker();
      if (type == 'photo') {
        return await picker.pickImage(source: ImageSource.gallery);
      } else {
        return await picker.pickVideo(source: ImageSource.gallery);
      }
    }
    return null;
  }

  Future<String?> _uploadMedia(dynamic mediaFile, String type) async {
    // Returns public URL or null on failure.
    try {
      final mediaId = const Uuid().v4();
      String filePath;
      String contentType;

      if (kIsWeb) {
        if (mediaFile is html.File) {
          final fileSizeInBytes = mediaFile.size;
          if (type == 'photo' && fileSizeInBytes > 5 * 1024 * 1024) {
            throw Exception('Image too large, max 5MB');
          }
          if (type == 'video' && fileSizeInBytes > 20 * 1024 * 1024) {
            throw Exception('Video too large, max 20MB');
          }
          final extension = mediaFile.name.split('.').last.toLowerCase();
          filePath = 'media/$mediaId.$extension';
          contentType = mediaFile.type;
          final reader = html.FileReader();
          reader.readAsArrayBuffer(mediaFile);
          await reader.onLoad.first;
          final result = reader.result;
          if (result is! ByteBuffer && result is! Uint8List) {
            // Some browsers give ArrayBuffer (ByteBuffer)
          }
          Uint8List bytes;
          if (result is ByteBuffer) {
            bytes = result.asUint8List();
          } else if (result is Uint8List) {
            bytes = result;
          } else {
            throw Exception('Could not read file bytes');
          }
          await _supabase.storage.from('feeds').uploadBinary(filePath, bytes, fileOptions: FileOptions(contentType: contentType));
        } else {
          throw Exception('Invalid web file');
        }
      } else {
        if (mediaFile is XFile) {
          final file = File(mediaFile.path);
          final fileSizeInBytes = await file.length();
          if (type == 'photo' && fileSizeInBytes > 5 * 1024 * 1024) {
            throw Exception('Image too large, max 5MB');
          }
          if (type == 'video' && fileSizeInBytes > 20 * 1024 * 1024) {
            throw Exception('Video too large, max 20MB');
          }
          final extension = p.extension(mediaFile.path).replaceFirst('.', '');
          filePath = 'media/$mediaId.$extension';
          contentType = _getMimeType(extension);
          await _supabase.storage.from('feeds').upload(filePath, File(mediaFile.path), fileOptions: FileOptions(contentType: contentType));
        } else {
          throw Exception('Invalid file type');
        }
      }

      final url = _supabase.storage.from('feeds').getPublicUrl(filePath);
      return url.isNotEmpty ? url : null;
    } catch (e) {
      debugPrint('upload error: $e');
      return null;
    }
  }

  String _getMimeType(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'mp4':
        return 'video/mp4';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> _defaultOnPostReview(Map<String, dynamic> reviewData) async {
    // Called when no external onPostReview callback supplied.
    // Upload media (if any), then add a post document under user's posts and feeds.
    if (widget.currentUser == null) throw Exception('No current user');

    String? mediaUrl;
    if (reviewData['media'] != null) {
      mediaUrl = await _uploadMedia(reviewData['media'], reviewData['mediaType'] ?? 'photo');
      if (mediaUrl == null) throw Exception('Failed to upload media');
    }

    final newPost = {
      'user': widget.currentUser?['username'] ?? 'User',
      'userId': widget.currentUser?['id']?.toString() ?? '',
      'post': reviewData['isTVShow'] == true
          ? 'Reviewed ${reviewData['title']} S${reviewData['season']}: E${reviewData['episode']} - ${reviewData['review']}'
          : 'Reviewed ${reviewData['title']}: ${reviewData['review']}',
      'type': 'review',
      'likedBy': [],
      'title': reviewData['title'] ?? '',
      'season': reviewData['season'] ?? '',
      'episode': reviewData['episode'] ?? '',
      'media': mediaUrl ?? '',
      'mediaType': mediaUrl != null ? (reviewData['mediaType'] ?? '') : '',
      'timestamp': DateTime.now().toIso8601String(),
    };

    // write to user's posts subcollection
    final userId = widget.currentUser?['id']?.toString();
    if (userId == null || userId.isEmpty) throw Exception('Invalid user id');

    final docRef = await FirebaseFirestore.instance.collection('users').doc(userId).collection('posts').add(newPost);
    newPost['id'] = docRef.id;
    await FirebaseFirestore.instance.collection('feeds').add(newPost);
  }

  void _handlePostReview() async {
    if (_isPosting) return;
    if (movieController.text.trim().isEmpty || reviewController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fill in all fields")),
      );
      return;
    }

    setState(() => _isPosting = true);
    await _animationController.forward();
    await _animationController.reverse();

    final reviewData = {
      'title': movieController.text.trim(),
      'review': reviewController.text.trim(),
      'season': seasonController.text.trim(),
      'episode': episodeController.text.trim(),
      'media': mediaFile,
      'mediaType': mediaType,
      'isTVShow': isTVShow,
    };

    try {
      if (widget.onPostReview != null) {
        await widget.onPostReview!(reviewData);
      } else {
        await _defaultOnPostReview(reviewData);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Review posted')));
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('Failed to post review: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to post review: $e")));
      }
    } finally {
      if (mounted) setState(() => _isPosting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          "Write a Review",
          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 24),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          Container(color: const Color(0xFF111927)),
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.1, -0.4),
                radius: 1.2,
                colors: [widget.accentColor.withOpacity(0.4), Colors.black],
                stops: const [0.0, 0.6],
              ),
            ),
          ),
          Positioned.fill(
            top: kToolbarHeight + MediaQuery.of(context).padding.top,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.6,
                    colors: [widget.accentColor.withOpacity(0.2), Colors.transparent],
                    stops: const [0.0, 1.0],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: widget.accentColor.withOpacity(0.4),
                      blurRadius: 10,
                      spreadRadius: 1,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color.fromARGB(180, 17, 19, 40),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.1)),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: !isTVShow ? widget.accentColor : Colors.grey[800],
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  ),
                                  onPressed: () => setState(() => isTVShow = false),
                                  child: const Text("Movie", style: TextStyle(fontSize: 16)),
                                ),
                                const SizedBox(width: 12),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isTVShow ? widget.accentColor : Colors.grey[800],
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  ),
                                  onPressed: () => setState(() => isTVShow = true),
                                  child: const Text("TV Show", style: TextStyle(fontSize: 16)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            TextField(
                              controller: movieController,
                              style: const TextStyle(color: Colors.white, fontSize: 16),
                              decoration: InputDecoration(
                                hintText: "Movie/TV Show Name",
                                hintStyle: const TextStyle(color: Colors.white54),
                                filled: true,
                                fillColor: Colors.white.withOpacity(0.05),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: widget.accentColor, width: 1.5),
                                ),
                              ),
                            ),
                            if (isTVShow) ...[
                              const SizedBox(height: 16),
                              TextField(
                                controller: seasonController,
                                style: const TextStyle(color: Colors.white, fontSize: 16),
                                decoration: InputDecoration(
                                  hintText: "Season (e.g., Season 1)",
                                  hintStyle: const TextStyle(color: Colors.white54),
                                  filled: true,
                                  fillColor: Colors.white.withOpacity(0.05),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide.none,
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide(color: widget.accentColor, width: 1.5),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              TextField(
                                controller: episodeController,
                                style: const TextStyle(color: Colors.white, fontSize: 16),
                                decoration: InputDecoration(
                                  hintText: "Episode (e.g., Episode 1 or Pilot)",
                                  hintStyle: const TextStyle(color: Colors.white54),
                                  filled: true,
                                  fillColor: Colors.white.withOpacity(0.05),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide.none,
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide(color: widget.accentColor, width: 1.5),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            TextField(
                              controller: reviewController,
                              style: const TextStyle(color: Colors.white, fontSize: 16),
                              decoration: InputDecoration(
                                hintText: "Share your thoughts...",
                                hintStyle: const TextStyle(color: Colors.white54),
                                filled: true,
                                fillColor: Colors.white.withOpacity(0.05),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: widget.accentColor, width: 1.5),
                                ),
                              ),
                              maxLines: 5,
                              minLines: 3,
                            ),
                            const SizedBox(height: 16),
                            if (mediaFile != null)
                              Container(
                                height: 150,
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color: Colors.grey[900],
                                ),
                                child: kIsWeb
                                    ? Center(
                                        child: Text(
                                          "${mediaType == 'photo' ? 'Image' : 'Video'} selected",
                                          style: const TextStyle(color: Colors.white70, fontSize: 16),
                                        ),
                                      )
                                    : mediaType == 'photo'
                                        ? ClipRRect(
                                            borderRadius: BorderRadius.circular(12),
                                            child: Image.file(
                                              File((mediaFile as XFile).path),
                                              fit: BoxFit.cover,
                                              height: 150,
                                              width: double.infinity,
                                            ),
                                          )
                                        : const Center(
                                            child: Text(
                                              "Video selected",
                                              style: TextStyle(color: Colors.white70, fontSize: 16),
                                            ),
                                          ),
                              ),
                            const SizedBox(height: 12),
                            TextButton.icon(
                              icon: Icon(Icons.image, color: widget.accentColor, size: 20),
                              label: Text(
                                mediaFile == null ? "Add Photo or Video" : "Change Media",
                                style: TextStyle(color: widget.accentColor, fontSize: 16),
                              ),
                              onPressed: () async {
                                final choice = await showModalBottomSheet<String>(
                                  context: context,
                                  backgroundColor: const Color.fromARGB(255, 17, 25, 40),
                                  shape: const RoundedRectangleBorder(
                                    borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                                  ),
                                  builder: (context) => SafeArea(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ListTile(
                                          leading: Icon(Icons.photo, color: widget.accentColor),
                                          title: const Text(
                                            "Upload Photo",
                                            style: TextStyle(color: Colors.white, fontSize: 16),
                                          ),
                                          onTap: () => Navigator.pop(context, 'photo'),
                                        ),
                                        ListTile(
                                          leading: Icon(Icons.videocam, color: widget.accentColor),
                                          title: const Text(
                                            "Upload Video",
                                            style: TextStyle(color: Colors.white, fontSize: 16),
                                          ),
                                          onTap: () => Navigator.pop(context, 'video'),
                                        ),
                                        const SizedBox(height: 8),
                                      ],
                                    ),
                                  ),
                                );
                                if (choice != null) {
                                  final picked = await pickFile(choice);
                                  if (picked != null && mounted) {
                                    setState(() {
                                      mediaFile = picked;
                                      mediaType = choice;
                                    });
                                  }
                                }
                              },
                            ),
                            const SizedBox(height: 24),
                            ScaleTransition(
                              scale: _buttonScaleAnimation,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: widget.accentColor,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 32),
                                  minimumSize: const Size(double.infinity, 50),
                                  elevation: 2,
                                ),
                                onPressed: _isPosting ? null : _handlePostReview,
                                child: _isPosting
                                    ? const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text(
                                        "Post Review",
                                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
