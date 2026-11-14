import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'memory.dart';
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

/// Which field a Firebase Auth error belongs to, and a plain message for it.
enum _AuthField { email, password, other }

(_AuthField, String) _authError(FirebaseAuthException e) => switch (e.code) {
      // Firebase reports 'invalid-credential' for both a wrong password and an unknown email,
      // so it can't reveal which emails have accounts.
      'invalid-credential' || 'invalid-login-credentials' =>
        (_AuthField.password, 'Wrong email or password. Check them and try again.'),
      'wrong-password' => (_AuthField.password, 'Incorrect password. Try again or reset it.'),
      'user-not-found' => (_AuthField.email, 'No account uses this email. Register instead?'),
      'invalid-email' => (_AuthField.email, 'Enter a valid email address.'),
      'missing-email' => (_AuthField.email, 'Enter your email.'),
      'email-already-in-use' => (_AuthField.email, 'An account already uses this email. Log in instead.'),
      'missing-password' => (_AuthField.password, 'Enter your password.'),
      'weak-password' || 'password-does-not-meet-requirements' =>
        (_AuthField.password, 'Password is too weak. Use at least 6 characters.'),
      'user-disabled' => (_AuthField.other, 'This account has been disabled.'),
      'too-many-requests' => (_AuthField.other, 'Too many attempts. Wait a few minutes or reset your password.'),
      'network-request-failed' => (_AuthField.other, 'No internet connection. Check it and try again.'),
      _ => (_AuthField.other, e.message ?? 'Something went wrong. Please try again.'),
    };

/// Sends a Firebase password reset email after confirming the address with the user.
Future<void> _resetPassword(BuildContext context, String email) async {
  final ctl = TextEditingController(text: email.trim());
  String? error;
  var busy = false;
  final sentTo = await showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: const Text('Reset password'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text("Enter your account's email. We'll send you a link to set a new password."),
          const SizedBox(height: 16),
          TextField(
            controller: ctl,
            autofocus: ctl.text.isEmpty,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
                labelText: 'Email', prefixIcon: const Icon(Icons.email_outlined), errorText: error),
            onChanged: (_) => setState(() => error = null),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    final e = ctl.text.trim();
                    if (e.isEmpty) return setState(() => error = 'Enter your email.');
                    setState(() => busy = true);
                    try {
                      await FirebaseAuth.instance.sendPasswordResetEmail(email: e);
                      if (c.mounted) Navigator.pop(c, e);
                    } on FirebaseAuthException catch (ex) {
                      setState(() {
                        busy = false;
                        error = _authError(ex).$2;
                      });
                    }
                  },
            child: const Text('Send link'),
          ),
        ],
      ),
    ),
  );
  if (sentTo == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.mark_email_read_outlined),
      title: const Text('Check your email'),
      content: Text('If an account exists for $sentTo, we sent a link to reset the password. '
          'Open it, choose a new password, then log in here. Check your spam folder if you can\'t find it.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
    ),
  );
}

class _LoginScreenState extends State<LoginScreen> {
  final _name = TextEditingController(), _email = TextEditingController(), _pass = TextEditingController();
  bool _register = false, _busy = false, _showPass = false;
  String? _emailError, _passError, _error;

  Future<void> _submit() async {
    final email = _email.text.trim();
    setState(() {
      _emailError = email.isEmpty ? 'Enter your email.' : null;
      _passError = _pass.text.isEmpty ? 'Enter your password.' : null;
      _error = null;
    });
    if (_emailError != null || _passError != null) return;
    setState(() => _busy = true);
    try {
      final auth = FirebaseAuth.instance;
      if (_register) {
        final c = await auth.createUserWithEmailAndPassword(email: email, password: _pass.text);
        await c.user?.updateDisplayName(_name.text.trim());
        await Repo.saveProfile({'name': _name.text.trim(), 'currency': 'MYR', 'monthlyBudget': 0.0});
      } else {
        await auth.signInWithEmailAndPassword(email: email, password: _pass.text);
      }
    } on FirebaseAuthException catch (e) {
      final (field, msg) = _authError(e);
      if (mounted) {
        setState(() {
          if (field == _AuthField.email) _emailError = msg;
          if (field == _AuthField.password) _passError = msg;
          if (field == _AuthField.other) _error = msg;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _clearErrors() {
    if (_emailError != null || _passError != null || _error != null) {
      setState(() => _emailError = _passError = _error = null);
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
                autofillHints: const [AutofillHints.email],
                onChanged: (_) => _clearErrors(),
                decoration: InputDecoration(
                    labelText: 'Email',
                    prefixIcon: const Icon(Icons.email_outlined),
                    errorText: _emailError,
                    border: const OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(
                controller: _pass,
                obscureText: !_showPass,
                autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
                onChanged: (_) => _clearErrors(),
                onSubmitted: (_) => _busy ? null : _submit(),
                decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    helperText: _register ? 'At least 6 characters' : null,
                    errorText: _passError,
                    errorMaxLines: 2,
                    suffixIcon: IconButton(
                      tooltip: _showPass ? 'Hide password' : 'Show password',
                      icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _showPass = !_showPass),
                    ),
                    border: const OutlineInputBorder())),
            if (!_register)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                    onPressed: () => _resetPassword(context, _email.text), child: const Text('Forgot password?')),
              )
            else
              const SizedBox(height: 12),
            if (_error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Icon(Icons.error_outline, color: cs.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_error!, style: TextStyle(color: cs.onErrorContainer))),
                ]),
              ),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_register ? 'Register' : 'Log in')),
            ),
            TextButton(
                onPressed: () => setState(() {
                      _register = !_register;
                      _emailError = _passError = _error = null;
                    }),
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

DateTime _monthOf(DateTime d) => DateTime(d.year, d.month);
String _monthLabel(DateTime m) => '${_months[m.month - 1]} ${m.year}';
bool _inMonth(Txn t, DateTime m) => t.date.year == m.year && t.date.month == m.month;

/// Grid of months for one year, with arrows to change year. Months after this one are disabled.
/// Returns the chosen month; with [allowAll], `DateTime(0)` means "all time".
Future<DateTime?> _pickMonth(BuildContext context, DateTime? initial, {bool allowAll = false}) {
  final now = _monthOf(DateTime.now());
  var year = (initial ?? now).year;
  return showDialog<DateTime>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) {
        final cs = Theme.of(c).colorScheme;
        return AlertDialog(
          title: Row(children: [
            IconButton(
                onPressed: year > 2020 ? () => setState(() => year--) : null, icon: const Icon(Icons.chevron_left)),
            Expanded(child: Text('$year', textAlign: TextAlign.center)),
            IconButton(
                onPressed: year < now.year ? () => setState(() => year++) : null,
                icon: const Icon(Icons.chevron_right)),
          ]),
          content: SizedBox(
            width: 300,
            child: GridView.count(
              shrinkWrap: true,
              crossAxisCount: 3,
              childAspectRatio: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                for (var m = 1; m <= 12; m++)
                  Builder(builder: (_) {
                    final d = DateTime(year, m);
                    final label = Text(_months[m - 1].substring(0, 3));
                    if (initial != null && d == _monthOf(initial)) {
                      return FilledButton(onPressed: () => Navigator.pop(c, d), child: label);
                    }
                    return OutlinedButton(
                        onPressed: d.isAfter(now) ? null : () => Navigator.pop(c, d),
                        style: OutlinedButton.styleFrom(side: BorderSide(color: cs.outlineVariant)),
                        child: label);
                  }),
              ],
            ),
          ),
          actions: [
            if (allowAll) TextButton(onPressed: () => Navigator.pop(c, DateTime(0)), child: const Text('All time')),
            TextButton(onPressed: () => Navigator.pop(c, now), child: const Text('This month')),
          ],
        );
      },
    ),
  );
}

/// "‹  November 2026  ›" with a month picker in the middle. [month] null means all time (only with [allowAll]).
class _MonthBar extends StatelessWidget {
  final DateTime? month;
  final ValueChanged<DateTime?> onChanged;
  final bool allowAll;
  const _MonthBar({required this.month, required this.onChanged, this.allowAll = false});

  @override
  Widget build(BuildContext context) {
    final m = month;
    final now = _monthOf(DateTime.now());
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(children: [
        IconButton(
            tooltip: 'Previous month',
            onPressed: m == null ? null : () => onChanged(DateTime(m.year, m.month - 1)),
            icon: const Icon(Icons.chevron_left)),
        Expanded(
          child: TextButton.icon(
            onPressed: () async {
              final d = await _pickMonth(context, m, allowAll: allowAll);
              if (d != null) onChanged(d.year == 0 ? null : d);
            },
            icon: const Icon(Icons.calendar_month),
            label: Text(m == null ? 'All time' : _monthLabel(m), style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        IconButton(
            tooltip: 'Next month',
            onPressed: m == null || !m.isBefore(now) ? null : () => onChanged(DateTime(m.year, m.month + 1)),
            icon: const Icon(Icons.chevron_right)),
      ]),
    );
  }
}

/// Numbers shown on the dashboard for the selected [month].
class _Stats {
  final DateTime month;
  final bool isCurrent;
  final List<Txn> txns; // in the month, newest first
  final double total, today, week, dailyAvg, relief;
  final Map<String, double> byCat;
  final List<double> daily; // index 0 = day 1

  factory _Stats(List<Txn> all, DateTime month, DateTime now) {
    final isCurrent = month == _monthOf(now);
    final today = DateTime(now.year, now.month, now.day);
    final weekStart = today.subtract(const Duration(days: 6));
    final txns = all.where((t) => _inMonth(t, month)).toList();
    final days = DateUtils.getDaysInMonth(month.year, month.month);
    final daily = List<double>.filled(days, 0);
    final byCat = <String, double>{};
    for (final t in txns) {
      daily[t.date.day - 1] += t.amount;
      byCat[t.category] = (byCat[t.category] ?? 0) + t.amount;
    }
    final total = txns.fold<double>(0, (a, t) => a + t.amount);
    double sumFrom(DateTime from) => all.where((t) => !t.date.isBefore(from)).fold(0, (a, t) => a + t.amount);
    return _Stats._(month, isCurrent, txns, total, sumFrom(today), sumFrom(weekStart),
        total / (isCurrent ? now.day : days), txns.fold(0, (a, t) => a + t.reliefTotal), byCat, daily);
  }

  _Stats._(this.month, this.isCurrent, this.txns, this.total, this.today, this.week, this.dailyAvg, this.relief,
      this.byCat, this.daily);

  int get count => txns.length;

  /// Day of the month with the most spending (1-based), or 0 if nothing was spent.
  int get topDay {
    var best = 0;
    for (var i = 0; i < daily.length; i++) {
      if (daily[i] > 0 && (best == 0 || daily[i] > daily[best - 1])) best = i + 1;
    }
    return best;
  }
}

class LedgerPage extends StatefulWidget {
  final VoidCallback onScan, onProfile;
  const LedgerPage({super.key, required this.onScan, required this.onProfile});

  @override
  State<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends State<LedgerPage> {
  DateTime _month = _monthOf(DateTime.now());

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
                final st = _Stats(all, _month, DateTime.now());
                final budget = ((p.data?['monthlyBudget']) as num?)?.toDouble() ?? 0;
                final name = (p.data?['name'] ?? '') as String;
                void seeAll() =>
                    Navigator.push(context, MaterialPageRoute(builder: (_) => TransactionsPage(month: _month)));
                return ListView(padding: const EdgeInsets.only(bottom: 16), children: [
                  ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    leading: GestureDetector(onTap: widget.onProfile, child: _Avatar(p.data, radius: 22)),
                    title: Text(name.isEmpty ? 'Hi there' : 'Hi, $name',
                        style: Theme.of(context).textTheme.titleLarge),
                  ),
                  _MonthBar(month: _month, onChanged: (m) => setState(() => _month = m!)),
                  _BudgetCard(st: st, budget: budget, onSetBudget: widget.onProfile, onTap: seeAll),
                  _StatGrid(st),
                  if (st.total > 0) _CategoryCard(st),
                  _ReliefCard(all: all, year: _month.year),
                  _Section(
                    title: st.isCurrent ? 'Recent transactions' : 'Transactions in ${_months[_month.month - 1]}',
                    trailing: st.count > 0 ? TextButton(onPressed: seeAll, child: const Text('See all')) : null,
                    child: all.isEmpty
                        ? _EmptyTxns(onScan: widget.onScan)
                        : st.txns.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Text('No transactions in ${_monthLabel(_month)}.',
                                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)))
                            : Column(children: [for (final t in st.txns.take(5)) _TxnTile(t)]),
                  ),
                  if (st.total > 0) _DailyChart(st),
                ]);
              },
            ),
          ),
        ),
      );
}

class _BudgetCard extends StatelessWidget {
  final _Stats st;
  final double budget;
  final VoidCallback onSetBudget, onTap;
  const _BudgetCard({required this.st, required this.budget, required this.onSetBudget, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final spent = st.total;
    final over = budget > 0 && spent > budget;
    final onCard = cs.onPrimary;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
                colors: [cs.primary, Color.lerp(cs.primary, cs.tertiary, 0.6)!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(st.isCurrent ? 'Total spent this month' : 'Total spent in ${_monthLabel(st.month)}',
                    style: tt.titleSmall?.copyWith(color: onCard.withValues(alpha: 0.85))),
              ),
              Icon(Icons.chevron_right, color: onCard.withValues(alpha: 0.85)),
            ]),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(_rm(spent), style: tt.displaySmall?.copyWith(color: onCard, fontWeight: FontWeight.bold)),
            ),
            Text('${st.count} receipt${st.count == 1 ? '' : 's'}',
                style: tt.bodySmall?.copyWith(color: onCard.withValues(alpha: 0.85))),
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
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  final _Stats st;
  const _StatGrid(this.st);

  @override
  Widget build(BuildContext context) {
    final top = st.topDay;
    final mon = _months[st.month.month - 1].substring(0, 3);
    // Today and the last 7 days only make sense for the current month; past months show their busiest day.
    final first = st.isCurrent
        ? [
            _StatCard(icon: Icons.today, label: 'Today', value: _rm(st.today)),
            _StatCard(icon: Icons.date_range, label: 'Last 7 days', value: _rm(st.week)),
          ]
        : [
            _StatCard(
                icon: Icons.local_fire_department,
                label: top == 0 ? 'Highest day' : 'Highest day ($top $mon)',
                value: _rm(top == 0 ? 0 : st.daily[top - 1])),
            _StatCard(icon: Icons.receipt, label: 'Receipts', value: '${st.count}'),
          ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(children: [
        Row(children: [Expanded(child: first[0]), const SizedBox(width: 12), Expanded(child: first[1])]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _StatCard(icon: Icons.show_chart, label: 'Daily average', value: _rm(st.dailyAvg))),
          const SizedBox(width: 12),
          Expanded(
              child: _StatCard(icon: Icons.volunteer_activism, label: 'Tax relief items', value: _rm(st.relief))),
        ]),
      ]),
    );
  }
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
                  Text('${(e.value / st.total * 100).round()}%',
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
  final _Stats st;
  const _DailyChart(this.st);

  static String _compact(double v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : v.toStringAsFixed(0);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final daily = st.daily;
    final month = st.month;
    final highlight = st.isCurrent ? DateTime.now().day : st.topDay;
    final maxY = math.max(10.0, daily.reduce(math.max) * 1.2);
    final label = TextStyle(fontSize: 10, color: cs.onSurfaceVariant);
    return _Section(
      title: 'Daily spending in ${_monthLabel(month)}',
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
                  '${g.x} ${_months[month.month - 1].substring(0, 3)}\n${_rm(rod.toY)}',
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
                  color: i + 1 == highlight ? cs.primary : cs.primary.withValues(alpha: 0.45),
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

/// Transactions filtered by month (or all time) and category, with the total for the filter at the top.
class TransactionsPage extends StatefulWidget {
  final DateTime? month; // null = all time
  const TransactionsPage({super.key, this.month});

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  late DateTime? _month = widget.month;
  String? _cat; // null = all categories

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Transactions')),
      body: StreamBuilder<List<Txn>>(
        stream: Repo.txns(),
        builder: (c, s) {
          if (!s.hasData) return const Center(child: CircularProgressIndicator());
          final m = _month;
          final inPeriod = m == null ? s.data! : s.data!.where((t) => _inMonth(t, m)).toList();
          final cats = {for (final t in inPeriod) t.category}.toList()..sort();
          final list = _cat == null ? inPeriod : inPeriod.where((t) => t.category == _cat).toList();
          final total = list.fold<double>(0, (a, t) => a + t.amount);
          final relief = list.fold<double>(0, (a, t) => a + t.reliefTotal);
          return ListView(padding: const EdgeInsets.only(bottom: 16), children: [
            _MonthBar(
                month: m,
                allowAll: true,
                onChanged: (v) => setState(() {
                      _month = v;
                      _cat = null;
                    })),
            Card(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              color: cs.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_cat == null ? 'Total spent' : 'Total spent on $_cat',
                          style: tt.titleSmall?.copyWith(color: cs.onPrimaryContainer)),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(_rm(total),
                            style: tt.headlineMedium
                                ?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.bold)),
                      ),
                      Text(
                          '${list.length} receipt${list.length == 1 ? '' : 's'}'
                          '${relief > 0 ? ' • ${_rm(relief)} tax relief items' : ''}',
                          style: tt.bodySmall?.copyWith(color: cs.onPrimaryContainer)),
                    ]),
                  ),
                  Icon(Icons.account_balance_wallet_outlined, size: 36, color: cs.onPrimaryContainer),
                ]),
              ),
            ),
            if (cats.length > 1)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(children: [
                  for (final k in [null, ...cats])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        avatar: k == null ? null : Icon(_catIcon(k), size: 18, color: _catColor(k)),
                        label: Text(k ?? 'All'),
                        selected: _cat == k,
                        onSelected: (_) => setState(() => _cat = k),
                      ),
                    ),
                ]),
              ),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text('No transactions in ${m == null ? 'your ledger' : _monthLabel(m)}.',
                    textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(children: [for (final t in list) _TxnTile(t)]),
              ),
          ]);
        },
      ),
    );
  }
}

// ───────────── Tax relief (LHDN) ─────────────

const _reliefIcons = {
  'Lifestyle': Icons.menu_book,
  'Sports': Icons.sports_tennis,
  'Medical': Icons.medical_services,
  'Parents medical': Icons.elderly,
  'Disability equipment': Icons.accessible,
  'Education': Icons.school,
  'Childcare': Icons.child_care,
  'Breastfeeding': Icons.baby_changing_station,
  'Tourism': Icons.attractions,
  'EV & home': Icons.ev_station,
  'Insurance': Icons.shield,
};

IconData _reliefIcon(String key) => _reliefIcons[key] ?? Icons.volunteer_activism;

/// Tagged items for [year], grouped by relief: relief key → (transaction, item) pairs.
Map<String, List<(Txn, TxnItem)>> _reliefItems(List<Txn> all, int year) {
  final out = <String, List<(Txn, TxnItem)>>{};
  for (final t in all) {
    if (t.date.year != year) continue;
    for (final i in t.items) {
      if (i.relief.isNotEmpty) (out[i.relief] ??= []).add((t, i));
    }
  }
  return out;
}

class _ReliefBar extends StatelessWidget {
  final Relief r;
  final double claimed;
  const _ReliefBar(this.r, this.claimed);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final full = claimed >= r.limit;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_reliefIcon(r.key), size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(r.key)),
          Text('${_rm(claimed)} / ${_rm(r.limit)}',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: full ? cs.tertiary : null)),
        ]),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
              minHeight: 6, value: (claimed / r.limit).clamp(0, 1).toDouble(), color: full ? cs.tertiary : null),
        ),
      ]),
    );
  }
}

class _ReliefCard extends StatelessWidget {
  final List<Txn> all;
  final int year;
  const _ReliefCard({required this.all, required this.year});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = _reliefItems(all, year);
    final sums = {for (final e in items.entries) e.key: e.value.fold<double>(0, (a, p) => a + p.$2.price)};
    final total = sums.values.fold<double>(0, (a, v) => a + v);
    return _Section(
      title: 'Tax relief $year',
      trailing: TextButton(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReliefPage(year: year))),
          child: const Text('Details')),
      child: total == 0
          ? Text(
              'No tax relief items yet. Books, gadgets, sports gear, medical bills and similar items are '
              'tagged automatically when you scan a receipt.',
              style: TextStyle(color: cs.onSurfaceVariant))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${_rm(total)} in receipts you may be able to claim',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              for (final r in kReliefs)
                if ((sums[r.key] ?? 0) > 0) _ReliefBar(r, sums[r.key]!),
            ]),
    );
  }
}

/// Every tagged item for a year, grouped by relief, with the YA limits.
class ReliefPage extends StatelessWidget {
  final int year;
  const ReliefPage({super.key, required this.year});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('Tax relief $year')),
      body: StreamBuilder<List<Txn>>(
        stream: Repo.txns(),
        builder: (c, s) {
          if (!s.hasData) return const Center(child: CircularProgressIndicator());
          final items = _reliefItems(s.data!, year);
          return ListView(padding: const EdgeInsets.only(top: 8, bottom: 16), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                'Limits shown are for year of assessment $kReliefYear'
                '${year == kReliefYear ? '' : ' and may differ for $year'}. '
                'AI tags are a guide only: check each item against LHDN rules and keep the original receipts '
                'for 7 years. Medical bills for parents must be tagged by hand on the receipt.',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
            ),
            for (final r in kReliefs)
              _Section(
                title: r.key,
                trailing: Icon(_reliefIcon(r.key), color: cs.primary),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.covers, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
                  _ReliefBar(r, (items[r.key] ?? const []).fold(0, (a, p) => a + p.$2.price)),
                  for (final (t, i) in items[r.key] ?? const <(Txn, TxnItem)>[])
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(i.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${t.store.isEmpty ? '(no store name)' : t.store} • ${_day(t.date)}'),
                      trailing: Text(_rm(i.price), style: const TextStyle(fontWeight: FontWeight.w600)),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReviewPage.edit(t))),
                    ),
                ]),
              ),
          ]);
        },
      ),
    );
  }
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
        if (mounted) _invalid('No text was found in this image. It may not be a receipt, or it is too dark or blurry.');
        return;
      }
      setState(() => _step = 2);
      final memories = await Repo.storeMemories();
      var parsed = await GeminiService().parse(text,
          image: _image, pastReceipts: memoryHints(memories.values), categories: await Repo.categories());
      if (!mounted) return;
      if (!parsed.isReceipt) {
        _invalid(parsed.notReceiptReason);
        return;
      }
      // Fill in what the user chose last time at this store (category, total row, tax relief tags...).
      final memory = Repo.memoryFor(memories, parsed.store);
      if (memory != null) parsed = applyMemory(parsed, memory, text);
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ReviewPage(
                  parsed: parsed,
                  rawText: text,
                  image: _image,
                  storeAlias: memory == null || memory.to.isEmpty ? null : memory.to)));
    } catch (e) {
      if (mounted) _snack(context, 'Scan failed: $e');
    } finally {
      if (mounted) setState(() => _step = 0);
    }
  }

  /// Tells the user the image isn't a receipt and lets them scan or pick another one straight away.
  Future<void> _invalid(String reason) async {
    final next = await showDialog<ImageSource>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(Icons.image_not_supported_outlined, color: Theme.of(c).colorScheme.error),
        title: const Text('Invalid image'),
        content: Text('$reason\n\nPlease scan or upload a clear photo of a receipt.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, ImageSource.gallery), child: const Text('Upload another')),
          FilledButton(onPressed: () => Navigator.pop(c, ImageSource.camera), child: const Text('Scan again')),
        ],
      ),
    );
    if (next != null && mounted) {
      _pick(next);
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

  /// Shows where the scanned total came from, or warns when it isn't in the receipt text at all.
  String? get _totalHint {
    final p = _p;
    if (p == null || p.total == null) return null;
    if (!p.totalInText) return 'This amount wasn\'t found in the receipt text. Check it against the photo.';
    if (p.remembered.contains('total')) return 'Read from: "${p.totalLabel}", the row you used last time at this store';
    return p.totalLabel.isEmpty ? null : 'Read from: "${p.totalLabel}"';
  }

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
      // Not shown on screen any more, but kept: the receipt number powers the duplicate check.
      receiptNo: _e?.receiptNo ?? _p!.receiptNo,
      serviceCharge: _e != null ? _e.serviceCharge : _p!.serviceCharge,
      discount: _e != null ? _e.discount : _p!.discount,
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
    // Learn from what was saved, so the next receipt from this store is filled in the same way.
    if (t.store.isNotEmpty) Repo.remember(t, detected: _p?.store ?? '');
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
    var relief = old?.relief ?? '';
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
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: relief,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Tax relief ($kReliefYear)'),
            items: [
              const DropdownMenuItem(value: '', child: Text('None')),
              for (final r in kReliefs)
                DropdownMenuItem(
                  value: r.key,
                  child: Row(children: [
                    Icon(_reliefIcon(r.key), size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${r.key} (max ${_rm(r.limit)})', overflow: TextOverflow.ellipsis)),
                  ]),
                ),
            ],
            onChanged: (v) => relief = v ?? '',
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
              onPressed: () {
                final p = double.tryParse(price.text.trim());
                if (name.text.trim().isEmpty || p == null) return;
                Navigator.pop(
                    c,
                    TxnItem(
                        name: name.text.trim(),
                        qty: double.tryParse(qty.text.trim()) ?? 1,
                        price: p,
                        relief: relief));
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

  bool _remembered(String field) => _p?.remembered.contains(field) ?? false;

  Widget _rememberedNote(ColorScheme cs, [String text = 'From your past receipts at this store.']) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Icon(Icons.history, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(color: cs.primary, fontSize: 13))),
        ]),
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
    final reliefTotal = _items.where((i) => i.relief.isNotEmpty).fold<double>(0, (a, i) => a + i.price);
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
            decoration: InputDecoration(
                labelText: 'Total',
                prefixText: 'RM ',
                prefixIcon: const Icon(Icons.payments_outlined),
                helperText: _totalHint,
                helperMaxLines: 3,
                helperStyle: _p != null && !_p.totalInText ? TextStyle(color: cs.error) : null,
                border: border)),
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
        if (_remembered('category')) _rememberedNote(cs),
        if (_p != null && _catIsNew && _cat == _p.category && !_remembered('category'))
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
        if (_remembered('payment')) _rememberedNote(cs, 'Not printed on this receipt, so using how you paid last time.'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final k in kPayments)
            ChoiceChip(
              avatar: Icon(_paymentIcon(k), size: 18),
              label: Text(k),
              selected: _payment == k,
              onSelected: (s) => setState(() => _payment = s ? k : ''),
            ),
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
              subtitle: _items[i].relief.isEmpty
                  ? null
                  : Row(children: [
                      Icon(_reliefIcon(_items[i].relief), size: 14, color: cs.primary),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text('Tax relief: ${_items[i].relief}',
                            style: TextStyle(color: cs.primary, fontSize: 12), overflow: TextOverflow.ellipsis),
                      ),
                    ]),
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
          if (reliefTotal > 0)
            Text('Tax relief items: ${_rm(reliefTotal)}',
                style: TextStyle(color: cs.primary, fontSize: 12, fontWeight: FontWeight.w600),
                textAlign: TextAlign.right),
          if (_remembered('relief'))
            Text('Some tax relief tags are from your past receipts at this store.',
                style: TextStyle(color: cs.primary, fontSize: 12), textAlign: TextAlign.right),
          Text('Tap an item to change its tax relief.',
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

// ───────────── Learned stores ─────────────

/// Everything the app remembers per store, with a way to forget a store or everything.
class LearnedStoresPage extends StatelessWidget {
  const LearnedStoresPage({super.key});

  Future<bool> _confirm(BuildContext context, String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Forget')),
          ],
        ),
      ) ==
      true;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return StreamBuilder<List<StoreMemory>>(
      stream: Repo.storeMemoriesStream(),
      builder: (c, s) {
        final list = s.data ?? const <StoreMemory>[];
        return Scaffold(
          appBar: AppBar(title: const Text('Learned stores'), actions: [
            if (list.isNotEmpty)
              TextButton(
                onPressed: () async {
                  if (await _confirm(context, 'Forget everything?',
                      'Keihi will stop filling in details from your past receipts. Saved transactions are not deleted.')) {
                    await Repo.forgetAllStores();
                  }
                },
                child: const Text('Forget all'),
              ),
          ]),
          body: !s.hasData
              ? const Center(child: CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.all(16), children: [
                  Text(
                    'When you save a receipt, Keihi remembers your choices for that store and fills them in next time. '
                    'This stays in your account and is not used to train the AI.',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  if (list.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Nothing learned yet. Scan and save a receipt to start.',
                          textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
                    ),
                  for (final m in list)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _catColor(m.category).withValues(alpha: 0.15),
                          child: Icon(_catIcon(m.category), color: _catColor(m.category)),
                        ),
                        title: Text(m.name.isEmpty ? '(no store name)' : m.name),
                        subtitle: Text(
                          [
                            if (m.to.isNotEmpty && m.from.isNotEmpty) 'Printed as "${m.from}"',
                            if (m.category.isNotEmpty) m.category,
                            if (m.payment.isNotEmpty) m.payment,
                            if (m.totalLabel.isNotEmpty) 'Total row "${m.totalLabel}"',
                            if (m.items.values.any((i) => i.relief.isNotEmpty))
                              '${m.items.values.where((i) => i.relief.isNotEmpty).length} tax relief items',
                            if (m.scans > 0) '${m.scans} scan${m.scans == 1 ? '' : 's'}',
                          ].join(' • '),
                        ),
                        trailing: IconButton(
                          tooltip: 'Forget this store',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            if (await _confirm(context, 'Forget ${m.name}?',
                                'The next receipt from this store will be read without your past choices.')) {
                              await Repo.forgetStore(m.key);
                            }
                          },
                        ),
                      ),
                    ),
                ]),
        );
      },
    );
  }
}

// ───────────── Change password ─────────────

/// Firebase needs a recent sign-in to change a password, so the current password is checked first.
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});
  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _current = TextEditingController(), _new = TextEditingController(), _confirm = TextEditingController();
  String? _currentError, _newError, _confirmError, _error;
  bool _busy = false, _show = false;

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _currentError = _current.text.isEmpty ? 'Enter your current password.' : null;
      _newError = _new.text.length < 6
          ? 'Use at least 6 characters.'
          : _new.text == _current.text
              ? 'Choose a password different from your current one.'
              : null;
      _confirmError = _confirm.text != _new.text ? 'Passwords don\'t match.' : null;
      _error = null;
    });
    if (_currentError != null || _newError != null || _confirmError != null) return;
    final user = FirebaseAuth.instance.currentUser!;
    setState(() => _busy = true);
    try {
      await user.reauthenticateWithCredential(
          EmailAuthProvider.credential(email: user.email!, password: _current.text));
    } on FirebaseAuthException catch (e) {
      final (field, msg) = _authError(e);
      if (mounted) {
        setState(() {
          _busy = false;
          // A wrong password here is always the current one.
          field == _AuthField.other
              ? _error = msg
              : _currentError =
                  e.code == 'invalid-credential' || e.code == 'wrong-password' ? 'Incorrect current password.' : msg;
        });
      }
      return;
    }
    try {
      await user.updatePassword(_new.text);
      if (!mounted) return;
      _snack(context, 'Password changed');
      Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      final (field, msg) = _authError(e);
      if (mounted) {
        setState(() {
          _busy = false;
          field == _AuthField.password ? _newError = msg : _error = msg;
        });
      }
    }
  }

  Widget _field(TextEditingController c, String label, String? error, {String? helper, bool last = false}) =>
      TextField(
        controller: c,
        obscureText: !_show,
        textInputAction: last ? TextInputAction.done : TextInputAction.next,
        onSubmitted: last ? (_) => _busy ? null : _save() : null,
        onChanged: (_) {
          if (error != null || _error != null) {
            setState(() => _currentError = _newError = _confirmError = _error = null);
          }
        },
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.lock_outline),
          helperText: helper,
          errorText: error,
          errorMaxLines: 2,
          border: const OutlineInputBorder(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _field(_current, 'Current password', _currentError),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
              onPressed: () => _resetPassword(context, FirebaseAuth.instance.currentUser?.email ?? ''),
              child: const Text('Forgot current password?')),
        ),
        _field(_new, 'New password', _newError, helper: 'At least 6 characters'),
        const SizedBox(height: 12),
        _field(_confirm, 'Confirm new password', _confirmError, last: true),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _show,
          onChanged: (v) => setState(() => _show = v ?? false),
          title: const Text('Show passwords'),
        ),
        if (_error != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(Icons.error_outline, color: cs.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: TextStyle(color: cs.onErrorContainer))),
            ]),
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Change password'),
        ),
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
              title: 'What Keihi has learned',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history),
                title: const Text('Learned stores'),
                subtitle: const Text('Names, categories, total rows and tax relief choices from your saved receipts'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LearnedStoresPage())),
              ),
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
                  leading: const Icon(Icons.password),
                  title: const Text('Change password'),
                  onTap: () =>
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePasswordPage())),
                ),
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
