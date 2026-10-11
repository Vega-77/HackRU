import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/routing/router.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../core/logging/debug_log.dart';
import '../../state/experiment_settings.dart';
import '../debug/copy_debug_log.dart';
import 'backend_url.dart';

/// Which backend the camera streams to, and the debug log.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(AppIcons.arrowLeft),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go(Routes.home),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.sm,
                AppSpace.lg,
                AppSpace.xxl,
              ),
              children: [
                const _SectionTitle('Backend'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.xs,
                    0,
                    AppSpace.xs,
                    AppSpace.md,
                  ),
                  child: Text(
                    'Your camera streams to the backend, which tracks the '
                    'object and sends the physics back. With no camera, a '
                    'test video stands in.',
                    style: AppType.body.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const _BackendForm(),
                const _SectionTitle('Debug log'),
                const _DebugLog(),
                const _About(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xs,
        AppSpace.xl,
        0,
        AppSpace.md,
      ),
      child: Semantics(
        header: true,
        child: Text(text, style: Theme.of(context).textTheme.titleLarge),
      ),
    );
  }
}

enum _Test { idle, running, passed, failed }

/// The backend address, with a check that it answers.
class _BackendForm extends ConsumerStatefulWidget {
  const _BackendForm();

  @override
  ConsumerState<_BackendForm> createState() => _BackendFormState();
}

class _BackendFormState extends ConsumerState<_BackendForm> {
  late final _text = TextEditingController(
    text: ref.read(experimentSettingsProvider).backendUrl,
  );

  /// Kept so [dispose] can save without `ref`, which is gone by then.
  late final ExperimentSettingsController _settings;
  Timer? _saveTimer;
  String? _error;
  _Test _test = _Test.idle;
  Duration? _testTime;

  /// Bumped on every edit, so a slow test result for an old address is
  /// thrown away.
  int _edit = 0;

  @override
  void initState() {
    super.initState();
    _settings = ref.read(experimentSettingsProvider.notifier);
    // Opening Settings checks the backend straight away. For the hosted
    // server that also wakes it up while the user sets up the experiment.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _runTest();
    });
  }

  @override
  void dispose() {
    // Leaving mid-edit: save what was typed instead of dropping it.
    if (_saveTimer?.isActive ?? false) _save();
    _saveTimer?.cancel();
    _text.dispose();
    super.dispose();
  }

  /// The typed address with what a laptop address leaves out filled in.
  String get _url => normalizeBackendUrl(_text.text);

  void _onChanged(String value) {
    _edit++;
    setState(() {
      _error = validateBackendUrl(normalizeBackendUrl(value));
      _test = _Test.idle;
    });
    // Saving restarts a running session's connection, so wait until the
    // user stops typing.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), _save);
  }

  /// Saves the address if it is valid. Saving the same address again is
  /// harmless: the session only reconnects when the address changes.
  void _save() {
    _saveTimer?.cancel();
    final url = _url;
    if (validateBackendUrl(url) == null) _settings.setBackendUrl(url);
  }

  void _useDefault() {
    _text.text = AppConfig.defaultBackendUrl;
    _onChanged(_text.text);
    _runTest();
  }

  Future<void> _runTest() async {
    final url = _url;
    final error = validateBackendUrl(url);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    // Show the full address that is saved and tested. Setting the text
    // does not call onChanged, so this is not counted as an edit.
    if (_text.text != url) _text.text = url;
    _save();
    final edit = _edit;
    setState(() => _test = _Test.running);
    try {
      final time = await ref.read(backendTestProvider)(url);
      if (!mounted || edit != _edit) return;
      setState(() {
        _test = _Test.passed;
        _testTime = time;
      });
    } catch (_) {
      if (!mounted || edit != _edit) return;
      setState(() => _test = _Test.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _text,
            onChanged: _onChanged,
            onSubmitted: (_) => _runTest(),
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.go,
            style: AppType.body,
            decoration: InputDecoration(
              labelText: 'Backend address',
              errorText: _error,
              errorMaxLines: 3,
              // Break before the example so the address never wraps.
              helperText: pageNeedsWss
                  ? 'Starts on the hosted backend. For a laptop, enter\n'
                        'its tunnel address, like name.trycloudflare.com'
                  : 'Starts on the hosted backend. For a laptop on the\n'
                        'same Wi-Fi, enter its address, like 192.168.1.20',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              OutlinedButton.icon(
                onPressed: _test == _Test.running ? null : _runTest,
                icon: const Icon(AppIcons.plugs, size: 18),
                label: const Text('Test connection'),
              ),
              if (_text.text.trim() != AppConfig.defaultBackendUrl)
                TextButton(
                  onPressed: _useDefault,
                  child: Text(
                    isHostedBackend(AppConfig.defaultBackendUrl)
                        ? 'Use the hosted backend'
                        : 'Use the default address',
                  ),
                ),
            ],
          ),
          // The result gets its own full-width line, so a failure reads as
          // a sentence instead of a narrow column beside the button.
          Semantics(
            liveRegion: true,
            child: AnimatedSize(
              duration: AppMotion.quick,
              alignment: Alignment.topLeft,
              child: AnimatedSwitcher(
                duration: AppMotion.quick,
                child: _result(scheme),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Milliseconds for a quick answer, seconds after a server woke up.
  String _took() {
    final time = _testTime!;
    return time < const Duration(seconds: 2)
        ? '${time.inMilliseconds} ms'
        : '${time.inSeconds} s';
  }

  Widget _result(ColorScheme scheme) {
    final url = _text.text.trim();
    final online = isHostedBackend(url);
    // Any other wss:// address is a laptop backend behind a tunnel.
    final hosted = online && url == AppConfig.defaultBackendUrl;
    final (IconData? icon, String text) = switch (_test) {
      _Test.idle => (null, ''),
      _Test.running when hosted => (
        AppIcons.arrowClockwise,
        'Connecting. If nobody has used the hosted backend for a while, '
            'it takes up to a minute to wake up.',
      ),
      _Test.running when online => (
        AppIcons.arrowClockwise,
        'Connecting. A new tunnel address can take up to a minute to '
            'start working.',
      ),
      _Test.running => (AppIcons.arrowClockwise, 'Connecting'),
      _Test.passed => (AppIcons.checkCircle, 'Connected in ${_took()}'),
      _Test.failed when hosted => (
        AppIcons.warning,
        "Couldn't reach the hosted backend. Check that this device is "
            'online, then test again.',
      ),
      _Test.failed when online => (
        AppIcons.warning,
        "Couldn't connect. Check the address, and that the laptop backend "
            'and its tunnel are still running.',
      ),
      _Test.failed => (
        AppIcons.warning,
        "Couldn't connect. Check the address, and that the backend is "
            'running on the same Wi-Fi.',
      ),
    };
    if (icon == null) return const SizedBox.shrink(key: ValueKey('idle'));
    return Padding(
      key: ValueKey(_test),
      padding: const EdgeInsets.fromLTRB(AppSpace.xs, AppSpace.md, 0, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onSurface),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              text,
              style: AppType.caption.copyWith(
                fontSize: 13,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Copy or clear the hidden debug log.
class _DebugLog extends StatefulWidget {
  const _DebugLog();

  @override
  State<_DebugLog> createState() => _DebugLogState();
}

class _DebugLogState extends State<_DebugLog> {
  // The log isn't listenable (it takes a line per frame), so the count is
  // checked once a second while Settings is open.
  late final Timer _refresh;
  int _shown = log.entryCount;

  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) => _update());
  }

  @override
  void dispose() {
    _refresh.cancel();
    super.dispose();
  }

  void _update() {
    if (mounted && log.entryCount != _shown) {
      setState(() => _shown = log.entryCount);
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final count = _shown;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Records what the app does during an experiment. Copy it to '
            'share when something goes wrong.',
            style: AppType.body.copyWith(color: muted),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            count == 1
                ? '1 entry so far'
                : '${groupDigits(count)} entries so far',
            style: AppType.caption.copyWith(color: muted),
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  await copyDebugLog(context);
                  _update();
                },
                icon: const Icon(AppIcons.copy, size: 18),
                label: const Text('Copy debug log'),
              ),
              TextButton(
                onPressed: count == 0
                    ? null
                    : () {
                        log.clear();
                        log.i('Debug log cleared');
                        _update();
                      },
                child: const Text('Clear'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Which build this is, for when teammates compare notes.
class _About extends StatelessWidget {
  const _About();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.xs, AppSpace.xxxl, 0, 0),
      child: Text(
        'HandsOn Physics ${AppConfig.appVersion}, '
        'protocol ${AppConfig.protocolVersion}',
        style: AppType.caption.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
