import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:movie_app/marketplace/ticket_sales_screen.dart';
import 'package:movie_app/marketplace/marketplace_listings_screen.dart';
import 'package:movie_app/marketplace/my_assets_screen.dart';

const sectionTitleStyle = TextStyle(
  color: Colors.white,
  fontSize: 20,
  fontWeight: FontWeight.bold,
  fontFamily: 'Poppins',
);

class MarketplaceHomeScreen extends StatefulWidget {
  final String userName;
  final String userEmail;
  final String? userAvatar;

  const MarketplaceHomeScreen({
    super.key,
    required this.userName,
    required this.userEmail,
    this.userAvatar,
  });

  static const List<_FeaturedListing> featuredListings = [
    _FeaturedListing(
      title: 'Exclusive Premiere Ticket',
      image: 'assets/icon/premierticket.jpg',
      price: 49.99,
    ),
    _FeaturedListing(
      title: 'Rare Movie Poster',
      image: 'assets/icon/movieposter.jpg',
      price: 29.99,
    ),
    _FeaturedListing(
      title: 'Indie Film Screening',
      image: 'assets/icon/indiefilm.jpg',
      price: 19.99,
    ),
  ];

  @override
  State<MarketplaceHomeScreen> createState() => _MarketplaceHomeScreenState();
}

class _MarketplaceHomeScreenState extends State<MarketplaceHomeScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  late final AnimationController _animationController;
  late final Animation<double> _fadeAnimation;

  static const _screenPadding = EdgeInsets.all(12.0);

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _fadeAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _searchController.addListener(() {
      _filterFeatures(_searchController.text);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _filterFeatures(String query) {
    _searchQuery = query.toLowerCase();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    const accent = Colors.blueAccent;
    final filteredFeatures = _features
        .where((f) => f.title.toLowerCase().contains(_searchQuery))
        .toList();

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(
          'Marketplace',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontFamily: 'Poppins',
          ),
        ),
        backgroundColor: Colors.black.withOpacity(0.8),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          _AvatarButton(
            userAvatar: widget.userAvatar,
            userName: widget.userName,
            userEmail: widget.userEmail,
          ),
        ],
      ),
      body: Stack(
        children: [
          const Opacity(
            opacity: 0.3,
            child: Image(
              image: AssetImage('assets/marketplace_banner.png'),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
            ),
          ),
          SafeArea(
            child: Padding(
              padding: _screenPadding,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Color.fromARGB(180, 17, 25, 40),
                      borderRadius: BorderRadius.all(Radius.circular(16)),
                      border: Border.fromBorderSide(
                        BorderSide(color: Color.fromRGBO(255, 255, 255, 0.12)),
                      ),
                      gradient: RadialGradient(
                        center: Alignment(0.0, -0.6),
                        radius: 1.2,
                        colors: [Color.fromRGBO(0, 255, 191, 0.2), Colors.transparent],
                      ),
                    ),
                    child: CustomScrollView(
                      physics: const BouncingScrollPhysics(),
                      slivers: [
                        SliverToBoxAdapter(
                          child: _SearchBar(controller: _searchController),
                        ),
                        SliverToBoxAdapter(
                          child: _Banner(animation: _fadeAnimation),
                        ),
                        SliverToBoxAdapter(
                          child: _QuickActions(
                            userName: widget.userName,
                            userEmail: widget.userEmail,
                            accent: accent,
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: _FeaturedListingsSection(
                            accent: accent,
                            userName: widget.userName,
                            userEmail: widget.userEmail,
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                            child: const Text('Explore Categories', style: sectionTitleStyle),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverGrid(
                            delegate: SliverChildBuilderDelegate(
                              (context, i) => RepaintBoundary(
                                child: _FeatureCard(
                                  feature: filteredFeatures[i],
                                  accent: accent,
                                  userName: widget.userName,
                                  userEmail: widget.userEmail,
                                ),
                              ),
                              childCount: filteredFeatures.length,
                            ),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 16,
                              crossAxisSpacing: 16,
                              childAspectRatio: 1,
                            ),
                          ),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 24)),
                      ],
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

  static const List<_Feature> _features = [
    _Feature(icon: Icons.shopping_bag, title: 'Collectibles', routeToListings: true),
    _Feature(icon: Icons.gavel, title: 'Auctions', routeToListings: true),
    _Feature(icon: Icons.swap_horiz, title: 'Rentals', routeToListings: true),
    _Feature(icon: Icons.confirmation_number, title: 'Theater Tickets', routeToTickets: true),
    _Feature(icon: Icons.movie, title: 'Indie Films', routeToListings: true),
    _Feature(icon: Icons.new_releases, title: 'Premieres', routeToListings: true),
    _Feature(icon: Icons.star, title: 'Exclusive Merch', routeToListings: true),
    _Feature(icon: Icons.event, title: 'Fan Events', routeToListings: true),
  ];
}

class _Feature {
  final IconData icon;
  final String title;
  final bool routeToListings;
  final bool routeToTickets;

  const _Feature({
    required this.icon,
    required this.title,
    this.routeToListings = false,
    this.routeToTickets = false,
  });
}

class _FeaturedListing {
  final String title;
  final String image;
  final double price;

  const _FeaturedListing({
    required this.title,
    required this.image,
    required this.price,
  });
}

class _AvatarButton extends StatelessWidget {
  final String? userAvatar;
  final String userName;
  final String userEmail;

  const _AvatarButton({
    required this.userAvatar,
    required this.userName,
    required this.userEmail,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 12.0),
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MyAssetsScreen(
              userName: userName,
              userEmail: userEmail,
              userAvatar: userAvatar,
            ),
          ),
        ),
        child: CircleAvatar(
          radius: 18,
          backgroundImage: userAvatar != null &&
                  userAvatar!.isNotEmpty &&
                  Uri.tryParse(userAvatar!)?.hasAbsolutePath == true
              ? NetworkImage(userAvatar!)
              : null,
          child: userAvatar == null ||
                  userAvatar!.isEmpty ||
                  Uri.tryParse(userAvatar!)?.hasAbsolutePath != true
              ? const Icon(Icons.person, color: Colors.white, size: 20)
              : null,
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;

  const _SearchBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: TextField(
        controller: controller,
        decoration: const InputDecoration(
          hintText: 'Search categories...',
          hintStyle: TextStyle(color: Colors.grey, fontFamily: 'Poppins'),
          prefixIcon: Icon(Icons.search, color: Colors.white70),
          filled: true,
          fillColor: Color.fromRGBO(55, 71, 79, 1),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(30)),
            borderSide: BorderSide.none,
          ),
          contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        ),
        style: const TextStyle(color: Colors.white, fontFamily: 'Poppins'),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final Animation<double> animation;

  const _Banner({required this.animation});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 160,
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage('assets/marketplace_banner.png'),
          fit: BoxFit.cover,
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Container(
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color.fromRGBO(0, 0, 0, 0.7), Colors.transparent],
          ),
        ),
        alignment: Alignment.center,
        child: RepaintBoundary(
          child: FadeTransition(
            opacity: animation,
            child: const Text(
              'Spring Movie Sale!',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                fontFamily: 'Poppins',
                shadows: [
                  Shadow(
                    blurRadius: 4,
                    color: Colors.black54,
                    offset: Offset(2, 2),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  final String userName;
  final String userEmail;
  final Color accent;

  const _QuickActions({
    required this.userName,
    required this.userEmail,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _QuickActionButton(
            icon: Icons.add_circle,
            label: 'Sell Now',
            accent: accent,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TicketSalesScreen(
                  userName: userName,
                  userEmail: userEmail,
                ),
              ),
            ),
          ),
          _QuickActionButton(
            icon: Icons.shopping_cart,
            label: 'View Cart',
            accent: accent,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MarketplaceListingsScreen(
                  userName: userName,
                  userEmail: userEmail,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeaturedListingsSection extends StatelessWidget {
  final Color accent;
  final String userName;
  final String userEmail;

  const _FeaturedListingsSection({
    required this.accent,
    required this.userName,
    required this.userEmail,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Featured Listings', style: sectionTitleStyle),
          const SizedBox(height: 12),
          SizedBox(
            height: 180,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: MarketplaceHomeScreen.featuredListings.length,
              itemBuilder: (context, index) {
                final listing = MarketplaceHomeScreen.featuredListings[index];
                return RepaintBoundary(
                  child: _FeaturedListingCard(
                    listing: listing,
                    accent: accent,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TicketSalesScreen(
                          userName: userName,
                          userEmail: userEmail,
                        ),
                      ),
                    ),
                  ),
                );
              },
              separatorBuilder: (_, __) => const SizedBox(width: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final _Feature feature;
  final Color accent;
  final String userName;
  final String userEmail;

  const _FeatureCard({
    required this.feature,
    required this.accent,
    required this.userName,
    required this.userEmail,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (feature.routeToTickets) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TicketSalesScreen(
                userName: userName,
                userEmail: userEmail,
              ),
            ),
          );
        } else if (feature.routeToListings) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MarketplaceListingsScreen(
                userName: userName,
                userEmail: userEmail,
              ),
            ),
          );
        }
      },
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            decoration: const BoxDecoration(
              color: Color.fromARGB(160, 17, 25, 40),
              borderRadius: BorderRadius.all(Radius.circular(12)),
              border: Border.fromBorderSide(
                BorderSide(color: Color.fromRGBO(255, 255, 255, 0.12)),
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(feature.icon, size: 42, color: accent),
                const SizedBox(height: 12),
                Text(
                  feature.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    fontFamily: 'Poppins',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FeaturedListingCard extends StatelessWidget {
  final _FeaturedListing listing;
  final Color accent;
  final VoidCallback onTap;

  const _FeaturedListingCard({
    required this.listing,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 160,
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          color: Colors.grey.shade900,
          boxShadow: const [
            BoxShadow(
              color: Color.fromRGBO(0, 0, 0, 0.3),
              blurRadius: 8,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              child: Image.asset(
                listing.image,
                height: 100,
                width: double.infinity,
                fit: BoxFit.cover,
                cacheWidth: 300,
                errorBuilder: (context, error, stackTrace) => const SizedBox(
                  height: 100,
                  child: ColoredBox(
                    color: Color.fromRGBO(55, 71, 79, 1),
                    child: Icon(Icons.image_not_supported, color: Colors.white70),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    listing.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'Poppins',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '\$${listing.price.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      fontFamily: 'Poppins',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;

  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: accent.withOpacity(0.2),
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          border: Border.all(color: accent.withOpacity(0.5)),
        ),
        child: Row(
          children: [
            Icon(icon, color: accent, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFamily: 'Poppins',
              ),
            ),
          ],
        ),
      ),
    );
  }
}