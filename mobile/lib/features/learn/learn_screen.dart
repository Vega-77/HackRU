import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/routing/router.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../models/experiment_mode.dart';
import '../../state/experiment_settings.dart';
import '../home/widgets/experiment_preview.dart';
import '../home/widgets/laboratory_diagram.dart';
import '../home/widgets/preview_physics.dart';
import 'formula.dart';
import 'lesson.dart';

/// The theory behind one experiment: why it matters, how to read each
/// arrow, every force involved, the equations, and how to run it well.
///
/// Reads without the camera, so it works before any setup.
class LearnScreen extends ConsumerWidget {
  const LearnScreen({super.key, required this.lessonId});

  final String lessonId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lesson = Lesson.byId(lessonId);
    final mode = lesson.mode;
    final next = lesson.next;
    return Theme(
      data: AppTheme.dark(),
      child: Scaffold(
        backgroundColor: AppColors.graphite,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gutter = constraints.maxWidth >= 960
                  ? AppSpace.xxxl
                  : AppSpace.lg;
              return SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        gutter,
                        AppSpace.lg,
                        gutter,
                        AppSpace.xxxl,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Header(lesson),
                          const SizedBox(height: AppSpace.xl),
                          _LessonPicker(current: lesson),
                          const SizedBox(height: AppSpace.xl),
                          _DiagramPanel(
                            mode: mode ?? ExperimentMode.ramp,
                            startWithForces: mode == null,
                          ),
                          _Section(
                            title: 'Why we do it',
                            child: _Paragraph(lesson.why),
                          ),
                          _Section(
                            title: 'The idea',
                            child: _Stack([
                              for (final p in lesson.idea) _Paragraph(p),
                            ]),
                          ),
                          _Section(
                            title: 'Reading the arrows',
                            child: _Stack([
                              for (final a in lesson.arrows) _ArrowRow(a),
                            ]),
                          ),
                          _Section(
                            title: 'The forces',
                            child: _Stack([
                              for (final f in lesson.forces) _ForceRow(f),
                            ]),
                          ),
                          _Section(
                            title: 'The equations',
                            child: _Stack([
                              for (final e in lesson.equations)
                                _EquationCard(e),
                            ]),
                          ),
                          if (lesson.equipment.isNotEmpty)
                            _Section(
                              title: 'What you need',
                              child: _Stack([
                                for (final item in lesson.equipment)
                                  _Bullet(item, icon: AppIcons.check),
                              ]),
                            ),
                          if (lesson.steps.isNotEmpty)
                            _Section(
                              title: 'Running it',
                              child: _Stack([
                                for (final (i, step) in lesson.steps.indexed)
                                  _Step(i + 1, step),
                              ]),
                            ),
                          _Section(
                            title: mode == null
                                ? 'Where you will see it'
                                : 'What to expect',
                            child: _Stack([
                              for (final item in lesson.expect)
                                _Bullet(item, icon: AppIcons.caretRight),
                            ]),
                          ),
                          _Section(
                            title: 'Common mistakes',
                            child: _Stack([
                              for (final m in lesson.mistakes) _MistakeRow(m),
                            ]),
                          ),
                          const SizedBox(height: AppSpace.xxl),
                          if (mode != null) ...[
                            _PrimaryButton(
                              label: 'Set up ${mode.label.toLowerCase()}',
                              onPressed: () {
                                ref
                                    .read(experimentSettingsProvider.notifier)
                                    .setMode(mode);
                                context.push(Routes.calibrate);
                              },
                            ),
                            const SizedBox(height: AppSpace.md),
                          ],
                          if (next != null)
                            _SecondaryButton(
                              label: 'Next: ${next.title.toLowerCase()}',
                              onPressed: () =>
                                  context.replace(Routes.lesson(next.id)),
                            )
                          else
                            _SecondaryButton(
                              label: 'Back to the experiments',
                              onPressed: () => context.go(Routes.home),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.lesson);
  final Lesson lesson;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          IconButton(
            style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
            tooltip: 'Back',
            onPressed: () =>
                context.canPop() ? context.pop() : context.go(Routes.home),
            icon: const Icon(AppIcons.arrowLeft, size: 22),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              'Learn the physics',
              style: AppType.label.copyWith(color: AppColors.inkMutedDark),
            ),
          ),
          Text(
            '${lesson.number} / ${(Lesson.all.length - 1).toString().padLeft(2, '0')}',
            style: AppType.readoutSmall.copyWith(color: AppColors.inkMutedDark),
          ),
        ],
      ),
      const SizedBox(height: AppSpace.xl),
      Text(
        lesson.title,
        style: AppType.display.copyWith(color: AppColors.vellum),
      ),
      const SizedBox(height: AppSpace.md),
      Text(
        lesson.summary,
        style: AppType.body.copyWith(
          color: AppColors.inkMutedDark,
          fontSize: 16,
        ),
      ),
    ],
  );
}

/// Jumps between lessons without stacking them up behind the back button.
class _LessonPicker extends StatelessWidget {
  const _LessonPicker({required this.current});
  final Lesson current;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final lesson in Lesson.all)
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.sm),
            child: Semantics(
              selected: lesson == current,
              child: TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  foregroundColor: lesson == current
                      ? AppColors.vellum
                      : AppColors.inkMutedDark,
                  backgroundColor: lesson == current
                      ? AppColors.ruleDark
                      : Colors.transparent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                    vertical: AppSpace.md,
                  ),
                  shape: const RoundedRectangleBorder(
                    borderRadius: AppRadii.controlAll,
                  ),
                ),
                onPressed: lesson == current
                    ? null
                    : () => context.replace(Routes.lesson(lesson.id)),
                child: Text(lesson.title),
              ),
            ),
          ),
      ],
    ),
  );
}

/// The home screen's diagram, with motion and force arrows to compare.
class _DiagramPanel extends StatefulWidget {
  const _DiagramPanel({required this.mode, required this.startWithForces});
  final ExperimentMode mode;
  final bool startWithForces;

  @override
  State<_DiagramPanel> createState() => _DiagramPanelState();
}

class _DiagramPanelState extends State<_DiagramPanel>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late bool _forces = widget.startWithForces;
  late double _time = ExperimentPreview.stillTime(widget.mode);
  Duration _last = Duration.zero;

  void _tick(Duration elapsed) {
    final dt = elapsed - _last;
    _last = elapsed;
    setState(() => _time += dt.inMicroseconds / 1e6);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (!reduced && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (reduced && _ticker.isActive) {
      _ticker.stop();
      _time = ExperimentPreview.stillTime(widget.mode);
    }
  }

  @override
  void didUpdateWidget(_DiagramPanel old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) {
      _time = ExperimentPreview.stillTime(widget.mode);
      _forces = widget.startWithForces;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sample = PreviewPhysics.sample(widget.mode, _time);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.graphiteDeep,
            border: Border.all(color: AppColors.ruleDark),
            borderRadius: AppRadii.panelAll,
          ),
          clipBehavior: Clip.antiAlias,
          child: Semantics(
            label:
                '${widget.mode.label} diagram with '
                '${_forces ? 'force' : 'motion'} arrows.',
            child: ExcludeSemantics(
              child: LayoutBuilder(
                builder: (context, constraints) => SizedBox(
                  height: (constraints.maxWidth / 1.35).clamp(240, 400),
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: LaboratoryDiagram(
                        widget.mode,
                        sample,
                        forces: _forces,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.md),
        Wrap(
          spacing: AppSpace.md,
          runSpacing: AppSpace.sm,
          children: [
            _Toggle(
              label: 'Motion vectors',
              selected: !_forces,
              onPressed: () => setState(() => _forces = false),
            ),
            _Toggle(
              label: 'Force vectors',
              selected: _forces,
              onPressed: () => setState(() => _forces = true),
            ),
          ],
        ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.selected,
    required this.onPressed,
  });
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: selected ? AppColors.vellum : AppColors.inkMutedDark,
        backgroundColor: selected ? AppColors.ruleDark : Colors.transparent,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.md,
        ),
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.controlAll),
      ),
      onPressed: onPressed,
      child: Text(label),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: AppSpace.xxl),
    padding: const EdgeInsets.only(top: AppSpace.xl),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: AppColors.ruleDark)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: AppType.title.copyWith(color: AppColors.vellum),
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        child,
      ],
    ),
  );
}

/// A column of rows with even gaps between them.
class _Stack extends StatelessWidget {
  const _Stack(this.children);
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final (i, child) in children.indexed) ...[
        if (i > 0) const SizedBox(height: AppSpace.lg),
        child,
      ],
    ],
  );
}

class _Paragraph extends StatelessWidget {
  const _Paragraph(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: AppType.body.copyWith(color: AppColors.vellum));
}

Color _arrowColor(VectorKind kind) => switch (kind) {
  VectorKind.velocity => AppColors.velocity,
  VectorKind.acceleration => AppColors.acceleration,
  VectorKind.netForce => AppColors.forceNet,
  VectorKind.component => AppColors.forceComponent,
};

class _ArrowRow extends StatelessWidget {
  const _ArrowRow(this.note);
  final ArrowNote note;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: AppSpace.sm),
        child: Icon(
          AppIcons.arrowRight,
          size: AppSpace.xl,
          color: _arrowColor(note.kind),
        ),
      ),
      const SizedBox(width: AppSpace.md),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              note.name,
              style: AppType.bodyStrong.copyWith(color: AppColors.vellum),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              note.text,
              style: AppType.body.copyWith(color: AppColors.inkMutedDark),
            ),
          ],
        ),
      ),
    ],
  );
}

class _ForceRow extends StatelessWidget {
  const _ForceRow(this.note);
  final ForceNote note;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(AppSpace.lg),
    decoration: BoxDecoration(
      color: AppColors.graphiteRaised,
      border: Border.all(color: AppColors.ruleDark),
      borderRadius: AppRadii.controlAll,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpace.md,
          runSpacing: AppSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              note.name,
              style: AppType.bodyStrong.copyWith(color: AppColors.vellum),
            ),
            Formula(
              note.formula,
              style: AppType.variable.copyWith(
                color: AppColors.instrumentAccentDark,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          note.text,
          style: AppType.body.copyWith(color: AppColors.inkMutedDark),
        ),
      ],
    ),
  );
}

class _EquationCard extends StatelessWidget {
  const _EquationCard(this.equation);
  final LessonEquation equation;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(AppSpace.lg),
    decoration: BoxDecoration(
      color: AppColors.graphiteDeep,
      border: Border.all(color: AppColors.ruleDark),
      borderRadius: AppRadii.controlAll,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Formula(
          equation.formula,
          style: AppType.title.copyWith(color: AppColors.vellum, fontSize: 22),
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          equation.meaning,
          style: AppType.body.copyWith(color: AppColors.inkMutedDark),
        ),
        for (final s in equation.symbols) ...[
          const SizedBox(height: AppSpace.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: AppSpace.xxxl + AppSpace.lg,
                child: Formula(
                  s.symbol,
                  style: AppType.variable.copyWith(
                    color: AppColors.instrumentAccentDark,
                    fontSize: 15,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  s.meaning,
                  style: AppType.caption.copyWith(
                    color: AppColors.inkMutedDark,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text, {required this.icon});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: AppSpace.xs),
        child: Icon(icon, size: AppSpace.lg, color: AppColors.inkMutedDark),
      ),
      const SizedBox(width: AppSpace.md),
      Expanded(
        child: Text(
          text,
          style: AppType.body.copyWith(color: AppColors.vellum),
        ),
      ),
    ],
  );
}

class _Step extends StatelessWidget {
  const _Step(this.number, this.text);
  final int number;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: AppSpace.xl,
        child: Text(
          '$number',
          style: AppType.readoutSmall.copyWith(
            color: AppColors.instrumentAccentDark,
            height: 1.6,
          ),
        ),
      ),
      const SizedBox(width: AppSpace.md),
      Expanded(
        child: Text(
          text,
          style: AppType.body.copyWith(color: AppColors.vellum),
        ),
      ),
    ],
  );
}

class _MistakeRow extends StatelessWidget {
  const _MistakeRow(this.mistake);
  final Mistake mistake;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.only(top: AppSpace.xs),
        child: Icon(
          AppIcons.warning,
          size: AppSpace.lg,
          color: AppColors.instrumentAccentDark,
        ),
      ),
      const SizedBox(width: AppSpace.md),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              mistake.mistake,
              style: AppType.bodyStrong.copyWith(color: AppColors.vellum),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              mistake.fix,
              style: AppType.body.copyWith(color: AppColors.inkMutedDark),
            ),
          ],
        ),
      ),
    ],
  );
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.instrumentAccentDark,
        foregroundColor: AppColors.graphiteDeep,
        padding: const EdgeInsets.symmetric(
          vertical: AppSpace.xl - AppSpace.xs,
        ),
        textStyle: AppType.bodyStrong,
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.controlAll),
      ),
      onPressed: onPressed,
      child: Text(label),
    ),
  );
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.vellum,
        side: const BorderSide(color: AppColors.ruleDark),
        padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
        textStyle: AppType.bodyStrong,
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.controlAll),
      ),
      onPressed: onPressed,
      child: Text(label),
    ),
  );
}
