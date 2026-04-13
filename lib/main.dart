import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

import 'pages/login.dart';
import 'package:firebase_auth/firebase_auth.dart';

// 1. เพิ่ม Import สำหรับแจ้งเตือน
import 'package:firebase_messaging/firebase_messaging.dart';

//2. เพิ่มฟังก์ชันรับแจ้งเตือนตอนแอปปิดอยู่ (ต้องอยู่นอกสุด ห้ามอยู่ในคลาสใดๆ)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // สำคัญ: ต้อง Initialize Firebase ใน background ด้วย
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint("Handling a background message: ${message.messageId}");
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  debugPrint('✅ uid: ${FirebaseAuth.instance.currentUser?.uid}'); 

  final app = Firebase.app();
  debugPrint('✅ Firebase projectId: ${app.options.projectId}');
  debugPrint('✅ iOS appId        : ${app.options.appId}');
  debugPrint('✅ iOS bundleId     : ${app.options.iosBundleId}');

  // 3. ตั้งค่าขออนุญาตและจัดการ Push Notifications
  // ผูกฟังก์ชัน Background
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  
  // ขออนุญาตผู้ใช้ (เด้ง Pop-up ขอส่งแจ้งเตือนบน iOS/Android)
  await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );
  
  // ตั้งค่าให้แจ้งเตือนเด้งโชว์ด้านบน แม้ตอนที่กำลังเปิดแอปเล่นอยู่ (Foreground)
  await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );

  runApp(const MyApp());
}

/// ---------- 🎯 App Root ----------
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedPink = Color(0xFFFF4D6D); 
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Aqua Guard',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seedPink),
        useMaterial3: true,
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: seedPink,
            foregroundColor: Colors.white,
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      home: const LoginPage(),
    );
  }
}