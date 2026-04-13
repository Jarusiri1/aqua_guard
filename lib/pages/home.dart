import 'dart:async';
import 'package:flutter/material.dart';
//import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:video_player/video_player.dart';

import '../models/tank.dart';
import '../services/tank_service.dart';
import '../widgets/metric_pill.dart';
import 'profile.dart';
import 'notification.dart';
import 'water_change.dart'; // หน้าควบคุมเปลี่ยนน้ำ
import 'dashboard.dart';

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_messaging/firebase_messaging.dart';

const double kBtnHeight = 56.0;

//ใส่ URL HLS จาก MediaMTX ของ Raspberry Pi
const String kHlsUrl = 'https://camera.aquaguardproject.me/tank/index.m3u8';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Tank> _myTanks = []; // เก็บรายการตู้ของผู้ใช้
  Tank? _selectedTank;      // ตู้ที่เลือกอยู่ (เริ่มต้นเป็น null)
  Map<String, DateTime> _lastLineNotifyTimes = {};

  // ตัวควบคุมช่องกรอกข้อความสำหรับเพิ่มตู้
  final TextEditingController _snController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();

  bool _loading = false;
  
  bool _realtime = false;
  Duration _interval = const Duration(seconds: 5);
  Timer? _timer;

  // Auto-refill: เติมน้ำอัตโนมัติ 5 วิ เมื่อ float switch ตก
  bool _autoFilling = false;
  Timer? _autoFillTimer;

  // Auto water-change: เปลี่ยนน้ำอัตโนมัติเมื่อน้ำขุ่น (drain → พัก → fill)
  bool _isWaterChanging = false;
  Timer? _waterChangeTimer;
  DateTime? _lastWaterChangeTime; // cooldown 5 นาที กัน trigger ซ้ำ

  double? _ph, _tempC, _turbidity; // ค่าเซนเซอร์
  bool? _phSensorActive; // สถานะว่า pH sensor อ่านค่าได้ไม
  int? _moving, _noMoving;

  // >>> Water level flags
  bool? _levelLow;

  // ---- Video Player ----
  VideoPlayerController? _video;
  Future<void>? _videoInit;
  bool _muted = true;

  String? _phase; // เก็บค่า 'idle', 'draining', 'filling'
  bool? _pumpDrainOn;
  bool? _pumpFillOn;

  // Real-time listener สำหรับ float switch (ตอบสนองทันที)
  StreamSubscription<Map<String, dynamic>>? _waterSub;

  @override
  void initState() {
    super.initState();
    _initVideo();

    // เรียกฟังก์ชันโหลดข้อมูลตู้
    _loadMyTanks(); 
  }

  @override
  void dispose() {
    _timer?.cancel();
    _autoFillTimer?.cancel();
    _waterChangeTimer?.cancel();
    _waterSub?.cancel();
    _video?.dispose();
    super.dispose();
  }

  //โหลดข้อมูลตู้
  Future<void> _loadMyTanks() async {
    setState(() => _loading = true);
    try {
      final tanks = await TankService.getMyTanks();
      setState(() {
        _myTanks = tanks;
        // ถ้ามีselectedTank ยู่แล้วให้หาตัวใหม่ที่ idตรงกัน
        if (_selectedTank != null) {
          final match = tanks.where((t) => t.id == _selectedTank!.id);
          _selectedTank = match.isNotEmpty ? match.first : null;
        }
        // ถ้ายังไม่ได้เลือกตู้ไหน ให้เลือกตู้แรก
        if (_selectedTank == null && tanks.isNotEmpty) {
          _selectedTank = tanks.first;
        }
      });
      // ถ้าเลือกตู้ได้แล้ว ให้ไปดึงค่า Sensor มาโชว์
      if (_selectedTank != null) {
        await TankService.ensureDeviceInitialized(_selectedTank!.id);
        _subscribeWaterStream(_selectedTank!.id); // ฟัง float switch แบบ real-time
        await _refreshAll();
      }
    } catch (e) {
      debugPrint('Error loading tanks: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  //ฟังกแสดงหน้เพิ่มตู้ต้อง
  void _showAddTankDialog() {
    _snController.clear();
    _nameController.clear();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('เพิ่มตู้ใหม่'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _snController,
                decoration: const InputDecoration(
                  labelText: 'Serial Number',
                  hintText: 'เช่น TANK-f2ff8a3e',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'ตั้งชื่อตู้',
                  hintText: 'เช่น ตู้ห้องรับแขก',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('ยกเลิก'),
            ),
            FilledButton(
              onPressed: () async {
                if (_snController.text.trim().isEmpty) return;
                try {
                  // เรียก Service ผูกตู้
                  await TankService.linkTankToUser(
                    _snController.text.trim(), 
                    _nameController.text.trim()
                  );
                  Navigator.pop(context);
                  _loadMyTanks(); // โหลดรายการใหม่
                  if (mounted) {
                     ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('เพิ่มตู้สำเร็จ!')),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('เกิดข้อผิดพลาด: $e')),
                    );
                  }
                }
              },
              child: const Text('บันทึก'),
            ),
          ],
        );
      },
    );
  }


  // ===== Helpers =====
  bool? _toBoolLoose(dynamic v) {
    if (v == null) return null;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().toLowerCase();
    return (s == 'true' || s == '1' || s == 'yes' || s == 'on');
  }

  double? _toDoubleLoose(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  dynamic _getNested(Map<String, dynamic> map, String path) {
    var cur = map;
    for (final part in path.split('.')) {
      final v = cur[part];
      if (v is Map<String, dynamic>) {
        cur = v;
      } else {
        return v;
      }
    }
    return cur;
  }

  String _waterLevelText() {
    if (_levelLow == true) return 'ปกติ';
    return 'ต่ำ';
  }

  /// ฟัง float switch แบบ real-time ผ่าน Firestore stream
  /// เมื่อ Pi อัปเดตค่า levelLow ลง Firestore แอปจะรับทันทีไม่ต้องรอ poll
  void _subscribeWaterStream(String tankId) {
    _waterSub?.cancel();
    _waterSub = TankService.streamWaterStatus(tankId).listen(
      (data) {
        if (!mounted) return;
        final newLevelLow = data['levelLow'] == true;
        final oldLevelLow = _levelLow;

        setState(() {
          _levelLow = newLevelLow;
          _phase = data['phase']?.toString() ?? _phase;
          _pumpDrainOn = data['pumpDrainOn'] == true;
          _pumpFillOn = data['pumpFillOn'] == true;
        });

        // ถ้าเพิ่งเปลี่ยนจากปกติ → น้ำต่ำ ให้ auto-fill ทันที
        // แต่ถ้ากำลังเปลี่ยนน้ำอยู่ (drain→fill) ให้ข้ามไป ไม่งั้นจะเติมซ้ำ
        if (!newLevelLow && oldLevelLow != false && !_isWaterChanging) {
          _showTopBanner('⚠️ ระดับน้ำต่ำ', 'ตรวจพบน้ำระดับต่ำ กำลังเติมน้ำอัตโนมัติ...', isDanger: true);
          _triggerAutoFill();
        }
      },
      onError: (e) => debugPrint('waterStream error: $e'),
    );
  }
  
Future<void> _refreshAll() async {
  final tank = _selectedTank;
  if (tank == null) return;

  setState(() => _loading = true);
  try {
    final latest = await TankService.bumpAndFetchLatest(
      tank.id,
      timeout: const Duration(seconds: 8),
      minWait: const Duration(milliseconds: 1500),
    );

    // --- 1. pH Calculation (Verified: 2.374V -> pH 7.7) ---
    final double? pHvoltRaw = _toDoubleLoose(latest['pHvolt']);
    double? calculatedPh;
    bool phActive = false;

    if (pHvoltRaw != null && pHvoltRaw > 0.1) {
      double neutralV = 2.5; 
      double sensitivity = 0.18; 
      // สูตร: 7 - (V_raw - V_neutral) / Sensitivity
      double cal = 7.0 - (pHvoltRaw - neutralV) / sensitivity;
      calculatedPh = cal.clamp(0.0, 14.0);
      phActive = true;
    }

    // -Turbidity Calculation (Verified: Water Clear -> 0.0 NTU
    final double? turbidityVolt = _toDoubleLoose(latest['turbidity']);
    double? calculatedNtu;

    if (turbidityVolt != null) {
      double vClear = 1.80;  //ค่าน้ำปกติที่เคยได้มา
      double vPepsi = 0.70;  
      double ntuClear = 12.5; 
      double ntuPepsi = 100.0; 

      if (turbidityVolt >= vClear) {
        calculatedNtu = ntuClear - ((turbidityVolt - vClear) * 15.0);
        if (calculatedNtu < 8.2) calculatedNtu = 8.2; 
      } else {
        double slope = (ntuPepsi - ntuClear) / (vPepsi - vClear);
        calculatedNtu = ntuClear + slope * (turbidityVolt - vClear);
      }
      
      if (calculatedNtu! > 3000) calculatedNtu = 3000;
    }

    // --ซิงStatusอื่น 
    setState(() {
      _ph = calculatedPh;
      _phSensorActive = phActive;
      _turbidity = calculatedNtu;
      _tempC = _toDoubleLoose(latest['tempC']);
      _levelLow = _toBoolLoose(latest['levelLow']);
      _phase = latest['phase']?.toString() ?? 'idle';
      _pumpDrainOn = _toBoolLoose(latest['pumpDrainOn']);
      _pumpFillOn = _toBoolLoose(latest['pumpFillOn']);
      _moving = latest['moving'] as int?;
      _noMoving = latest['noMoving'] as int?;
    });

    debugPrint('Final UI Update -> pH: ${_ph?.toStringAsFixed(2)}, NTU: ${_turbidity?.toStringAsFixed(1)}');

    // บันทึกลง log สำหรับ Dashboard history
    TankService.logSensorReading(
      tank.id,
      ph: _ph,
      tempC: _tempC,
      turbidity: _turbidity,
      levelLow: _levelLow,
    );

     // จุดที่เพิ่มเข้ามา: สั่งให้ Pop-up เด้งตรงนี้
    if (_phSensorActive == true && _ph != null) {
      if (_ph! < 6.5 || _ph! > 8.0) {
        _showTopBanner("⚠️ คุณภาพน้ำผิดปกติ", "ค่า pH อยู่ที่ ${_ph!.toStringAsFixed(1)} (ควรอยู่ระหว่าง 6.5-8.0)", isDanger: true);
      }
    }

    if (_turbidity != null && _turbidity! > 100) {
      _showTopBanner("⚠️ ตรวจพบน้ำขุ่น", "ค่าความขุ่นสูงผิดปกติ: ${_turbidity!.toStringAsFixed(1)} NTU", isDanger: true);
      // สั่งเปลี่ยนน้ำอัตโนมัติ (drain → พัก → fill)
      _triggerAutoWaterChange();
    }

    // เติมน้ำอัตโนมัติเมื่อ float switch ตก
    // แต่ถ้ากำลังเปลี่ยนน้ำอยู่ ให้ข้ามไป (ไม่งั้น fill จะซ้ำกับ drain)
    if (_levelLow == false && !_isWaterChanging) { 
       _showTopBanner("⚠️ ระดับน้ำต่ำ", "กรุณาเติมน้ำเพื่อความปลอดภัยของปลา", isDanger: true);
       _triggerAutoFill();
    }
    

  } catch (e) {
    debugPrint('Error in _refreshAll: $e');
  } finally {
    if (mounted) setState(() => _loading = false);
  }
}


  /// เติมน้ำอัตโนมัติ 5 วินาที เมื่อ float switch ตรวจจับน้ำระดับต่ำ
  Future<void> _triggerAutoFill() async {
    // กัน trigger ซ้ำ: ถ้ากำลังเติมอยู่แล้ว หรือกำลังเปลี่ยนน้ำอยู่ จะไม่ทำซ้ำ
    if (_autoFilling || _isWaterChanging) return;
    final tank = _selectedTank;
    if (tank == null) return;

    setState(() => _autoFilling = true);

    try {
      // สั่ง fill
      await TankService.sendWaterCommand(tank.id, 'fill');
      debugPrint('🔵 Auto-fill started for ${tank.id}');

      _showTopBanner(
        'เติมน้ำอัตโนมัติ',
        'ตรวจพบน้ำระดับต่ำ กำลังเติมน้ำ 5 วินาที...',
        isDanger: false,
      );

      // ตั้ง Timer 5 วิ แล้วสั่ง stop
      _autoFillTimer?.cancel();
      _autoFillTimer = Timer(const Duration(seconds: 5), () async {
        try {
          await TankService.sendWaterCommand(tank.id, 'stop');
          debugPrint('Auto-fill stopped for ${tank.id}');
          if (mounted) {
            _showTopBanner(
              'เติมน้ำเสร็จแล้ว',
              'ระบบเติมน้ำอัตโนมัติ 5 วินาที เสร็จสิ้น',
              isDanger: false,
            );
          }
        } catch (e) {
          debugPrint('Auto-fill stop error: $e');
        } finally {
          if (mounted) setState(() => _autoFilling = false);
        }
      });
    } catch (e) {
      debugPrint('Auto-fill start error: $e');
      if (mounted) setState(() => _autoFilling = false);
    }
  }

  /// เปลี่ยนน้ำอัตโนมัติเมื่อ turbidity สูง: drain 10 วิ → พัก 3 วิ → fill 10 วิ
  Future<void> _triggerAutoWaterChange() async {
    // กัน trigger ซ้ำ
    if (_isWaterChanging || _autoFilling) return;
    final tank = _selectedTank;
    if (tank == null) return;

    // Cooldown: ไม่เปลี่ยนน้ำซ้ำภายใน 5 นาที (นับจากรอบล่าสุดเสร็จ)
    final now = DateTime.now();
    if (_lastWaterChangeTime != null &&
        now.difference(_lastWaterChangeTime!).inMinutes < 5) {
      debugPrint('Water change skipped: cooldown active');
      return;
    }
    // ไม่ตั้ง _lastWaterChangeTime ตรงนี้ → ย้ายไปตั้งตอนเสร็จสิ้น (Step 4)

    setState(() => _isWaterChanging = true);

    try {
      // ===== Step 1: DRAIN 10 วินาที =====
      await TankService.sendWaterCommand(tank.id, 'drain');
      debugPrint('🔵 Water change: DRAIN started');
      _showTopBanner(
        'เปลี่ยนน้ำ: ระบายน้ำออก',
        'ตรวจพบน้ำขุ่น — กำลังระบายน้ำออก (10 วิ)...',
        isDanger: false,
      );

      _waterChangeTimer?.cancel();
      _waterChangeTimer = Timer(const Duration(seconds: 10), () async {
        if (!mounted) { _isWaterChanging = false; return; }
        try {
          // ===== Step 2: หยุด drain → พัก 3 วินาที =====
          await TankService.sendWaterCommand(tank.id, 'stop');
          debugPrint('Water change: DRAIN stopped, pausing 3s...');
          if (mounted) {
            _showTopBanner(
              'เปลี่ยนน้ำ: ระบายเสร็จ',
              'ระบายน้ำเสร็จ — รอ 3 วินาที...',
              isDanger: false,
            );
          }

          _waterChangeTimer = Timer(const Duration(seconds: 3), () async {
            if (!mounted) { _isWaterChanging = false; return; }
            try {
              // ===== Step 3: FILL 10 วินาที =====
              await TankService.sendWaterCommand(tank.id, 'fill');
              debugPrint('🔵 Water change: FILL started');
              if (mounted) {
                _showTopBanner(
                  'เปลี่ยนน้ำ: เติมน้ำใหม่',
                  'กำลังเติมน้ำใหม่ (10 วิ)...',
                  isDanger: false,
                );
              }

              _waterChangeTimer = Timer(const Duration(seconds: 10), () async {
                if (!mounted) { _isWaterChanging = false; return; }
                try {
                  // ===== Step 4: STOP → เสร็จสิ้น =====
                  await TankService.sendWaterCommand(tank.id, 'stop');
                  debugPrint('Water change: COMPLETE ');
                  if (mounted) {
                    _lastWaterChangeTime = DateTime.now(); // เริ่มนับ cooldown ตอนเสร็จ
                    _showTopBanner(
                      'เปลี่ยนน้ำ: เสร็จสิ้น',
                      'ระบบเปลี่ยนน้ำอัตโนมัติเสร็จสิ้น (drain → fill)',
                      isDanger: false,
                    );
                    setState(() => _isWaterChanging = false);
                  }
                } catch (e) {
                  debugPrint('Water change fill-stop error: $e');
                  if (mounted) setState(() => _isWaterChanging = false);
                }
              });
            } catch (e) {
              debugPrint('Water change fill-start error: $e');
              if (mounted) setState(() => _isWaterChanging = false);
            }
          });
        } catch (e) {
          debugPrint('Water change drain-stop error: $e');
          if (mounted) setState(() => _isWaterChanging = false);
        }
      });
    } catch (e) {
      debugPrint('Water change drain-start error: $e');
      if (mounted) setState(() => _isWaterChanging = false);
    }
  }

  void _startRealtime() {
    _timer?.cancel();
    _refreshAll(); // ดึงทันที 1 รอบก่อนเริ่มนับเวลา
    _timer = Timer.periodic(_interval, (_) => _refreshAll());
  }

  void _stopRealtime() {
    _timer?.cancel();
    _timer = null;
  }

  void _toggleRealtime(bool value) {
    setState(() => _realtime = value);
    if (_realtime) {
      _startRealtime();
    } else {
      _stopRealtime();
    }
  }

  // ===== Video handling =====
  void _initVideo() {
    // 1. เคลียร์ตัวเก่าออกก่อนป้องกัน Memory Leak
    _video?.dispose();

    // 2. สร้าง Controller ใหม่
    _video = VideoPlayerController.networkUrl(
      Uri.parse(kHlsUrl),
      httpHeaders: const {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1',
      },

      formatHint: VideoFormat.hls,
      
      videoPlayerOptions: VideoPlayerOptions(
        mixWithOthers: true,
        allowBackgroundPlayback: false,
      ),
    );

    // 3. เริ่มต้นการทำงาน (Initialize)
    _videoInit = _video!.initialize().then((_) async {
      await _video!.setLooping(true);
      await _video!.setVolume(_muted ? 0.0 : 1.0);
      await _video!.play();

      // 4. [สำคัญ] เพิ่มระบบเช็คการ "ค้าง" ทุกๆ 2 วินาที
      // ถ้าวิดีโอโหลดเสร็จแล้วแต่หยุดเล่นเอง (โดยที่ไม่ได้กด Pause) ให้สั่ง Play ใหม่ทันที
      Timer.periodic(const Duration(seconds: 2), (timer) {
        if (!mounted || _video == null) {
          timer.cancel();
          return;
        }

        final value = _video!.value;
        // ถ้า initialized แล้ว, ไม่ได้เล่นอยู่, ไม่ได้บัฟเฟอร์ และไม่มี Error
        if (value.isInitialized && 
            !value.isPlaying && 
            !value.isBuffering && 
            !value.hasError) {
          debugPrint("Video stalled, forcing play...");
          _video!.play();
        }
      });

      if (mounted) setState(() {});
    }).catchError((e) {
      debugPrint('Video init error: $e');
      // ถ้าโหลดไม่สำเร็จ ให้ลองโหลดใหม่หลังจาก 5 วินาที
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) _initVideo();
      });
    });

    setState(() {});
  }

  void _togglePlay() {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    setState(() {
      v.value.isPlaying ? v.pause() : v.play();
    });
  }

  Future<void> _toggleMute() async {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    setState(() => _muted = !_muted);
    await v.setVolume(_muted ? 0.0 : 1.0);
  }

  Future<void> _reconnectVideo() async {
    _initVideo();
  }

  // เพิ่มฟังก์ชันนี้เข้าไปใน Class _HomePageState
void _confirmDeleteTank(Tank tank) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('ยืนยันการลบตู้'),
      content: Text('คุณต้องการลบตู้ "${tank.name}" ออกจากการดูแลใช่หรือไม่?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('ยกเลิก'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          onPressed: () async {
            Navigator.pop(context); // ปิดหน้าต่างถาม
            setState(() => _loading = true);
            try {
              // เรียกคำสั่งลบจาก Service
              await TankService.unlinkTankFromUser(tank.id);
              
              setState(() {
                _selectedTank = null; // ล้างตู้ที่เลือกอยู่
              });
              
              await _loadMyTanks(); // โหลดรายการตู้ใหม่
              
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('ลบตู้สำเร็จแล้ว')),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('ลบไม่สำเร็จ: $e')),
                );
              }
            } finally {
              if (mounted) setState(() => _loading = false);
            }
          },
          child: const Text('ลบตู้'),
        ),
      ],
    ),
  );
}

void _showTopBanner(String title, String message, {bool isDanger = false}) async {
    // Show in-app standard SnackBar
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$title\n$message', style: const TextStyle(color: Colors.white)),
          backgroundColor: isDanger ? Colors.redAccent : Colors.blueAccent,
          duration: const Duration(seconds: 4),
        ),
      );
    }

    // Rate limit LINE API (max once per 60 secs PER ALERT TYPE)
    final now = DateTime.now();
    final lastTime = _lastLineNotifyTimes[title];
    if (lastTime != null && now.difference(lastTime).inSeconds < 60) {
      return;
    }
    _lastLineNotifyTimes[title] = now;

    const String token = 'TmG88rn5QfmfMerx1cMCISCTcJ3OA7pxZUcUtDccW9UkZDATTfwurIDIZT7ua6ws51gLBwFGweSvLE4yNFAWYC0GzMeKK8IMn+fys2YV82GWiQdW87KAUEaWq/p/dA7mBoFr9iu3VuXOJ9vO1H7ymgdB04t89/1O/w1cDnyilFU=';
    const String url = 'https://api.line.me/v2/bot/message/broadcast';

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'messages': [
            {
              'type': 'text',
              'text': '$title\n$message'
            }
          ]
        }),
      );
      if (response.statusCode != 200) {
        debugPrint('LINE API Error: ${response.statusCode} ${response.body}');
      } else {
        debugPrint('LINE API Sent successfully');
      }
    } catch (e) {
      debugPrint('LINE API Exception: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tank = _selectedTank;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Aqua Guard', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'Dashboard',
            onPressed: tank == null
                ? null
                : () {
                    final t = _selectedTank;
                    if (t == null) return;
                    Navigator.push(context, MaterialPageRoute(builder: (_) => DashboardPage(tank: t)));
                  },
            icon: const Icon(Icons.dashboard_outlined),
          ),
          // เพิ่มปุ่มนี้เข้าไป
          IconButton(
            tooltip: 'เพิ่มตู้ใหม่',
            onPressed: _showAddTankDialog,
            icon: const Icon(Icons.add_circle_outline),
          ),
          IconButton(
            tooltip: 'การแจ้งเตือน',
            onPressed: tank == null
                ? null // ถ้ายังไม่ได้เลือกตู้ จะกดปุ่มนี้ไม่ได้ (ป้องกัน Error)
                : () {
                    final t = _selectedTank;
                    if (t == null) return;
                    //  ส่ง ID ของตู้ปัจจุบันไปให้หน้า NotificationsPage ทำงานต่อ
                    Navigator.push(
                      context, 
                      MaterialPageRoute(
                        builder: (_) => NotificationsPage(tankId: t.id),
                      ),
                    );
                  },
            icon: const Icon(Icons.notifications_none),
          ),
          IconButton(
            tooltip: 'โปรไฟล์',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfilePage())),
            icon: const Icon(Icons.person_outline),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // เลือกตู้
            Row(
              children: [
                const Text('เลือกตู้: ', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                Expanded(

                  child: DropdownButton<Tank>(
                    value: _myTanks.contains(_selectedTank) ? _selectedTank : null, // แก้ปัญหา Dropdown ล่ม
                    isExpanded: true,

                    hint: const Text('ยังไม่มีตู้ (กด + มุมขวาบน)'),

                    // 2. เปลี่ยนจาก mockTanks เป็น _myTanks
                    items: _myTanks.map((t) {
                      return DropdownMenuItem(value: t, child: Text(t.name));
                    }).toList(),
                    // -----------------------------
                    onChanged: (t) async {

                      if (_selectedTank != null) {
                        await FirebaseMessaging.instance.unsubscribeFromTopic(_selectedTank!.id);
                      }

                      setState(() => _selectedTank = t);
                      if (t != null) {
                        await TankService.ensureDeviceInitialized(t.id); // <<< สำคัญ
                        _subscribeWaterStream(t.id); // ฟัง float switch แบบ real-time

                        await FirebaseMessaging.instance.subscribeToTopic(t.id);
                        debugPrint('ติดตามการแจ้งเตือนตู้: ${t.id} สำเร็จ');
                      }
                      await _refreshAll();
                      if (_realtime) _startRealtime();
                    },
                  ),
                ),
                if (tank != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () {
                    final t = _selectedTank;
                    if (t != null) _confirmDeleteTank(t);
                  },
                  tooltip: 'ลบตู้นี้ออก',
                ),
              ],
            ),
            const SizedBox(height: 8),

            // สวิตช์ Real-time + เลือกช่วงเวลา
            /*Row(
              children: [
                Expanded(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Real-time', style: TextStyle(fontWeight: FontWeight.w700)),
                    value: _realtime,
                    onChanged: _toggleRealtime,
                  ),
                ),
                DropdownButton<Duration>(
                  value: _interval,
                   items: const [
                    DropdownMenuItem(value: Duration(seconds: 5), child: Text('5s')),
                    DropdownMenuItem(value: Duration(seconds: 10), child: Text('10s')),
                    DropdownMenuItem(value: Duration(seconds: 30), child: Text('30s')),
                    DropdownMenuItem(value: Duration(minutes: 1), child: Text('1m')),
                    DropdownMenuItem(value: Duration(minutes: 3), child: Text('3m')),
                  ],
                  onChanged: (d) {
                    if (d == null) return;
                    setState(() => _interval = d);
                    if (_realtime) _startRealtime();
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),*/

            // ====== วิดีโอเรียลไทม์จาก Raspberry Pi Camera (HLS) ======
            if (tank != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: AspectRatio(
                  aspectRatio: _video?.value.isInitialized == true
                      ? _video!.value.aspectRatio
                      : 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      FutureBuilder(
                        future: _videoInit,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState != ConnectionState.done) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          if (_video == null || !_video!.value.isInitialized) {
                            return Container(
                              color: Colors.black12,
                              alignment: Alignment.center,
                              child: const Text('โหลดสตรีมไม่สำเร็จ'),
                            );
                          }
                          return VideoPlayer(_video!);
                        },
                      ),
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                onPressed: _togglePlay,
                                icon: Icon(
                                  (_video?.value.isPlaying ?? false) ? Icons.pause : Icons.play_arrow,
                                  color: Colors.white,
                                ),
                              ),
                              IconButton(
                                onPressed: _reconnectVideo,
                                icon: const Icon(Icons.refresh, color: Colors.white),
                                tooltip: 'Reconnect',
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              //Align(
                //alignment: Alignment.centerRight,
                //child: OutlinedButton.icon(
                  //onPressed: _reconnectVideo,
                  //icon: const Icon(Icons.refresh),
                  //label: const Text('Reconnect video'),
                //),
              //),
            ],

            const SizedBox(height: 24),

            Row(
              children: [
                Expanded(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Real-time', style: TextStyle(fontWeight: FontWeight.w700)),
                    value: _realtime,
                    onChanged: _toggleRealtime,
                  ),
                ),
                DropdownButton<Duration>(
                  value: _interval,
                  items: const [
                    DropdownMenuItem(value: Duration(seconds: 5), child: Text('5s')),
                    DropdownMenuItem(value: Duration(seconds: 10), child: Text('10s')),
                    DropdownMenuItem(value: Duration(seconds: 30), child: Text('30s')),
                    DropdownMenuItem(value: Duration(minutes: 1), child: Text('1m')),
                    DropdownMenuItem(value: Duration(minutes: 3), child: Text('3m')),
                  ],
                  onChanged: (d) {
                    if (d == null) return;
                    setState(() => _interval = d);
                    if (_realtime) _startRealtime();
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ====== Metrics 2 คอลัมน์ ======
            GridView.count(
              crossAxisCount: 2,
              crossAxisSpacing: 18,
              mainAxisSpacing: 18,
              childAspectRatio: 2.0,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                // แถว 1: PH | Temp
                MetricPill(
                  color: cs.secondaryContainer.withOpacity(0.6),
                  label: 'PH',
                  valueText: _loading 
                      ? '…' 
                      : (_phSensorActive == false 
                          ? 'none' 
                          : (_ph?.toStringAsFixed(1) ?? 'none')),
                  textColor: (!_loading && _phSensorActive == true && _ph != null && (_ph! < 6.5 || _ph! > 8.0))
                      ? Colors.red
                      : null,
                ),
                MetricPill(
                  color: cs.secondaryContainer.withOpacity(0.6),
                  label: 'Temperature',
                  valueText: _loading ? '…' : (_tempC != null ? '${_tempC!.toStringAsFixed(0)} °C' : '-'),
                  textColor: (!_loading && _tempC != null && (_tempC! < 22 || _tempC! > 28))
                      ? Colors.red
                      : null,
                ),

                // แถว 2: Turbid | Water Level
                MetricPill(
                  color: cs.secondaryContainer.withOpacity(0.6),
                  label: 'Turbidity',
                  valueText: _loading
                      ? '…'
                      : (_turbidity != null ? '${_turbidity!.toStringAsFixed(3)} NTU' : '-'),
                  textColor: (!_loading && _turbidity != null && _turbidity! > 100)
                      ? Colors.red
                      : null,
                ),
                MetricPill(
                  color: (_levelLow == false)
                      ? Theme.of(context).colorScheme.errorContainer.withOpacity(0.7)
                      : cs.secondaryContainer.withOpacity(0.6),
                  label: 'Water Level',
                  valueText: _loading ? '…' : _waterLevelText(),
                  textColor: (!_loading && _levelLow == false)
                      ? Colors.red
                      : null,
                ),

              ],
            ),

            const SizedBox(height: 18),

            // ปุ่มเปลี่ยนน้ำกึ่งกลาง ขนาดเท่าช่องในกริด
            LayoutBuilder(
              builder: (context, constraints) {
                const crossAxisSpacing = 18.0;   // ต้องตรงกับค่าที่ใช้ในกริด
                const columns = 2;
                const childAspectRatio = 2.0;    // ต้องตรงกับกริดด้วย

                final cellWidth  = (constraints.maxWidth - crossAxisSpacing) / columns;
                final cellHeight = cellWidth / childAspectRatio;

                // --- Logic เปลี่ยนสีและข้อความตามสถานะปั๊ม ---
                Color statusColor = Colors.orange.shade200.withOpacity(0.8);
                String statusLabel = 'เปลี่ยนน้ำ';
                String statusValue = 'กดเพื่อทำงาน';

                if (_phase == 'draining' || (_pumpDrainOn == true)) {
                  statusColor = Colors.orange.withOpacity(0.8); // สีส้มตอนถ่ายน้ำ
                  statusLabel = 'กำลังทำงาน';
                  statusValue = 'ระบายน้ำออก...';
                } else if (_phase == 'filling' || (_pumpFillOn == true)) {
                  statusColor = Colors.blue.withOpacity(0.8);   // สีฟ้าตอนเติมน้ำ
                  statusLabel = 'กำลังทำงาน';
                  statusValue = 'เติมน้ำเข้า...';
                }

                return Center(
                  child: SizedBox(
                    width: cellWidth,
                    height: cellHeight,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: tank == null
                          ? null
                          : () {
                              final t = _selectedTank;
                              if (t == null) return;
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => WaterChangePage(tank: t),
                                ),
                              );
                            },
                      child: MetricPill(
                        borderRadius: 999,
                        color: statusColor,   // ใช้สีที่เปลี่ยนตามสถานะ
                        label: statusLabel,   // ข้อความเปลี่ยนตามสถานะ
                        valueText: statusValue, 
                      ),
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 24),

            // ปุ่ม Refresh
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _loading ? null : _refreshAll,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kBtnHeight)),
                child: const Text('Refresh'),
              ),
            ),
            
            // Loading Bar
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
