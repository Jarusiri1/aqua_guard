import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key, this.initialEmail});
  final String? initialEmail; // ใช้เติมอีเมลล่วงหน้า (ถ้ามี)

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _loading = false;
  String _msg = '';

  final _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void initState() {
    super.initState();
    if (widget.initialEmail?.isNotEmpty == true) {
      _email.text = widget.initialEmail!.trim();
    }
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  String? _validateEmail(String? v) {
    if (v == null || v.trim().isEmpty) return 'กรุณากรอกอีเมล';
    return _emailRegex.hasMatch(v.trim()) ? null : 'อีเมลไม่ถูกต้อง';
    }

  Future<void> _sendReset() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() { _loading = true; _msg = ''; });
    final e = _email.text.trim();

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: e);
      if (!mounted) return;
      setState(() => _msg = '📩 ส่งลิงก์รีเซ็ตรหัสผ่านไปที่ $e แล้ว');
    } on FirebaseAuthException catch (ex) {
      String msg;
      switch (ex.code) {
        case 'invalid-email':
          msg = '❌ อีเมลไม่ถูกต้อง';
          break;
        case 'missing-email':
          msg = '❌ กรุณากรอกอีเมล';
          break;
        case 'user-not-found':
          // บางโปรเจกต์ Firebase จะไม่บอกว่ามีผู้ใช้หรือไม่ เพื่อความปลอดภัย
          msg = '📩 ถ้ามีบัญชีที่ใช้อีเมลนี้ เราได้ส่งลิงก์รีเซ็ตไปแล้ว';
          break;
        case 'network-request-failed':
          msg = '❌ เครือข่ายมีปัญหา ลองใหม่อีกครั้ง';
          break;
        case 'too-many-requests':
          msg = '❌ ทำรายการบ่อยเกินไป รอสักครู่แล้วลองใหม่';
          break;
        default:
          msg = '❌ ${ex.message ?? 'ส่งลิงก์ไม่สำเร็จ'}';
      }
      if (!mounted) return;
      setState(() => _msg = msg);
    } catch (e) {
      if (!mounted) return;
      setState(() => _msg = '❌ เกิดข้อผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ok = _emailRegex.hasMatch(_email.text.trim());
    return Scaffold(
      appBar: AppBar(title: const Text('ลืมรหัสผ่าน')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'อีเมล',
                  hintText: 'you@example.com',
                  border: OutlineInputBorder(),
                ),
                validator: _validateEmail,
                onChanged: (_) => setState(() {}), // อัปเดตสถานะปุ่ม
                onFieldSubmitted: (_) => _sendReset(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _loading || !ok ? null : _sendReset,
                  child: _loading
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('ส่งลิงก์รีเซ็ต'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _msg,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _msg.startsWith('❌') ? Colors.red : Colors.green,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _loading ? null : () => Navigator.pop(context),
                child: const Text('ย้อนกลับไปหน้าเข้าสู่ระบบ'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
