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

const double kBtnHeight = 56.0;

//ใส่ URL HLS จาก MediaMTX ของ Raspberry Pi
const String kHlsUrl = 'http://192.168.1.109:8888/tank/index.m3u8';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Tank? _selectedTank = mockTanks.first;

  bool _loading = false;

  
  bool _realtime = false;
  Duration _interval = const Duration(seconds: 2);
  Timer? _timer;

  double? _ph, _tempC, _turbidity; // ค่าเซนเซอร์
  bool? _phSensorActive; // สถานะว่า pH sensor อ่านค่าได้หรือไม่
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

  @override
  void initState() {
    super.initState();
    _initVideo();

    // ดึงข้อมูลครั้งแรก + ensure device
    Future.microtask(() async {
      final t = _selectedTank;
      if (t != null) {
        await TankService.ensureDeviceInitialized(t.id); // <<< สำคัญ
      }
      await _refreshAll();
      
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _video?.dispose();
    super.dispose();
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

    // --- 2. Turbidity Calculation (Verified: Water Clear -> 0.0 NTU) ---
    final double? turbidityVolt = _toDoubleLoose(latest['turbidity']);
    double? calculatedNtu;

    if (turbidityVolt != null) {
      double vClear = 1.15;  // จุดอ้างอิงน้ำใส
      double vPepsi = 0.70;  // จุดอ้างอิงน้ำขุ่น
      double ntuPepsi = 100.0; 

      if (turbidityVolt >= vClear) {
        calculatedNtu = 0.0;
      } else {
        double slope = (ntuPepsi - 0) / (vPepsi - vClear);
        calculatedNtu = slope * (turbidityVolt - vClear);
      }
      
      if (calculatedNtu! < 2.0) calculatedNtu = 0; // ตัด noise ต่ำๆ
      if (calculatedNtu > 3000) calculatedNtu = 3000;
    }

    // --- 3. Sync Other Status ---
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

  } catch (e) {
    debugPrint('Error in _refreshAll: $e');
  } finally {
    if (mounted) setState(() => _loading = false);
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tank = _selectedTank;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Aqua Guard', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'การแจ้งเตือน',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsPage())),
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
                    value: _selectedTank,
                    isExpanded: true,
                    items: mockTanks
                        .map((t) => DropdownMenuItem(value: t, child: Text(t.name)))
                        .toList(),
                    onChanged: (t) async {
                      setState(() => _selectedTank = t);
                      if (t != null) {
                        await TankService.ensureDeviceInitialized(t.id); // <<< สำคัญ
                      }
                      await _refreshAll();
                      if (_realtime) _startRealtime();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // สวิตช์ Real-time + เลือกช่วงเวลา
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
                    DropdownMenuItem(value: Duration(seconds: 2), child: Text('2s')),
                    DropdownMenuItem(value: Duration(seconds: 5), child: Text('5s')),
                    DropdownMenuItem(value: Duration(seconds: 10), child: Text('10s')),
                  ],
                  onChanged: (d) {
                    if (d == null) return;
                    setState(() => _interval = d);
                    if (_realtime) _startRealtime();
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),

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
                                onPressed: _toggleMute,
                                icon: Icon(_muted ? Icons.volume_off : Icons.volume_up, color: Colors.white),
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
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: _reconnectVideo,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reconnect video'),
                ),
              ),
            ],

            const SizedBox(height: 24),

            // ====== Metrics 2 คอลัมน์ ======
            GridView.count(
              crossAxisCount: 2,
              crossAxisSpacing: 18,
              mainAxisSpacing: 18,
              childAspectRatio: 2.2,
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
                ),
                MetricPill(
                  color: cs.secondaryContainer.withOpacity(0.6),
                  label: 'Temperature',
                  valueText: _loading ? '…' : (_tempC != null ? '${_tempC!.toStringAsFixed(0)} °C' : '-'),
                ),

                // แถว 2: Turbid | Water Level
                MetricPill(
                  color: cs.secondaryContainer.withOpacity(0.6),
                  label: 'Turbidity',
                  valueText: _loading
                      ? '…'
                      : (_turbidity != null ? '${_turbidity!.toStringAsFixed(3)} NTU' : '-'),
                ),
                MetricPill(
                  color: (_levelLow == true)
                      ? Theme.of(context).colorScheme.errorContainer.withOpacity(0.7)
                      : cs.secondaryContainer.withOpacity(0.6),
                  label: 'Water Level',
                  valueText: _loading ? '…' : _waterLevelText(),
                ),

                // แถว 3: moving | not moving
                MetricPill(
                  color: cs.secondaryContainer.withOpacity(0.6),
                  label: 'Moving',
                  valueText: _loading ? '…' : (_moving?.toString() ?? '-'),
                ),
                MetricPill(
                  color: cs.secondaryContainer.withOpacity(0.6),
                  label: 'No Moving',
                  valueText: _loading ? '…' : (_noMoving?.toString() ?? '-'),
                ),
              ],
            ),

            const SizedBox(height: 18),

            // ปุ่มเปลี่ยนน้ำกึ่งกลาง ขนาดเท่าช่องในกริด
            LayoutBuilder(
              builder: (context, constraints) {
                const crossAxisSpacing = 18.0;   // ต้องตรงกับค่าที่ใช้ในกริด
                const columns = 2;
                const childAspectRatio = 2.2;    // ต้องตรงกับกริดด้วย

                final cellWidth  = (constraints.maxWidth - crossAxisSpacing) / columns;
                final cellHeight = cellWidth / childAspectRatio;

                // --- Logic เปลี่ยนสีและข้อความตามสถานะปั๊ม ---
                Color statusColor = cs.tertiaryContainer.withOpacity(0.6);
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
                      onTap: _selectedTank == null
                          ? null
                          : () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => WaterChangePage(tank: _selectedTank!),
                                ),
                              );
                            },
                      child: MetricPill(
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
