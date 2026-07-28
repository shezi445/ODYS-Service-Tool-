import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'odys_theme.dart';

/// The ODYS gauge mark — the same geometry as the launcher icon, but painted
/// rather than rasterised so it stays crisp at any size and can carry a live
/// needle.
///
/// Angles here are canvas angles: measured clockwise from the positive x axis,
/// which is what `SweepGradient` and `Canvas.drawArc` both use. The sweep runs
/// from the lower left (130°) clockwise through the top to the lower right
/// (410°), so the needle reads like a real dial.
class OdysMark extends StatelessWidget {
  const OdysMark({
    super.key,
    this.size = 32,
    this.fraction,
    this.filled = false,
  });

  final double size;

  /// Needle position within the sweep, 0..1. Null holds the brand pose, which
  /// is where the launcher icon's needle sits.
  final double? fraction;

  /// Paints the dark dial behind the arc. Off by default: on a card the mark
  /// reads better as a floating gauge than as a coaster.
  final bool filled;

  static const double brandFraction = 0.625;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _OdysMarkPainter(
            fraction: (fraction ?? brandFraction).clamp(0.0, 1.0),
            filled: filled,
          ),
        ),
      );
}

class _OdysMarkPainter extends CustomPainter {
  const _OdysMarkPainter({required this.fraction, required this.filled});

  final double fraction;
  final bool filled;

  static const double _startRad = 130 * math.pi / 180;
  static const double _sweepRad = 280 * math.pi / 180;

  /// Enough segments that the tapering band reads as a smooth curve even when
  /// the mark is used at header size.
  static const int _steps = 96;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final radius = side * 0.360;
    final thin = side * 0.085;
    final thick = side * 0.185;

    if (filled) {
      final dial = Paint()
        ..shader = RadialGradient(
          colors: const [Color(0xff16233A), Color(0xff05080E)],
        ).createShader(
          Rect.fromCircle(center: center, radius: radius + thick),
        );
      canvas.drawCircle(center, radius + thick * 0.75, dial);
    }

    canvas.drawPath(
      _bandPath(center, radius, thin, thick),
      Paint()
        ..shader = const SweepGradient(
          startAngle: _startRad,
          endAngle: _startRad + _sweepRad,
          colors: [Color(0xff1C847C), AppColors.primary, Color(0xff7AECC0)],
          stops: [0.0, 0.55, 1.0],
          tileMode: TileMode.clamp,
        ).createShader(
          Rect.fromCircle(center: center, radius: radius + thick),
        )
        ..isAntiAlias = true,
    );

    _paintNeedle(canvas, center, side);
  }

  /// One closed path: outer edge forward, inner edge back, round caps added as
  /// circles. Filling a single tapered path avoids the seams a stack of stroked
  /// arc segments would show.
  Path _bandPath(Offset center, double radius, double thin, double thick) {
    final path = Path();
    Offset at(double angle, double r) =>
        center + Offset(math.cos(angle), math.sin(angle)) * r;

    for (var i = 0; i <= _steps; i++) {
      final t = i / _steps;
      final angle = _startRad + _sweepRad * t;
      final half = (thin + (thick - thin) * t) / 2;
      final point = at(angle, radius + half);
      i == 0 ? path.moveTo(point.dx, point.dy) : path.lineTo(point.dx, point.dy);
    }
    for (var i = _steps; i >= 0; i--) {
      final t = i / _steps;
      final angle = _startRad + _sweepRad * t;
      final half = (thin + (thick - thin) * t) / 2;
      final point = at(angle, radius - half);
      path.lineTo(point.dx, point.dy);
    }
    path.close();

    path.addOval(Rect.fromCircle(center: at(_startRad, radius), radius: thin / 2));
    path.addOval(Rect.fromCircle(
        center: at(_startRad + _sweepRad, radius), radius: thick / 2));
    return path;
  }

  void _paintNeedle(Canvas canvas, Offset center, double side) {
    final angle = _startRad + _sweepRad * fraction;
    final direction = Offset(math.cos(angle), math.sin(angle));
    final normal = Offset(-direction.dy, direction.dx);

    final length = side * 0.300;
    final tail = side * 0.070;
    final baseHalf = side * 0.036;
    final tipHalf = baseHalf * 0.38;

    // A blunt trapezoid rather than a spike: at 48 px a pointed needle
    // disappears into a single pixel of antialiasing.
    final blade = Path()
      ..moveTo(
        center.dx + direction.dx * length + normal.dx * tipHalf,
        center.dy + direction.dy * length + normal.dy * tipHalf,
      )
      ..lineTo(
        center.dx + direction.dx * length - normal.dx * tipHalf,
        center.dy + direction.dy * length - normal.dy * tipHalf,
      )
      ..lineTo(
        center.dx - direction.dx * tail - normal.dx * baseHalf,
        center.dy - direction.dy * tail - normal.dy * baseHalf,
      )
      ..lineTo(
        center.dx - direction.dx * tail + normal.dx * baseHalf,
        center.dy - direction.dy * tail + normal.dy * baseHalf,
      )
      ..close();

    canvas.drawPath(
      blade,
      Paint()
        ..color = const Color(0xffEAF1F8)
        ..isAntiAlias = true,
    );
    canvas.drawCircle(
      center,
      side * 0.054,
      Paint()..color = const Color(0xffEAF1F8),
    );
    canvas.drawCircle(
      center,
      side * 0.030,
      Paint()..color = AppColors.surface,
    );
  }

  @override
  bool shouldRepaint(covariant _OdysMarkPainter old) =>
      old.fraction != fraction || old.filled != filled;
}

/// Shared page header: the mark, the product name, the page title and an
/// optional trailing action. Replaces the bare title text each page used to
/// carry, so the four tabs read as one product.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.trailing,
    this.needleFraction,
  });

  final String title;
  final Widget? trailing;

  /// Drives the mark's needle. Feeding live speed in makes the logo the
  /// smallest speedometer in the app.
  final double? needleFraction;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          children: [
            OdysMark(size: 40, fraction: needleFraction),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('ODYS SERVICE TOOL',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textDim,
                        letterSpacing: 1.7,
                      )),
                  const SizedBox(height: 1),
                  Text(title,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text,
                        letterSpacing: -0.5,
                        height: 1.05,
                      )),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}
