import 'package:flutter/material.dart';

class AppSkeletonLoader extends StatefulWidget {
  final EdgeInsetsGeometry padding;
  final int count;

  const AppSkeletonLoader({
    super.key,
    this.padding = const EdgeInsets.all(16),
    this.count = 5,
  });

  @override
  State<AppSkeletonLoader> createState() => _AppSkeletonLoaderState();
}

class _AppSkeletonLoaderState extends State<AppSkeletonLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final x = -1.2 + (_pulse.value * 2.4);
        final gradient = LinearGradient(
          begin: Alignment(x - 1, 0),
          end: Alignment(x + 1, 0),
          colors: const [
            Color(0xFFE0E0E0),
            Color(0xFFF7F7F7),
            Color(0xFFE0E0E0),
          ],
        );
        return ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: widget.padding,
          itemCount: widget.count,
          separatorBuilder: (_, __) => const SizedBox(height: 14),
          itemBuilder: (_, index) => _SkeletonCard(
            gradient: gradient,
            surface: surface,
            imageHeight: index == 0 ? 120 : 72,
          ),
        );
      },
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  final Gradient gradient;
  final Color surface;
  final double imageHeight;

  const _SkeletonCard({
    required this.gradient,
    required this.surface,
    required this.imageHeight,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SkeletonBlock(height: imageHeight, gradient: gradient),
          const SizedBox(height: 14),
          _SkeletonBlock(height: 22, widthFactor: .72, gradient: gradient),
          const SizedBox(height: 10),
          _SkeletonBlock(height: 14, gradient: gradient),
          const SizedBox(height: 8),
          _SkeletonBlock(height: 14, widthFactor: .58, gradient: gradient),
        ],
      ),
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  final double height;
  final double widthFactor;
  final Gradient gradient;

  const _SkeletonBlock({
    required this.height,
    required this.gradient,
    this.widthFactor = 1,
  });

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}
