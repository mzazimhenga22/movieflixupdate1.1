import 'dart:ui';
import 'package:flutter/material.dart';

class BottomNavBar extends StatelessWidget {
  final Color accentColor;
  final int selectedIndex;
  final ValueChanged<int> onItemTapped;
  final bool useBlurEffect;

  const BottomNavBar({
    required this.accentColor,
    required this.selectedIndex,
    required this.onItemTapped,
    this.useBlurEffect = false,
    super.key,
  });

  static const List<BottomNavigationBarItem> _navItems = [
    BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
    BottomNavigationBarItem(icon: Icon(Icons.category), label: 'Categories'),
    BottomNavigationBarItem(icon: Icon(Icons.download), label: 'Downloads'),
    BottomNavigationBarItem(icon: Icon(Icons.live_tv), label: 'Interactive'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: useBlurEffect
          ? BoxDecoration(
              color: Colors.white.withOpacity(0.08), // subtle translucent layer
              border: Border(
                top: BorderSide(color: Colors.white.withOpacity(0.2), width: 1.0),
              ),
              boxShadow: [
                BoxShadow(
                  color: accentColor.withOpacity(0.25),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ],
            )
          : BoxDecoration(
              color: Colors.black.withOpacity(0.8),
            ),
      child: ClipRRect(
        borderRadius: useBlurEffect
            ? const BorderRadius.vertical(top: Radius.circular(18))
            : BorderRadius.zero,
        child: useBlurEffect
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20.0, sigmaY: 20.0),
                child: BottomNavigationBar(
                  type: BottomNavigationBarType.fixed,
                  elevation: 0,
                  backgroundColor: Colors.transparent, // glassy background
                  selectedItemColor: accentColor,
                  unselectedItemColor: Colors.white.withOpacity(0.7),
                  currentIndex: selectedIndex,
                  items: _navItems,
                  onTap: onItemTapped,
                ),
              )
            : BottomNavigationBar(
                backgroundColor: Colors.black.withOpacity(0.8),
                selectedItemColor: accentColor,
                unselectedItemColor: Colors.white.withOpacity(0.6),
                currentIndex: selectedIndex,
                items: _navItems,
                onTap: onItemTapped,
              ),
      ),
    );
  }
}
