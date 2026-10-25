// SpeedCheck – تطبيق قياس سرعة الإنترنت
// ملف واحد (main.dart) بدون أي حزم خارجية — يعمل على أندرويد وiOS وسطح المكتب.
//
// الصلاحيات:
//  • أندرويد: أضف في android/app/src/main/AndroidManifest.xml
//      <uses-permission android:name="android.permission.INTERNET"/>
//  • macOS: فعّل com.apple.security.network.client في ملفات entitlements.
//
// ملاحظة: يستخدم dart:io لذلك لا يعمل على الويب.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

void main() => runApp(const SpeedCheckApp());

// ───────────────────────── الألوان ─────────────────────────
class AppColors {
  static const bg = Color(0xFF0A1020);
  static const bgGlow = Color(0xFF14264A);
  static const card = Color(0x0DFFFFFF); // أبيض 5%
  static const border = Color(0x17FFFFFF); // أبيض 9%
  static const text = Color(0xFFF1F5FB);
  static const muted = Color(0xFF9AA8C0);
  static const teal = Color(0xFF2DD4BF);
  static const blue = Color(0xFF5B8CFF);
  static const lightBlue = Color(0xFF8FB0FF);
  static const amber = Color(0xFFF5B94A);
  static const green = Color(0xFF6EE7B7);
  static const track = Color(0xFF1C2A47);
  static const gradient = LinearGradient(colors: [teal, blue]);
}

// ───────────────────────── النماذج ─────────────────────────
class TestResult {
  TestResult({
    required this.download,
    required this.upload,
    required this.ping,
    required this.jitter,
  }) : date = DateTime.now();

  final double download; // Mbps
  final double upload; // Mbps
  final double ping; // ms
  final double jitter; // ms
  final DateTime date;

  String get quality {
    if (download >= 100) return 'ممتاز للبث 4K والألعاب';
    if (download >= 25) return 'جيد للبث بجودة HD';
    if (download >= 5) return 'مناسب للتصفح والمكالمات';
    return 'اتصال بطيء';
  }
}

// ───────────────────────── خدمة القياس ─────────────────────────
class SpeedService {
  static const _down = 'https://speed.cloudflare.com/__down?bytes=';
  static const _up = 'https://speed.cloudflare.com/__up';

  /// زمن الاستجابة (الوسيط) والـ Jitter.
  Future<({double ping, double jitter})> measurePing() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    final samples = <int>[];
    try {
      for (var i = 0; i < 6; i++) {
        final sw = Stopwatch()..start();
        final req = await client.getUrl(Uri.parse('${_down}0'));
        final res = await req.close();
        await res.drain<void>();
        samples.add(sw.elapsedMilliseconds);
      }
    } finally {
      client.close(force: true);
    }
    var jitter = 0.0;
    for (var i = 1; i < samples.length; i++) {
      jitter += (samples[i] - samples[i - 1]).abs();
    }
    jitter /= max(1, samples.length - 1);
    final sorted = [...samples]..sort();
    return (ping: sorted[sorted.length ~/ 2].toDouble(), jitter: jitter);
  }

  /// بث السرعة الحالية بالميغابت/ثانية أثناء التحميل.
  Stream<double> measureDownload({
    int bytes = 50000000,
    Duration limit = const Duration(seconds: 8),
  }) async* {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.parse('$_down$bytes'));
      final res = await req.close();
      final sw = Stopwatch()..start();
      var received = 0;
      await for (final chunk in res) {
        received += chunk.length;
        if (sw.elapsedMilliseconds > 250) {
          // بت لكل ميكروثانية = ميغابت/ثانية
          yield received * 8 / max(1, sw.elapsedMicroseconds);
        }
        if (sw.elapsed > limit) break;
      }
    } finally {
      client.close(force: true);
    }
  }

  /// بث السرعة الحالية أثناء الرفع.
  Stream<double> measureUpload({int bytes = 10000000}) async* {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(Uri.parse(_up));
      req.headers.contentType = ContentType.binary;
      req.contentLength = bytes;
      final chunk = Uint8List(64 * 1024);
      final sw = Stopwatch()..start();
      var sent = 0;
      while (sent < bytes) {
        final n = min(chunk.length, bytes - sent);
        req.add(Uint8List.sublistView(chunk, 0, n));
        sent += n;
        await req.flush();
        if (sw.elapsedMilliseconds > 250) {
          yield sent * 8 / max(1, sw.elapsedMicroseconds);
        }
      }
      final res = await req.close();
      await res.drain<void>();
    } finally {
      client.close(force: true);
    }
  }
}

// ───────────────────────── الحالة ─────────────────────────
enum Phase { idle, ping, download, upload, done, error }

class TestController extends ChangeNotifier {
  final _service = SpeedService();

  Phase phase = Phase.idle;
  double live = 0;
  double? ping, download, upload;
  TestResult? last;
  final List<TestResult> history = [];

  bool get running =>
      phase == Phase.ping || phase == Phase.download || phase == Phase.upload;

  String get statusText => switch (phase) {
        Phase.idle => 'جاهز للاختبار',
        Phase.ping => 'قياس زمن الاستجابة…',
        Phase.download => 'قياس سرعة التحميل…',
        Phase.upload => 'قياس سرعة الرفع…',
        Phase.done => 'اكتمل الاختبار',
        Phase.error => 'تعذّر الاختبار، تحقّق من الاتصال',
      };

  Future<bool> start() async {
    if (running) return false;
    ping = download = upload = null;
    live = 0;
    phase = Phase.ping;
    notifyListeners();
    try {
      final p = await _service.measurePing();
      ping = p.ping;

      phase = Phase.download;
      live = 0;
      notifyListeners();
      var d = 0.0;
      await for (final v in _service.measureDownload()) {
        d = v;
        live = v;
        notifyListeners();
      }
      download = d;

      phase = Phase.upload;
      live = 0;
      notifyListeners();
      var u = 0.0;
      await for (final v in _service.measureUpload()) {
        u = v;
        live = v;
        notifyListeners();
      }
      upload = u;

      last = TestResult(download: d, upload: u, ping: p.ping, jitter: p.jitter);
      history.insert(0, last!);
      live = d;
      phase = Phase.done;
      notifyListeners();
      return true;
    } catch (_) {
      phase = Phase.error;
      notifyListeners();
      return false;
    }
  }
}

// ───────────────────────── التطبيق ─────────────────────────
class SpeedCheckApp extends StatelessWidget {
  const SpeedCheckApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SpeedCheck',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.teal,
          surface: AppColors.bg,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xE60A1020),
          indicatorColor: AppColors.teal.withOpacity(.14),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (s) => TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: s.contains(WidgetState.selected)
                  ? AppColors.teal
                  : AppColors.muted,
            ),
          ),
          iconTheme: WidgetStateProperty.resolveWith(
            (s) => IconThemeData(
              color: s.contains(WidgetState.selected)
                  ? AppColors.teal
                  : AppColors.muted,
            ),
          ),
        ),
      ),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _ctrl = TestController();
  int _index = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _runTest() async {
    final ok = await _ctrl.start();
    if (ok && mounted) setState(() => _index = 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -1.2),
            radius: 1.2,
            colors: [AppColors.bgGlow, AppColors.bg],
            stops: [0, .6],
          ),
        ),
        child: SafeArea(
          child: ListenableBuilder(
            listenable: _ctrl,
            builder: (context, _) => IndexedStack(
              index: _index,
              children: [
                TestScreen(ctrl: _ctrl, onStart: _runTest),
                ResultsScreen(
                  ctrl: _ctrl,
                  onRetry: () {
                    setState(() => _index = 0);
                    _runTest();
                  },
                ),
                HistoryScreen(ctrl: _ctrl),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.speed_rounded), label: 'الاختبار'),
          NavigationDestination(
              icon: Icon(Icons.bar_chart_rounded), label: 'النتائج'),
          NavigationDestination(
              icon: Icon(Icons.history_rounded), label: 'السجل'),
        ],
      ),
    );
  }
}

// ───────────────────────── شاشة الاختبار ─────────────────────────
class TestScreen extends StatelessWidget {
  const TestScreen({super.key, required this.ctrl, required this.onStart});
  final TestController ctrl;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final shown = ctrl.running ? ctrl.live : (ctrl.last?.download ?? 0);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        children: [
          const _TopBar(),
          const SizedBox(height: 12),
          SpeedGauge(value: shown),
          const SizedBox(height: 4),
          Text(ctrl.statusText,
              style: const TextStyle(color: AppColors.muted, fontSize: 14)),
          const SizedBox(height: 20),
          _StartButton(running: ctrl.running, onTap: onStart),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.arrow_downward_rounded,
                  color: AppColors.teal,
                  label: 'تحميل',
                  value: ctrl.download,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  icon: Icons.arrow_upward_rounded,
                  color: AppColors.lightBlue,
                  label: 'رفع',
                  value: ctrl.upload,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  icon: Icons.network_ping_rounded,
                  color: AppColors.amber,
                  label: 'Ping',
                  value: ctrl.ping,
                  unit: 'ms',
                  decimals: 0,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: AppColors.gradient,
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.bolt_rounded, color: Color(0xFF04141F)),
            ),
            const SizedBox(width: 10),
            const Text('SpeedCheck',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          ],
        ),
        const _Chip(label: 'متصل', dot: Color(0xFF34D399)),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.dot});
  final String label;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.07),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(label,
              style: const TextStyle(fontSize: 12, color: Color(0xFFC9D4E6))),
        ],
      ),
    );
  }
}

class _StartButton extends StatelessWidget {
  const _StartButton({required this.running, required this.onTap});
  final bool running;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: running ? 'الاختبار قيد التنفيذ' : 'ابدأ اختبار السرعة',
      child: Container(
        width: 136,
        height: 136,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: AppColors.gradient,
          boxShadow: [
            BoxShadow(
                color: AppColors.teal.withOpacity(.12), spreadRadius: 10),
            BoxShadow(color: AppColors.teal.withOpacity(.06), spreadRadius: 22),
            BoxShadow(
                color: AppColors.teal.withOpacity(.35),
                blurRadius: 40,
                offset: const Offset(0, 12)),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: running ? null : onTap,
            child: Center(
              child: running
                  ? const SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(
                        strokeWidth: 3.5,
                        color: Color(0xFF04141F),
                      ),
                    )
                  : const Text(
                      'ابدأ',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF04141F),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── العداد ─────────────────────────
class SpeedGauge extends StatelessWidget {
  const SpeedGauge({super.key, required this.value});
  final double value;

  static double _scaleFor(double v) {
    for (final m in const [100.0, 200.0, 500.0, 1000.0]) {
      if (v <= m * .95) return m;
    }
    return 2000;
  }

  @override
  Widget build(BuildContext context) {
    final maxValue = _scaleFor(value);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      builder: (context, v, _) {
        return SizedBox(
          width: 320,
          height: 200,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _GaugePainter(
                    fraction: (v / maxValue).clamp(0.0, 1.0),
                  ),
                ),
              ),
              Positioned(
                top: 62,
                child: Column(
                  children: [
                    Text(
                      v.toStringAsFixed(1),
                      style: const TextStyle(
                        fontSize: 52,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                      ),
                    ),
                    const Text('ميغابت / ثانية',
                        style:
                            TextStyle(color: AppColors.muted, fontSize: 13)),
                  ],
                ),
              ),
              Positioned(
                bottom: 14,
                left: 22,
                child: Text('${maxValue.toInt()}',
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11)),
              ),
              const Positioned(
                bottom: 14,
                right: 30,
                child: Text('0',
                    style: TextStyle(color: AppColors.muted, fontSize: 11)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.fraction});
  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 30);
    final radius = size.width * .385;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // علامات القياس
    final tick = Paint()
      ..color = const Color(0xFF3A4C6E)
      ..strokeWidth = 2;
    for (var i = 0; i <= 6; i++) {
      final a = pi + pi * i / 6;
      final dir = Offset(cos(a), sin(a));
      canvas.drawLine(
        center + dir * (radius + 16),
        center + dir * (radius + 26),
        tick,
      );
    }

    // المسار الخلفي
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16
      ..strokeCap = StrokeCap.round
      ..color = AppColors.track;
    canvas.drawArc(rect, pi, pi, false, track);

    // قوس التقدّم
    if (fraction > 0) {
      final progress = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16
        ..strokeCap = StrokeCap.round
        ..shader = const SweepGradient(
          startAngle: pi,
          endAngle: 2 * pi,
          colors: [AppColors.teal, AppColors.blue],
        ).createShader(rect);
      canvas.drawArc(rect, pi, pi * fraction, false, progress);
    }

    // المؤشر
    final a = pi + pi * fraction;
    final knob = center + Offset(cos(a), sin(a)) * radius;
    canvas.drawCircle(knob, 11, Paint()..color = AppColors.teal);
    canvas.drawCircle(knob, 6.5, Paint()..color = AppColors.text);
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.fraction != fraction;
}

// ───────────────────────── مكوّنات مشتركة ─────────────────────────
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.gradient,
  });
  final Widget child;
  final EdgeInsets padding;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? AppColors.card : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.unit = '',
    this.decimals = 1,
  });
  final IconData icon;
  final Color color;
  final String label;
  final double? value;
  final String unit;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 4),
              Text(label,
                  style:
                      const TextStyle(color: AppColors.muted, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              text: value == null ? '—' : value!.toStringAsFixed(decimals),
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              children: [
                if (value != null && unit.isNotEmpty)
                  TextSpan(
                    text: ' $unit',
                    style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.muted,
                        fontWeight: FontWeight.w400),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDate(DateTime d) {
  final now = DateTime.now();
  final t =
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  final sameDay = d.year == now.year && d.month == now.month && d.day == now.day;
  if (sameDay) return 'اليوم · $t';
  final y = now.subtract(const Duration(days: 1));
  if (d.year == y.year && d.month == y.month && d.day == y.day) {
    return 'أمس · $t';
  }
  return '${d.day}/${d.month}/${d.year} · $t';
}

// ───────────────────────── شاشة النتائج ─────────────────────────
class ResultsScreen extends StatelessWidget {
  const ResultsScreen({super.key, required this.ctrl, required this.onRetry});
  final TestController ctrl;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final r = ctrl.last;
    if (r == null) {
      return const Center(
        child: Text('لا توجد نتائج بعد — ابدأ أول اختبار',
            style: TextStyle(color: AppColors.muted)),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('نتيجة الاختبار',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              _Chip(label: _formatDate(r.date)),
            ],
          ),
          const SizedBox(height: 14),
          GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
            gradient: LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [
                AppColors.teal.withOpacity(.16),
                AppColors.blue.withOpacity(.10),
              ],
            ),
            child: Column(
              children: [
                const Text('سرعة التحميل',
                    style: TextStyle(color: AppColors.muted, fontSize: 13)),
                ShaderMask(
                  shaderCallback: (b) => const LinearGradient(
                    colors: [AppColors.teal, AppColors.lightBlue],
                  ).createShader(b),
                  child: Text(
                    r.download.toStringAsFixed(1),
                    style: const TextStyle(
                      fontSize: 68,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.15,
                    ),
                  ),
                ),
                const Text('ميغابت / ثانية',
                    style: TextStyle(color: AppColors.muted, fontSize: 13)),
                const SizedBox(height: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.07),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(r.quality,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.green)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.arrow_upward_rounded,
                  color: AppColors.lightBlue,
                  label: 'الرفع',
                  value: r.upload,
                  unit: 'Mbps',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  icon: Icons.network_ping_rounded,
                  color: AppColors.amber,
                  label: 'Ping',
                  value: r.ping,
                  unit: 'ms',
                  decimals: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.show_chart_rounded,
                  color: const Color(0xFFC9D4E6),
                  label: 'Jitter',
                  value: r.jitter,
                  unit: 'ms',
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: GlassCard(
                  padding: EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('الخادم',
                          style:
                              TextStyle(color: AppColors.muted, fontSize: 13)),
                      SizedBox(height: 6),
                      Text('Cloudflare',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: onRetry,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.teal,
                foregroundColor: const Color(0xFF04141F),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: const Text('إعادة الاختبار',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── شاشة السجل ─────────────────────────
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.ctrl});
  final TestController ctrl;

  @override
  Widget build(BuildContext context) {
    final items = ctrl.history;
    if (items.isEmpty) {
      return const Center(
        child: Text('السجل فارغ',
            style: TextStyle(color: AppColors.muted)),
      );
    }
    final recent = items.take(7).toList().reversed.toList();
    final maxDl = recent.map((e) => e.download).reduce(max);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        const Text('السجل',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('التحميل · آخر ${recent.length} اختبارات (Mbps)',
                  style:
                      const TextStyle(color: AppColors.muted, fontSize: 13)),
              const SizedBox(height: 14),
              SizedBox(
                height: 130,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < recent.length; i++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text(recent[i].download.toStringAsFixed(0),
                                  style: const TextStyle(
                                      fontSize: 10, color: AppColors.muted)),
                              const SizedBox(height: 4),
                              Container(
                                height: 14 +
                                    80 *
                                        (maxDl == 0
                                            ? 0
                                            : recent[i].download / maxDl),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(7),
                                  gradient: const LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      AppColors.teal,
                                      Color(0xFF3B82F6)
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        for (final r in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GlassCard(
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.teal.withOpacity(.14),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(Icons.arrow_downward_rounded,
                        color: AppColors.teal, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(_formatDate(r.date),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text.rich(
                        TextSpan(
                          text: r.download.toStringAsFixed(1),
                          style: const TextStyle(
                              color: AppColors.teal,
                              fontSize: 17,
                              fontWeight: FontWeight.w800),
                          children: const [
                            TextSpan(
                              text: ' Mbps',
                              style: TextStyle(
                                  color: AppColors.muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w400),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '↑ ${r.upload.toStringAsFixed(1)} · ${r.ping.toStringAsFixed(0)} ms',
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}