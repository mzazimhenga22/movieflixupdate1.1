import 'package:flutter/material.dart';

class MovieflixLoader extends StatefulWidget {
  const MovieflixLoader({super.key});

  @override
  _MovieflixLoaderState createState() => _MovieflixLoaderState();
}

class _MovieflixLoaderState extends State<MovieflixLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _rotation;
  late Animation<double> _shimmer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    // rotation from 0 to 2π
    _rotation = Tween<double>(begin: 0, end: 2 * 3.14159).animate(
      CurvedAnimation(parent: _controller, curve: Curves.linear),
    );
    // shimmer: 0 → 1 → 0
    _shimmer = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 50),
    ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 200,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // rotating reel
            AnimatedBuilder(
              animation: _rotation,
              builder: (_, __) => Transform.rotate(
                angle: _rotation.value,
                child: Icon(
                  Icons.movie, 
                  size: 64, 
                  color: Colors.deepPurpleAccent,
                ),
              ),
            ),

            const SizedBox(height: 16),

            // shimmering text
            AnimatedBuilder(
              animation: _shimmer,
              builder: (_, __) {
                final intensity = (_shimmer.value * 0.7) + 0.3;
                return Text(
                  'Movieflix',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    foreground: Paint()
                      ..shader = LinearGradient(
                        colors: [
                          Colors.deepPurpleAccent.withOpacity(intensity),
                          Colors.white.withOpacity(intensity),
                        ],
                      ).createShader(const Rect.fromLTWH(0, 0, 200, 40)),
                  ),
                );
              },
            ),

            const SizedBox(height: 8),

            // optional subtitle
            const Text(
              'Loading your movie…',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
