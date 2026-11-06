import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../utils/image_url.dart';

/// Network image with a warm placeholder + graceful error fallback.
/// Uses [CachedNetworkImage] so images persist on disk and load instantly on
/// repeat visits (offline-first friendly).
///
/// Loads first through [thumbUrl] (a width-capped, CDN-optimised rewrite).
/// If that fails for any reason — a host not respecting the transformation,
/// a transient network hiccup, a very new asset whose URL shape differs — it
/// retries once with the raw URL before giving up and showing the placeholder.
class AppImage extends StatefulWidget {
  const AppImage(
    this.url, {
    super.key,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.borderRadius,
    this.icon = Icons.chair_outlined,
    this.targetWidth,
  });

  final String? url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final IconData icon;

  /// Pixel width to request from the image host — see [thumbUrl]. A card does
  /// not need the seller's 4 MB original, and downloading it is why a feed of
  /// Supabase-hosted photos used to sit on the placeholder forever. Leave null
  /// only where the full-size image is the point, such as a zoomable gallery.
  final int? targetWidth;

  @override
  State<AppImage> createState() => _AppImageState();
}

enum _LoadStage {
  /// Trying the width-capped/rewritten URL first.
  thumb,

  /// Thumb failed — retrying the stored URL exactly as-is.
  raw,

  /// Both attempts failed; show the placeholder icon.
  failed,
}

class _AppImageState extends State<AppImage> {
  _LoadStage _stage = _LoadStage.thumb;

  String? _urlFor(_LoadStage stage) {
    switch (stage) {
      case _LoadStage.thumb:
        return thumbUrl(widget.url, width: widget.targetWidth);
      case _LoadStage.raw:
        return widget.url;
      case _LoadStage.failed:
        return null;
    }
  }

  @override
  void didUpdateWidget(covariant AppImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new URL must restart the attempt ladder; leaving [_stage] pinning the
    // "failed" state would show the placeholder forever for a changed image.
    if (oldWidget.url != widget.url ||
        oldWidget.targetWidth != widget.targetWidth) {
      _stage = _LoadStage.thumb;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = Container(
      width: widget.width,
      height: widget.height,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(widget.icon, size: 32, color: theme.colorScheme.outline),
    );

    if (widget.url == null || widget.url!.isEmpty) return placeholder;

    final displayUrl = _urlFor(_stage);
    if (displayUrl == null || displayUrl.isEmpty) return placeholder;

    Widget image = CachedNetworkImage(
      // Evict caches when falling back so a poisoned thumb entry (e.g. a 404
      // response cached by an older release) does not shadow the raw URL.
      cacheKey: _stage == _LoadStage.thumb ? displayUrl : '$displayUrl#raw',
      imageUrl: displayUrl,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      // Bound the decoded bitmap too, not just the download: a 4000x3000 JPEG
      // decodes to ~48 MB in memory, which on a mid-range Android device is
      // enough for the image to be dropped and the placeholder to stay put.
      memCacheWidth: widget.targetWidth,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) {
        if (_stage == _LoadStage.thumb) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _stage = _LoadStage.raw);
          });
        }
        return placeholder;
      },
    );

    if (widget.borderRadius != null) {
      image = ClipRRect(borderRadius: widget.borderRadius!, child: image);
    }
    return image;
  }
}
