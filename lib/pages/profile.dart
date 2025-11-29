import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'login.dart';

const double kBtnHeight = 56.0; // ความสูงปุ่มมาตรฐาน

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _formKey = GlobalKey<FormState>();

  // controllers (โหมดแก้ไข)
  final _firstName = TextEditingController();
  final _lastName  = TextEditingController();
  final _username  = TextEditingController();
  final _phone     = TextEditingController();

  bool _editing = false;
  bool _loading = false;

  String _msg = '';
  bool _msgIsError = false;

  // ---- ตัวหนังสือใหญ่ขึ้น ----
  TextStyle get _valueStyle =>
      const TextStyle(fontSize: 18, fontWeight: FontWeight.w600);
  TextStyle get _lineStyle => const TextStyle(fontSize: 18);
  final _btnText = const TextStyle(fontSize: 18, fontWeight: FontWeight.w700);

  // ปุ่มให้สูงเท่าปุ่ม Refresh (16)
  ButtonStyle get _filledLikeRefresh =>
      FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), textStyle: _btnText);
  ButtonStyle get _outlinedLikeRefresh =>
      OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), textStyle: _btnText);

  // ===== Validators =====
  String? _required(String? v, {String label = 'ข้อมูล'}) =>
      (v == null || v.trim().isEmpty) ? 'กรุณากรอก$label' : null;

  final _nameRegex = RegExp(r"^[A-Za-zก-๙' .-]{2,50}$");
  final _usernameRegex = RegExp(r"^[A-Za-z][A-Za-z0-9_.]{2,19}$");
  final _phoneRegex = RegExp(r'^0\d{9}$');

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
        ? null
        : 'ขึ้นต้นตัวอักษร และใช้ a-z 0-9 _ . ได้ ยาว 3–20';
  }
  String? _validatePhone(String? v) {
    if (_required(v, label: 'เบอร์โทร') != null) return 'กรุณากรอกเบอร์โทร';
    final s = v!.replaceAll(' ', '');
    return _phoneRegex.hasMatch(s) ? null : 'เบอร์โทรต้อง 10 หลักและขึ้นต้น 0';
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _username.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _enterEdit(Map<String, dynamic> data) {
    _firstName.text = (data['firstName'] ?? '').toString();
    _lastName.text  = (data['lastName']  ?? '').toString();
    _username.text  = (data['username']  ?? '').toString();
    _phone.text     = (data['phone']     ?? '').toString();
    setState(() {
      _editing = true;
      _msg = '';
      _msgIsError = false;
    });
  }

  Future<void> _save(String uid, Map<String, dynamic> currentData) async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _msg = '';
      _msgIsError = false;
    });

    final newFirst = _firstName.text.trim();
    final newLast  = _lastName.text.trim();
    final newUser  = _username.text.trim().toLowerCase();
    final newPhone = _phone.text.trim();

    final oldUser  = (currentData['username'] ?? '').toString().toLowerCase();

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final userRef = FirebaseFirestore.instance.collection('users').doc(uid);

        if (newUser != oldUser && newUser.isNotEmpty) {
          final newRef = FirebaseFirestore.instance.collection('usernames').doc(newUser);
          final oldRef = oldUser.isNotEmpty
              ? FirebaseFirestore.instance.collection('usernames').doc(oldUser)
              : null;

          final newSnap = await tx.get(newRef);
          if (newSnap.exists) {
            throw FirebaseException(
              plugin: 'firestore',
              code: 'username-taken',
              message: 'Username already taken',
            );
          }

          tx.set(newRef, {'uid': uid, 'createdAt': FieldValue.serverTimestamp()});

          if (oldRef != null) {
            final oldSnap = await tx.get(oldRef);
            if (oldSnap.exists && (oldSnap.data() as Map?)?['uid'] == uid) {
              tx.delete(oldRef);
            }
          }
        }

        tx.update(userRef, {
          'firstName': newFirst,
          'lastName' : newLast,
          'username' : newUser,
          'phone'    : newPhone,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      await FirebaseAuth.instance.currentUser
          ?.updateDisplayName('$newFirst $newLast'.trim());

      setState(() {
        _editing = false;
        _msg = 'บันทึกข้อมูลเรียบร้อย';
        _msgIsError = false;
      });
    } on FirebaseException catch (e) {
      setState(() {
        if (e.plugin == 'firestore' && e.code == 'username-taken') {
          _msg = 'Username นี้ถูกใช้แล้ว';
        } else if (e.plugin == 'firestore' && e.code == 'permission-denied') {
          _msg = 'ไม่มีสิทธิ์แก้ไขข้อมูล ตรวจสอบ Firestore Rules';
        } else {
          _msg = '[${e.plugin}/${e.code}] ${e.message ?? 'เกิดข้อผิดพลาด'}';
        }
        _msgIsError = true;
      });
    } catch (e) {
      setState(() {
        _msg = e.toString();
        _msgIsError = true;
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('โปรไฟล์')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('ยังไม่ได้เข้าสู่ระบบ',
                  style: _valueStyle.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              FilledButton(
                style: _filledLikeRefresh,
                onPressed: () {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginPage()),
                    (_) => false,
                  );
                },
                child: const Text('ไปหน้าเข้าสู่ระบบ'),
              ),
            ],
          ),
        ),
      );
    }

    final uid = user.uid;
    final email = user.email ?? '-';
    final userDoc = FirebaseFirestore.instance.collection('users').doc(uid);

    return Scaffold(
      appBar: AppBar(
        title: const Text('โปรไฟล์'),
        actions: [
          if (!_editing)
            IconButton(
              tooltip: 'ออกจากระบบ',
              onPressed: () async {
                await FirebaseAuth.instance.signOut();
                if (context.mounted) {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginPage()),
                    (_) => false,
                  );
                }
              },
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: userDoc.snapshots(),
        builder: (context, snap) {
          final cs = Theme.of(context).colorScheme;
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('โหลดข้อมูลไม่สำเร็จ', style: _lineStyle));
          }

          final data = snap.data?.data() ?? {};
          final firstName = (data['firstName'] ?? '') as String;
          final lastName  = (data['lastName']  ?? '') as String;
          final username  = (data['username']  ?? '') as String;
          final phone     = (data['phone']     ?? '') as String;
          final fullName  =
              (firstName.isNotEmpty || lastName.isNotEmpty) ? '$firstName $lastName'.trim() : '-';

          return Padding(
            padding: const EdgeInsets.all(24.0),
            child: _editing
                ? Form(
                    key: _formKey,
                    child: ListView(
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 48,
                              backgroundColor: cs.secondaryContainer,
                              child: const Icon(Icons.person, size: 48),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: Text(
                                email,
                                textAlign: TextAlign.right,
                                style: const TextStyle(color: Colors.black54, fontSize: 18),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // ชื่อ-สกุล
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _firstName,
                                decoration: const InputDecoration(
                                  labelText: 'ชื่อ',
                                  border: OutlineInputBorder(),
                                ),
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
                                decoration: const InputDecoration(
                                  labelText: 'สกุล',
                                  border: OutlineInputBorder(),
                                ),
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
                        const SizedBox(height: 20),

                        // ปุ่มบันทึก/ยกเลิก (เท่าปุ่ม Refresh)
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                style: _filledLikeRefresh,
                                onPressed: _loading ? null : () => _save(uid, data),
                                icon: _loading
                                    ? const SizedBox(
                                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.save, size: 22),
                                label: const Text('บันทึก'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                style: _outlinedLikeRefresh,
                                onPressed: _loading
                                    ? null
                                    : () => setState(() {
                                          _editing = false;
                                          _msg = '';
                                          _msgIsError = false;
                                        }),
                                icon: const Icon(Icons.close, size: 22),
                                label: const Text('ยกเลิก'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        if (_msg.isNotEmpty)
                          Text(
                            _msg,
                            style: TextStyle(
                              fontSize: 18,
                              color: _msgIsError ? Colors.red : Colors.green,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 36,
                        backgroundColor: cs.secondaryContainer,
                        child: const Icon(Icons.person, size: 48),
                      ),
                      const SizedBox(height: 20),
                      Text('ชื่อ-สกุล: $fullName', style: _lineStyle),
                      const SizedBox(height: 6),
                      Text('Username: ${username.isEmpty ? '-' : username}', style: _lineStyle),
                      const SizedBox(height: 6),
                      Text('อีเมล: $email', style: _lineStyle),
                      const SizedBox(height: 6),
                      Text('เบอร์โทร: ${phone.isEmpty ? '-' : phone}', style: _lineStyle),
                      const SizedBox(height: 16),
                      if (_msg.isNotEmpty)
                        Text(
                          _msg,
                          style: TextStyle(
                            fontSize: 18,
                            color: _msgIsError ? Colors.red : Colors.green,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      const Spacer(),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16),), // เท่าปุ่ม Refresh
                          onPressed: () => _enterEdit(data),
                          icon: const Icon(Icons.edit),
                          label: const Text('แก้ไขโปรไฟล์'),
                        ),
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }
}
