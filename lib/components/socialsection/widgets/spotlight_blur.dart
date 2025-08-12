import 'dart:ui';
import 'package:flutter/material.dart';

class SpotlightBlur extends StatelessWidget {
  final Rect spotlightRect;

  const SpotlightBlur({super.key, required this.spotlightRect});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ClipPath(
        clipper: SpotlightClipper(spotlightRect),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: Container(color: Colors.black.withOpacity(0.5)),
        ),
      ),
    );
  }
}

class SpotlightClipper extends CustomClipper<Path> {
  final Rect spotlightRect;

  SpotlightClipper(this.spotlightRect);

  @override
  Path getClip(Size size) {
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(RRect.fromRectAndRadius(
        spotlightRect,
        const Radius.circular(12),
      ))
      ..fillType = PathFillType.evenOdd;
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => true;
}