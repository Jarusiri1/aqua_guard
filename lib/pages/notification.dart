import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class NotificationsPage extends StatelessWidget {
  final String tankId; 

  const NotificationsPage({super.key, required this.tankId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('การแจ้งเตือน'),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('devices')
            .doc(tankId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError || !snapshot.hasData || !snapshot.data!.exists) {
            return const Center(
              child: Text(
                'ไม่สามารถเชื่อมต่อข้อมูลตู้ปลาได้',
                style: TextStyle(color: Colors.red, fontSize: 16),
              ),
            );
          }

          final data = snapshot.data!.data() as Map<String, dynamic>? ?? {};
          final status = data['status'] as Map<String, dynamic>? ?? {};

          // ==========================================
          // 🟢 1. ดึงข้อมูลและคำนวณผ่านสูตร (เหมือนหน้า Dashboard)
          // ==========================================
          
          // --- คำนวณ pH ---
          double pHvoltRaw = (status['pHvolt'] ?? 0.0).toDouble();
          double currentPh = 7.0; // ค่าเริ่มต้น
          if (pHvoltRaw > 0.1) {
            double neutralV = 2.5; 
            double sensitivity = 0.18; 
            currentPh = 7.0 - (pHvoltRaw - neutralV) / sensitivity;
            currentPh = currentPh.clamp(0.0, 14.0);
          }

          // --- คำนวณ Turbidity (NTU) ---
          double turbidityVolt = (status['turbidity'] ?? 0.0).toDouble();
          double currentTurbid = 0.0;
          double vClear = 1.15;  
          double vPepsi = 0.70;  
          double ntuPepsi = 100.0; 

          if (turbidityVolt < vClear) {
            double slope = (ntuPepsi - 0) / (vPepsi - vClear);
            currentTurbid = slope * (turbidityVolt - vClear);
            if (currentTurbid < 2.0) currentTurbid = 0;
            if (currentTurbid > 3000) currentTurbid = 3000;
          }

          // --- อุณหภูมิ และ ระดับน้ำ ---
          double currentTemp = (status['tempC'] ?? 28.0).toDouble();
          
          // ใน Dashboard: true = ปกติ, false = น้ำต่ำ
          bool isLevelLowStatus = status['levelLow'] ?? true; 
          bool alertWaterLow = !isLevelLowStatus; // ถ้า false แปลว่าต้องแจ้งเตือน

          // ==========================================
          // 🟢 2. เช็คเงื่อนไขเพื่อสร้างการแจ้งเตือน
          // ==========================================
          List<Map<String, dynamic>> alerts = [];

          // ⚠️ แนะนำ: ค่า pH ควรเตือนเมื่อต่ำไป หรือสูงไป (อันนี้ผมใส่เผื่อให้เตือนถ้าเกิน 7.5 หรือต่ำกว่า 6.0)
          if (currentPh > 7.5 || currentPh < 6.0) { 
            alerts.add({
              'title': 'ค่า pH ผิดปกติ',
              'subtitle': 'ปัจจุบัน: ${currentPh.toStringAsFixed(1)} (ควรอยู่ระหว่าง 6.0 - 7.5)',
              'icon': Icons.science,
              'color': Colors.orange,
            });
          }

          if (currentTemp > 30) {
            alerts.add({
              'title': 'อุณหภูมิน้ำสูงเกินไป',
              'subtitle': 'ปัจจุบัน: ${currentTemp.toStringAsFixed(1)} °C (ควรต่ำกว่า 30 °C)',
              'icon': Icons.thermostat,
              'color': Colors.red,
            });
          }

          if (currentTurbid > 10) {
            alerts.add({
              'title': 'น้ำขุ่นเกินกำหนด',
              'subtitle': 'ปัจจุบัน: ${currentTurbid.toStringAsFixed(1)} NTU (ควรต่ำกว่า 10 NTU)',
              'icon': Icons.water_drop,
              'color': Colors.brown,
            });
          }

          if (alertWaterLow) { // 🟢 เปลี่ยนมาใช้ตัวแปรที่เช็คความถูกต้องแล้ว
            alerts.add({
              'title': 'ระดับน้ำต่ำผิดปกติ',
              'subtitle': 'กรุณาเติมน้ำในตู้ปลา หรือตรวจสอบระบบปั๊มน้ำ',
              'icon': Icons.waves,
              'color': Colors.blue,
            });
          }

          // กรณีค่าทุกอย่างปกติ (ไม่มี Alert)
          if (alerts.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 80),
                  SizedBox(height: 16),
                  Text(
                    'สภาพน้ำปกติ ไม่มีแจ้งเตือน',
                    style: TextStyle(
                        fontSize: 20,
                        color: Colors.green,
                        fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            );
          }

          // กรณีมีค่าผิดปกติ
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: alerts.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final alert = alerts[i];
              return Card(
                elevation: 0,
                color: alert['color'].withOpacity(0.05), 
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: alert['color'].withOpacity(0.5)),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: CircleAvatar(
                    backgroundColor: alert['color'].withOpacity(0.2),
                    child: Icon(alert['icon'], color: alert['color']),
                  ),
                  title: Text(
                    alert['title'],
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: alert['color'], 
                    ),
                  ),
                  subtitle: Text(
                    alert['subtitle'],
                    style: const TextStyle(color: Colors.black87),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}