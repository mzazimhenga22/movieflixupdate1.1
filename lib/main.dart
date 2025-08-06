import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:movie_app/splash_screen.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/database/auth_database.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:movie_app/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:movie_app/components/socialsection/ProfileScreen.dart';
import 'package:movie_app/components/socialsection/messages_controller.dart';
import 'package:movie_app/components/socialsection/messages_screen.dart';
import 'package:movie_app/components/socialsection/presence_wrapper.dart';



void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // Initialize Firebase
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('✅ Firebase initialized');

    FirebaseFirestore.instance.settings = const Settings(
  persistenceEnabled: true,
  cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
);


    // Initialize Supabase
    await Supabase.initialize(
      url: 'https://qumrbpxhyxkgreoqsnis.supabase.co',
      anonKey:
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF1bXJicHhoeXhrZ3Jlb3FzbmlzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDg2NzkyNDksImV4cCI6MjA2NDI1NTI0OX0.r-Scwh1gYAfMwYjh1_wjAVb66XSjvcUgPeV_CH7VkS4',
    );
    debugPrint('✅ Supabase initialized');

    // Initialize AuthDatabase
    await AuthDatabase.instance.initialize();
    debugPrint('✅ AuthDatabase initialized');
  } catch (e) {
    debugPrint('❌ Initialization error: $e');
    rethrow;
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => SettingsProvider()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);

    // Get current user ID for presence tracking
    final userId = Supabase.instance.client.auth.currentUser?.id;

    Widget home = const SplashScreen();
    if (userId != null) {
      home = PresenceWrapper(
        userId: userId,
        child: const SplashScreen(),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.dark(primary: settings.accentColor),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: settings.accentColor,
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: settings.accentColor,
        ),
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: Colors.black,
          selectedItemColor: settings.accentColor,
          unselectedItemColor: Colors.grey,
        ),
      ),
      locale: settings.getLocale(),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
      onGenerateRoute: (RouteSettings routeSettings) {
        if (routeSettings.name == '/profile') {
          final user = routeSettings.arguments as Map<String, dynamic>;
          return MaterialPageRoute(
            builder: (context) => ProfileScreen(user: user),
          );
        } else if (routeSettings.name == '/messages') {
          final args = routeSettings.arguments as Map<String, dynamic>;
          final user = args['user'] as Map<String, dynamic>;
          final accentColor = args['accentColor'] as Color? ??
              Provider.of<SettingsProvider>(context).accentColor;
          return MaterialPageRoute(
            builder: (context) => ChangeNotifierProvider(
              create: (newContext) => MessagesController(user, newContext),
              child: MessagesScreen(
                currentUser: user,
                accentColor: accentColor,
              ),
            ),
          );
        }

        return null;
      },
    );
  }
}
