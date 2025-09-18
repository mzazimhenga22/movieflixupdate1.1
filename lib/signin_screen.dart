// signin_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:movie_app/database/auth_database.dart';
import 'package:movie_app/user_manager.dart';
import 'package:movie_app/session_manager.dart';
import 'package:movie_app/profile_selection_screen.dart';
import 'package:movie_app/signup_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:ui';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  SignInScreenState createState() => SignInScreenState();
}

class SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  String? _email, _password;
  bool _isProcessing = false;
  final FirebaseAuth _firebaseAuth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: ['email']);
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  void initState() {
    super.initState();
    _firestore.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
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

  Future<void> _forceRefreshAuthToken() async {
    try {
      final currentUser = _firebaseAuth.currentUser;
      if (currentUser != null) {
        debugPrint('[AUTH] Forcing ID token refresh for ${currentUser.uid}');
        await currentUser.getIdToken(true);
        debugPrint('[AUTH] ID token refreshed for ${currentUser.uid}');
      } else {
        debugPrint('[AUTH] No current user to refresh token for');
      }
    } catch (e) {
      debugPrint('[AUTH] Failed to refresh ID token: $e');
    }
  }

  Future<void> _saveFcmTokenForUser(String userId) async {
    try {
      await _forceRefreshAuthToken();

      final currentUser = _firebaseAuth.currentUser;
      if (currentUser == null || currentUser.uid != userId) {
        debugPrint('[FCM] Auth user mismatch or not signed in. '
            'currentUser=${currentUser?.uid}, expected=$userId. Skipping FCM save.');
        return;
      }

      final fcm = FirebaseMessaging.instance;
      final token = await fcm.getToken();
      if (token != null && token.isNotEmpty) {
        try {
          await _firestore.collection('users').doc(userId).set({'fcmToken': token}, SetOptions(merge: true));
          debugPrint('[FCM] saved token for $userId -> $token');
        } catch (e) {
          debugPrint('[FCM] failed to save token to Firestore for $userId: $e');
        }
      } else {
        debugPrint('[FCM] getToken returned null or empty for $userId');
      }

      fcm.onTokenRefresh.listen((newToken) async {
        try {
          final current = _firebaseAuth.currentUser;
          if (current == null) {
            debugPrint('[FCM] token refreshed but no auth user present, skipping save');
            return;
          }
          if (current.uid != userId) {
            debugPrint('[FCM] token refreshed for another user (${current.uid}), skipping save for $userId');
            return;
          }
          if (newToken != null && newToken.isNotEmpty) {
            try {
              await current.getIdToken(true);
            } catch (e) {
              debugPrint('[FCM] failed to refresh ID token before saving refreshed FCM token: $e');
            }
            await _firestore.collection('users').doc(userId).set({'fcmToken': newToken}, SetOptions(merge: true));
            debugPrint('[FCM] refreshed token saved for $userId -> $newToken');
          } else {
            debugPrint('[FCM] onTokenRefresh provided null/empty token for $userId');
          }
        } catch (e) {
          debugPrint('[FCM] failed saving refreshed token: $e');
        }
      });
    } catch (e) {
      debugPrint('[FCM] _saveFcmTokenForUser error: $e');
    }
  }

  Future<void> _removeFcmTokenForUser(String userId) async {
    try {
      await _firestore.collection('users').doc(userId).update({'fcmToken': FieldValue.delete()});
      debugPrint('[FCM] removed token field for $userId');
      try {
        await FirebaseMessaging.instance.deleteToken();
        debugPrint('[FCM] local token deleted');
      } catch (e) {
        debugPrint('[FCM] failed to delete local token: $e');
      }
    } catch (e) {
      debugPrint('[FCM] _removeFcmTokenForUser error: $e');
    }
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();
    setState(() => _isProcessing = true);

    try {
      final userCredential = await _firebaseAuth.signInWithEmailAndPassword(
        email: _email!,
        password: _password!,
      );
      final firebaseUser = userCredential.user;

      if (!mounted) return;

      if (firebaseUser != null) {
        try {
          await firebaseUser.getIdToken(true);
          debugPrint('[AUTH] forced ID token refresh immediately after sign-in for ${firebaseUser.uid}');
        } catch (e) {
          debugPrint('[AUTH] failed forcing ID token refresh after sign-in: $e');
        }

        final userDoc = await _firestore.collection('users').doc(firebaseUser.uid).get();
        final userData = userDoc.exists
            ? {
                'id': firebaseUser.uid,
                'username': userDoc.data()?['username'] ?? 'User',
                'email': firebaseUser.email ?? '',
                'status': 'Online',
                'auth_provider': 'firebase',
                'created_at': userDoc.data()?['created_at'] ?? FieldValue.serverTimestamp(),
                'updated_at': FieldValue.serverTimestamp(),
              }
            : {
                'id': firebaseUser.uid,
                'username': 'User',
                'email': firebaseUser.email ?? '',
                'status': 'Online',
                'auth_provider': 'firebase',
                'created_at': FieldValue.serverTimestamp(),
                'updated_at': FieldValue.serverTimestamp(),
              };

        if (!userDoc.exists) {
          await _firestore.collection('users').doc(firebaseUser.uid).set(userData, SetOptions(merge: true));
        } else {
          await _firestore.collection('users').doc(firebaseUser.uid).update({
            'status': 'Online',
            'updated_at': FieldValue.serverTimestamp(),
          });
        }

        await AuthDatabase.instance.createUser({
          'id': firebaseUser.uid,
          'username': userData['username'],
          'email': firebaseUser.email ?? '',
          'password': _password!,
          'auth_provider': 'firebase',
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });

        await _saveUserOffline(firebaseUser.uid, userData);
        UserManager.instance.updateUser(userData);

        await _saveFcmTokenForUser(firebaseUser.uid);

        final token = await firebaseUser.getIdToken();
        if (token != null) {
          await SessionManager.saveAuthToken(token);
          await _storeSession(firebaseUser.uid, token);
        } else {
          throw Exception('Failed to obtain auth token');
        }

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const ProfileSelectionScreen()),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Sign-in failed: No user returned")),
          );
        }
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? e.code)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error during sign-in: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _isProcessing = true);

    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Google sign-in cancelled")),
          );
        }
        return;
      }

      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final userCredential = await _firebaseAuth.signInWithCredential(credential);
      final firebaseUser = userCredential.user;

      if (!mounted) return;

      if (firebaseUser != null) {
        try {
          await firebaseUser.getIdToken(true);
          debugPrint('[AUTH] forced ID token refresh immediately after Google sign-in for ${firebaseUser.uid}');
        } catch (e) {
          debugPrint('[AUTH] failed forcing ID token refresh after Google sign-in: $e');
        }

        final username = firebaseUser.displayName ?? 'GoogleUser';
        final userData = {
          'id': firebaseUser.uid,
          'username': username,
          'email': firebaseUser.email ?? '',
          'status': 'Online',
          'auth_provider': 'google',
          'created_at': FieldValue.serverTimestamp(),
          'updated_at': FieldValue.serverTimestamp(),
        };

        final userDoc = await _firestore.collection('users').doc(firebaseUser.uid).get();
        if (!userDoc.exists) {
          await _firestore.collection('users').doc(firebaseUser.uid).set(userData, SetOptions(merge: true));
        } else {
          await _firestore.collection('users').doc(firebaseUser.uid).update({
            'status': 'Online',
            'updated_at': FieldValue.serverTimestamp(),
          });
        }

        await AuthDatabase.instance.createUser({
          'id': firebaseUser.uid,
          'username': username,
          'email': firebaseUser.email ?? '',
          'password': '',
          'auth_provider': 'google',
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });

        await _saveUserOffline(firebaseUser.uid, userData);
        UserManager.instance.updateUser({
          'id': firebaseUser.uid,
          'username': username,
          'email': firebaseUser.email ?? '',
          'photoURL': firebaseUser.photoURL,
        });

        await _saveFcmTokenForUser(firebaseUser.uid);

        final idToken = await firebaseUser.getIdToken();
        if (idToken != null) {
          await SessionManager.saveAuthToken(idToken);
          await _storeSession(firebaseUser.uid, idToken);
        } else {
          throw Exception('Failed to obtain auth token');
        }

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const ProfileSelectionScreen()),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Google sign-in failed: No user returned")),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Google sign-in failed: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _isProcessing = true);

    try {
      final user = _firebaseAuth.currentUser;
      if (user != null) {
        await _firestore.collection('sessions').doc(user.uid).delete();
        debugPrint('✅ Firestore session deleted for user: ${user.uid}');

        await _removeFcmTokenForUser(user.uid);

        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('session_user_id');
        await prefs.remove('session_token');
        await prefs.remove('session_expires_at');
        await prefs.remove('user_${user.uid}');
        debugPrint('✅ Local session and user data cleared for user: ${user.uid}');
      }

      await SessionManager.clearAuthToken();
      await _firebaseAuth.signOut();
      await _googleSignIn.signOut();
      UserManager.instance.clearUser();

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const SignInScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error during sign-out: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _goToSignUp() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SignUpScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Sign In"),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (_firebaseAuth.currentUser != null)
            IconButton(
              icon: const Icon(Icons.logout, color: Colors.blueAccent),
              onPressed: _signOut,
              tooltip: 'Sign Out',
            ),
        ],
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
          Center(
            child: SingleChildScrollView(
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
                                    Text(
                                      "Welcome Back",
                                      style: TextStyle(
                                        fontSize: 28,
                                        color: Colors.blueAccent,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    TextFormField(
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
                                      validator: (value) {
                                        if (value == null || value.isEmpty) {
                                          return "Enter email";
                                        }
                                        if (!RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(value)) {
                                          return "Enter valid email";
                                        }
                                        return null;
                                      },
                                      onSaved: (value) => _email = value,
                                    ),
                                    const SizedBox(height: 16),
                                    TextFormField(
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
                                      validator: (value) {
                                        if (value == null || value.isEmpty) {
                                          return "Enter password";
                                        }
                                        return null;
                                      },
                                      onSaved: (value) => _password = value,
                                    ),
                                    const SizedBox(height: 24),
                                    ElevatedButton(
                                      onPressed: _signIn,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.blueAccent,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 40,
                                          vertical: 16,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        elevation: 0,
                                        shadowColor: Colors.transparent,
                                      ),
                                      child: const Text(
                                        "Sign In",
                                        style: TextStyle(fontSize: 16, color: Colors.white),
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    ElevatedButton.icon(
                                      onPressed: _signInWithGoogle,
                                      icon: Image.asset(
                                        'assets/googlelogo1.png',
                                        height: 24,
                                        width: 24,
                                      ),
                                      label: const Text(
                                        "Sign in with Google",
                                        style: TextStyle(fontSize: 16, color: Colors.black87),
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.white.withOpacity(0.9),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 24,
                                          vertical: 14,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        elevation: 0,
                                        shadowColor: Colors.transparent,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          "Don't have an account? ",
                                          style: TextStyle(color: Colors.blueAccent.withOpacity(0.7)),
                                        ),
                                        GestureDetector(
                                          onTap: _goToSignUp,
                                          child: const Text(
                                            "Sign Up",
                                            style: TextStyle(
                                              color: Colors.blueAccent,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
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
        ],
      ),
    );
  }
}
