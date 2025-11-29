import 'dart:async';
import 'package:flutter/material.dart';
import '../models/tank.dart';
import '../services/tank_service.dart';

class WaterChangePage extends StatefulWidget {
  final Tank tank;
  const WaterChangePage({super.key, required this.tank});

  @override
  State<WaterChangePage> createState() => _WaterChangePageState();
}

class _WaterChangePageState extends State<WaterChangePage> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  Map<String, dynamic> _status = const {};
  bool _sending = false;

  @override
  void initState() {
    super.initState();

    // สร้าง devices/{id} และ ctrl/waterChange อัตโนมัติถ้ายังไม่มี
    TankService.ensureDeviceInitialized(widget.tank.id).catchError((e) {
      debugPrint('seed error: $e');
    });

    _sub = TankService.streamWaterStatus(widget.tank.id).listen(
      (data) {
        if (!mounted) return;
        setState(() => _status = data);
      },
      onError: (e) => debugPrint('water stream error: $e'),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _send(String cmd, {bool confirm = false}) async {
    if (_sending) return;

    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('ยืนยันการสั่งงาน'),
          content: Text('สั่ง “$cmd” ไปยัง ${widget.tank.name}?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('ยกเลิก')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('ยืนยัน')),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _sending = true);
    try {
      await TankService
          .sendWaterCommand(widget.tank.id, cmd)
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ส่งคำสั่ง $cmd แล้ว')));
    } on TimeoutException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ช้าเกินไป: โปรดตรวจอินเทอร์เน็ตหรือสิทธิ์ Firestore')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ส่งคำสั่งล้มเหลว: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _phaseText(dynamic phase) {
    switch ('$phase') {
      case 'draining':
        return 'กำลังระบายน้ำออก';
      case 'filling':
        return 'กำลังเติมน้ำเข้า';
      case 'done':
        return 'เสร็จสิ้น';
      case 'error':
        return 'ผิดพลาด';
      case 'idle':
      default:
        return 'พร้อมทำงาน (Idle)';
    }
  }

  Color _phaseColor(ColorScheme cs, dynamic phase) {
    switch ('$phase') {
      case 'draining':
        return Colors.orange;
      case 'filling':
        return Colors.blue;
      case 'done':
        return Colors.green;
      case 'error':
        return cs.error;
      case 'idle':
      default:
        return cs.secondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final phase = _status['phase'] ?? 'idle';
    final pumpDrainOn = _status['pumpDrainOn'] == true;
    final pumpFillOn = _status['pumpFillOn'] == true;
    final levelLow = _status['levelLow'] == true;
    final levelHigh = _status['levelHigh'] == true;
    final turbidity = _status['turbidity'] as num?;
    final updatedAt = _status['updatedAt'] as DateTime?;
    final isFresh = updatedAt != null && DateTime.now().difference(updatedAt).inSeconds <= 10;

    return Scaffold(
      appBar: AppBar(
        title: Text('เปลี่ยนน้ำ • ${widget.tank.name}', overflow: TextOverflow.ellipsis),
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: [
              // หัวข้อ + สถานะ + เวลาล่าสุด
              Row(
                children: [
                  Icon(Icons.water_drop, color: _phaseColor(cs, phase)),
                  const SizedBox(width: 8),
                  Text(
                    'การเปลี่ยนน้ำ',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge!
                        .copyWith(fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _phaseColor(cs, phase).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _phaseColor(cs, phase).withOpacity(0.4)),
                    ),
                    child: Text(
                      _phaseText(phase),
                      style: TextStyle(
                        color: _phaseColor(cs, phase),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // แสดงความสด + เวลาอัปเดตล่าสุด
              Row(
                children: [
                  Icon(Icons.circle, size: 10, color: isFresh ? Colors.green : cs.error),
                  const SizedBox(width: 6),
                  Text(
                    updatedAt == null
                        ? 'ยังไม่เคยอัปเดต'
                        : 'อัปเดตล่าสุด: ${_fmtTime(updatedAt)}',
                    style: TextStyle(
                      color: isFresh ? cs.onSurfaceVariant : cs.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ชิปสถานะ
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip(cs, 'Pump Drain', pumpDrainOn, Icons.arrow_downward),
                  _chip(cs, 'Pump Fill', pumpFillOn, Icons.arrow_upward),
                  Chip(
                    avatar: const Icon(Icons.opacity, size: 18),
                    label: Text(
                      'Turbidity: ${turbidity == null ? '-' : turbidity.toStringAsFixed(3)}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Float switch
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _level(cs, 'ระดับต่ำ (LOW)', levelLow),
                  _level(cs, 'ระดับสูง (HIGH)', levelHigh),
                ],
              ),
              const SizedBox(height: 18),

              // ปุ่มควบคุม
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _sending ? null : () => _send('start', confirm: true),
                      icon: const Icon(Icons.play_circle),
                      label: const Text('Start (Auto)'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _sending ? null : () => _send('drain'),
                      icon: const Icon(Icons.arrow_downward),
                      label: const Text('Drain'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _sending ? null : () => _send('fill'),
                      icon: const Icon(Icons.arrow_upward),
                      label: const Text('Fill'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _sending ? null : () => _send('stop', confirm: true),
                      icon: const Icon(Icons.stop_circle),
                      label: const Text('Stop'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48)),
                    ),
                  ),
                ],
              ),

              // คำเตือนถ้าข้อมูลไม่สด
              if (!isFresh)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.errorContainer.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: cs.onErrorContainer),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'ข้อมูลไม่อัปเดต (อาจหลุดจาก Pi/เน็ต) ตรวจสคริปต์บน Raspberry Pi',
                            style: TextStyle(
                              color: cs.onErrorContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),

          // Overlay โหลดขณะส่งคำสั่ง
          if (_sending)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.08),
                child: const Center(
                  child: Card(
                    elevation: 6,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 3)),
                          SizedBox(width: 12),
                          Text('กำลังส่งคำสั่ง...',
                              style: TextStyle(fontWeight: FontWeight.w700)),
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

  Chip _chip(ColorScheme cs, String label, bool on, IconData icon) {
    return Chip(
      avatar: Icon(icon, size: 18, color: on ? Colors.white : cs.onSurfaceVariant),
      label: Text(label),
      backgroundColor: on ? Colors.green : cs.surfaceVariant,
      labelStyle: TextStyle(color: on ? Colors.white : cs.onSurfaceVariant),
    );
  }

  Widget _level(ColorScheme cs, String label, bool on) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(on ? Icons.sensors : Icons.sensors_off,
            size: 18, color: on ? Colors.green : cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: cs.onSurfaceVariant)),
      ],
    );
  }

  String _fmtTime(DateTime dt) {
    // HH:mm:ss (local)
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
