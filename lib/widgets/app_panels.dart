import 'package:flutter/material.dart';

class AppPressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  final double pressedScale;

  const AppPressable({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.pressedScale = .985,
  });

  @override
  State<AppPressable> createState() => _AppPressableState();
}

class _AppPressableState extends State<AppPressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onTap == null) return widget.child;
    return AnimatedScale(
      scale: _pressed ? widget.pressedScale : 1,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      child: Material(
        color: Colors.transparent,
        borderRadius: widget.borderRadius,
        child: InkWell(
          borderRadius: widget.borderRadius,
          onTap: widget.onTap,
          onHighlightChanged: _setPressed,
          splashColor: const Color(0x2200838F),
          highlightColor: const Color(0x1100838F),
          child: widget.child,
        ),
      ),
    );
  }
}

class AppSoftCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color backgroundColor;
  final EdgeInsetsGeometry? margin;

  const AppSoftCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.backgroundColor = const Color(0xFFF8FAFC),
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class AppSectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const AppSectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF172033),
                ),
              ),
              if ((subtitle ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: const TextStyle(
                    color: Color(0xFF667085),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
  }
}

class AppMetaChip extends StatelessWidget {
  final IconData? icon;
  final String text;
  final Color backgroundColor;
  final Color borderColor;
  final Color foregroundColor;

  const AppMetaChip({
    super.key,
    this.icon,
    required this.text,
    this.backgroundColor = Colors.white,
    this.borderColor = const Color(0xFFE1E7EF),
    this.foregroundColor = const Color(0xFF364056),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: foregroundColor),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: TextStyle(
              color: foregroundColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class AppStatusPill extends StatelessWidget {
  final String text;
  final Color color;

  const AppStatusPill({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

ButtonStyle appGreenButtonStyle(BuildContext context) {
  const primary = Color(0xFF00838F);
  return FilledButton.styleFrom(
    backgroundColor: const Color(0xFFE3F2F0),
    foregroundColor: primary,
    iconColor: primary,
    side: const BorderSide(color: Color(0xFFB9DBD7)),
    textStyle: Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
  );
}

ButtonStyle appGreenOutlineButtonStyle(BuildContext context) {
  const primary = Color(0xFF00838F);
  return OutlinedButton.styleFrom(
    backgroundColor: Colors.white,
    foregroundColor: primary,
    side: const BorderSide(color: Color(0xFFB9DBD7)),
    textStyle: Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
  );
}

ButtonStyle appDangerOutlineButtonStyle(BuildContext context) {
  const danger = Color(0xFFB42318);
  return OutlinedButton.styleFrom(
    backgroundColor: Colors.white,
    foregroundColor: danger,
    side: const BorderSide(color: Color(0xFFF0C7C2)),
    textStyle: Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
  );
}
