import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/routing/router.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../models/experiment_mode.dart';
import '../../models/session_config.dart';
import '../../models/vec2.dart';
import '../../services/camera/frame_source.dart';
import '../../services/network/mock_physics_stream.dart';
import '../../state/calibration_controller.dart';
import '../../state/experiment_settings.dart';
import '../../state/session_controller.dart';
import '../experiment/widgets/demo_scene.dart';
import '../home/widgets/experiment_preview.dart';
import 'mass_steps.dart';
import 'widgets/calibration_stage.dart';

/// Three steps before an experiment: set the scale with a ruler, mark the
/// object, enter its mass. On iOS with ARKit there is a step before them:
/// pick the real surface the object moves on, which replaces the ruler.
///
/// The scale matters most. The backend measures motion in pixels and
/// divides by pixels per metre to get metres, so a ruler line that is 10 %
/// short makes every velocity 10 % too fast.
///
/// In demo mode the ruler and object are already placed, so you can go
/// straight on, or drag them to see how calibration works.
class CalibrationScreen extends ConsumerStatefulWidget {
  const CalibrationScreen({super.key});

  @override
  ConsumerState<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends ConsumerState<CalibrationScreen> {
  late final FrameSource _camera = ref.read(frameSourceProvider);
  late final bool _demo = ref.read(experimentSettingsProvider).demoMode;

  /// Live mode only: null while the camera starts.
  FrameSize? _cameraFrame;
  String? _cameraError;

  FrameSize get _frameSize =>
      _demo ? SessionController.demoFrameSize : _cameraFrame!;

  @override
  void initState() {
    super.initState();
    if (_demo) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _placeDefaults());
    } else {
      _startCamera();
    }
  }

  @override
  void dispose() {
    if (!_demo) {
      final camera = _camera;
      Future.microtask(camera.stop);
    }
    super.dispose();
  }

  Future<void> _startCamera() async {
    setState(() => _cameraError = null);
    try {
      await _camera.start();
    } on CameraUnavailableException catch (e) {
      if (mounted) setState(() => _cameraError = e.message);
      return;
    }
    if (!mounted) return;
    setState(() => _cameraFrame = _camera.frameSize);
    _placeDefaults();
  }

  /// Puts the ruler and target somewhere sensible the first time, so there
  /// is something to drag. In demo mode they land exactly on the scene's
  /// 30 cm and on the object.
  void _placeDefaults() {
    final calibration = ref.read(calibrationProvider);
    final controller = ref.read(calibrationProvider.notifier);
    final frame = _frameSize;
    final mode = ref.read(experimentSettingsProvider).mode;

    if (calibration.rulerStart == null || calibration.rulerEnd == null) {
      if (_demo) {
        // The demo scene is drawn at MockPhysics.pxPerM, so the right answer
        // is known: a 30 cm line along the top of the grid.
        Vec2 at(double x, double y) =>
            MockPhysics.worldToFrame(Vec2(x, y), frame);
        controller
          ..setRulerLength(0.30)
          ..setRulerStart(at(0.5, 0.6))
          ..setRulerEnd(at(0.8, 0.6));
      } else {
        // A starting guess across the middle; the user drags it onto a ruler.
        controller
          ..setRulerStart(Vec2(frame.width * 0.3, frame.height * 0.35))
          ..setRulerEnd(Vec2(frame.width * 0.7, frame.height * 0.35));
      }
    }
    if (_demo && calibration.target == null) {
      final state = MockPhysics.sample(
        mode,
        ExperimentPreview.stillTime(mode),
        frameSize: frame,
      );
      if (state.pixel != null) controller.setTarget(state.pixel!);
    }
  }

  Future<void> _startExperiment() async {
    await context.push(Routes.experiment);
    if (!mounted) return;
    // A popped route can finish disposing after this Future completes. Stop
    // its session before setup takes the shared camera back.
    await ref.read(sessionProvider.notifier).stop();
    if (mounted && !_demo) await _startCamera();
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(experimentSettingsProvider.select((s) => s.mode));
    final stage = _Stage(
      demo: _demo,
      frameSize: _demo ? SessionController.demoFrameSize : _cameraFrame,
      error: _cameraError,
      onRetry: _startCamera,
      camera: _camera,
      mode: mode,
    );
    final surfaces = switch (_camera) {
      final SurfaceFinder f
          when !_demo && _cameraFrame != null && f.canFindSurfaces =>
        f,
      _ => null,
    };
    final steps = _Steps(
      demo: _demo,
      surfaces: surfaces,
      frameSize: _cameraFrame,
    );
    final start = FilledButton(
      onPressed: _startExperiment,
      child: const Text('Start experiment'),
    );

    return Scaffold(
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
          if (constraints.maxWidth >= 760) {
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
                    child: Center(child: stage),
                  ),
                ),
                SizedBox(
                  width: 380,
                  child: SafeArea(
                    left: false,
                    top: false,
                    child: Column(
                      children: [
                        Expanded(child: SingleChildScrollView(child: steps)),
                        Padding(
                          padding: const EdgeInsets.all(AppSpace.lg),
                          child: SizedBox(width: double.infinity, child: start),
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
    );
  }
}

/// The dark picture panel: demo scene, live camera, or why there is none.
class _Stage extends StatelessWidget {
  const _Stage({
    required this.demo,
    required this.frameSize,
    required this.error,
    required this.onRetry,
    required this.camera,
    required this.mode,
  });

  final bool demo;
  final FrameSize? frameSize;
  final String? error;
  final VoidCallback onRetry;
  final FrameSource camera;
  final ExperimentMode mode;

  @override
  Widget build(BuildContext context) {
    final frame = frameSize;
    final Widget content;
    if (error != null) {
      content = _CameraMessage(
        text: 'The camera did not start. $error',
        action: 'Try again',
        onAction: onRetry,
      );
    } else if (frame == null) {
      content = const _CameraMessage(text: 'Starting camera');
    } else {
      content = CalibrationStage(
        frameSize: frame,
        fit: demo ? DemoScene.fit : BoxFit.cover,
        background: demo
            ? DemoScene(mode: mode, frameSize: frame)
            : camera.buildPreview(context),
      );
    }

    return ClipRRect(
      borderRadius: AppRadii.panelAll,
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: ColoredBox(color: AppColors.graphiteDeep, child: content),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
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
                  side: const BorderSide(color: AppColors.ruleDark, width: 1.5),
                ),
                onPressed: onAction,
                child: Text(action!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The numbered steps. Numbered because they are a real sequence.
class _Steps extends ConsumerWidget {
  const _Steps({required this.demo, this.surfaces, this.frameSize});

  final bool demo;

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
    var number = 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.lg,
        AppSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (surfaces != null)
            _SurfaceStep(
              number: ++number,
              finder: surfaces,
              frameSize: frameSize!,
            ),
          _Step(
            number: ++number,
            title: 'Set the scale',
            body: demo
                ? 'The line is on a 30 cm mark. Drag its ends to try it.'
                : hasSurface
                ? 'Not needed while a surface is set. The surface measures '
                      'depth and tilt, so it is more accurate.'
                : 'Put a ruler in the picture, level with the experiment. '
                      'Drag both ends of the line onto it.',
            done: scale != null || hasSurface,
            trailing: _RulerLengthField(lengthM: calibration.rulerLengthM),
            footer: Text(
              scale == null
                  ? 'Place both ends to set the scale'
                  : '${scale.round()} px per metre',
              style: AppType.readoutSmall.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          _Step(
            number: ++number,
            title: 'Mark the object',
            body: calibration.target == null
                ? 'Tap the object in the picture so the tracker knows which '
                      'one to follow.'
                : 'Marked. Tap somewhere else to move it.',
            done: calibration.target != null,
            trailing: calibration.target == null
                ? null
                : TextButton(
                    onPressed: ref
                        .read(calibrationProvider.notifier)
                        .clearTarget,
                    child: const Text('Clear'),
                  ),
          ),
          _Step(
            number: ++number,
            title: 'Enter its mass',
            body: 'Forces and energy scale with mass. Weigh it if you can.',
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

/// Finds the board or table the object moves on with an ARKit raycast
/// through the middle of the picture. Positions are then measured on that
/// surface in 3D, so the phone may move during the experiment.
class _SurfaceStep extends ConsumerStatefulWidget {
  const _SurfaceStep({
    required this.number,
    required this.finder,
    required this.frameSize,
  });

  final int number;
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
    required this.title,
    required this.body,
    required this.done,
    this.trailing,
    this.footer,
    this.last = false,
  });

  final int number;
  final String title;
  final String body;
  final bool done;
  final Widget? trailing;
  final Widget? footer;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: 'Step $number of 3${done ? ', done' : ''}',
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The number, with a rule down to the next step.
            Column(
              children: [
                AnimatedContainer(
                  duration: AppMotion.quick,
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done ? scheme.primary : Colors.transparent,
                    border: Border.all(color: scheme.primary, width: 1.5),
                  ),
                  child: done
                      ? Icon(AppIcons.check, size: 15, color: scheme.surface)
                      : Text(
                          '$number',
                          style: AppType.label.copyWith(color: scheme.primary),
                        ),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 1.5,
                      margin: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                      color: scheme.outline,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(bottom: last ? 0 : AppSpace.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  title,
                                  style: AppType.bodyStrong.copyWith(
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                body,
                                style: AppType.caption.copyWith(
                                  fontSize: 13,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (trailing != null) ...[
                          const SizedBox(width: AppSpace.md),
                          trailing!,
                        ],
                      ],
                    ),
                    if (footer != null) ...[
                      const SizedBox(height: AppSpace.sm),
                      footer!,
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
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
    // Changed elsewhere (demo defaults): show it, unless the user is typing.
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
      width: 104,
      child: TextField(
        controller: _text,
        onChanged: _onChanged,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
        ],
        textAlign: TextAlign.end,
        style: AppType.readoutSmall.copyWith(fontSize: 17),
        decoration: InputDecoration(
          isDense: true,
          labelText: 'Length',
          suffixText: 'cm',
          errorText: _invalid ? '1 to 500' : null,
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
          shape: StadiumBorder(side: BorderSide(color: scheme.outline)),
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
              SizedBox(
                width: 64,
                child: Text(
                  MassSteps.format(massKg),
                  textAlign: TextAlign.center,
                  style: AppType.readoutSmall.copyWith(fontSize: 16),
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
