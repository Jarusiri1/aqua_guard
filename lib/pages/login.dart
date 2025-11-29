import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';


import 'signup.dart';
import 'forgot_pass.dart';
import 'home.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  String _message = '';

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _message = '❌ กรุณากรอกอีเมลและรหัสผ่าน');
      return;
    }

    setState(() => _message = '');
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: password);
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomePage()));
    } on FirebaseAuthException catch (e) {
      setState(() {
        _message = switch (e.code) {
          'user-not-found' => '❌ ไม่พบบัญชีนี้',
          'wrong-password' => '❌ รหัสผ่านไม่ถูกต้อง',
          'invalid-email' => '❌ อีเมลไม่ถูกต้อง',
          'too-many-requests' => '❌ พยายามบ่อยเกินไป รอสักครู่',
          _ => '❌ ${e.message ?? 'ล็อกอินไม่สำเร็จ'}',
        };
      });
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).size.width > 520 ? 48.0 : 24.0;
    return Scaffold(
      appBar: AppBar(title: const Text('เข้าสู่ระบบ')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: EdgeInsets.all(pad),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Aqua Guard', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800)),
                const SizedBox(height: 24),
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(
      builder: (_) => ForgotPasswordPage(
        initialEmail: _emailController.text.trim(),
      ),
    ),
  ),
  child: const Text('ลืมรหัสผ่าน?'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(onPressed: _login, child: const Text('เข้าสู่ระบบ')),
                ),
                const SizedBox(height: 12),
                Text(
                  _message,
                  style: TextStyle(
                    color: _message.contains('สำเร็จ') ? Colors.green : Colors.red,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () async {
                    final result = await Navigator.push<Map<String, String>?>(
                      context,
                      MaterialPageRoute(builder: (_) => const SignUpPage()),
                    );
                    if (result != null && result['email'] != null) {
                      _emailController.text = result['email']!;
                    }
                  },
                  child: const Text("ยังไม่มีบัญชี? สมัคร"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
