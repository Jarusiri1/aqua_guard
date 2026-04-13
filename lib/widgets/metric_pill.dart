import 'package:flutter/material.dart';

class MetricPill extends StatelessWidget {
  final String label;
  final String valueText;
  final Color color;
  final double borderRadius;
  final Color? textColor; // สีตัวหนังสือ (ส่งสีแดงเมื่อค่าผิดปกติ)

  const MetricPill({
    super.key,
    required this.label,
    required this.valueText,
    required this.color,
    this.borderRadius = 8,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 132,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(valueText, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: textColor)),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(color: textColor?.withOpacity(0.7) ?? Colors.black54)),
        ],
      ),
    );
  }
}
