import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'; // debugPrint

class TankService {
  static final _db = FirebaseFirestore.instance;

  // ---------- Utilities ----------
  static double? _asDouble(dynamic x) {
    if (x == null) return null;
    if (x is num) return x.toDouble();
    return double.tryParse(x.toString());
  }

  static int? _asInt(dynamic x) {
    if (x == null) return null;
    if (x is int) return x;
    if (x is num) return x.toInt();
    return int.tryParse(x.toString());
  }

  // ========= Bootstrapping =========
  /// เรียกครั้งเดียว (หรือทุกครั้งที่เปิดหน้า) เพื่อให้มั่นใจว่ามี doc/โครงสร้างพื้นฐาน
  static Future<void> ensureDeviceInitialized(String tankId) async {
    // ต้องมีผู้ใช้ก่อน (rules เช็ค owner)
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }
    final uid = FirebaseAuth.instance.currentUser!.uid;

    final devRef = _db.collection('devices').doc(tankId);

    // สร้าง devices/{tankId} ถ้ายังไม่มี
    await _db.runTransaction((tx) async {
      final snap = await tx.get(devRef);
      if (!snap.exists) {
        tx.set(devRef, {
          'ownerUid': uid,
          'mode': 'manual',
          // ค่าเริ่มต้นให้หน้า Home อ่านได้
          'ph': 7.5,
          'tempC': 28,
          'moving': 0,
          'noMoving': 0,
          'status': {
            'phase': 'idle',
            'pumpDrainOn': false,
            'pumpFillOn': false,
            'levelLow': false,
            'levelHigh': false,
            'turbidity': 0,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          'config': {
            'turbidityThreshold': 800,
            'maxDrainSeconds': 300,
            'maxFillSeconds': 420,
          },
        });
      }
    });

    // เตรียมเอกสารคำสั่งต่าง ๆ ใต้ ctrl
    await Future.wait([
      // ควบคุมเปลี่ยนน้ำ
      devRef.collection('ctrl').doc('waterChange').set({
        'request': 'idle',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)),

      //จุดสั่งให้วัด turbidity แบบ on-demand (daemon ฝั่ง Pi ฟังเอกสารนี้)
      devRef.collection('ctrl').doc('sense').set({
        'nonce': 0,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)),
      // +++ NEW: จุดสั่งอ่านระดับน้ำแบบ on-demand
devRef.collection('ctrl').doc('levels').set({
  'nonce': 0,
  'updatedAt': FieldValue.serverTimestamp(),
}, SetOptions(merge: true)),

    ]);
  }

  // ========= Read metrics (ปกติ) =========
  /// อ่านค่า metric ปัจจุบันจาก devices/{tankId}
  static Future<Map<String, dynamic>> fetchLatest(String tankId) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) throw Exception('not-signed-in');

  final ref = _db.collection('devices').doc(tankId);
  try {
    final snap = await ref.get();
    if (!snap.exists) throw Exception('device-not-found: $tankId');

    T? _get<T>(String path) {
      try {
        final v = snap.get(path);
        return v is T ? v : null;
      } catch (_) {
        return null;
      }
    }

    final d = snap.data() ?? <String, dynamic>{};
    final s = (d['status'] ?? const {}) as Map<String, dynamic>;

    final num? phFromStatus = _get<num>('status.ph');
    final num? pHvolt       = _get<num>('status.pHvolt');

    return {
      // ใช้ค่าใต้ status ก่อน ถ้าไม่มีค่อย fallback ไป top-level
      'ph'       : _asDouble(phFromStatus ?? pHvolt ?? d['ph']),
      'pHvolt'   : _asDouble(pHvolt),
      'tempC'    : _asDouble(_get<num>('status.tempC') ?? d['tempC']),
      'moving'   : _asInt(d['moving']) ?? 0,
      'noMoving' : _asInt(d['noMoving']) ?? 0,
      'turbidity': _asDouble(_get<num>('status.turbidity') ?? s['turbidity']),

      'levelLow' : _get<bool>('status.levelLow')  ?? (s['levelLow']  == true),
      'levelHigh': _get<bool>('status.levelHigh') ?? (s['levelHigh'] == true),

      'updatedAt': (_get<Timestamp>('status.updatedAt') ?? s['updatedAt'] as Timestamp?)?.toDate(),
    };
  } on FirebaseException {
    rethrow;
  }
}


  // ========= On-demand turbidity =========
  /// บั้มป์ nonce เพื่อสั่ง Pi ให้วัด turbidity 1 ครั้ง
  static Future<void> requestTurbidityOnce(String tankId) async {
    final ref = _db
        .collection('devices')
        .doc(tankId)
        .collection('ctrl')
        .doc('sense');

    await ref.set({
      'nonce': FieldValue.increment(1),
      'requestedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // +++ NEW
static Future<void> requestLevelsOnce(String tankId) async {
  final ref = _db
      .collection('devices')
      .doc(tankId)
      .collection('ctrl')
      .doc('levels');

  await ref.set({
    'nonce': FieldValue.increment(1),
    'requestedAt': FieldValue.serverTimestamp(),
    'updatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
}


  /// สั่งวัด แล้ว "รอจนได้ค่าใหม่" (updatedAt เปลี่ยน) ภายใน timeout
  /// ใช้ในปุ่ม Refresh แทนการ delay ตายตัว จะเนียนและแม่นกว่า
  static Future<Map<String, dynamic>> bumpAndFetchLatest(
  String tankId, {
  Duration timeout = const Duration(seconds: 6),
  Duration minWait = const Duration(milliseconds: 300),
}) async {
  final docRef = _db.collection('devices').doc(tankId);

  // อ่าน timestamp ปัจจุบัน (ใช้เป็นเส้นตายว่าต้องได้ค่าใหม่กว่า)
  DateTime before = DateTime.now().toUtc().subtract(const Duration(milliseconds: 150));
  try {
    final curr = await docRef.get();
    try {
      final ts = curr.get('status.updatedAt') as Timestamp;
      before = ts.toDate().toUtc().subtract(const Duration(milliseconds: 50));
    } catch (_) {}
  } catch (_) {}

  // สั่งวัด: turbidity/tempC/pH + water levels
  await Future.wait([
    requestTurbidityOnce(tankId),
    requestLevelsOnce(tankId),
  ]);

  // เว้นระยะสั้น ๆ ให้ daemon ทำงาน
  await Future.delayed(minWait);

  try {
    final snap = await docRef
        .snapshots()
        .timeout(timeout)
        .firstWhere((s) {
          try {
            final ts = s.get('status.updatedAt') as Timestamp;
            return ts.toDate().toUtc().isAfter(before);
          } catch (_) {
            return false;
          }
        });

    T? _get<T>(String path) {
      try {
        final v = snap.get(path);
        return v is T ? v : null;
      } catch (_) {
        return null;
      }
    }

    final d = snap.data() as Map<String, dynamic>? ?? {};
    final s = (d['status'] ?? const {}) as Map<String, dynamic>;

    final num? phFromStatus = _get<num>('status.ph');
    final num? pHvolt       = _get<num>('status.pHvolt');

    return {
      'ph'       : _asDouble(phFromStatus ?? pHvolt ?? d['ph']),
      'pHvolt'   : _asDouble(pHvolt),
      'tempC'    : _asDouble(_get<num>('status.tempC') ?? d['tempC']),
      'moving'   : _asInt(d['moving']) ?? 0,
      'noMoving' : _asInt(d['noMoving']) ?? 0,
      'turbidity': _asDouble(_get<num>('status.turbidity') ?? s['turbidity']),

      'levelLow' : _get<bool>('status.levelLow')  ?? (s['levelLow']  == true),
      'levelHigh': _get<bool>('status.levelHigh') ?? (s['levelHigh'] == true),

      'updatedAt': (_get<Timestamp>('status.updatedAt') ?? s['updatedAt'] as Timestamp?)?.toDate(),
    };
  } catch (e) {
    debugPrint('bumpAndFetchLatest timeout/fail -> $e (fallback fetchLatest)');
    return fetchLatest(tankId);
  }
}

  // ========= Water-change status stream =========
  /// สตรีมสถานะเปลี่ยนน้ำ อ่านสดจาก devices/{tankId}
  static Stream<Map<String, dynamic>> streamWaterStatus(String tankId) {
    return _db.collection('devices').doc(tankId).snapshots().map((snap) {
      final data = (snap.data() ?? const {});
      final s = (data['status'] ?? const {}) as Map<String, dynamic>;

      DateTime? updatedAt;
      final ts = s['updatedAt'];
      if (ts is Timestamp) updatedAt = ts.toDate();

      // อ่าน pH จริงถ้ามี, ถ้าไม่มีให้ fallback เป็นโวลต์ดิบ (pHvolt)
      final phFromStatus = _asDouble(s['ph']);
      final pHvolt       = _asDouble(s['pHvolt']);
      final phValue      = phFromStatus ?? pHvolt; // เอามาแสดงในหน้า Home เป็น _ph

      return {
        'phase': (s['phase'] ?? 'idle').toString(),
        'pumpDrainOn': s['pumpDrainOn'] == true,
        'pumpFillOn': s['pumpFillOn'] == true,
        'levelLow': s['levelLow'] == true,
        'levelHigh': s['levelHigh'] == true,
        'turbidity': _asDouble(s['turbidity']),
        'tempC': _asDouble(s['tempC']),
        'ph': phValue,      // สำหรับแสดง (อาจเป็นค่า pH หรือโวลต์ ขึ้นกับว่ามีการคาลิเบรตหรือยัง)
        'pHvolt': pHvolt,   // เก็บเผื่อ UI อยากโชว์เป็นโวลต์
        'updatedAt': updatedAt,
      };
    });
  }

  // ========= Control: water change =========
  /// ส่งคำสั่งเปลี่ยนน้ำไปที่ /devices/{tankId}/ctrl/waterChange
  static Future<void> sendWaterCommand(String tankId, String cmd) async {
    final ref = _db
        .collection('devices')
        .doc(tankId)
        .collection('ctrl')
        .doc('waterChange');

    await ref.set({
      'request': cmd,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
