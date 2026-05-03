import 'package:flutter/material.dart';

class AppExpandableCard extends StatefulWidget {
  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final List<Widget> children;
  final bool initiallyExpanded;
  final Color backgroundColor;
  final Color expandedColor;
  final Color borderColor;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry headerPadding;
  final EdgeInsetsGeometry childrenPadding;

  const AppExpandableCard({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.leading,
    this.trailing,
    this.initiallyExpanded = true,
    this.backgroundColor = Colors.white,
    this.expandedColor = const Color(0xFFEAF7F5),
    this.borderColor = const Color(0xFFE2EAED),
    this.margin = const EdgeInsets.only(bottom: 10),
    this.headerPadding = const EdgeInsets.fromLTRB(14, 12, 10, 12),
    this.childrenPadding = const EdgeInsets.fromLTRB(14, 0, 14, 14),
  });

  @override
  State<AppExpandableCard> createState() => _AppExpandableCardState();
}

class _AppExpandableCardState extends State<AppExpandableCard> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      margin: widget.margin,
      decoration: BoxDecoration(
        color: _expanded ? widget.expandedColor : widget.backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: widget.borderColor),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: widget.headerPadding,
                  child: Row(
                    children: [
                      if (widget.leading != null) ...[
                        widget.leading!,
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            widget.title,
                            if (widget.subtitle != null) ...[
                              const SizedBox(height: 3),
                              widget.subtitle!,
                            ],
                          ],
                        ),
                      ),
                      if (widget.trailing != null) ...[
                        const SizedBox(width: 8),
                        widget.trailing!,
                      ],
                      AnimatedRotation(
                        turns: _expanded ? .5 : 0,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        child: const Icon(Icons.keyboard_arrow_down, size: 22),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedCrossFade(
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Padding(
                  padding: widget.childrenPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: widget.children,
                  ),
                ),
                crossFadeState: _expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 160),
                sizeCurve: Curves.easeOutCubic,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
