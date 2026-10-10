import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/routing/router.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../models/experiment_mode.dart';
import '../../state/experiment_settings.dart';
import 'widgets/experiment_preview.dart';

/// Pick an experiment. The selected one plays live in the panel at the top,
/// drawn by the same overlay the experiment screen uses.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const _maxWidth = 560.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(experimentSettingsProvider.select((s) => s.mode));
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.xl,
                    AppSpace.lg,
                    AppSpace.md,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'HANDSON PHYSICS',
                                style: AppType.label.copyWith(
                                  color: scheme.primary,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: AppSpace.xs),
                              Semantics(
                                header: true,
                                child: Text(
                                  'Motion lab',
                                  style: Theme.of(context)
                                      .textTheme
                                      .displaySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: scheme.outline),
                            borderRadius: AppRadii.controlAll,
                          ),
                          child: IconButton(
                            onPressed: () => context.push(Routes.settings),
                            tooltip: 'Settings',
                            iconSize: 22,
                            padding: const EdgeInsets.all(AppSpace.md),
                            icon: const Icon(AppIcons.gear),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.xl,
                    AppSpace.md,
                    AppSpace.xl,
                    AppSpace.xl,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Text(
                      'Follow position, velocity and force as an experiment moves.',
                      style: AppType.body.copyWith(
                        fontSize: 17,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.xl,
                    AppSpace.lg,
                    AppSpace.xl,
                    AppSpace.sm,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Semantics(
                      header: true,
                      child: Text(
                        'Choose an experiment',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                  sliver: SliverToBoxAdapter(child: _Hero(mode: mode)),
                ),
                SliverList.list(
                  children: [
                    for (final m in _order)
                      _ModeRow(
                        mode: m,
                        selected: m == mode,
                        onTap: () => ref
                            .read(experimentSettingsProvider.notifier)
                            .setMode(m),
                      ),
                  ],
                ),
                const SliverToBoxAdapter(child: SizedBox(height: AppSpace.lg)),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _StartBar(mode: mode),
    );
  }

  /// Roughly simplest first.
  static const _order = [
    ExperimentMode.ramp,
    ExperimentMode.freeFall,
    ExperimentMode.pendulum,
    ExperimentMode.collision,
  ];
}

/// One line on what each experiment shows. Plain language for students.
String _blurb(ExperimentMode mode) => switch (mode) {
  ExperimentMode.ramp =>
    'A block slides down a slope. Gravity splits into a part along the '
        'ramp and a part into it.',
  ExperimentMode.freeFall =>
    'A ball thrown across the table. Velocity keeps changing, '
        'acceleration stays at g.',
  ExperimentMode.pendulum =>
    'A bob on a string. Energy swaps between kinetic and potential '
        'on every swing.',
  ExperimentMode.collision =>
    'A cart hits a heavier one. Momentum carries over and the impact '
        'force spikes.',
};

/// The selected experiment, running live on the instrument display, with
/// the colour key underneath (inside, it would hide the lowest arrows).
class _Hero extends StatelessWidget {
  const _Hero({required this.mode});

  final ExperimentMode mode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final index = HomeScreen._order.indexOf(mode) + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            border: Border.all(color: scheme.outline),
            borderRadius: AppRadii.panelAll,
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.xs,
                    AppSpace.xs,
                    AppSpace.xs,
                    AppSpace.md,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Text('MODEL PREVIEW', style: AppType.label),
                      const Spacer(),
                      Text(
                        '${index.toString().padLeft(2, '0')}  /  04',
                        style: AppType.readoutSmall.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(10)),
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: ColoredBox(
                      color: AppColors.graphiteDeep,
                      child: AnimatedSwitcher(
                        duration: AppMotion.slow,
                        switchInCurve: AppMotion.ease,
                        child: ExperimentPreview(
                          key: ValueKey(mode),
                          mode: mode,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.md),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mode.label,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        _blurb(mode),
                        style: AppType.body.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpace.md),
                      const _Legend(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// What the arrow colours mean. The same colours mean the same thing on
/// every screen.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget item(Color color, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 14, height: 3, color: color),
        const SizedBox(width: 6),
        Text(text, style: AppType.caption.copyWith(color: muted)),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
      child: Wrap(
        spacing: AppSpace.lg,
        runSpacing: AppSpace.xs,
        children: [
          item(AppColors.velocity, 'Velocity'),
          item(AppColors.acceleration, 'Acceleration'),
          item(AppColors.forceNet, 'Net force'),
          item(AppColors.forceComponent, 'Forces'),
        ],
      ),
    );
  }
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final ExperimentMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      inMutuallyExclusiveGroup: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        child: AnimatedContainer(
          duration: AppMotion.quick,
          curve: AppMotion.ease,
          padding: const EdgeInsets.all(AppSpace.sm),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.07)
                : Colors.transparent,
            borderRadius: AppRadii.controlAll,
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: AppRadii.controlAll,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: AppMotion.quick,
                  width: 88,
                  height: 66,
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(Radius.circular(10)),
                    border: Border.all(
                      color: selected ? scheme.primary : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  padding: const EdgeInsets.all(2),
                  child: ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                    child: ExperimentPreview(
                      mode: mode,
                      animate: false,
                      showLabels: false,
                      showGrid: false,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mode.label,
                        style: AppType.bodyStrong.copyWith(fontSize: 16),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _blurb(mode),
                        style: AppType.caption.copyWith(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                SizedBox(
                  width: 24,
                  child: AnimatedOpacity(
                    duration: AppMotion.quick,
                    opacity: selected ? 1 : 0,
                    child: Icon(AppIcons.checkCircle, color: scheme.primary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The primary action, pinned to the bottom, plus which backend measures it.
class _StartBar extends ConsumerWidget {
  const _StartBar({required this.mode});

  final ExperimentMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(
      experimentSettingsProvider.select((s) => s.backendUrl),
    );
    final scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outline)),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: HomeScreen._maxWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.md,
                AppSpace.lg,
                AppSpace.sm,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    onPressed: () => context.push(Routes.calibrate),
                    child: Text('Set up ${mode.label.toLowerCase()}'),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  TextButton.icon(
                    onPressed: () => context.push(Routes.settings),
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.onSurfaceVariant,
                      textStyle: AppType.caption.copyWith(fontSize: 13),
                    ),
                    icon: const Icon(AppIcons.broadcast, size: 16),
                    label: Text(
                      'Live from ${Uri.tryParse(url)?.authority ?? url}',
                      overflow: TextOverflow.ellipsis,
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
