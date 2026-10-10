import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/routing/router.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../state/experiment_settings.dart';
import 'backend_url.dart';

/// Where the data comes from: simulated, or the team's backend.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final demo = ref.watch(
      experimentSettingsProvider.select((s) => s.demoMode),
    );
    final settings = ref.read(experimentSettingsProvider.notifier);

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
                const _SectionTitle('Data source'),
                RadioGroup<bool>(
                  groupValue: demo,
                  onChanged: (value) {
                    if (value != null) settings.setDemoMode(value);
                  },
                  child: const Column(
                    children: [
                      _SourceOption(
                        value: true,
                        title: 'Demo data',
                        body:
                            'Simulated experiments. No camera or backend '
                            'needed, so it works anywhere.',
                      ),
                      SizedBox(height: AppSpace.sm),
                      _SourceOption(
                        value: false,
                        title: 'Live backend',
                        body:
                            'Your camera streams to the backend, which '
                            'tracks the object and sends the physics back. '
                            'With no camera, a test video stands in.',
                      ),
                    ],
                  ),
                ),
                AnimatedSize(
                  duration: AppMotion.standard,
                  curve: AppMotion.ease,
                  alignment: Alignment.topCenter,
                  child: demo
                      ? const SizedBox(width: double.infinity)
                      : const _BackendForm(),
                ),
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
        AppSpace.lg,
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

/// One choice of data source, as a whole tappable panel.
class _SourceOption extends StatelessWidget {
  const _SourceOption({
    required this.value,
    required this.title,
    required this.body,
  });

  final bool value;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = RadioGroup.maybeOf<bool>(context)?.groupValue == value;
    return Material(
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.panelAll,
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outline,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: RadioListTile<bool>(
        value: value,
        contentPadding: const EdgeInsets.fromLTRB(
          AppSpace.sm,
          AppSpace.xs,
          AppSpace.lg,
          AppSpace.xs,
        ),
        title: Text(title, style: AppType.bodyStrong.copyWith(fontSize: 16)),
        subtitle: Text(
          body,
          style: AppType.caption.copyWith(
            fontSize: 13,
            color: scheme.onSurfaceVariant,
          ),
        ),
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
    // Choosing Live backend checks it straight away. For the hosted server
    // that also wakes it up while the user sets up the experiment.
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

  void _onChanged(String value) {
    _edit++;
    setState(() {
      _error = validateBackendUrl(value);
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
    if (validateBackendUrl(_text.text) == null) {
      _settings.setBackendUrl(_text.text);
    }
  }

  void _useDefault() {
    _text.text = AppConfig.defaultBackendUrl;
    _onChanged(_text.text);
    _runTest();
  }

  Future<void> _runTest() async {
    final error = validateBackendUrl(_text.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    _save();
    final edit = _edit;
    setState(() => _test = _Test.running);
    try {
      final time = await ref.read(backendTestProvider)(_text.text.trim());
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
      padding: const EdgeInsets.only(top: AppSpace.xl),
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
              errorMaxLines: 2,
              // Break before the example so the address never wraps.
              helperText:
                  'Starts on the hosted backend. For a laptop on the\n'
                  'same Wi-Fi, use ws://192.168.1.20:8000/ws/frames',
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
    final hosted = isHostedBackend(_text.text);
    final (IconData? icon, String text) = switch (_test) {
      _Test.idle => (null, ''),
      _Test.running when hosted => (
        AppIcons.arrowClockwise,
        'Connecting. If nobody has used the hosted backend for a while, '
            'it takes up to a minute to wake up.',
      ),
      _Test.running => (AppIcons.arrowClockwise, 'Connecting'),
      _Test.passed => (AppIcons.checkCircle, 'Connected in ${_took()}'),
      _Test.failed when hosted => (
        AppIcons.warning,
        "Couldn't reach the hosted backend. Check that this device is "
            'online, then test again.',
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

/// Which build this is, for when teammates compare notes.
class _About extends StatelessWidget {
  const _About();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.xs, AppSpace.xxxl, 0, 0),
      child: Text(
        'HandsOn Physics 0.1.0, protocol v0.2',
        style: AppType.caption.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
