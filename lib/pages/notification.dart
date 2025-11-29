import 'package:flutter/material.dart';

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final items = List.generate(
      5,
      (i) => 'แจ้งเตือน #${i + 1} : ค่าพารามิเตอร์เปลี่ยนแปลงในช่วงเวลา ${TimeOfDay.now().format(context)}',
    );
    return Scaffold(
      appBar: AppBar(title: const Text('การแจ้งเตือน')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) => ListTile(
          leading: const Icon(Icons.notifications),
          title: Text(items[i]),
          subtitle: const Text('กดเพื่อตรวจสอบรายละเอียด'),
          onTap: () {},
        ),
      ),
    );
  }
}
