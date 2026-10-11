import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/routing/router.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../models/experiment_mode.dart';
import '../../services/network/physics_socket.dart';
import '../../state/experiment_settings.dart';
import '../../state/session_controller.dart';
import '../debug/copy_debug_log.dart';
import '../settings/backend_url.dart';
import 'server_error_text.dart';
import 'widgets/experiment_stage.dart';
import 'widgets/telemetry_panel.dart';

/// The live experiment: picture with arrows, plus telemetry.
///
/// * Portrait: the picture on top, telemetry in a sheet you can drag up.
///   The picture always fills the space above the sheet.
/// * Landscape: picture on the left, telemetry in a column on the right.
///
/// Always dark, whatever the system theme: the camera feed and the coloured
/// arrows read best on graphite, like a lab instrument's display.
class ExperimentScreen extends ConsumerStatefulWidget {
  const ExperimentScreen({super.key});

  @override
  ConsumerState<ExperimentScreen> createState() => _ExperimentScreenState();
}

class _ExperimentScreenState extends ConsumerState<ExperimentScreen> {
  static const _sheetMin = 0.28;
  static const _sheetInitial = 0.52;
  static const _sheetMax = 0.88;

  late final SessionController _session;
  int? _sessionEpoch;
  final _sheetExtent = ValueNotifier<double>(_sheetInitial);

  @override
  void initState() {
    super.initState();
    _session = ref.read(sessionProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _session.start();
      _sessionEpoch = _session.sessionEpoch;
    });
  }

  @override
  void dispose() {
    _sheetExtent.dispose();
    // Not during the tree teardown: providers can't change mid-frame.
    final session = _session;
    final epoch = _sessionEpoch;
    if (epoch != null) {
      Future.microtask(() => session.stop(onlyIfEpoch: epoch));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AppTheme.dark(),
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: AppColors.graphiteDeep,
          body: OrientationBuilder(
            builder: (context, orientation) =>
                orientation == Orientation.landscape
                ? _landscape(context)
                : _portrait(context),
          ),
        ),
      ),
    );
  }

  Widget _portrait(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        return Stack(
          children: [
            // The stage tracks the sheet, so the picture is never hidden
            // behind it, but stops shrinking at 40 % of the screen.
            ValueListenableBuilder<double>(
              valueListenable: _sheetExtent,
              builder: (context, extent, child) => Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: height * (1 - extent).clamp(0.4, 1.0) + AppRadii.panel,
                child: child!,
              ),
              child: const _StageWithHud(),
            ),
            NotificationListener<DraggableScrollableNotification>(
              onNotification: (n) {
                _sheetExtent.value = n.extent;
                return false;
              },
              child: DraggableScrollableSheet(
                minChildSize: _sheetMin,
                initialChildSize: _sheetInitial,
                maxChildSize: _sheetMax,
                snap: true,
                snapSizes: const [_sheetInitial],
                builder: (context, scrollController) => DecoratedBox(
                  decoration: const BoxDecoration(
                    color: AppColors.graphiteRaised,
                    borderRadius: AppRadii.sheetTop,
                  ),
                  child: SafeArea(
                    top: false,
                    child: TelemetryPanel(scrollController: scrollController),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _landscape(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: _StageWithHud()),
        SizedBox(
          width: 360,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: AppColors.graphiteRaised,
              border: Border(left: BorderSide(color: AppColors.ruleDark)),
            ),
            child: SafeArea(
              left: false,
              child: const TelemetryPanel(showHandle: false),
            ),
          ),
        ),
      ],
    );
  }
}

/// The stage plus everything floating on it: navigation, status, and the
/// messages that explain an empty or frozen picture.
class _StageWithHud extends ConsumerWidget {
  const _StageWithHud();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(sessionProvider.select((s) => s.phase));

    return Stack(
      fit: StackFit.expand,
      children: [
        if (phase == SessionPhase.failed)
          const _CameraFailed()
        else
          const ExperimentStage(),
        const _StageMessage(),
        const SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.all(AppSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(),
                SizedBox(height: AppSpace.sm),
                _Banners(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(experimentSettingsProvider.select((s) => s.mode));
    final phase = ref.watch(sessionProvider.select((s) => s.phase));
    final session = ref.read(sessionProvider.notifier);
    final paused = phase == SessionPhase.paused;

    return Row(
      children: [
        _GlassIconButton(
          icon: AppIcons.arrowLeft,
          tooltip: 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go(Routes.home),
        ),
        const SizedBox(width: AppSpace.sm),
        // The mode pill takes the spare width first; it only truncates when
        // the screen is genuinely too narrow.
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: _GlassPill(
                  onTap: () => _pickMode(context, ref, mode),
                  semanticsLabel:
                      'Experiment: ${mode.label}. Change experiment',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          mode.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.label.copyWith(
                            fontSize: 14,
                            color: AppColors.vellum,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        AppIcons.caretDown,
                        size: 14,
                        color: AppColors.vellum,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              _StatusChip(compact: MediaQuery.sizeOf(context).width < 430),
            ],
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        _GlassIconButton(
          icon: paused ? AppIcons.play : AppIcons.pause,
          tooltip: paused ? 'Resume' : 'Pause',
          onPressed: switch (phase) {
            SessionPhase.running => session.pause,
            SessionPhase.paused => session.resume,
            _ => null,
          },
        ),
      ],
    );
  }

  Future<void> _pickMode(
    BuildContext context,
    WidgetRef ref,
    ExperimentMode current,
  ) async {
    final picked = await showModalBottomSheet<ExperimentMode>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.xl,
                  0,
                  AppSpace.xl,
                  AppSpace.sm,
                ),
                child: Text(
                  'Experiment',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final m in ExperimentMode.values)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.xl,
                  ),
                  title: Text(m.label, style: AppType.bodyStrong),
                  trailing: m == current ? const Icon(AppIcons.check) : null,
                  selected: m == current,
                  onTap: () => Navigator.of(context).pop(m),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked != current) {
      ref.read(experimentSettingsProvider.notifier).setMode(picked);
    }
  }
}

/// How the connection to the backend is doing. Neutral on purpose: colour
/// on this screen means physics.
class _StatusChip extends ConsumerWidget {
  const _StatusChip({this.compact = false});

  final bool compact;

  /// Leaves the experiment pill room on a small phone.
  static const _maxWidth = 140.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(sessionProvider.select((s) => s.connection));
    final latency = ref.watch(sessionProvider.select((s) => s.latencyMs));

    // The broadcast icon already says live, so the round trip stands alone.
    final (IconData icon, String text) = switch (connection) {
      ConnectionStatus.live => (
        AppIcons.broadcast,
        latency == null ? 'Live' : '${latency.round()} ms',
      ),
      ConnectionStatus.connecting => (AppIcons.arrowClockwise, 'Connecting'),
      ConnectionStatus.offline => (AppIcons.wifiSlash, 'Offline'),
      ConnectionStatus.idle => (AppIcons.plugs, 'Not connected'),
    };

    return Semantics(
      liveRegion: true,
      label: connection == ConnectionStatus.live && latency != null
          ? 'Live, $text round trip'
          : text,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: compact ? 40 : _maxWidth),
        child: _GlassPill(
          dense: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: AppColors.inkMutedDark),
              if (!compact) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.readoutSmall.copyWith(
                      color: AppColors.vellum,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Server errors and lost connections, under the top bar.
class _Banners extends ConsumerWidget {
  const _Banners();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(
      experimentSettingsProvider.select((s) => s.backendUrl),
    );
    final connection = ref.watch(sessionProvider.select((s) => s.connection));
    final serverError = ref.watch(sessionProvider.select((s) => s.serverError));
    final errorCount = ref.watch(
      sessionProvider.select((s) => s.serverErrorCount),
    );

    final banners = <Widget>[
      if (connection == ConnectionStatus.offline)
        _Banner(
          icon: AppIcons.cellSignalSlash,
          message: isHostedBackend(url)
              ? "Can't reach the hosted backend yet. If it was asleep, it "
                    'takes up to a minute to wake. Retrying.'
              : "Can't reach the backend at $url. Retrying every few seconds.",
          actions: [('Settings', () => context.push(Routes.settings))],
        ),
      if (serverError != null)
        _Banner(
          icon: AppIcons.warning,
          message: describeServerError(serverError, count: errorCount),
          actions: [
            if (ref.watch(sessionProvider).phase == SessionPhase.failed)
              (
                'Select again',
                () => context.canPop()
                    ? context.pop()
                    : context.go(Routes.calibrate),
              ),
            ('Copy log', () => copyDebugLog(context)),
            ('Dismiss', ref.read(sessionProvider.notifier).dismissServerError),
          ],
        ),
    ];

    return AnimatedSize(
      duration: AppMotion.standard,
      curve: AppMotion.ease,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final b in banners)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: b,
            ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.message,
    required this.actions,
  });

  final IconData icon;
  final String message;

  /// Button labels and what they do, shown after the message.
  final List<(String, VoidCallback)> actions;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.scrim,
          borderRadius: AppRadii.panelAll,
          border: Border.all(color: AppColors.ruleDark),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.md,
            AppSpace.xs,
            AppSpace.xs,
            AppSpace.xs,
          ),
          // One action fits beside the message; more go under it, so the
          // message keeps its width on a phone.
          child: actions.length == 1
              ? Row(children: [..._message(), ..._buttons()])
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        top: AppSpace.sm,
                        right: AppSpace.sm,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: _message(),
                      ),
                    ),
                    Row(mainAxisSize: MainAxisSize.min, children: _buttons()),
                  ],
                ),
        ),
      ),
    );
  }

  List<Widget> _message() => [
    Icon(icon, size: 18, color: AppColors.vellum),
    const SizedBox(width: AppSpace.sm),
    Expanded(
      child: Text(
        message,
        style: AppType.caption.copyWith(color: AppColors.vellum, fontSize: 13),
      ),
    ),
  ];

  List<Widget> _buttons() => [
    for (final (label, onPressed) in actions)
      TextButton(onPressed: onPressed, child: Text(label)),
  ];
}

/// A centred note when the picture alone would be confusing: starting up,
/// paused, or the object is not in view.
class _StageMessage extends ConsumerWidget {
  const _StageMessage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(sessionProvider.select((s) => s.phase));
    final hasState = ref.watch(sessionProvider.select((s) => s.latest != null));
    final tracked = ref.watch(
      sessionProvider.select((s) => s.latest?.tracked ?? false),
    );
    final connection = ref.watch(sessionProvider.select((s) => s.connection));
    final trackingStatus = ref.watch(
      sessionProvider.select((s) => s.latest?.trackingStatus),
    );

    final (IconData, String)? message = switch (phase) {
      SessionPhase.starting => (AppIcons.circle, 'Starting'),
      SessionPhase.paused => (AppIcons.pause, 'Paused. Tap play to carry on.'),
      SessionPhase.running when hasState && !tracked => (
        AppIcons.crosshair,
        switch (trackingStatus) {
          'stale' => 'Observation delayed. Waiting for a fresh camera frame.',
          'selection_required' ||
          'invalid_selection' => 'Return to setup and select an object region.',
          'insufficient_contrast' => 'The selection has too little contrast. Return to setup and include the object outline.',
          _ => 'Looking for the object',
        },
      ),
      SessionPhase.running
          when !hasState && connection == ConnectionStatus.live =>
        (AppIcons.crosshair, 'Waiting for the first result'),
      _ => null,
    };

    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, 0.55),
        child: AnimatedSwitcher(
          duration: AppMotion.standard,
          child: message == null
              ? const SizedBox.shrink()
              : Semantics(
                  liveRegion: true,
                  child: _GlassPill(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(message.$1, size: 16, color: AppColors.vellum),
                        const SizedBox(width: AppSpace.sm),
                        Text(
                          message.$2,
                          style: AppType.label.copyWith(
                            fontSize: 14,
                            color: AppColors.vellum,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// The experiment needs the camera. Explain what happened and offer a way on.
class _CameraFailed extends ConsumerWidget {
  const _CameraFailed();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(sessionProvider.select((s) => s.cameraError));
    final session = ref.read(sessionProvider.notifier);

    return ColoredBox(
      color: AppColors.graphiteDeep,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.xl,
            96,
            AppSpace.xl,
            AppSpace.xl,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.graphiteRaised,
                borderRadius: AppRadii.panelAll,
                border: Border.all(color: AppColors.ruleDark),
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          AppIcons.cameraSlash,
                          size: 20,
                          color: AppColors.instrumentAccentDark,
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Text(
                          'Camera input',
                          style: AppType.label.copyWith(
                            color: AppColors.inkMutedDark,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.lg),
                    Text(
                      'The camera did not start',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      '${error ?? 'No camera was found.'} '
                      'Check that the app may use the camera, then try again.',
                      style: AppType.body.copyWith(
                        color: AppColors.inkMutedDark,
                      ),
                    ),
                    const SizedBox(height: AppSpace.xl),
                    FilledButton(
                      onPressed: session.start,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Translucent graphite chrome that floats over the picture.
class _GlassPill extends StatelessWidget {
  const _GlassPill({
    required this.child,
    this.onTap,
    this.semanticsLabel,
    this.dense = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticsLabel;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? AppSpace.md : AppSpace.lg,
      ),
      child: SizedBox(
        height: dense ? 32 : 44,
        child: Center(widthFactor: 1, child: child),
      ),
    );
    return Semantics(
      button: onTap != null,
      label: semanticsLabel,
      excludeSemantics: semanticsLabel != null,
      child: Material(
        color: AppColors.scrim,
        shape: const StadiumBorder(side: BorderSide(color: AppColors.ruleDark)),
        clipBehavior: Clip.antiAlias,
        child: onTap == null ? content : InkWell(onTap: onTap, child: content),
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: Material(
          color: AppColors.scrim,
          shape: const CircleBorder(
            side: BorderSide(color: AppColors.ruleDark),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox.square(
              dimension: 44,
              child: Icon(
                icon,
                size: 20,
                color: onPressed == null
                    ? AppColors.inkMutedDark
                    : AppColors.vellum,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
