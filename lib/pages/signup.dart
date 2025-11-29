import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});
  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _formKey = GlobalKey<FormState>();

  final _firstName = TextEditingController();
  final _lastName  = TextEditingController();
  final _username  = TextEditingController();
  final _email     = TextEditingController();
  final _password  = TextEditingController();
  final _phone     = TextEditingController();

  bool _obscure = true;
  bool _loading = false;
  String _message = '';

  // ---------- Validators (Regex) ----------
  String? _required(String? v, {String label = 'ข้อมูล'}) =>
      (v == null || v.trim().isEmpty) ? 'กรุณากรอก$label' : null;

  final _nameRegex = RegExp(r"^[A-Za-zก-๙' .-]{2,50}$");        // ชื่อ/สกุล
  final _usernameRegex = RegExp(r"^[A-Za-z][A-Za-z0-9_.]{2,19}$"); // เริ่มตัวอักษร 3–20
  final _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');       // อีเมลทั่วไป
  final _passwordRegex = RegExp(r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).{8,}$'); // 8+ มี a-z A-Z เลข
  final _phoneRegex = RegExp(r'^0\d{9}$');                          // เบอร์ไทย 10 หลัก

  String? _validateFirst(String? v) {
    if (_required(v, label: 'ชื่อ') != null) return 'กรุณากรอกชื่อ';
    return _nameRegex.hasMatch(v!.trim()) ? null : 'ชื่อใช้ ก-๙/A-Z/a-z และยาว 2–50';
  }
  String? _validateLast(String? v) {
    if (_required(v, label: 'สกุล') != null) return 'กรุณากรอกสกุล';
    return _nameRegex.hasMatch(v!.trim()) ? null : 'สกุลใช้ ก-๙/A-Z/a-z และยาว 2–50';
  }
  String? _validateUsername(String? v) {
    if (_required(v, label: 'Username') != null) return 'กรุณาตั้ง Username';
    return _usernameRegex.hasMatch(v!.trim())
        ? null : 'ขึ้นต้นตัวอักษร และใช้ a-z 0-9 _ . ได้ ยาว 3–20';
  }
  String? _validateEmail(String? v) {
    if (_required(v, label: 'อีเมล') != null) return 'กรุณากรอกอีเมล';
    return _emailRegex.hasMatch(v!.trim()) ? null : 'อีเมลไม่ถูกต้อง';
  }
  String? _validatePassword(String? v) {
    if (_required(v, label: 'รหัสผ่าน') != null) return 'กรุณากรอกรหัสผ่าน';
    return _passwordRegex.hasMatch(v!) ? null : 'อย่างน้อย 8 ตัว มี a-z, A-Z และตัวเลข';
  }
  String? _validatePhone(String? v) {
    if (_required(v, label: 'เบอร์โทร') != null) return 'กรุณากรอกเบอร์โทร';
    final s = v!.replaceAll(' ', '');
    return _phoneRegex.hasMatch(s) ? null : 'เบอร์โทรต้อง 10 หลักและขึ้นต้น 0';
  }

  void _suggestUsernameFromEmail() {
    final e = _email.text.trim();
    if (e.contains('@') && _username.text.trim().isEmpty) {
      _username.text = e.split('@').first.replaceAll(RegExp(r'[^A-Za-z0-9_.]'), '');
      setState(() {});
    }
  }

  @override
  void dispose() {
    _firstName.dispose(); _lastName.dispose(); _username.dispose();
    _email.dispose(); _password.dispose(); _phone.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
  FocusScope.of(context).unfocus();
  if (!_formKey.currentState!.validate()) return;

  setState(() { _loading = true; _message = ''; });

  final uname = _username.text.trim().toLowerCase();
  final email = _email.text.trim();
  final phone = _phone.text.trim();

  UserCredential? cred;
  bool usernameReserved = false;

  try {
    // STEP 1: สร้างผู้ใช้ (ต้องเปิด Email/Password ใน Firebase Console)
    debugPrint('STEP1: createUserWithEmailAndPassword');
    cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
      email: email,
      password: _password.text,
    );
    final uid = cred.user!.uid;
    await cred.user!.updateDisplayName('${_firstName.text.trim()} ${_lastName.text.trim()}');

    // STEP 2: จอง username (กันซ้ำแบบอะตอมมิก)
    debugPrint('STEP2: reserve username "$uname"');
    final unameRef = FirebaseFirestore.instance.collection('usernames').doc(uname);
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final snap = await tx.get(unameRef);
      if (snap.exists) {
        throw FirebaseException(plugin: 'firestore', code: 'username-taken', message: 'Username already taken');
      }
      tx.set(unameRef, {'uid': uid, 'createdAt': FieldValue.serverTimestamp()});
    });
    usernameReserved = true;

    // STEP 3: เขียนโปรไฟล์ users/{uid}
    debugPrint('STEP3: write users/${cred.user!.uid}');
    await FirebaseFirestore.instance.collection('users').doc(uid).set({
      'firstName': _firstName.text.trim(),
      'lastName' : _lastName.text.trim(),
      'username' : uname,
      'email'    : email,
      'phone'    : phone,
      'createdAt': FieldValue.serverTimestamp(),
    });

    setState(() => _message = '✅ สมัครสำเร็จ! ไปล็อกอินได้เลย');
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    Navigator.pop(context, {'email': email});

  } on FirebaseAuthException catch (e, st) {
    debugPrint('AUTH ERROR: ${e.code} ${e.message}');
    debugPrintStack(stackTrace: st);

    String msg;
    switch (e.code) {
      case 'operation-not-allowed':
        msg = '❌ โปรดเปิด Email/Password ที่ Firebase Console → Authentication → Sign-in method';
        break;
      case 'email-already-in-use':
        msg = '❌ อีเมลนี้ถูกใช้แล้ว';
        break;
      case 'invalid-email':
        msg = '❌ อีเมลไม่ถูกต้อง';
        break;
      case 'weak-password':
        msg = '❌ รหัสผ่านอ่อนเกินไป (ควร ≥ 8 ตัว และมี a-z, A-Z และตัวเลข)';
        break;
      case 'network-request-failed':
        msg = '❌ เครือข่ายมีปัญหา กรุณาลองใหม่';
        break;
      default:
        msg = '❌ [auth/${e.code}] ${e.message ?? 'เกิดข้อผิดพลาด'}';
    }
    if (mounted) setState(() => _message = msg);

  } on FirebaseException catch (e, st) {
    debugPrint('FIREBASE ERROR: ${e.plugin}/${e.code} ${e.message}');
    debugPrintStack(stackTrace: st);

    // Rollback ถ้าเกิดหลังสร้าง user แล้ว
    try {
      if (usernameReserved) {
        await FirebaseFirestore.instance.collection('usernames').doc(uname).delete();
      }
      if (cred?.user != null) {
        await cred!.user!.delete(); // เพิ่งสร้าง จะลบได้
      }
    } catch (_) {}

    String msg;
    if (e.plugin == 'firestore' && e.code == 'username-taken') {
      msg = '❌ Username นี้ถูกใช้แล้ว';
    } else if (e.plugin == 'firestore' && e.code == 'permission-denied') {
      msg = '❌ ไม่มีสิทธิ์เขียน/อ่าน Firestore — ตรวจ rules และยืนยันว่าได้ล็อกอินแล้ว';
    } else {
      msg = '❌ [${e.plugin}/${e.code}] ${e.message ?? 'เกิดข้อผิดพลาด'}';
    }
    if (mounted) setState(() => _message = msg);

  } catch (e, st) {
    debugPrint('UNKNOWN ERROR: $e');
    debugPrintStack(stackTrace: st);
    if (mounted) setState(() => _message = '❌ $e');

  } finally {
    if (mounted) setState(() => _loading = false);
  }
}


  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).size.width > 520 ? 32.0 : 20.0;

    return Scaffold(
      appBar: AppBar(title: const Text('สมัครสมาชิก')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(pad),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  // ชื่อ - สกุล
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _firstName,
                          decoration: const InputDecoration(labelText: 'ชื่อ', border: OutlineInputBorder()),
                          validator: _validateFirst,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r"[A-Za-zก-๙' .-]")),
                            LengthLimitingTextInputFormatter(50),
                          ],
                          textInputAction: TextInputAction.next,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _lastName,
                          decoration: const InputDecoration(labelText: 'สกุล', border: OutlineInputBorder()),
                          validator: _validateLast,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r"[A-Za-zก-๙' .-]")),
                            LengthLimitingTextInputFormatter(50),
                          ],
                          textInputAction: TextInputAction.next,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Username
                  TextFormField(
                    controller: _username,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      hintText: 'ขึ้นต้นตัวอักษร ใช้ a-z 0-9 _ . ได้',
                      border: OutlineInputBorder(),
                    ),
                    validator: _validateUsername,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r"[A-Za-z0-9_.]")),
                      LengthLimitingTextInputFormatter(20),
                    ],
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),

                  // Email
                  TextFormField(
                    controller: _email,
                    decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                    validator: _validateEmail,
                    onChanged: (_) => _suggestUsernameFromEmail(),
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),

                  // Password
                  TextFormField(
                    controller: _password,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      helperText: 'อย่างน้อย 8 ตัว มี a-z, A-Z และตัวเลข',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                      ),
                    ),
                    obscureText: _obscure,
                    validator: _validatePassword,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),

                  // Phone
                  TextFormField(
                    controller: _phone,
                    decoration: const InputDecoration(
                      labelText: 'เบอร์โทร',
                      hintText: 'เช่น 089xxxxxxx',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.phone,
                    validator: _validatePhone,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(10),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Submit
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _loading ? null : _onSubmit,
                      child: _loading
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('สมัครสมาชิก'),
                    ),
                  ),
                  const SizedBox(height: 12),

                  Text(
                    _message,
                    style: TextStyle(
                      color: _message.startsWith('✅') ? Colors.green : Colors.red,
                      fontWeight: FontWeight.w700,
                    ),
                  ),

                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _loading ? null : () => Navigator.pop(context),
                    child: const Text('มีบัญชีแล้ว? เข้าสู่ระบบ'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
