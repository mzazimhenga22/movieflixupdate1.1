// signup_screen.dart
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:movie_app/database/auth_database.dart';
import 'package:movie_app/profile_selection_screen.dart';
// removed import of signin_screen.dart to avoid circular import
import 'package:movie_app/user_manager.dart';
import 'package:movie_app/session_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:ui';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  SignUpScreenState createState() => SignUpScreenState();
}

class SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _pageController = PageController();
  bool _isProcessing = false;
  int _currentPage = 0;

  final FirebaseAuth _firebaseAuth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final List<Map<String, String>> slides = [
    {
      'image': 'assets/cinema.jpg',
      'title': 'Stream Anywhere',
      'description': 'Watch your favorite movies and shows on any device.',
    },
    {
      'image': 'assets/icon/movieposter.jpg',
      'title': 'Exclusive Content',
      'description': 'Enjoy original series and movies you won\'t find anywhere else.',
    },
    {
      'image': 'assets/icon/movieposter.jpg',
      'title': 'Personalized Recommendations',
      'description': 'Discover content tailored just for you.',
    },
  ];

  @override
  void initState() {
    super.initState();
    _firestore.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _storeSession(String userId, String token) async {
    try {
      final expirationDate = DateTime.now().add(const Duration(days: 5));
      await _firestore.collection('sessions').doc(userId).set({
        'userId': userId,
        'token': token,
        'expiresAt': Timestamp.fromDate(expirationDate),
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('session_user_id', userId);
      await prefs.setString('session_token', token);
      await prefs.setInt('session_expires_at', expirationDate.millisecondsSinceEpoch);
      debugPrint('✅ Session saved for user: $userId');
    } catch (e) {
      debugPrint('❌ Error storing session: $e');
      rethrow;
    }
  }

  Future<void> _saveUserOffline(String userId, Map<String, dynamic> userData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_$userId', userData.toString());
      debugPrint('✅ User data saved offline for user: $userId');
    } catch (e) {
      debugPrint('❌ Error saving user offline: $e');
      rethrow;
    }
  }

  Future<void> _saveFcmTokenForUser(String userId) async {
    try {
      final fcm = FirebaseMessaging.instance;
      final token = await fcm.getToken();
      if (token != null && token.isNotEmpty) {
        await _firestore.collection('users').doc(userId).set({'fcmToken': token}, SetOptions(merge: true));
        debugPrint('[FCM] saved token for $userId');
      } else {
        debugPrint('[FCM] getToken returned null or empty for $userId');
      }

      fcm.onTokenRefresh.listen((newToken) async {
        try {
          if (newToken != null && newToken.isNotEmpty) {
            await _firestore.collection('users').doc(userId).set({'fcmToken': newToken}, SetOptions(merge: true));
            debugPrint('[FCM] refreshed token saved for $userId');
          }
        } catch (e) {
          debugPrint('[FCM] failed saving refreshed token: $e');
        }
      });
    } catch (e) {
      debugPrint('[FCM] _saveFcmTokenForUser error: $e');
    }
  }

  Future<void> _signUpEmail() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isProcessing = true);
    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text;
      final username = _usernameController.text.trim();

      final userCred = await _firebaseAuth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      if (!mounted) return;

      final user = userCred.user;
      if (user != null) {
        final userData = {
          'id': user.uid,
          'username': username.isNotEmpty ? username : user.displayName ?? 'User',
          'email': email,
          'status': 'Online',
          'auth_provider': 'firebase',
          'pinnedChats': <String>[],
          'created_at': FieldValue.serverTimestamp(),
          'updated_at': FieldValue.serverTimestamp(),
        };

        final userDoc = await _firestore.collection('users').doc(user.uid).get();
        if (!userDoc.exists) {
          await _firestore.collection('users').doc(user.uid).set(userData, SetOptions(merge: true));
        }

        await AuthDatabase.instance.createUser({
          'id': user.uid,
          'username': username.isNotEmpty ? username : 'User',
          'email': email,
          'password': password,
          'auth_provider': 'firebase',
          'pinnedChats': <String>[],
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });

        await _saveUserOffline(user.uid, userData);
        UserManager.instance.updateUser(userData);

        await _saveFcmTokenForUser(user.uid);

        final token = await user.getIdToken();
        if (token != null) {
          await SessionManager.saveAuthToken(token);
          await _storeSession(user.uid, token);
        } else {
          throw Exception('Failed to obtain auth token');
        }

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Sign up successful")),
        );
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ProfileSelectionScreen()),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? e.code)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Sign up failed: $e")),
      );
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _signUpWithGoogle() async {
    setState(() => _isProcessing = true);
    try {
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Google sign-up cancelled")),
          );
        }
        return;
      }
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final userCred = await _firebaseAuth.signInWithCredential(credential);
      final user = userCred.user;
      if (!mounted) return;

      if (user != null) {
        final username = user.displayName ?? 'GoogleUser';
        final userData = {
          'id': user.uid,
          'username': username,
          'email': user.email ?? '',
          'status': 'Online',
          'pinnedChats': <String>[],
          'auth_provider': 'google',
          'created_at': FieldValue.serverTimestamp(),
          'updated_at': FieldValue.serverTimestamp(),
        };

        final userDoc = await _firestore.collection('users').doc(user.uid).get();
        if (!userDoc.exists) {
          await _firestore.collection('users').doc(user.uid).set(userData, SetOptions(merge: true));
        }

        await AuthDatabase.instance.createUser({
          'id': user.uid,
          'username': username,
          'email': user.email ?? '',
          'password': '',
          'auth_provider': 'google',
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });

        await _saveUserOffline(user.uid, userData);
        UserManager.instance.updateUser({
          'id': user.uid,
          'username': username,
          'email': user.email ?? '',
          'photoURL': user.photoURL,
        });

        await _saveFcmTokenForUser(user.uid);

        final token = await user.getIdToken();
        if (token != null) {
          await SessionManager.saveAuthToken(token);
          await _storeSession(user.uid, token);
        } else {
          throw Exception('Failed to obtain auth token');
        }

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Google sign-up successful")),
        );
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ProfileSelectionScreen()),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Google sign-up failed: $e")),
      );
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Widget _buildSlide(Map<String, String> slide, int index, double topHeight) {
    final imageHeight = min(180.0, topHeight * 0.6);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset(
                slide['image']!,
                height: imageHeight,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              slide['title']!,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              slide['description']!,
              style: const TextStyle(
                fontSize: 16,
                color: Colors.white70,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(slides.length, (index) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          height: 8,
          width: _currentPage == index ? 24 : 8,
          decoration: BoxDecoration(
            color: _currentPage == index ? Colors.blueAccent : Colors.white70,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final keyboardInset = mq.viewInsets.bottom;
    final double topHeight = keyboardInset > 0
        ? max(120.0, mq.size.height * 0.22)
        : mq.size.height * 0.35;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Sign Up"),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.redAccent, Colors.blueAccent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.1, -0.4),
                radius: 1.2,
                colors: [Colors.blueAccent.withOpacity(0.4), Colors.black],
                stops: const [0.0, 0.6],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                SizedBox(
                  height: topHeight,
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: slides.length,
                    onPageChanged: (index) {
                      setState(() {
                        _currentPage = index;
                      });
                    },
                    itemBuilder: (context, index) => _buildSlide(slides[index], index, topHeight),
                    physics: const BouncingScrollPhysics(),
                  ),
                ),

                _buildPageIndicator(),
                const SizedBox(height: 20),

                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom + 24),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: _isProcessing
                            ? const Center(child: CircularProgressIndicator(color: Colors.blueAccent))
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.7),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: Colors.blueAccent.withOpacity(0.3),
                                        width: 1.5,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.blueAccent.withOpacity(0.4),
                                          blurRadius: 10,
                                          spreadRadius: 1,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(24.0),
                                      child: Form(
                                        key: _formKey,
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Text(
                                              "Create Account",
                                              style: TextStyle(
                                                fontSize: 28,
                                                color: Colors.blueAccent,
                                                fontWeight: FontWeight.bold,
                                                letterSpacing: 1.2,
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            TextFormField(
                                              controller: _usernameController,
                                              style: const TextStyle(color: Colors.white),
                                              decoration: InputDecoration(
                                                labelText: "Username",
                                                labelStyle: TextStyle(color: Colors.blueAccent.withOpacity(0.7)),
                                                filled: true,
                                                fillColor: Colors.blueAccent.withOpacity(0.15),
                                                border: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(12),
                                                  borderSide: BorderSide.none,
                                                ),
                                                enabledBorder: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(12),
                                                  borderSide: BorderSide(
                                                    color: Colors.blueAccent.withOpacity(0.3),
                                                  ),
                                                ),
                                                focusedBorder: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(12),
                                                  borderSide: const BorderSide(
                                                    color: Colors.blueAccent,
                                                    width: 2,
                                                  ),
                                                ),
                                              ),
                                              validator: (v) => v == null || v.isEmpty ? 'Enter username' : null,
                                            ),
                                            const SizedBox(height: 16),
                                            TextFormField(
                                              controller: _emailController,
                                              style: const TextStyle(color: Colors.white),
                                              decoration: InputDecoration(
                                                labelText: "Email",
                                                labelStyle: TextStyle(color: Colors.blueAccent.withOpacity(0.7)),
                                                filled: true,
                                                fillColor: Colors.blueAccent.withOpacity(0.15),
                                                border: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(12),
                                                  borderSide: BorderSide.none,
                                                ),
                                                enabledBorder: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(12),
                                                  borderSide: BorderSide(
                                                    color: Colors.blueAccent.withOpacity(0.3),
                                                  ),
                                                ),
                                                focusedBorder: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(12),
                                                  borderSide: const BorderSide(
                                                    color: Colors.blueAccent,
                                                    width: 2,
                                                  ),
                                                ),
                                              ),
                                              keyboardType: TextInputType.emailAddress,
                                              validator: (v) => v == null || !RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(v)
                                                  ? 'Enter valid email'
                                                  : null,
                                            ),
                                            const SizedBox(height: 16),
                                            TextFormField(
                                              controller: _passwordController,
                                              style: const TextStyle(color: Colors.white),
                                              decoration: InputDecoration(
                                                labelText: "Password",
                                                labelStyle: TextStyle(color: Colors.blueAccent.withOpacity(0.7)),
                                                filled: true,
                                                fillColor: Colors.blueAccent.withOpacity(0.15),
                                                border: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(12),
                                                  borderSide: BorderSide.none,
                                                ),
                                                enabledBorder: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(12),
                                                  borderSide: BorderSide(
                                                    color: Colors.blueAccent.withOpacity(0.3),
                                                  ),
                                                ),
                                                focusedBorder: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(12),
                                                  borderSide: const BorderSide(
                                                    color: Colors.blueAccent,
                                                    width: 2,
                                                  ),
                                                ),
                                              ),
                                              obscureText: true,
                                              validator: (v) => v == null || v.length < 6 ? 'Min 6 chars' : null,
                                            ),
                                            const SizedBox(height: 16),
                                            TextFormField(
                                              controller: _confirmPasswordController,
                                              style: const TextStyle(color: Colors.white),
                                              decoration: InputDecoration(
                                                labelText: "Confirm Password",
                                                labelStyle: TextStyle(color: Colors.blueAccent.withOpacity(0.7)),
                                                filled: true,
                                                fillColor: Colors.blueAccent.withOpacity(0.15),
                                                border: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(12),
                                                  borderSide: BorderSide.none,
                                                ),
                                                enabledBorder: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(12),
                                                  borderSide: BorderSide(
                                                    color: Colors.blueAccent.withOpacity(0.3),
                                                  ),
                                                ),
                                                focusedBorder: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(12),
                                                  borderSide: const BorderSide(
                                                    color: Colors.blueAccent,
                                                    width: 2,
                                                  ),
                                                ),
                                              ),
                                              obscureText: true,
                                              validator: (v) => v == _passwordController.text ? null : 'Passwords must match',
                                            ),
                                            const SizedBox(height: 24),
                                            ElevatedButton(
                                              onPressed: _signUpEmail,
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.blueAccent,
                                                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                                elevation: 0,
                                                shadowColor: Colors.transparent,
                                              ),
                                              child: const Text(
                                                'Sign Up',
                                                style: TextStyle(fontSize: 16, color: Colors.white),
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            ElevatedButton.icon(
                                              onPressed: _signUpWithGoogle,
                                              icon: Image.asset(
                                                'assets/googlelogo1.png',
                                                height: 24,
                                                width: 24,
                                              ),
                                              label: const Text(
                                                'Sign Up with Google',
                                                style: TextStyle(fontSize: 16, color: Colors.black87),
                                              ),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.white.withOpacity(0.9),
                                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                                elevation: 0,
                                                shadowColor: Colors.transparent,
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            TextButton(
                                              onPressed: () {
                                                if (!mounted) return;
                                                // Return to previous screen (Sign In) — avoids circular import
                                                Navigator.pop(context);
                                              },
                                              child: const Text(
                                                'Already have an account? Sign In',
                                                style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
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
          ),
        ],
      ),
    );
  }
}
