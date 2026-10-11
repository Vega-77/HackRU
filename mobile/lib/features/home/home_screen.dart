import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/routing/router.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/tokens.dart';
import '../../models/experiment_mode.dart';
import '../../state/experiment_settings.dart';
import 'widgets/experiment_preview.dart';

//// Pick an experiment. The selected one plays live at the top, drawn by
/// the same overlay the experiment screen uses.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const _maxWidth = 560.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(experimentSettingsProvider.select((s) => s.mode));

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
                    AppSpace.sm,
                    AppSpace.sm,
                    AppSpace.sm,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            header: true,
                            child: Text(
                              'HandsOn Physics',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => context.push(Routes.settings),
                          tooltip: 'Settings',
                          icon: const Icon(AppIcons.gear),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                  sliver: SliverToBoxAdapter(child: _Preview(mode: mode)),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.xl,
                    AppSpace.xl,
                    AppSpace.xl,
                    AppSpace.sm,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Semantics(
                      header: true,
                      child: Text(
                        'Choose an experiment',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
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

/// The selected experiment running on the instrument display, with the
/// colour key underneath (inside, it would hide the lowest arrows).
class _Preview extends StatelessWidget {
  const _Preview({required this.mode});

  final ExperimentMode mode;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The edge keeps the display apart from a dark page.
        DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: AppRadii.panelAll,
            border: Border.all(color: Theme.of(context).colorScheme.outline),
          ),
          child: ClipRRect(
            borderRadius: AppRadii.panelAll,
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: ColoredBox(
                color: AppColors.graphiteDeep,
                child: AnimatedSwitcher(
                  duration: AppMotion.slow,
                  switchInCurve: AppMotion.ease,
                  child: ExperimentPreview(key: ValueKey(mode), mode: mode),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        const _Legend(),
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

/// One experiment in the list, picked like a radio button.
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
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.sm,
          vertical: 2,
        ),
        child: AnimatedContainer(
          duration: AppMotion.quick,
          curve: AppMotion.ease,
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.07)
                : Colors.transparent,
            borderRadius: AppRadii.controlAll,
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
            ),
          ),
          // Ink paints on the nearest Material: give it one above the
          // tinted box, not the page's underneath it.
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: AppRadii.controlAll,
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: _RadioMark(selected: selected),
                    ),
                    const SizedBox(width: AppSpace.md),
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

class _RadioMark extends StatelessWidget {
  const _RadioMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: AppMotion.quick,
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? scheme.primary : scheme.outline,
          width: 1.5,
        ),
      ),
      child: AnimatedScale(
        duration: AppMotion.quick,
        scale: selected ? 1 : 0,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: scheme.primary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

// The primary action, pinned to the bottom, plus which backend measures it.
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
