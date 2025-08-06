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
              color: const Color.fromARGB(160, 17, 19, 40),
              border: Border(
                top: BorderSide(color: Colors.white.withOpacity(0.125), width: 1.0),
              ),
              boxShadow: [
                BoxShadow(
                  color: accentColor.withOpacity(0.3),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ],
            )
          : BoxDecoration(
              color: Colors.black.withOpacity(0.8),
            ),
      child: ClipRRect(
        borderRadius: useBlurEffect
            ? const BorderRadius.vertical(top: Radius.circular(12))
            : BorderRadius.zero,
        child: useBlurEffect
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
                child: BottomNavigationBar(
                  backgroundColor: Colors.transparent,
                  selectedItemColor: Colors.white,
                  unselectedItemColor: accentColor.withOpacity(0.6),
                  currentIndex: selectedIndex,
                  items: _navItems,
                  onTap: onItemTapped,
                ),
              )
            : BottomNavigationBar(
                backgroundColor: Colors.black.withOpacity(0.8),
                selectedItemColor: Colors.white,
                unselectedItemColor: accentColor.withOpacity(0.6),
                currentIndex: selectedIndex,
                items: _navItems,
                onTap: onItemTapped,
              ),
      ),
    );
  }
}