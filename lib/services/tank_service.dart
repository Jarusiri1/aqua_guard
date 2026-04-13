import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'; // debugPrint

import '../models/tank.dart'; // <--- เติมบรรทัดนี้ครับ

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


  static double? _convertPhVoltToPh(double? voltage) {
    if (voltage == null) return null;
    //สูตรแปลงโวลต์เป็น pH: pH = 7 - (voltage - 2.5) / 0.18
    final ph = 7.0 - (voltage - 2.5) / 0.18;
    //จำกัดค่า pHระหว่าง 0-14
    if (ph < 0) return 0.0;
    if (ph > 14) return 14.0;
    return ph;
  }

  //เรียก
  static Future<void> ensureDeviceInitialized(String tankId) async {
    // ต้องมีผู้ใช้ก่อนเช็คown
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

  /// อ่านค่า metric ปัจจุบันจาก devices/{tankId}
  static Future<Map<String, dynamic>> fetchLatest(String tankId) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) throw Exception('not-signed-in');

  final ref = _db.collection('devices').doc(tankId);
  try {
    final snap = await ref.get();
    if (!snap.exists) throw Exception('device-not-found: $tankId');

    T? get<T>(String path) {
      try {
        final v = snap.get(path);
        return v is T ? v : null;
      } catch (_) {
        return null;
      }
    }

    final d = snap.data() ?? <String, dynamic>{};
    final s = (d['status'] ?? const {}) as Map<String, dynamic>;

    final num? phFromStatus = get<num>('status.ph');
    final num? pHvolt       = get<num>('status.pHvolt');

    // ใช้ pHvolt เป็นหลัก (ค่าใหม่) แปลงเป็น pH ถ้ามี
    // ถ้าไม่มี pHvolt ค่อยใช้ phFromStatus หรือค่า default
    final double? phConverted = pHvolt != null 
        ? _convertPhVoltToPh(_asDouble(pHvolt))
        : (phFromStatus != null ? _asDouble(phFromStatus) : null);

    // Debug: แสดงค่า pHvolt และ pH ที่แปลงได้
    debugPrint('pH sensor [fetchLatest]: pHvolt=$pHvolt, phFromStatus=$phFromStatus, converted pH=$phConverted, d[ph]=${d['ph']}');

    return {
      // ใช้ค่า pHvolt ที่แปลงแล้วเป็นหลัก (ค่าใหม่) 
      // ถ้าไม่มี pHvolt และไม่มี phFromStatus ค่อย fallback ไป d['ph']
      // แต่ถ้ามี pHvolt ต้องแปลงเสมอ (ไม่ใช้ค่าเก่า)
      'ph'       : phConverted ?? (pHvolt == null ? _asDouble(d['ph']) : null),
      'pHvolt'   : _asDouble(pHvolt),
      'tempC'    : _asDouble(get<num>('status.tempC') ?? d['tempC']),
      'moving'   : _asInt(d['moving']) ?? 0,
      'noMoving' : _asInt(d['noMoving']) ?? 0,
      'turbidity': _asDouble(get<num>('status.turbidity') ?? s['turbidity']),

      'levelLow' : get<bool>('status.levelLow')  ?? (s['levelLow']  == true),
      'levelHigh': get<bool>('status.levelHigh') ?? (s['levelHigh'] == true),

      'updatedAt': (get<Timestamp>('status.updatedAt') ?? s['updatedAt'] as Timestamp?)?.toDate(),
    };
  } on FirebaseException {
    rethrow;
  }
}

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


  /// สั่งวัดอจนได้ค่าใหม่"ฃ
  /// ใช้ในปุ่ม Refres
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

  //turbidity/tempC/pH + water levels
  await Future.wait([
    requestTurbidityOnce(tankId),
    requestLevelsOnce(tankId),
  ]);

  //เว้นให้ทำงาน pHsensorองใช้เวลา
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

    T? get<T>(String path) {
      try {
        final v = snap.get(path);
        return v is T ? v : null;
      } catch (_) {
        return null;
      }
    }

    final d = snap.data() ?? {};
    final s = (d['status'] ?? const {}) as Map<String, dynamic>;

    final num? phFromStatus = get<num>('status.ph');
    final num? pHvolt       = get<num>('status.pHvolt');

    // ใช้ pHvolt เป็นหลัก (ค่าใหม่) แปลงเป็น pH ถ้ามี
    // ถ้าไม่มี pHvolt ค่อยใช้ phFromStatus หรือค่า default
    final double? phConverted = pHvolt != null 
        ? _convertPhVoltToPh(_asDouble(pHvolt))
        : (phFromStatus != null ? _asDouble(phFromStatus) : null);

    // Debug: แสดงค่า pHvolt และ pH ที่แปลงได้
    debugPrint('pH sensor [bumpAndFetchLatest]: pHvolt=$pHvolt, phFromStatus=$phFromStatus, converted pH=$phConverted');
    if (pHvolt != null) {
      final calculated = 7.0 - (pHvolt.toDouble() - 2.5) / 0.18;
      debugPrint('  -> pH calculation: 7 - ($pHvolt - 2.5) / 0.18 = ${calculated.toStringAsFixed(2)}');
      debugPrint('  -> pH range check: voltage ${pHvolt}V → pH ${calculated.toStringAsFixed(1)}');
      debugPrint('  -> Expected: pH 7 (water) = 2.5V, pH 2 (lemon) = ~3.4V, pH 10 (alkaline) = ~1.3V');
    } else {
      debugPrint('  -> WARNING: pHvolt is NULL! Sensor may not be reading new values.');
      debugPrint('  -> This means the sensor is not updating. Check sensor connection.');
    }

    return {
      // ใช้ค่า pHvolt ที่แปลงแล้วเป็นหลัก (ค่าใหม่)
      // ถ้าไม่มี pHvolt และไม่มี phFromStatus ค่อย fallback ไป d['ph']
      'ph'       : phConverted ?? (pHvolt == null ? _asDouble(d['ph']) : null),
      'pHvolt'   : _asDouble(pHvolt),
      'tempC'    : _asDouble(get<num>('status.tempC') ?? d['tempC']),
      'moving'   : _asInt(d['moving']) ?? 0,
      'noMoving' : _asInt(d['noMoving']) ?? 0,
      'turbidity': _asDouble(get<num>('status.turbidity') ?? s['turbidity']),

      'levelLow' : get<bool>('status.levelLow')  ?? (s['levelLow']  == true),
      'levelHigh': get<bool>('status.levelHigh') ?? (s['levelHigh'] == true),

      'updatedAt': (get<Timestamp>('status.updatedAt') ?? s['updatedAt'] as Timestamp?)?.toDate(),
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

      // ใช้ pHvolt เป็นหลัก (ค่าใหม่) แปลงเป็น pH ถ้ามี
      // ถ้าไม่มี pHvolt ค่อยใช้ phFromStatus
      final phFromStatus = _asDouble(s['ph']);
      final pHvolt       = _asDouble(s['pHvolt']);
      final phValue      = pHvolt != null 
          ? _convertPhVoltToPh(pHvolt)  // ใช้ pHvolt แปลงเป็น pH (ค่าใหม่)
          : phFromStatus;  // ถ้าไม่มี pHvolt ค่อยใช้ phFromStatus

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

  // -----------------------------------------------------------
  // >>>> เริ่มวางโค้ดใหม่ตรงนี้ (ต่อจาก sendWaterCommand) <<<<
  // -----------------------------------------------------------

  /// 1. ฟังก์ชันเพิ่มตู้ (ผูก User กับ Serial Number)
  static Future<void> linkTankToUser(String serialNumber, String customName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('กรุณาเข้าสู่ระบบก่อนเพิ่มตู้');

    final db = FirebaseFirestore.instance;

    // เช็คว่ามี Serial Number นี้จริงไหมใน collection 'devices'
    final deviceDoc = await db.collection('devices').doc(serialNumber).get();
    if (!deviceDoc.exists) {
      throw Exception('ไม่พบรหัสตู้ $serialNumber ในระบบ');
    }

    // บันทึกลง user profile
    await db.collection('users')
        .doc(user.uid)
        .collection('my_tanks')
        .doc(serialNumber)
        .set({
          'id': serialNumber,

          'sn': serialNumber,
          'name': customName.isEmpty ? 'My Tank' : customName,
          'addedAt': FieldValue.serverTimestamp(),
        });
  }

  /// 2. ฟังก์ชันดึงรายชื่อตู้ของ User คนนั้นๆ
  static Future<List<Tank>> getMyTanks() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return [];

    final db = FirebaseFirestore.instance;
    final snapshot = await db
        .collection('users')
        .doc(user.uid)
        .collection('my_tanks')
        .orderBy('addedAt', descending: true)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      // ใช้ doc.id (= serial number) เป็น tank ID เสมอ
      // เพราะ field 'id' ใน document อาจว่างเปล่า
      final tank = Tank.fromMap({...data, 'id': doc.id});
      return tank;
    }).toList();
  }

  /// 3. ฟังก์ชันลบตู้ (ยกเลิกการผูก User กับ Serial Number)
  static Future<void> unlinkTankFromUser(String serialNumber) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('กรุณาเข้าสู่ระบบก่อนดำเนินการ');

    final db = FirebaseFirestore.instance;

    try {
      // ลบเอกสารตู้ออกจากคอลเลกชัน my_tanks ของผู้ใช้ปัจจุบัน
      await db.collection('users')
          .doc(user.uid)
          .collection('my_tanks')
          .doc(serialNumber)
          .delete();
          
      debugPrint('Unlinked tank $serialNumber from user ${user.uid}');
    } catch (e) {
      debugPrint('Error unlinking tank: $e');
      rethrow;
    }
  }

  // ========= Sensor History (Dashboard) =========

  /// บันทึกค่าเซนเซอร์ลง devices/{tankId}/logs
  /// เรียกทุกครั้งที่ refresh สำเร็จ
  static Future<void> logSensorReading(String tankId, {
    double? ph,
    double? tempC,
    double? turbidity,
    bool? levelLow,
  }) async {
    try {
      await _db.collection('devices').doc(tankId).collection('logs').add({
        'ph': ph,
        'tempC': tempC,
        'turbidity': turbidity,
        'levelLow': levelLow,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('logSensorReading error: $e');
    }
  }

  /// ดึงประวัติเซนเซอร์ย้อนหลัง
  /// รองรับการจำกัดจำนวน (limit) เพื่อประหยัด Quota
  /// return List<Map> เรียงตามเวลา (เก่า → ใหม่) สำหรับวาดกราฟ
  static Future<List<Map<String, dynamic>>> fetchSensorHistory(
    String tankId, {
    int? days,
    int? limit,
  }) async {
    // 💡 สังเกตว่าเราใช้ collection('logs') ดังนั้นใน Python ต้องบันทึกลง 'logs' ด้วยนะครับ
    Query query = _db.collection('devices').doc(tankId).collection('logs');

    if (limit != null) {
      // ถ้าขอดูเป็นนาที (มี limit) ให้ดึงข้อมูลล่าสุดตามจำนวน limit
      query = query.orderBy('createdAt', descending: true).limit(limit);
    } else if (days != null) {
      // ถ้าขอดูเป็นวัน (7 วัน)
      final cutoff = DateTime.now().subtract(Duration(days: days));
      query = query
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(cutoff))
          .orderBy('createdAt', descending: true); // เรียงจากใหม่ไปเก่าก่อน
    }

    final snap = await query.get();

    final docs = snap.docs.map((doc) {
      final d = doc.data() as Map<String, dynamic>;
      
      // รองรับ timestamp ทั้ง 2 ชื่อ (createdAt ของ Dart, timestamp ของ Python)
      final ts = d['createdAt'] ?? d['timestamp']; 
      
      // แปลงค่า pHvolt เป็น pH (ถ้ามีค่า pHvolt ส่งมาจาก Python)
      final pHvolt = _asDouble(d['pHvolt']);
      final phValue = pHvolt != null ? _convertPhVoltToPh(pHvolt) : _asDouble(d['ph']);

      return {
        'ph': phValue, 
        'tempC': _asDouble(d['tempC']),
        'turbidity': _asDouble(d['turbidity']),
        'levelLow': d['levelLow'],
        'createdAt': (ts as Timestamp?)?.toDate(),
      };
    }).toList();

    // 💡 ต้อง .reversed เพื่อกลับให้ข้อมูลเรียงจาก "ซ้ายไปขวา (เก่ามาใหม่)" ให้ Chart.js วาดกราฟถูกต้อง
    return docs.reversed.toList();
  }

}


