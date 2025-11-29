import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

import 'pages/login.dart';

// ⬇️ เพิ่ม
import 'package:firebase_auth/firebase_auth.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // ⬇️ แนะนำ: ล็อกอินแบบ anonymous เป็นค่าเริ่มต้นกัน permission-denied
  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }
    debugPrint('✅ uid: ${FirebaseAuth.instance.currentUser?.uid}'); // ต้องเห็นบรรทัดนี้

  final app = Firebase.app();
  debugPrint('✅ Firebase projectId: ${app.options.projectId}');
  debugPrint('✅ iOS appId        : ${app.options.appId}');
  debugPrint('✅ iOS bundleId     : ${app.options.iosBundleId}');
  runApp(const MyApp());
}


/// ---------- 🎯 App Root ----------
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedPink = Color(0xFFFF4D6D); // สีปุ่ม/สำเนียง
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
