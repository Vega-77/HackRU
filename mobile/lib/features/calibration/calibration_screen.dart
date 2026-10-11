import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/logging/debug_log.dart';
import '../../core/routing/router.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../models/experiment_mode.dart';
import '../../models/session_config.dart';
import '../../models/vec2.dart';
import '../../services/camera/frame_source.dart';
import '../../state/calibration_controller.dart';
import '../../state/experiment_settings.dart';
import '../../state/session_controller.dart';
import 'mass_steps.dart';
import 'widgets/calibration_stage.dart';
import 'widgets/measurement_chrome.dart';

/// Three steps before an experiment: set the scale with a ruler, mark the
/// object, enter its mass. On iOS with ARKit there is a step before them:
/// pick the real surface the object moves on, which replaces the ruler.
///
/// The scale matters most. The backend measures motion in pixels and
/// divides by pixels per metre to get metres, so a ruler line that is 10 %
/// short makes every velocity 10 % too fast.
class CalibrationScreen extends ConsumerStatefulWidget {
  const CalibrationScreen({super.key});

  @override
  ConsumerState<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends ConsumerState<CalibrationScreen> {
  late final FrameSource _camera = ref.read(frameSourceProvider);

  /// Null while the camera starts.
  FrameSize? _cameraFrame;
  String? _cameraError;

  /// Only the latest start may update the screen; Try again can start a new
  /// one while an old one is still waiting.
  int _cameraAttempt = 0;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  @override
  void dispose() {
    final camera = _camera;
    Future.microtask(camera.stop);
    super.dispose();
  }

  Future<void> _startCamera() async {
    final attempt = ++_cameraAttempt;
    setState(() => _cameraError = null);
    // Any failure has to reach the screen: an uncaught one would leave it
    // on "Starting camera" for good.
    String? error;
    try {
      await _camera.start();
    } on CameraUnavailableException catch (e) {
      error = e.message;
    } catch (e, stack) {
      log.e('The camera failed to start', e, stack);
      error = 'Close other apps using the camera, then try again.';
    }
    if (!mounted || attempt != _cameraAttempt) return;
    final frame = _camera.frameSize;
    if (error == null && frame == null) {
      log.w('The camera started without a picture size');
      error = 'It opened but sent no picture. Try again.';
    }
    if (error != null) {
      setState(() => _cameraError = error);
      return;
    }
    setState(() => _cameraFrame = frame);
    _placeDefaults();
  }

  /// Puts the ruler across the middle the first time, so there is something
  /// to drag onto a real ruler.
  void _placeDefaults() {
    final calibration = ref.read(calibrationProvider);
    if (calibration.rulerStart != null && calibration.rulerEnd != null) return;
    final frame = _cameraFrame!;
    ref.read(calibrationProvider.notifier)
      ..setRulerStart(Vec2(frame.width * 0.3, frame.height * 0.35))
      ..setRulerEnd(Vec2(frame.width * 0.7, frame.height * 0.35));
  }

  Future<void> _startExperiment() async {
    await context.push(Routes.experiment);
    if (!mounted) return;
    // A popped route can finish disposing after this Future completes. Stop
    // its session before setup takes the shared camera back, and open the
    // camera again in case the experiment stopped it.
    await ref.read(sessionProvider.notifier).stop();
    if (mounted) await _startCamera();
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(experimentSettingsProvider.select((s) => s.mode));
    final stage = _Stage(
      frameSize: _cameraFrame,
      error: _cameraError,
      onRetry: _startCamera,
      camera: _camera,
    );
    final surfaces = switch (_camera) {
      final SurfaceFinder f when _cameraFrame != null && f.canFindSurfaces => f,
      _ => null,
    };
    final steps = _Steps(surfaces: surfaces, frameSize: _cameraFrame);
    final start = FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 56),
        backgroundColor: AppColors.instrumentAccentDark,
        foregroundColor: AppColors.graphiteDeep,
      ),
      // A collision needs both objects, so the physics has a pair to compare.
      onPressed:
          (mode == ExperimentMode.collision
              ? ref.watch(calibrationProvider).pairConfirmed
              : ref.watch(calibrationProvider).selectionConfirmed)
          ? _startExperiment
          : null,
      child: const Text('Start experiment'),
    );

    return Theme(
      data: AppTheme.dark(),
      child: Scaffold(
        appBar: AppBar(
          title: Text('Set up ${mode.label.toLowerCase()}'),
          leading: IconButton(
            tooltip: 'Back',
            icon: const Icon(AppIcons.arrowLeft),
            onPressed: () =>
                context.canPop() ? context.pop() : context.go(Routes.home),
          ),
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final shortWorkspace = constraints.maxHeight < 500;
            if (constraints.maxWidth >= 960 ||
                (constraints.maxWidth >= 760 && shortWorkspace)) {
              // Landscape or tablet: picture left, steps right.
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpace.lg,
                        0,
                        AppSpace.sm,
                        AppSpace.lg,
                      ),
                      child: Column(
                        children: [
                          if (!shortWorkspace) const WorkspaceHeading(),
                          Expanded(child: Center(child: stage)),
                          if (!shortWorkspace) const WorkspaceFooter(),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 360,
                    child: SafeArea(
                      left: false,
                      top: false,
                      child: Column(
                        children: [
                          Expanded(child: SingleChildScrollView(child: steps)),
                          Padding(
                            padding: const EdgeInsets.all(AppSpace.lg),
                            child: SizedBox(
                              width: double.infinity,
                              child: start,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }
            // Portrait: picture on top (fixed, so dragging on it never
            // scrolls the page), steps scroll underneath.
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * 0.45,
                    ),
                    child: stage,
                  ),
                ),
                Expanded(child: SingleChildScrollView(child: steps)),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.lg,
                      AppSpace.sm,
                      AppSpace.lg,
                      AppSpace.sm,
                    ),
                    child: SizedBox(width: double.infinity, child: start),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The dark picture panel: the camera, or why there is none.
class _Stage extends ConsumerWidget {
  const _Stage({
    required this.frameSize,
    required this.error,
    required this.onRetry,
    required this.camera,
  });

  final FrameSize? frameSize;
  final String? error;
  final VoidCallback onRetry;
  final FrameSource camera;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final frame = frameSize;
    final Widget content;
    if (error != null) {
      content = _CameraMessage(
        text: 'The camera did not start. $error',
        action: 'Try again',
        onAction: onRetry,
      );
    } else if (frame == null) {
      content = const _CameraMessage(
        text: 'Starting camera. If asked, allow camera access.',
      );
    } else {
      content = CalibrationStage(
        frameSize: frame,
        fit: BoxFit.cover,
        background: camera.buildPreview(context),
      );
    }

    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Column(
        children: [
          CameraStatusStrip(frame: frame, unavailable: error != null),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(4)),
              child: ColoredBox(color: AppColors.graphiteDeep, child: content),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraMessage extends StatelessWidget {
  const _CameraMessage({required this.text, this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    if (action != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.graphiteRaised,
                borderRadius: AppRadii.panelAll,
                border: Border.all(color: AppColors.ruleDark),
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      AppIcons.cameraSlash,
                      size: 20,
                      color: AppColors.instrumentAccentDark,
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      text,
                      style: AppType.body.copyWith(color: AppColors.vellum),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.vellum,
                        side: const BorderSide(
                          color: AppColors.ruleDark,
                          width: 1.5,
                        ),
                      ),
                      onPressed: onAction,
                      child: Text(action!),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                textAlign: TextAlign.center,
                style: AppType.body.copyWith(color: AppColors.vellum),
              ),
              if (action != null) ...[
                const SizedBox(height: AppSpace.md),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.vellum,
                    side: const BorderSide(
                      color: AppColors.ruleDark,
                      width: 1.5,
                    ),
                  ),
                  onPressed: onAction,
                  child: Text(action!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The numbered steps. Numbered because they are a real sequence.
class _Steps extends ConsumerWidget {
  const _Steps({this.surfaces, this.frameSize});

  /// Set when the camera can find AR surfaces.
  final SurfaceFinder? surfaces;
  final FrameSize? frameSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calibration = ref.watch(calibrationProvider);
    final mass = ref.watch(experimentSettingsProvider.select((s) => s.massKg));
    final scheme = Theme.of(context).colorScheme;
    final scale = calibration.pxPerM;
    final surfaces = this.surfaces;
    final hasSurface = surfaces != null && calibration.surface != null;
    final collision =
        ref.watch(experimentSettingsProvider.select((s) => s.mode)) ==
        ExperimentMode.collision;
    final total = (surfaces == null ? 3 : 4) + (collision ? 1 : 0);
    var number = 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.xl,
        AppSpace.lg,
        AppSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.xs,
              AppSpace.xs,
              AppSpace.xs,
              AppSpace.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        'Measurement panel',
                        style: AppType.label.copyWith(
                          color: scheme.primary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '$total steps',
                      style: AppType.readoutSmall.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.xs),
                Text(
                  'Prepare the measurement',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
          ),
          if (surfaces != null)
            _SurfaceStep(
              number: ++number,
              total: total,
              finder: surfaces,
              frameSize: frameSize!,
            ),
          _Step(
            number: ++number,
            total: total,
            title: 'Set the scale',
            body: hasSurface
                ? 'Not needed while a surface is set. The surface measures '
                      'depth and tilt, so it is more accurate.'
                : 'Put a ruler in the picture, level with the experiment. '
                      'Drag both ends of the line onto it.',
            done: scale != null || hasSurface,
            trailing: _RulerLengthField(lengthM: calibration.rulerLengthM),
            footer: hasSurface
                ? const Text('AR surface sets the metric scale')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MeasurementValue(
                        label: 'Image scale',
                        value: scale?.toStringAsFixed(1) ?? 'Not set',
                        unit: scale == null ? '' : 'px/m',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        scale == null
                            ? 'Place both ends to set the scale'
                            : 'Verify endpoints A and B against a real ruler.',
                        style: AppType.caption.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
          ),
          _Step(
            number: ++number,
            total: total,
            title: collision ? 'Mark the first object' : 'Mark the object',
            // Keyboard controls are in the picture's screen reader label.
            body: calibration.selectionPending
                ? 'Finding the object in this picture. Hold it still.'
                : calibration.selectionError ??
                      (calibration.target == null
                          ? 'Tap the object to propose its boundary, or drag a box around it.'
                          : calibration.selectionConfirmed
                          ? collision
                                ? 'Now mark the object it will hit.'
                                : 'Keep it in view when you start.'
                          : 'Does the box fit the whole object? Confirm it, '
                                'or draw a better one.'),
            done: calibration.selectionConfirmed,
            footer: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : AppMotion.standard,
                  child: Text(
                    selectionStatus(calibration),
                    key: ValueKey(selectionStatus(calibration)),
                    style: AppType.label.copyWith(
                      color: calibration.selectionConfirmed
                          ? AppColors.instrumentAccentDark
                          : AppColors.vellum,
                    ),
                  ),
                ),
                if (calibration.targetBbox case final box?) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${box.w.toStringAsFixed(1)} × ${box.h.toStringAsFixed(1)} px · held selection picture',
                    style: AppType.readoutSmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (calibration.target != null)
                  Wrap(
                    spacing: AppSpace.sm,
                    runSpacing: AppSpace.sm,
                    children: [
                      if (calibration.targetBbox != null &&
                          !calibration.selectionConfirmed)
                        OutlinedButton.icon(
                          onPressed: ref
                              .read(calibrationProvider.notifier)
                              .confirmSelection,
                          icon: const Icon(AppIcons.check, size: 18),
                          label: const Text('Confirm object'),
                        ),
                      TextButton(
                        onPressed: ref
                            .read(calibrationProvider.notifier)
                            .clearTarget,
                        child: const Text('Select again'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          if (collision) _SecondObjectStep(number: ++number, total: total),
          _Step(
            number: ++number,
            total: total,
            title: 'Enter its mass',
            body: 'Forces and energy scale with mass. Weigh it if you can. The current value is used when you start.',
            done: true,
            last: true,
            trailing: _MassStepper(
              massKg: mass,
              onChanged: ref.read(experimentSettingsProvider.notifier).setMass,
            ),
          ),
        ],
      ),
    );
  }
}

/// Marks the other object in a collision the same way as the first. It
/// opens once the first object is confirmed, so a tap is never ambiguous.
class _SecondObjectStep extends ConsumerWidget {
  const _SecondObjectStep({required this.number, required this.total});

  final int number;
  final int total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calibration = ref.watch(calibrationProvider);
    final controller = ref.read(calibrationProvider.notifier);
    final second = calibration.second;
    final scheme = Theme.of(context).colorScheme;
    final String body;
    if (!calibration.selectionConfirmed) {
      body = 'Confirm the first object, then tap the second one.';
    } else if (second?.pending ?? false) {
      body = 'Finding the object in this picture. Hold it still.';
    } else if (calibration.secondError case final error?) {
      body = error;
    } else if (second == null) {
      body = 'Tap the other object, or drag a box around it.';
    } else if (second.confirmed) {
      body = 'Keep both objects in view when you start.';
    } else {
      body = 'Does the box fit the whole object? Confirm it, or draw a better one.';
    }
    return _Step(
      number: number,
      total: total,
      title: 'Mark the second object',
      body: body,
      done: second?.confirmed ?? false,
      footer: second == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (second.box case final box?) ...[
                  Text(
                    '${box.w.toStringAsFixed(1)} × ${box.h.toStringAsFixed(1)} px · held selection picture',
                    style: AppType.readoutSmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    if (second.box != null &&
                        !second.pending &&
                        !second.confirmed)
                      OutlinedButton.icon(
                        onPressed: controller.confirmSelection,
                        icon: const Icon(AppIcons.check, size: 18),
                        label: const Text('Confirm object'),
                      ),
                    TextButton(
                      onPressed: controller.clearSecond,
                      child: const Text('Select again'),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

/// Finds the board or table the object moves on with an ARKit raycast
/// through the middle of the picture. Positions are then measured on that
/// surface in 3D, so the phone may move during the experiment.
class _SurfaceStep extends ConsumerStatefulWidget {
  const _SurfaceStep({
    required this.number,
    required this.total,
    required this.finder,
    required this.frameSize,
  });

  final int number;
  final int total;
  final SurfaceFinder finder;
  final FrameSize frameSize;

  @override
  ConsumerState<_SurfaceStep> createState() => _SurfaceStepState();
}

class _SurfaceStepState extends ConsumerState<_SurfaceStep> {
  bool _searching = false;
  bool _missed = false;

  Future<void> _find() async {
    setState(() {
      _searching = true;
      _missed = false;
    });
    final centre = Vec2(
      widget.frameSize.width / 2,
      widget.frameSize.height / 2,
    );
    final surface = await widget.finder.findSurface(centre);
    if (!mounted) return;
    if (surface != null) {
      HapticFeedback.selectionClick();
      ref.read(calibrationProvider.notifier).setSurface(surface);
    }
    setState(() {
      _searching = false;
      _missed = surface == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final surface = ref.watch(calibrationProvider.select((c) => c.surface));
    final mode = ref.watch(experimentSettingsProvider.select((s) => s.mode));
    final scheme = Theme.of(context).colorScheme;
    // Gravity lies in a vertical board, so its 2D physics is exact there.
    final wantsBoard = mode != ExperimentMode.collision;

    final String status;
    if (_missed) {
      status =
          'No surface found there. Move the phone slowly so it can map the '
          'scene, then try again.';
    } else if (surface == null) {
      status = 'No surface yet';
    } else if (surface.vertical) {
      status = 'Using a vertical board';
    } else if (wantsBoard) {
      status =
          'Using a table top. For this experiment, the board behind it '
          'gives better forces.';
    } else {
      status = 'Using a table top';
    }

    return _Step(
      number: widget.number,
      total: widget.total,
      title: 'Find the surface',
      body: wantsBoard
          ? 'Aim the middle of the picture at a board behind the experiment, '
                'parallel to the motion, then tap Find.'
          : 'Aim the middle of the picture at the table the carts roll on, '
                'then tap Find.',
      done: surface != null,
      trailing: TextButton(
        onPressed: _searching ? null : _find,
        child: Text(surface == null ? 'Find' : 'Find again'),
      ),
      footer: Text(
        status,
        style: AppType.readoutSmall.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.total,
    required this.title,
    required this.body,
    required this.done,
    this.trailing,
    this.footer,
    this.last = false,
  });

  final int number;
  final int total;
  final String title;
  final String body;
  final bool done;
  final Widget? trailing;
  final Widget? footer;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return MeasurementSection(
      number: number,
      total: total,
      title: title,
      body: body,
      done: done,
      trailing: trailing,
      footer: footer,
      last: last,
    );
  }
}

/// The real length of the ruler line, in centimetres.
class _RulerLengthField extends ConsumerStatefulWidget {
  const _RulerLengthField({required this.lengthM});

  final double lengthM;

  @override
  ConsumerState<_RulerLengthField> createState() => _RulerLengthFieldState();
}

class _RulerLengthFieldState extends ConsumerState<_RulerLengthField> {
  late final _text = TextEditingController(text: _format(widget.lengthM));
  bool _invalid = false;

  static String _format(double m) {
    final cm = m * 100;
    return cm == cm.roundToDouble()
        ? cm.toStringAsFixed(0)
        : cm.toStringAsFixed(1);
  }

  @override
  void didUpdateWidget(_RulerLengthField old) {
    super.didUpdateWidget(old);
    // Changed elsewhere: show it, unless the user is typing.
    final typed = double.tryParse(_text.text.replaceAll(',', '.'));
    if (typed == null || (typed / 100 - widget.lengthM).abs() > 1e-6) {
      if (!_invalid) _text.text = _format(widget.lengthM);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    final cm = double.tryParse(value.replaceAll(',', '.'));
    final valid = cm != null && cm >= 1 && cm <= 500;
    setState(() => _invalid = !valid);
    if (valid) {
      ref.read(calibrationProvider.notifier).setRulerLength(cm / 100);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: TextField(
        controller: _text,
        onChanged: _onChanged,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
        ],
        textAlign: TextAlign.end,
        style: AppType.readout.copyWith(fontSize: 28),
        decoration: InputDecoration(
          isDense: true,
          labelText: 'Reference length',
          suffixText: 'cm',
          errorText: _invalid ? 'Use 1 to 500 cm' : null,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpace.md,
            vertical: AppSpace.md,
          ),
        ),
      ),
    );
  }
}

class _MassStepper extends StatelessWidget {
  const _MassStepper({required this.massKg, required this.onChanged});

  final double massKg;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget button(IconData icon, String tooltip, double? next) => IconButton(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      tooltip: tooltip,
      onPressed: next == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onChanged(next);
            },
      icon: Icon(icon, size: 18),
    );

    return Semantics(
      label: 'Mass',
      value: MassSteps.format(massKg),
      increasedValue: MassSteps.format(MassSteps.up(massKg)),
      decreasedValue: MassSteps.format(MassSteps.down(massKg)),
      onIncrease: MassSteps.canGoUp(massKg)
          ? () => onChanged(MassSteps.up(massKg))
          : null,
      onDecrease: MassSteps.canGoDown(massKg)
          ? () => onChanged(MassSteps.down(massKg))
          : null,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: RoundedRectangleBorder(
            borderRadius: AppRadii.controlAll,
            side: BorderSide(color: scheme.outline),
          ),
          color: scheme.surfaceContainer,
        ),
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              button(
                AppIcons.minus,
                'Lighter',
                MassSteps.canGoDown(massKg) ? MassSteps.down(massKg) : null,
              ),
              Flexible(
                child: Text(
                  MassSteps.format(massKg),
                  textAlign: TextAlign.center,
                  style: AppType.readout.copyWith(fontSize: 28),
                ),
              ),
              button(
                AppIcons.plus,
                'Heavier',
                MassSteps.canGoUp(massKg) ? MassSteps.up(massKg) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
