import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';

class MovieCard extends StatefulWidget {
  final String imageUrl;
  final String title;
  final double? rating;
  final VoidCallback? onTap;
  final double width;
  final bool showOverlay;

  const MovieCard({
    super.key,
    required this.imageUrl,
    required this.title,
    this.rating,
    this.onTap,
    this.width = 120,
    this.showOverlay = true,
  });

  factory MovieCard.fromJson(
    Map<String, dynamic> json, {
    VoidCallback? onTap,
    double width = 120,
    bool showOverlay = true,
  }) {
    String title = json['title'] ??
        json['name'] ??
        json['original_title'] ??
        json['original_name'] ??
        'No Title';

    String imagePath = json['poster_path'] ?? json['backdrop_path'] ?? '';
    String imageUrl = imagePath.isNotEmpty
        ? 'https://image.tmdb.org/t/p/w500$imagePath'
        : 'https://via.placeholder.com/500x750?text=No+Image';

    double? rating;
    if (json['vote_average'] != null) {
      rating = (json['vote_average'] as num).toDouble();
    }

    return MovieCard(
      imageUrl: imageUrl,
      title: title,
      rating: rating,
      onTap: onTap,
      width: width,
      showOverlay: showOverlay,
    );
  }

  @override
  State<MovieCard> createState() => _MovieCardState();
}

class _MovieCardState extends State<MovieCard> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onShowFocusHighlight: (focus) => setState(() => _isFocused = focus),
      autofocus: false,
      mouseCursor: SystemMouseCursors.click,
      onFocusChange: (focus) => setState(() => _isFocused = focus),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          margin: const EdgeInsets.all(8.0),
          width: widget.width,
          decoration: BoxDecoration(
            border: Border.all(
              color: _isFocused
                  ? Colors.amberAccent.withOpacity(0.9)
                  : Colors.transparent,
              width: 2.5,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: AspectRatio(
            aspectRatio: 1 / 1.5,
            child: Card(
              clipBehavior: Clip.antiAlias,
              elevation: _isFocused ? 16 : 10,
              shadowColor: _isFocused
                  ? Colors.amber.withOpacity(0.5)
                  : const Color.fromARGB(123, 245, 0, 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    imageUrl: widget.imageUrl,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => Shimmer.fromColors(
                      baseColor: Colors.grey[800]!,
                      highlightColor: Colors.grey[600]!,
                      child: Container(
                        color: Colors.grey[800],
                      ),
                    ),
                    errorWidget: (context, url, error) => Container(
                      color: Colors.grey,
                      child: const Center(
                        child: Icon(Icons.error, color: Colors.red),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.center,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  const Color.fromARGB(139, 159, 170, 0)
                                      .withOpacity(0.8),
                                  Colors.transparent,
                                ],
                                stops: const [0.5, 1.0],
                              ),
                            ),
                          ),
                          Icon(
                            Icons.play_circle_filled,
                            color: Colors.white.withOpacity(0.9),
                            size: 50,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (widget.showOverlay)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.black.withOpacity(0.9),
                              Colors.black.withOpacity(0.7),
                              Colors.transparent,
                            ],
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            stops: const [0.0, 0.5, 1.0],
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.title.isNotEmpty)
                              Text(
                                widget.title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            if (widget.rating != null)
                              Row(
                                children: [
                                  const Icon(Icons.star,
                                      color: Colors.yellow, size: 14),
                                  const SizedBox(width: 4),
                                  Text(
                                    widget.rating!.toStringAsFixed(1),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
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
