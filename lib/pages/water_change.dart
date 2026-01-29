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

  // เพิ่มตัวแปรนี้: เอาไว้เก็บสถานะ "หลอก" เพื่อให้ UI เปลี่ยนทันที
  String? _optimisticPhase; 
  Timer? _optimisticResetTimer;

  @override
  void initState() {
    super.initState();
    TankService.ensureDeviceInitialized(widget.tank.id).catchError((e) {
      debugPrint('seed error: $e');
    });

    _sub = TankService.streamWaterStatus(widget.tank.id).listen(
      (data) {
        if (!mounted) return;
        
        // ถ้าสถานะจริงจาก Pi ส่งมาตรงกับที่เรา "หลอก" ไว้แล้ว
        // ให้ยกเลิกการหลอก แล้วใช้ค่าจริงแทน (UI จะได้ไม่กระพริบ)
        if (_optimisticPhase != null) {
           final realPhase = data['phase'];
           if (realPhase == _optimisticPhase) {
             _optimisticPhase = null; // สถานะตรงกันแล้ว เลิกหลอก
           }
        }
        
        setState(() => _status = data);
      },
      onError: (e) => debugPrint('water stream error: $e'),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _optimisticResetTimer?.cancel();
    super.dispose();
  }

  Future<void> _send(String cmd, {bool confirm = false}) async {
    if (_sending) return;

    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('ยืนยันการสั่งงาน'),
          content: Text('ต้องการสั่ง “$cmd” ใช่หรือไม่?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('ยกเลิก')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('ยืนยัน')),
          ],
        ),
      );
      if (ok != true) return;
    }

    // 1. ตั้งค่า Optimistic Phase (เปลี่ยนสีปุ่มทันที ไม่ต้องรอเน็ต)
    setState(() {
      _sending = true;
      if (cmd == 'drain') {
        _optimisticPhase = 'draining';
      } else if (cmd == 'fill') _optimisticPhase = 'filling';
      else if (cmd == 'stop') _optimisticPhase = 'idle';
    });

    // กันเหนียว: ถ้าผ่านไป 5 วิ แล้ว Pi ยังไม่ตอบสนอง ให้เลิกหลอก (กัน UI ค้าง)
    _optimisticResetTimer?.cancel();
    _optimisticResetTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _optimisticPhase = null);
    });

    try {
      await TankService
          .sendWaterCommand(widget.tank.id, cmd)
          .timeout(const Duration(seconds: 8));
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ส่งคำสั่ง $cmd แล้ว')));
      
    } on TimeoutException {
      if (!mounted) return;
      // ถ้าส่งไม่ผ่าน ให้ยกเลิกสถานะหลอก
      setState(() => _optimisticPhase = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ช้าเกินไป: โปรดตรวจอินเทอร์เน็ต')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _optimisticPhase = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ส่งคำสั่งล้มเหลว: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _phaseText(dynamic phase) {
    switch ('$phase') {
      case 'draining': return 'กำลังระบายน้ำออก';
      case 'filling':  return 'กำลังเติมน้ำเข้า';
      case 'done':     return 'เสร็จสิ้น';
      case 'error':    return 'ผิดพลาด';
      case 'idle':
      default:         return 'พร้อมทำงาน (Idle)';
    }
  }

  Color _phaseColor(ColorScheme cs, dynamic phase) {
    switch ('$phase') {
      case 'draining': return Colors.orange;
      case 'filling':  return Colors.blue;
      case 'done':     return Colors.green;
      case 'error':    return cs.error;
      case 'idle':
      default:         return cs.secondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // --- LOGIC การแสดงผลแบบ Instant ---
    // ใช้ค่าจาก _optimisticPhase (ถ้ามี) มาแสดงก่อน ถ้าไม่มีค่อยใช้ค่าจริงจาก _status
    final realPhase = _status['phase'] ?? 'idle';
    final displayPhase = _optimisticPhase ?? realPhase;

    // สถานะปุ่ม: ให้ดูว่า Optimistic สั่งอะไรไว้ หรือ ค่าจริงเป็นยังไง
    final bool isDrainActive = displayPhase == 'draining' || _status['pumpDrainOn'] == true;
    final bool isFillActive = displayPhase == 'filling' || _status['pumpFillOn'] == true;

    final turbidity = _status['turbidity'] as num?;
    final updatedAt = _status['updatedAt'] as DateTime?;
    final isFresh = updatedAt != null && DateTime.now().difference(updatedAt).inSeconds <= 15;

    // Logic Sensor (คงเดิมจากรอบที่แล้ว)
    final bool rawLow = _status['levelHigh'] == true;    
    final bool rawNormal = _status['levelLow'] == true;  
    final bool showNormal = rawNormal;
    final bool showLow = rawLow && !rawNormal; // ไฟ Low ดับเมื่อถึง Normal
    final bool isLowWarning = !rawLow;

    return Scaffold(
      appBar: AppBar(
        title: Text('เปลี่ยนน้ำ • ${widget.tank.name}', overflow: TextOverflow.ellipsis),
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: [
              // Header ใช้ displayPhase (ค่าที่ตอบสนองทันที)
              Row(
                children: [
                  Icon(Icons.water_drop, color: _phaseColor(cs, displayPhase)),
                  const SizedBox(width: 8),
                  Text(
                    'สถานะการทำงาน',
                    style: Theme.of(context).textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _phaseColor(cs, displayPhase).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _phaseColor(cs, displayPhase).withOpacity(0.4)),
                    ),
                    child: Text(
                      _phaseText(displayPhase),
                      style: TextStyle(
                        color: _phaseColor(cs, displayPhase),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

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

              // Chips ใช้ isDrainActive / isFillActive (ตอบสนองทันที)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip(cs, 'Pump Drain', isDrainActive, Icons.arrow_downward, activeColor: Colors.orange),
                  _chip(cs, 'Pump Fill', isFillActive, Icons.arrow_upward, activeColor: Colors.blue),
                  Chip(
                    avatar: const Icon(Icons.opacity, size: 18),
                    label: Text('Turbidity: ${turbidity?.toStringAsFixed(3) ?? '-'}'),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _level(cs, 'ระดับต่ำ (LOW)', showLow, isWarning: isLowWarning),
                  _level(cs, 'ระดับปกติ (NORMAL)', showNormal),
                ],
              ),
              const SizedBox(height: 24),

              const Divider(),
              const SizedBox(height: 10),
              
              Text('ควบคุม (Manual Mode)', 
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: cs.primary)),
              const SizedBox(height: 16),

              // ปุ่มควบคุม
              Row(
                children: [
                  // ปุ่ม Drain
                  Expanded(
                    child: OutlinedButton.icon(
                      // ป้องกันการกดซ้อน: ถ้ากำลังส่ง หรือ Fill ทำงานอยู่ ห้ามกด
                      onPressed: (_sending || isFillActive) ? null : () => _send('drain'),
                      icon: const Icon(Icons.arrow_downward),
                      label: Text(isDrainActive ? 'กำลังระบาย...' : 'Drain (ระบายออก)'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        // ใช้ isDrainActive เพื่อเปลี่ยนสีทันที
                        backgroundColor: isDrainActive ? Colors.orange.withOpacity(0.15) : null,
                        side: isDrainActive ? const BorderSide(color: Colors.orange, width: 2) : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // ปุ่ม Fill
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (_sending || isDrainActive) ? null : () => _send('fill'),
                      icon: const Icon(Icons.arrow_upward),
                      label: Text(isFillActive ? 'กำลังเติม...' : 'Fill (เติมเข้า)'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        // ใช้ isFillActive เพื่อเปลี่ยนสีทันที
                        backgroundColor: isFillActive ? Colors.blue.withOpacity(0.15) : null,
                        side: isFillActive ? const BorderSide(color: Colors.blue, width: 2) : null,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              
              // ปุ่ม STOP
              FilledButton.icon(
                onPressed: _sending ? null : () => _send('stop', confirm: false),
                icon: const Icon(Icons.stop_circle_outlined, size: 28),
                label: const Text('STOP (หยุดทุกอย่าง)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(64),
                  backgroundColor: cs.error,
                  foregroundColor: cs.onError,
                ),
              ),

              if (!isFresh)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Center(
                     child: Text('ข้อมูลไม่อัปเดต (ตรวจสอบ Pi)', style: TextStyle(color: cs.error))
                  ),
                ),
            ],
          ),
          
          if (_sending)
            Positioned.fill(
              child: Container(
                color: Colors.black12,
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Chip _chip(ColorScheme cs, String label, bool on, IconData icon, {Color? activeColor}) {
    final color = activeColor ?? Colors.green;
    return Chip(
      avatar: Icon(icon, size: 18, color: on ? Colors.white : cs.onSurfaceVariant),
      label: Text(label),
      backgroundColor: on ? color : cs.surfaceContainerHighest,
      labelStyle: TextStyle(color: on ? Colors.white : cs.onSurfaceVariant),
      side: BorderSide.none,
    );
  }

  Widget _level(ColorScheme cs, String label, bool on, {bool isWarning = false}) {
    Color iconColor;
    if (isWarning) {
      iconColor = cs.error;
    } else if (on) {
      iconColor = Colors.green;
    } else {
      iconColor = cs.onSurfaceVariant.withOpacity(0.5);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isWarning ? Icons.warning_amber_rounded : (on ? Icons.radio_button_checked : Icons.radio_button_unchecked),
          size: 20,
          color: iconColor,
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: isWarning ? cs.error : cs.onSurfaceVariant,
            fontWeight: (on || isWarning) ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  String _fmtTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}