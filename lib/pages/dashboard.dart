import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../models/tank.dart';
import '../services/tank_service.dart';

class DashboardPage extends StatefulWidget {
  final Tank tank;
  const DashboardPage({super.key, required this.tank});
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool _loading = false;
  List<Map<String, dynamic>> _history = [];

  // ค่าเฉลี่ยของช่วงเวลาที่เลือก
  double? _avgPh, _avgTemp, _avgTurbidity;

  // ข้อมูลสำหรับวาดกราฟ (ใช้ได้ทั้งรายวันและรายนาที)
  List<_ChartData> _chartData = [];

  // State สำหรับเก็บช่วงเวลาที่เลือก (ค่าเริ่มต้น 1 ชั่วโมง)
  String _selectedTimeframe = '1h'; // '20m', '30m', '1h', '7d'

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _loading = true);
    try {
      // ดึงข้อมูลมาเผื่อไว้เยอะๆ หน่อย เพื่อหา "ค่าล่าสุด" (Last Known Value)
      // เผื่อเครื่อง Pi ดับไปก่อนหน้านี้ จะได้มีค่ามาลากเส้นต่อได้
      int fetchLimit = 150; 
      if (_selectedTimeframe == '7d') fetchLimit = 7 * 24 * 60; 

      final data = await TankService.fetchSensorHistory(
        widget.tank.id, 
        days: _selectedTimeframe == '7d' ? 7 : null,
        limit: _selectedTimeframe != '7d' ? fetchLimit : null,
      );

      final parsedChartData = <_ChartData>[];
      double phSum = 0, tempSum = 0, turbSum = 0;
      int phCount = 0, tempCount = 0, turbCount = 0;

      // 1. หา "ค่าล่าสุด" จากข้อมูลชุดแรกสุดที่เจอ
      // สมมติว่า data เรียงจาก ใหม่ -> เก่า
      double? lastPh, lastTemp, lastTurbidity;
      for (final d in data) {
        lastPh ??= d['ph'] as double?;
        lastTemp ??= d['tempC'] as double?;
        lastTurbidity ??= d['turbidity'] as double?;
        if (lastPh != null && lastTemp != null && lastTurbidity != null) break;
      }

      DateTime now = DateTime.now();

      if (_selectedTimeframe == '7d') {
        // ==========================================
        // ตรรกะ 7 วัน (สร้างเวลาต่อเนื่องทุก 1 วัน)
        // ==========================================
        Map<String, List<Map<String, dynamic>>> dataByDay = {};
        for (final d in data) {
          final dt = d['createdAt'] as DateTime?;
          if (dt == null) continue;
          final key = DateFormat('yyyy-MM-dd').format(dt);
          dataByDay.putIfAbsent(key, () => []).add(d);
        }

        for (int i = 6; i >= 0; i--) {
          DateTime currentDay = now.subtract(Duration(days: i));
          String key = DateFormat('yyyy-MM-dd').format(currentDay);
          String label = DateFormat('MM/dd').format(currentDay);

          if (dataByDay.containsKey(key)) {
            var records = dataByDay[key]!;
            double pS = 0, tS = 0, tbS = 0;
            int pC = 0, tC = 0, tbC = 0;
            for (var r in records) {
              if (r['ph'] != null) { pS += r['ph']; pC++; }
              if (r['tempC'] != null) { tS += r['tempC']; tC++; }
              if (r['turbidity'] != null) { tbS += r['turbidity']; tbC++; }
            }
            if (pC > 0) lastPh = pS / pC;
            if (tC > 0) lastTemp = tS / tC;
            if (tbC > 0) lastTurbidity = tbS / tbC;
          }

          parsedChartData.add(_ChartData(label: label, ph: lastPh, temp: lastTemp, turbidity: lastTurbidity));
          if (lastPh != null) { phSum += lastPh!; phCount++; }
          if (lastTemp != null) { tempSum += lastTemp!; tempCount++; }
          if (lastTurbidity != null) { turbSum += lastTurbidity!; turbCount++; }
        }
      } else {
        // ==========================================
        // ตรรกะรายนาที (สร้างเวลาต่อเนื่องทุก 1 นาที)
        // ==========================================
        int durationMins = _selectedTimeframe == '20m' ? 20 : _selectedTimeframe == '30m' ? 30 : 60;

        Map<String, List<Map<String, dynamic>>> dataByMinute = {};
        for (final d in data) {
          final dt = d['createdAt'] as DateTime?;
          if (dt == null) continue;
          final key = DateFormat('yyyy-MM-dd HH:mm').format(dt);
          dataByMinute.putIfAbsent(key, () => []).add(d);
        }

        // ลูปวาดกราฟจากอดีต -> ปัจจุบัน (ซ้ายไปขวา)
        for (int i = durationMins; i >= 0; i--) {
          DateTime currentMinute = now.subtract(Duration(minutes: i));
          String key = DateFormat('yyyy-MM-dd HH:mm').format(currentMinute);
          String label = DateFormat('HH:mm').format(currentMinute);

          // ถ้านาทีนั้นมีข้อมูล ก็อัปเดตค่าล่าสุด ถ้านาทีนั้นเครื่องดับหรือไม่มีข้อมูล จะใช้ค่า lastPh เดิมวาดต่อ
          if (dataByMinute.containsKey(key)) {
            var records = dataByMinute[key]!;
            double pS = 0, tS = 0, tbS = 0;
            int pC = 0, tC = 0, tbC = 0;
            for (var r in records) {
              if (r['ph'] != null) { pS += r['ph']; pC++; }
              if (r['tempC'] != null) { tS += r['tempC']; tC++; }
              if (r['turbidity'] != null) { tbS += r['turbidity']; tbC++; }
            }
            if (pC > 0) lastPh = pS / pC;
            if (tC > 0) lastTemp = tS / tC;
            if (tbC > 0) lastTurbidity = tbS / tbC;
          }

          parsedChartData.add(_ChartData(label: label, ph: lastPh, temp: lastTemp, turbidity: lastTurbidity));
          if (lastPh != null) { phSum += lastPh!; phCount++; }
          if (lastTemp != null) { tempSum += lastTemp!; tempCount++; }
          if (lastTurbidity != null) { turbSum += lastTurbidity!; turbCount++; }
        }
      }

      setState(() {
        _history = data;
        _chartData = parsedChartData;
        _avgPh = phCount > 0 ? phSum / phCount : null;
        _avgTemp = tempCount > 0 ? tempSum / tempCount : null;
        _avgTurbidity = turbCount > 0 ? turbSum / turbCount : null;
      });
    } catch (e) {
      debugPrint('Dashboard history error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    // ตั้งชื่อหัวข้อตามช่วงเวลาที่เลือก
    String headerText = '';
    if (_selectedTimeframe == '20m') headerText = '20 นาที';
    else if (_selectedTimeframe == '30m') headerText = '30 นาที';
    else if (_selectedTimeframe == '1h') headerText = '1 ชั่วโมง';
    else headerText = '7 วัน';

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.tank.name, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: RefreshIndicator(
        onRefresh: _loadHistory,
        child: _loading && _chartData.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                children: [
                  // ตัวเลือกช่วงเวลา (Segmented Picker)
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: '20m', label: Text('20 นาที')),
                      ButtonSegment(value: '30m', label: Text('30 นาที')),
                      ButtonSegment(value: '1h', label: Text('1 ชม.')),
                      ButtonSegment(value: '7d', label: Text('7 วัน')),
                    ],
                    selected: {_selectedTimeframe},
                    onSelectionChanged: (Set<String> newSelection) {
                      setState(() {
                        _selectedTimeframe = newSelection.first;
                        _loadHistory(); // โหลดข้อมูลใหม่เมื่อเปลี่ยนแท็บ
                      });
                    },
                    style: SegmentedButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ===== ค่าเฉลี่ย =====
                  _buildAvgHeader(cs, headerText),
                  const SizedBox(height: 24),

                  if (_chartData.isEmpty && !_loading) ...[
                    const SizedBox(height: 40),
                    Center(
                      child: Column(
                        children: [
                          Icon(Icons.info_outline, size: 48, color: cs.onSurfaceVariant),
                          const SizedBox(height: 12),
                          Text('ยังไม่มีข้อมูลประวัติ', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 16)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 40),
                  ],

                  if (_chartData.isNotEmpty) ...[
                    // pH line chart
                    _sectionTitle('pH ($headerText)'),
                    const SizedBox(height: 8),
                    _buildLineChart(
                      getValue: (d) => d.ph,
                      avgValue: _avgPh,
                      lineColor: const Color(0xFF7C4DFF),
                      maxY: 14,
                      unit: '',
                    ),
                    const SizedBox(height: 24),

                    // Temp line chart
                    _sectionTitle('Temperature ($headerText)'),
                    const SizedBox(height: 8),
                    _buildLineChart(
                      getValue: (d) => d.temp,
                      avgValue: _avgTemp,
                      lineColor: const Color(0xFFFF5252),
                      maxY: 50,
                      unit: '°C',
                    ),
                    const SizedBox(height: 24),

                    // Turbidity line chart
                    _sectionTitle('Turbidity ($headerText)'),
                    const SizedBox(height: 8),
                    _buildLineChart(
                      getValue: (d) => d.turbidity,
                      avgValue: _avgTurbidity,
                      lineColor: const Color(0xFF00BFA5),
                      maxY: null,
                      unit: ' NTU',
                    ),
                    const SizedBox(height: 24),
                  ],

                  // ปุ่ม Refresh
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _loading ? null : _loadHistory,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    ),
                  ),

                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                ],
              ),
      ),
    );
  }

  // ---------- Widgets ----------

  Widget _sectionTitle(String text) =>
      Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700));

  Widget _buildAvgHeader(ColorScheme cs, String headerText) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cs.primaryContainer, cs.secondaryContainer],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: cs.primary.withValues(alpha: 0.12), blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        children: [
          Icon(Icons.analytics_rounded, size: 34, color: cs.primary),
          const SizedBox(height: 6),
          Text('ค่าเฉลี่ย $headerText',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: cs.onPrimaryContainer)),
          const SizedBox(height: 16),
          Row(children: [
            _avgChip(Icons.science, 'pH', _avgPh?.toStringAsFixed(1) ?? '-', const Color(0xFF7C4DFF)),
            _avgChip(Icons.thermostat, 'Temp', _avgTemp != null ? '${_avgTemp!.toStringAsFixed(1)}°C' : '-', const Color(0xFFFF5252)),
            _avgChip(Icons.water_drop, 'Turbid', _avgTurbidity != null ? '${_avgTurbidity!.toStringAsFixed(1)}' : '-', const Color(0xFF00BFA5)),
          ]),
        ],
      ),
    );
  }

  Widget _avgChip(IconData icon, String label, String value, Color color) {
    return Expanded(
      child: Column(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: Icon(icon, color: color, size: 24),
        ),
        const SizedBox(height: 6),
        Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
      ]),
    );
  }

  Widget _buildLineChart({
    required double? Function(_ChartData) getValue,
    required double? avgValue,
    required Color lineColor,
    required double? maxY,
    required String unit,
  }) {
    final spots = <FlSpot>[];
    for (int i = 0; i < _chartData.length; i++) {
      final v = getValue(_chartData[i]);
      if (v != null) spots.add(FlSpot(i.toDouble(), v));
    }

    double computedMaxY = maxY ?? 10;
    if (maxY == null) {
      double maxVal = 0;
      for (final s in spots) {
        if (s.y > maxVal) maxVal = s.y;
      }
      if (avgValue != null && avgValue > maxVal) maxVal = avgValue;
      computedMaxY = (maxVal * 1.3).ceilToDouble();
      if (computedMaxY < 1) computedMaxY = 10;
    }

    // ตั้งค่าความห่างของแกน X (ให้แสดงทุกกี่นาที / กี่วัน)
    double xInterval = 1;
    if (_selectedTimeframe == '1h') {
      xInterval = 30; // แสดงป้ายกำกับทีละครึ่งชั่วโมง
    } else if (_selectedTimeframe == '30m') {
      xInterval = 10; // แสดงทีละ 10 นาที
    } else if (_selectedTimeframe == '20m') {
      xInterval = 5;  // แสดงทีละ 5 นาที
    } else if (_selectedTimeframe == '7d') {
      xInterval = 1;  // แสดงทุก 1 วัน
    }

    return Container(
      height: 220,
      padding: const EdgeInsets.fromLTRB(4, 16, 16, 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: spots.isEmpty
          ? const Center(child: Text('ไม่มีข้อมูล', style: TextStyle(color: Colors.grey)))
          : LineChart(
              LineChartData(
                minY: 0,
                maxY: computedMaxY,
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (spots) => spots.map((s) {
                      final label = _chartData[s.spotIndex].label;
                      return LineTooltipItem(
                        '$label\n${s.y.toStringAsFixed(1)}$unit',
                        const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                      );
                    }).toList(),
                  ),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      interval: xInterval, 
                      getTitlesWidget: (value, meta) {
                        final idx = value.toInt();
                        if (idx < 0 || idx >= _chartData.length) return const SizedBox.shrink();
                        return SideTitleWidget(
                          meta: meta,
                          space: 6,
                          child: Text(_chartData[idx].label,
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      getTitlesWidget: (value, meta) {
                        return Text(value.toStringAsFixed(0),
                            style: const TextStyle(fontSize: 10, color: Colors.black54));
                      },
                    ),
                  ),
                ),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: computedMaxY / 5,
                  getDrawingHorizontalLine: (value) =>
                      FlLine(color: Colors.grey.withValues(alpha: 0.15), strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
                extraLinesData: avgValue != null
                    ? ExtraLinesData(horizontalLines: [
                        HorizontalLine(
                          y: avgValue,
                          color: lineColor.withValues(alpha: 0.4),
                          strokeWidth: 1.5,
                          dashArray: [6, 4],
                          label: HorizontalLineLabel(
                            show: true,
                            alignment: Alignment.topRight,
                            style: TextStyle(color: lineColor, fontSize: 10, fontWeight: FontWeight.w700),
                            labelResolver: (_) => 'AVG ${avgValue.toStringAsFixed(1)}$unit',
                          ),
                        ),
                      ])
                    : const ExtraLinesData(),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    color: lineColor,
                    barWidth: 3,
                    dotData: FlDotData(
                      show: true,
                      checkToShowDot: (spot, barData) => _chartData.length <= 15,
                      getDotPainter: (spot, _, __, ___) =>
                          FlDotCirclePainter(radius: 4, color: lineColor, strokeWidth: 2, strokeColor: Colors.white),
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      color: lineColor.withValues(alpha: 0.10),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _ChartData {
  final String label;
  final double? ph;
  final double? temp;
  final double? turbidity;
  const _ChartData({required this.label, this.ph, this.temp, this.turbidity});
}