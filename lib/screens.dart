import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'models.dart';
import 'services.dart';

const _catColors = {
  'Food': Colors.orange,
  'Transport': Colors.blue,
  'Shopping': Colors.purple,
  'Entertainment': Colors.pink,
  'Others': Colors.grey,
};

// Custom and AI-suggested categories get a stable colour from their name.
const _extraColors = [
  Colors.teal, Colors.indigo, Colors.brown, Colors.cyan, Colors.green,
  Colors.red, Colors.amber, Colors.deepOrange, Colors.blueGrey, Colors.lightBlue,
];

Color _catColor(String c) =>
    _catColors[c] ?? _extraColors[c.toLowerCase().codeUnits.fold(0, (a, b) => (a * 31 + b) & 0xffffff) % _extraColors.length];

// Keys are lower case so AI suggestions match whatever their capitalisation.
const _catIcons = {
  'food': Icons.restaurant,
  'transport': Icons.directions_car,
  'shopping': Icons.shopping_bag,
  'entertainment': Icons.movie,
  'others': Icons.category,
  'groceries': Icons.shopping_cart,
  'petrol': Icons.local_gas_station,
  'fuel': Icons.local_gas_station,
  'bills': Icons.receipt,
  'utilities': Icons.bolt,
  'health': Icons.medical_services,
  'medical': Icons.medical_services,
  'education': Icons.school,
  'personal care': Icons.spa,
  'beauty': Icons.face,
  'home': Icons.home,
  'household': Icons.home,
  'travel': Icons.flight,
  'coffee': Icons.local_cafe,
  'drinks': Icons.local_cafe,
  'gifts': Icons.card_giftcard,
  'pets': Icons.pets,
  'fitness': Icons.fitness_center,
  'sports': Icons.sports_soccer,
  'subscriptions': Icons.subscriptions,
  'parking': Icons.local_parking,
  'toll': Icons.toll,
  'phone': Icons.phone_android,
  'insurance': Icons.shield,
  'charity': Icons.volunteer_activism,
  'kids': Icons.child_care,
  'electronics': Icons.devices,
  'clothing': Icons.checkroom,
};

IconData _catIcon(String c) => _catIcons[c.toLowerCase()] ?? Icons.label_outline;

const _paymentIcons = {
  'Cash': Icons.payments,
  'Debit/Credit card': Icons.credit_card,
  'DuitNow QR': Icons.qr_code,
  'Online banking': Icons.account_balance,
  'Other': Icons.more_horiz,
};

IconData _paymentIcon(String p) => _paymentIcons[p] ?? Icons.account_balance_wallet; // e-wallets

String _fmt(double? v) => v == null ? '' : v.toStringAsFixed(2);
String _qty(double q) => q == q.roundToDouble() ? '${q.toInt()}' : '$q';

/// Asks for a new category name. Returns the user's existing spelling if it matches one.
Future<String?> _askCategory(BuildContext context, List<String> existing) async {
  final ctl = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('New category'),
      content: TextField(
        controller: ctl,
        autofocus: true,
        maxLength: 24,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(hintText: 'e.g. Groceries, Bills, Health'),
        onSubmitted: (v) => Navigator.pop(c, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Add')),
      ],
    ),
  );
  final n = name?.trim() ?? '';
  if (n.isEmpty) return null;
  return existing.firstWhere((k) => k.toLowerCase() == n.toLowerCase(), orElse: () => n);
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'
];

void _snack(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));
String _rm(double v) => 'RM ${v.toStringAsFixed(2)}';
String _day(DateTime d) => '${d.day} ${_months[d.month - 1].substring(0, 3)} ${d.year}';

// The profile photo is a small base64 JPEG in the Firestore profile (Storage needs the paid plan).
String? _lastPhoto;
MemoryImage? _lastPhotoImage;
ImageProvider? _photoOf(Map<String, dynamic>? p) {
  final s = p?['photo'];
  if (s is! String || s.isEmpty) return null;
  if (s != _lastPhoto) {
    _lastPhoto = s;
    _lastPhotoImage = MemoryImage(base64Decode(s));
  }
  return _lastPhotoImage;
}

class _Avatar extends StatelessWidget {
  final Map<String, dynamic>? profile;
  final double radius;
  const _Avatar(this.profile, {this.radius = 20});

  @override
  Widget build(BuildContext context) {
    final photo = _photoOf(profile);
    final name = (profile?['name'] ?? '') as String;
    final cs = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: cs.primaryContainer,
      foregroundImage: photo,
      child: Text(name.isEmpty ? '?' : name[0].toUpperCase(),
          style: TextStyle(fontSize: radius * 0.8, color: cs.onPrimaryContainer)),
    );
  }
}

/// Rounded card with a title, used for each dashboard section.
class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  const _Section({required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              ?trailing,
            ]),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );
}

// ───────────── UC01: Register / Login ─────────────
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _name = TextEditingController(), _email = TextEditingController(), _pass = TextEditingController();
  bool _register = false, _busy = false;

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final auth = FirebaseAuth.instance;
      if (_register) {
        final c = await auth.createUserWithEmailAndPassword(email: _email.text.trim(), password: _pass.text);
        await c.user?.updateDisplayName(_name.text.trim());
        await Repo.saveProfile({'name': _name.text.trim(), 'currency': 'MYR', 'monthlyBudget': 0.0});
      } else {
        await auth.signInWithEmailAndPassword(email: _email.text.trim(), password: _pass.text);
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) _snack(context, e.message ?? 'Authentication failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(
                radius: 40,
                backgroundColor: cs.primaryContainer,
                child: Icon(Icons.receipt_long, size: 40, color: cs.onPrimaryContainer)),
            const SizedBox(height: 16),
            Text('Keihi', style: Theme.of(context).textTheme.displaySmall),
            Text('Track your spending from receipts', style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 32),
            if (_register) ...[
              TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                      labelText: 'Name', prefixIcon: Icon(Icons.person_outline), border: OutlineInputBorder())),
              const SizedBox(height: 12),
            ],
            TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                    labelText: 'Email', prefixIcon: Icon(Icons.email_outlined), border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(
                controller: _pass,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Password', prefixIcon: Icon(Icons.lock_outline), border: OutlineInputBorder())),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                  onPressed: _busy ? null : _submit, child: Text(_register ? 'Register' : 'Log in')),
            ),
            TextButton(
                onPressed: () => setState(() => _register = !_register),
                child: Text(_register ? 'Have an account? Log in' : 'No account? Register')),
          ]),
        ),
      ),
    );
  }
}

// ───────────── Shell: Ledger / Scan / Profile ─────────────
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _i = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: _i, children: [
          LedgerPage(onScan: () => setState(() => _i = 1), onProfile: () => setState(() => _i = 2)),
          const ScanPage(),
          const ProfilePage(),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _i,
          onDestinationSelected: (i) => setState(() => _i = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Ledger'),
            NavigationDestination(icon: Icon(Icons.document_scanner), label: 'Scan'),
            NavigationDestination(icon: Icon(Icons.person), label: 'Profile'),
          ],
        ),
      );
}

// ───────────── UC02: Financial ledger dashboard ─────────────

/// Numbers shown on the dashboard, all for the current month unless noted.
class _Stats {
  final double month, today, week, dailyAvg;
  final int count;
  final Map<String, double> byCat;
  final List<double> daily; // index 0 = day 1

  factory _Stats(List<Txn> all, DateTime now) {
    final start = DateTime(now.year, now.month);
    final today = DateTime(now.year, now.month, now.day);
    final weekStart = today.subtract(const Duration(days: 6));
    final inMonth = all.where((t) => !t.date.isBefore(start) && t.date.month == now.month).toList();
    final daily = List<double>.filled(DateUtils.getDaysInMonth(now.year, now.month), 0);
    final byCat = <String, double>{};
    for (final t in inMonth) {
      daily[t.date.day - 1] += t.amount;
      byCat[t.category] = (byCat[t.category] ?? 0) + t.amount;
    }
    final month = inMonth.fold<double>(0, (a, t) => a + t.amount);
    double sumFrom(DateTime from) => all.where((t) => !t.date.isBefore(from)).fold(0, (a, t) => a + t.amount);
    return _Stats._(month, sumFrom(today), sumFrom(weekStart), month / now.day, inMonth.length, byCat, daily);
  }

  _Stats._(this.month, this.today, this.week, this.dailyAvg, this.count, this.byCat, this.daily);
}

class LedgerPage extends StatelessWidget {
  final VoidCallback onScan, onProfile;
  const LedgerPage({super.key, required this.onScan, required this.onProfile});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: StreamBuilder<Map<String, dynamic>>(
            stream: Repo.profile(),
            builder: (c, p) => StreamBuilder<List<Txn>>(
              stream: Repo.txns(),
              builder: (c, s) {
                if (s.hasError) return Center(child: Text('Failed to load: ${s.error}'));
                if (!s.hasData) return const Center(child: CircularProgressIndicator());
                final all = s.data!;
                final now = DateTime.now();
                final st = _Stats(all, now);
                final budget = ((p.data?['monthlyBudget']) as num?)?.toDouble() ?? 0;
                final name = (p.data?['name'] ?? '') as String;
                return ListView(padding: const EdgeInsets.only(bottom: 16), children: [
                  ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    leading: GestureDetector(onTap: onProfile, child: _Avatar(p.data, radius: 22)),
                    title: Text(name.isEmpty ? 'Hi there' : 'Hi, $name',
                        style: Theme.of(context).textTheme.titleLarge),
                    subtitle: Text('${_months[now.month - 1]} ${now.year}'),
                  ),
                  _BudgetCard(spent: st.month, budget: budget, onSetBudget: onProfile),
                  _StatGrid(st),
                  if (st.month > 0) _CategoryCard(st),
                  _Section(
                    title: 'Recent transactions',
                    trailing: all.length > 5
                        ? TextButton(
                            onPressed: () => Navigator.push(
                                context, MaterialPageRoute(builder: (_) => const TransactionsPage())),
                            child: const Text('See all'))
                        : null,
                    child: all.isEmpty
                        ? _EmptyTxns(onScan: onScan)
                        : Column(children: [for (final t in all.take(5)) _TxnTile(t)]),
                  ),
                  _DailyChart(st.daily, now),
                ]);
              },
            ),
          ),
        ),
      );
}

class _BudgetCard extends StatelessWidget {
  final double spent, budget;
  final VoidCallback onSetBudget;
  const _BudgetCard({required this.spent, required this.budget, required this.onSetBudget});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final over = budget > 0 && spent > budget;
    final onCard = cs.onPrimary;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      clipBehavior: Clip.antiAlias,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [cs.primary, Color.lerp(cs.primary, cs.tertiary, 0.6)!],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Spent this month', style: tt.titleSmall?.copyWith(color: onCard.withValues(alpha: 0.85))),
          const SizedBox(height: 4),
          Text(_rm(spent), style: tt.displaySmall?.copyWith(color: onCard, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          if (budget > 0) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                minHeight: 10,
                value: (spent / budget).clamp(0, 1).toDouble(),
                backgroundColor: onCard.withValues(alpha: 0.25),
                color: over ? Colors.redAccent : onCard,
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Text(over ? '${_rm(spent - budget)} over budget' : '${_rm(budget - spent)} left',
                    style: tt.bodyMedium?.copyWith(color: onCard, fontWeight: FontWeight.w600)),
              ),
              Text('Budget ${_rm(budget)}', style: tt.bodySmall?.copyWith(color: onCard.withValues(alpha: 0.85))),
            ]),
          ] else
            OutlinedButton.icon(
              onPressed: onSetBudget,
              style: OutlinedButton.styleFrom(foregroundColor: onCard, side: BorderSide(color: onCard)),
              icon: const Icon(Icons.savings_outlined),
              label: const Text('Set a monthly budget'),
            ),
        ]),
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  final _Stats st;
  const _StatGrid(this.st);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(children: [
          Row(children: [
            Expanded(child: _StatCard(icon: Icons.today, label: 'Today', value: _rm(st.today))),
            const SizedBox(width: 12),
            Expanded(child: _StatCard(icon: Icons.date_range, label: 'Last 7 days', value: _rm(st.week))),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _StatCard(icon: Icons.show_chart, label: 'Daily average', value: _rm(st.dailyAvg))),
            const SizedBox(width: 12),
            Expanded(child: _StatCard(icon: Icons.receipt, label: 'Receipts this month', value: '${st.count}')),
          ]),
        ]),
      );
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label, value;
  const _StatCard({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: cs.primary),
        const SizedBox(height: 8),
        Text(label, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        ),
      ]),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  final _Stats st;
  const _CategoryCard(this.st);

  @override
  Widget build(BuildContext context) {
    final cats = st.byCat.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    return _Section(
      title: 'By category',
      child: Row(children: [
        SizedBox(
          width: 120,
          height: 120,
          child: PieChart(PieChartData(sectionsSpace: 2, centerSpaceRadius: 32, sections: [
            for (final e in cats)
              PieChartSectionData(value: e.value, color: _catColor(e.key), radius: 24, showTitle: false),
          ])),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(children: [
            for (final e in cats)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Icon(_catIcon(e.key), size: 18, color: _catColor(e.key)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(e.key)),
                  Text('${(e.value / st.month * 100).round()}%',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                  const SizedBox(width: 8),
                  Text(_rm(e.value), style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _DailyChart extends StatelessWidget {
  final List<double> daily;
  final DateTime now;
  const _DailyChart(this.daily, this.now);

  static String _compact(double v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : v.toStringAsFixed(0);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxY = math.max(10.0, daily.reduce(math.max) * 1.2);
    final label = TextStyle(fontSize: 10, color: cs.onSurfaceVariant);
    return _Section(
      title: 'Daily spending in ${_months[now.month - 1]}',
      child: SizedBox(
        height: 200,
        child: BarChart(BarChartData(
          maxY: maxY,
          alignment: BarChartAlignment.spaceBetween,
          borderData: FlBorderData(show: false),
          gridData: FlGridData(
              drawVerticalLine: false,
              getDrawingHorizontalLine: (_) => FlLine(color: cs.outlineVariant, strokeWidth: 0.5)),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                getTitlesWidget: (v, meta) => v == meta.max
                    ? const SizedBox.shrink()
                    : SideTitleWidget(meta: meta, child: Text(_compact(v), style: label)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (v, meta) {
                  final d = v.toInt();
                  final show = d == 1 || d % 5 == 0;
                  return SideTitleWidget(meta: meta, child: Text(show ? '$d' : '', style: label));
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => cs.inverseSurface,
              getTooltipItem: (g, _, rod, _) => BarTooltipItem(
                  '${g.x} ${_months[now.month - 1].substring(0, 3)}\n${_rm(rod.toY)}',
                  TextStyle(color: cs.onInverseSurface, fontSize: 12)),
            ),
          ),
          barGroups: [
            for (var i = 0; i < daily.length; i++)
              BarChartGroupData(x: i + 1, barRods: [
                BarChartRodData(
                  toY: daily[i],
                  width: 6,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                  color: i + 1 == now.day ? cs.primary : cs.primary.withValues(alpha: 0.45),
                ),
              ]),
          ],
        )),
      ),
    );
  }
}

class _EmptyTxns extends StatelessWidget {
  final VoidCallback onScan;
  const _EmptyTxns({required this.onScan});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Column(children: [
            Icon(Icons.receipt_long_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 8),
            const Text('No transactions yet'),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
                onPressed: onScan, icon: const Icon(Icons.document_scanner), label: const Text('Scan a receipt')),
          ]),
        ),
      );
}

class _TxnTile extends StatelessWidget {
  final Txn t;
  const _TxnTile(this.t);

  @override
  Widget build(BuildContext context) => Dismissible(
        key: ValueKey(t.id),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16),
          decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.delete, color: Colors.white),
        ),
        onDismissed: (_) {
          Repo.remove(t.id!);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Deleted ${t.store.isEmpty ? 'transaction' : t.store}'),
            action: SnackBarAction(label: 'Undo', onPressed: () => Repo.add(t)),
          ));
        },
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReviewPage.edit(t))),
          leading: CircleAvatar(
            backgroundColor: _catColor(t.category).withValues(alpha: 0.15),
            child: Icon(_catIcon(t.category), color: _catColor(t.category)),
          ),
          title: Text(t.store.isEmpty ? '(no store name)' : t.store, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${t.category} • ${_day(t.date)}${t.payment.isEmpty ? '' : ' • ${t.payment}'}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Text(_rm(t.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      );
}

class TransactionsPage extends StatelessWidget {
  const TransactionsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('All transactions')),
        body: StreamBuilder<List<Txn>>(
          stream: Repo.txns(),
          builder: (c, s) {
            if (!s.hasData) return const Center(child: CircularProgressIndicator());
            return ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [for (final t in s.data!) _TxnTile(t)]);
          },
        ),
      );
}

// ───────────── UC03 / UC04: Scan or upload → OCR → Gemini ─────────────
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  int _step = 0; // 0 idle, 1 reading text, 2 asking Gemini
  File? _image;

  Future<void> _pick(ImageSource src) async {
    try {
      // 2048 px keeps small print readable for OCR while keeping the upload to Gemini small.
      final x = await ImagePicker().pickImage(source: src, maxWidth: 2048, maxHeight: 2048, imageQuality: 85);
      if (x == null) return;
      setState(() {
        _image = File(x.path);
        _step = 1;
      });
      final text = await OcrService().read(_image!);
      if (text.trim().isEmpty) {
        if (mounted) _snack(context, 'No text found. Retake the photo in better lighting.');
        return;
      }
      setState(() => _step = 2);
      final aliases = await Repo.storeAliases();
      final parsed = await GeminiService().parse(text,
          image: _image, knownStores: aliases.values.toSet().take(50).toList(), categories: await Repo.categories());
      if (!mounted) return;
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ReviewPage(
                  parsed: parsed,
                  rawText: text,
                  image: _image,
                  storeAlias: aliases[Repo.storeKey(parsed.store)])));
    } catch (e) {
      if (mounted) _snack(context, 'Scan failed: $e');
    } finally {
      if (mounted) setState(() => _step = 0);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan Receipt')),
        body: _step == 0 ? _idle(context) : _busy(context),
      );

  Widget _idle(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(20), children: [
      const SizedBox(height: 8),
      Center(
        child: CircleAvatar(
            radius: 52,
            backgroundColor: cs.primaryContainer,
            child: Icon(Icons.document_scanner_outlined, size: 52, color: cs.onPrimaryContainer)),
      ),
      const SizedBox(height: 16),
      Text('Add a receipt', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 4),
      Text('Keihi reads the receipt and fills in the store, date, total and category for you.',
          textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
      const SizedBox(height: 24),
      _OptionCard(
          icon: Icons.photo_camera,
          title: 'Take a photo',
          subtitle: 'Use your camera to scan a paper receipt',
          highlight: true,
          onTap: () => _pick(ImageSource.camera)),
      const SizedBox(height: 12),
      _OptionCard(
          icon: Icons.photo_library,
          title: 'Choose from gallery',
          subtitle: 'Pick a receipt photo you already took',
          onTap: () => _pick(ImageSource.gallery)),
      const SizedBox(height: 24),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.lightbulb_outline, color: cs.primary),
            const SizedBox(width: 8),
            Text('Tips for a good scan', style: Theme.of(context).textTheme.titleSmall),
          ]),
          const SizedBox(height: 8),
          for (final tip in const [
            'Lay the receipt flat on a dark surface',
            'Use good lighting and avoid shadows',
            'Fit the whole receipt, including the total, in the frame',
          ])
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.check, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(tip)),
              ]),
            ),
        ]),
      ),
    ]);
  }

  Widget _busy(BuildContext context) => ListView(padding: const EdgeInsets.all(20), children: [
        if (_image != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(_image!, height: 280, fit: BoxFit.cover),
          ),
        const SizedBox(height: 24),
        _StepRow('Reading the receipt text', done: _step > 1, active: _step == 1),
        _StepRow('Understanding the receipt with AI', done: false, active: _step == 2),
      ]);
}

class _OptionCard extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final bool highlight;
  final VoidCallback onTap;
  const _OptionCard(
      {required this.icon, required this.title, required this.subtitle, required this.onTap, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = highlight ? cs.onPrimary : cs.onSurface;
    return Material(
      color: highlight ? cs.primary : cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: highlight ? cs.onPrimary.withValues(alpha: 0.2) : cs.primaryContainer,
              child: Icon(icon, color: highlight ? cs.onPrimary : cs.onPrimaryContainer),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(color: fg.withValues(alpha: 0.8))),
              ]),
            ),
            Icon(Icons.chevron_right, color: fg),
          ]),
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final String label;
  final bool done, active;
  const _StepRow(this.label, {required this.done, required this.active});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: SizedBox(
        width: 28,
        height: 28,
        child: done
            ? Icon(Icons.check_circle, color: cs.primary)
            : active
                ? const Padding(padding: EdgeInsets.all(4), child: CircularProgressIndicator(strokeWidth: 3))
                : Icon(Icons.radio_button_unchecked, color: cs.outline),
      ),
      title: Text(label, style: TextStyle(color: done || active ? cs.onSurface : cs.outline)),
    );
  }
}

// ───────────── UC07: Review, edit, save ─────────────

/// Used after a scan (from [parsed]) and to edit a saved transaction ([ReviewPage.edit]).
class ReviewPage extends StatefulWidget {
  final ParsedReceipt? parsed;
  final Txn? existing;
  final String rawText;
  final File? image;
  final String? storeAlias; // the user's earlier correction of parsed.store, if any

  const ReviewPage(
      {super.key, required ParsedReceipt this.parsed, required this.rawText, this.image, this.storeAlias})
      : existing = null;

  const ReviewPage.edit(Txn this.existing, {super.key})
      : parsed = null,
        rawText = '',
        image = null,
        storeAlias = null;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  late final Txn? _e = widget.existing;
  late final ParsedReceipt? _p = widget.parsed;
  bool get _editing => _e != null;

  late final _store = TextEditingController(text: _e?.store ?? widget.storeAlias ?? _p!.store);
  late final _amount = TextEditingController(text: _fmt(_e?.amount ?? _p!.total));
  late final _receiptNo = TextEditingController(text: _e?.receiptNo ?? _p!.receiptNo);
  late final _tax = TextEditingController(text: _fmt(_e != null ? _e.tax : _p!.tax));
  late final _service = TextEditingController(text: _fmt(_e != null ? _e.serviceCharge : _p!.serviceCharge));
  late final _discount = TextEditingController(text: _fmt(_e != null ? _e.discount : _p!.discount));
  late DateTime _date = _clampDate(_e?.date ?? _p!.date);
  late String _cat = _e?.category ?? _p!.category;
  late String _payment = _e?.payment ?? _p!.payment;
  late final List<TxnItem> _items = List.of(_e?.items ?? _p!.items);

  List<String> _categories = kCategories; // replaced with the user's list once loaded
  late final Set<String> _extra = {_cat}; // AI suggestion or new categories not in the list yet

  @override
  void initState() {
    super.initState();
    Repo.categories().then((c) {
      if (mounted) setState(() => _categories = c);
    });
  }

  // showDatePicker asserts initialDate is within [firstDate, lastDate]; OCR can misread years.
  static DateTime _clampDate(DateTime? d) {
    final now = DateTime.now();
    if (d == null || d.isAfter(now) || d.isBefore(DateTime(2020))) return now;
    return d;
  }

  bool get _catIsNew => !_categories.contains(_cat);

  Future<void> _save() async {
    final amt = double.tryParse(_amount.text.trim());
    if (amt == null || amt <= 0) return _snack(context, 'Enter a valid amount');
    final t = Txn(
      id: _e?.id,
      store: _store.text.trim(),
      amount: amt,
      date: DateTime(_date.year, _date.month, _date.day),
      category: _cat,
      rawText: _e?.rawText ?? widget.rawText,
      payment: _payment,
      receiptNo: _receiptNo.text.trim(),
      tax: double.tryParse(_tax.text.trim()),
      serviceCharge: double.tryParse(_service.text.trim()),
      discount: double.tryParse(_discount.text.trim()),
      items: _items,
    );
    if (!_editing && await Repo.isDuplicate(t)) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Possible duplicate'),
          content: Text(t.receiptNo.isNotEmpty
              ? 'A receipt from this store with the same receipt number is already saved. Save anyway?'
              : 'A transaction with the same store, date and amount exists. Save anyway?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (_catIsNew) Repo.addCategory(_cat);
    if (_p != null && _p.store.isNotEmpty) Repo.learnStore(_p.store, t.store);
    // Not awaited: Firestore's local cache updates at once and syncs when online (UC08 exception flow).
    _editing ? Repo.update(t) : Repo.add(t);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete transaction?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    Repo.remove(_e!.id!);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _newCategory() async {
    final c = await _askCategory(context, [..._categories, ..._extra]);
    if (c != null) {
      setState(() {
        _extra.add(c);
        _cat = c;
      });
    }
  }

  /// Add ([index] null) or edit one line item.
  Future<void> _editItem([int? index]) async {
    final old = index == null ? null : _items[index];
    final name = TextEditingController(text: old?.name ?? '');
    final qty = TextEditingController(text: old == null ? '1' : _qty(old.qty));
    final price = TextEditingController(text: _fmt(old?.price));
    final item = await showDialog<TxnItem>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(index == null ? 'Add item' : 'Edit item'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Item')),
          Row(children: [
            Expanded(
                child: TextField(
                    controller: qty,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Qty'))),
            const SizedBox(width: 12),
            Expanded(
                flex: 2,
                child: TextField(
                    controller: price,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Line total', prefixText: 'RM '))),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
              onPressed: () {
                final p = double.tryParse(price.text.trim());
                if (name.text.trim().isEmpty || p == null) return;
                Navigator.pop(
                    c, TxnItem(name: name.text.trim(), qty: double.tryParse(qty.text.trim()) ?? 1, price: p));
              },
              child: const Text('OK')),
        ],
      ),
    );
    if (item == null) return;
    setState(() => index == null ? _items.add(item) : _items[index] = item);
  }

  void _viewImage() => showDialog<void>(
        context: context,
        builder: (c) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: InteractiveViewer(child: Image.file(widget.image!)),
        ),
      );

  Widget _heading(String text, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Row(children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleSmall)),
          ?trailing,
        ]),
      );

  Widget _banner(ColorScheme cs) {
    final ai = _p!.fromAi;
    final fg = ai ? cs.onSecondaryContainer : cs.onErrorContainer;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ai ? cs.secondaryContainer : cs.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(ai ? Icons.auto_awesome : Icons.warning_amber, color: fg),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            ai
                ? 'Filled in by AI. Please check the details before saving.'
                : 'AI couldn\'t read this receipt, so some details may be missing. Please fill them in.',
            style: TextStyle(color: fg),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const border = OutlineInputBorder();
    const money = TextInputType.numberWithOptions(decimal: true);
    final chips = [..._categories, ..._extra.where((c) => !_categories.contains(c))];
    final itemsTotal = _items.fold<double>(0, (a, i) => a + i.price);
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Edit Transaction' : 'Review Receipt'),
        actions: [
          if (_editing) IconButton(onPressed: _delete, tooltip: 'Delete', icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (widget.image != null) ...[
          GestureDetector(
            onTap: _viewImage,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(children: [
                Image.file(widget.image!, height: 160, width: double.infinity, fit: BoxFit.cover),
                const Positioned(
                  right: 8,
                  bottom: 8,
                  child: Chip(
                      avatar: Icon(Icons.zoom_in, size: 18),
                      label: Text('Tap to view'),
                      visualDensity: VisualDensity.compact),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (_p != null) ...[_banner(cs), const SizedBox(height: 20)],
        TextField(
            controller: _store,
            decoration: InputDecoration(
                labelText: 'Store name',
                prefixIcon: const Icon(Icons.storefront),
                helperText: widget.storeAlias != null ? 'Using the name you saved for this store' : null,
                border: border)),
        const SizedBox(height: 12),
        TextField(
            controller: _amount,
            keyboardType: money,
            decoration: const InputDecoration(
                labelText: 'Total', prefixText: 'RM ', prefixIcon: Icon(Icons.payments_outlined), border: border)),
        const SizedBox(height: 12),
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () async {
            final d = await showDatePicker(
                context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime.now());
            if (d != null) setState(() => _date = d);
          },
          child: InputDecorator(
            decoration: const InputDecoration(labelText: 'Date', prefixIcon: Icon(Icons.calendar_today), border: border),
            child: Text(_day(_date)),
          ),
        ),

        _heading('Category'),
        if (_p != null && _catIsNew && _cat == _p.category)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('AI suggested a new category "$_cat". Keep it or pick another.',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final k in chips)
            ChoiceChip(
              avatar: Icon(
                  _p != null && k == _p.category && !_categories.contains(k) ? Icons.auto_awesome : _catIcon(k),
                  size: 18,
                  color: _cat == k ? null : _catColor(k)),
              label: Text(k),
              selected: _cat == k,
              onSelected: (_) => setState(() => _cat = k),
            ),
          ActionChip(avatar: const Icon(Icons.add, size: 18), label: const Text('New'), onPressed: _newCategory),
        ]),

        _heading('Payment method'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final k in kPayments)
            ChoiceChip(
              avatar: Icon(_paymentIcon(k), size: 18),
              label: Text(k),
              selected: _payment == k,
              onSelected: (s) => setState(() => _payment = s ? k : ''),
            ),
        ]),

        _heading('Receipt details'),
        TextField(
            controller: _receiptNo,
            decoration: const InputDecoration(
                labelText: 'Receipt / invoice no.', prefixIcon: Icon(Icons.tag), border: border)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: TextField(
                  controller: _tax,
                  keyboardType: money,
                  decoration: const InputDecoration(labelText: 'SST (RM)', border: border))),
          const SizedBox(width: 8),
          Expanded(
              child: TextField(
                  controller: _service,
                  keyboardType: money,
                  decoration: const InputDecoration(labelText: 'Service (RM)', border: border))),
          const SizedBox(width: 8),
          Expanded(
              child: TextField(
                  controller: _discount,
                  keyboardType: money,
                  decoration: const InputDecoration(labelText: 'Discount (RM)', border: border))),
        ]),

        _heading('Items (${_items.length})',
            trailing: TextButton.icon(
                onPressed: () => _editItem(), icon: const Icon(Icons.add, size: 18), label: const Text('Add'))),
        if (_items.isEmpty)
          Text('No items. Tap Add to list what you bought.', style: TextStyle(color: cs.onSurfaceVariant))
        else ...[
          for (var i = 0; i < _items.length; i++)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              onTap: () => _editItem(i),
              leading: Text('${_qty(_items[i].qty)}×', style: const TextStyle(fontWeight: FontWeight.w600)),
              title: Text(_items[i].name),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_rm(_items[i].price)),
                IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Remove',
                    onPressed: () => setState(() => _items.removeAt(i))),
              ]),
            ),
          Text('Items add up to ${_rm(itemsTotal)}',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12), textAlign: TextAlign.right),
        ],

        const SizedBox(height: 28),
        FilledButton.icon(
            onPressed: _save, icon: const Icon(Icons.check), label: Text(_editing ? 'Save changes' : 'Save')),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_editing ? 'Cancel' : 'Discard')),
      ]),
    );
  }
}

// ───────────── UC09: Profile ─────────────
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _name = TextEditingController(), _budget = TextEditingController();

  @override
  void initState() {
    super.initState();
    Repo.profile().first.then((p) {
      if (!mounted) return;
      setState(() {
        _name.text = (p['name'] ?? FirebaseAuth.instance.currentUser?.displayName ?? '') as String;
        final b = ((p['monthlyBudget'] as num?) ?? 0).toDouble();
        _budget.text = b > 0 ? b.toStringAsFixed(2) : '';
      });
    });
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    await Repo.saveProfile({'name': _name.text.trim(), 'monthlyBudget': double.tryParse(_budget.text) ?? 0});
    if (mounted) _snack(context, 'Profile saved');
  }

  Future<void> _pickPhoto(ImageSource src) async {
    // Small enough to keep the Firestore profile document well under its 1 MiB limit.
    final x = await ImagePicker().pickImage(source: src, maxWidth: 256, maxHeight: 256, imageQuality: 70);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    if (bytes.length > 300 * 1024) {
      if (mounted) _snack(context, 'That photo is too large. Try another one.');
      return;
    }
    await Repo.saveProfile({'photo': base64Encode(bytes)});
  }

  void _photoMenu(bool hasPhoto) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (c) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('Take a photo'),
                onTap: () {
                  Navigator.pop(c);
                  _pickPhoto(ImageSource.camera);
                }),
            ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from gallery'),
                onTap: () {
                  Navigator.pop(c);
                  _pickPhoto(ImageSource.gallery);
                }),
            if (hasPhoto)
              ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Remove photo'),
                  onTap: () {
                    Navigator.pop(c);
                    Repo.saveProfile({'photo': ''});
                  }),
          ]),
        ),
      );

  Future<void> _deleteAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text('This permanently deletes your account and all saved transactions.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Repo.deleteAccount();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      _snack(context,
          e.code == 'requires-recent-login' ? 'Please log out and log in again, then retry.' : e.message ?? 'Delete failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const border = OutlineInputBorder();
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: StreamBuilder<Map<String, dynamic>>(
        stream: Repo.profile(),
        builder: (c, s) {
          final p = s.data ?? {};
          final hasPhoto = _photoOf(p) != null;
          final mode = themeModeOf(p['themeMode']);
          final color = (p['themeColor'] ?? 'Teal') as String;
          return ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
            Center(
              child: GestureDetector(
                onTap: () => _photoMenu(hasPhoto),
                child: Stack(children: [
                  _Avatar(p, radius: 52),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: CircleAvatar(
                        radius: 18,
                        backgroundColor: cs.primary,
                        child: Icon(Icons.camera_alt, size: 18, color: cs.onPrimary)),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Center(
                child: Text(FirebaseAuth.instance.currentUser?.email ?? '',
                    style: TextStyle(color: cs.onSurfaceVariant))),
            const SizedBox(height: 24),
            _Section(
              title: 'Details',
              child: Column(children: [
                TextField(
                    controller: _name,
                    decoration:
                        const InputDecoration(labelText: 'Name', prefixIcon: Icon(Icons.person_outline), border: border)),
                const SizedBox(height: 12),
                TextField(
                    controller: _budget,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Monthly budget',
                        prefixText: 'RM ',
                        helperText: 'Leave empty for no budget',
                        prefixIcon: Icon(Icons.savings_outlined),
                        border: border)),
                const SizedBox(height: 12),
                SizedBox(width: double.infinity, child: FilledButton(onPressed: _save, child: const Text('Save'))),
              ]),
            ),
            _Section(
              title: 'Categories',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Built-in categories stay. Remove your own anytime; saved transactions keep their category.',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final k in Repo.categoriesOf(p))
                    kCategories.contains(k)
                        ? Chip(avatar: Icon(_catIcon(k), size: 18, color: _catColor(k)), label: Text(k))
                        : InputChip(
                            avatar: Icon(_catIcon(k), size: 18, color: _catColor(k)),
                            label: Text(k),
                            onDeleted: () => Repo.removeCategory(k),
                          ),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('Add'),
                    onPressed: () async {
                      final c = await _askCategory(context, Repo.categoriesOf(p));
                      if (c != null && !kCategories.contains(c)) Repo.addCategory(c);
                    },
                  ),
                ]),
              ]),
            ),
            _Section(
              title: 'Appearance',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
                      ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode)),
                      ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode)),
                    ],
                    selected: {mode},
                    onSelectionChanged: (v) => Repo.saveProfile({'themeMode': v.first.name}),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Colour', style: TextStyle(color: cs.onSurfaceVariant)),
                const SizedBox(height: 8),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  for (final e in kThemeColors.entries)
                    Tooltip(
                      message: e.key,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => Repo.saveProfile({'themeColor': e.key}),
                        child: CircleAvatar(
                          radius: 20,
                          backgroundColor: e.value,
                          child: e.key == color ? const Icon(Icons.check, color: Colors.white) : null,
                        ),
                      ),
                    ),
                ]),
              ]),
            ),
            _Section(
              title: 'Account',
              child: Column(children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.logout),
                  title: const Text('Log out'),
                  onTap: () => FirebaseAuth.instance.signOut(),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.delete_forever, color: Colors.red),
                  title: const Text('Delete account', style: TextStyle(color: Colors.red)),
                  onTap: _deleteAccount,
                ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}
