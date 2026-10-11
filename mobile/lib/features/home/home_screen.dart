import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/routing/router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../state/experiment_settings.dart';
import 'widgets/investigation.dart';
import 'widgets/investigation_index.dart';
import 'widgets/laboratory_exhibit.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(experimentSettingsProvider);
    final item = Investigation.forMode(settings.mode);
    return Theme(
      data: AppTheme.dark(),
      child: Scaffold(
        backgroundColor: AppColors.graphite,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final desktop = constraints.maxWidth >= 960;
              final gutter = desktop ? 48.0 : 20.0;
              final introduction = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 3,
                        height: 36,
                        color: AppColors.instrumentAccentDark,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'HandsOn\nPhysics',
                          style: AppType.title.copyWith(
                            fontSize: 19,
                            height: 1,
                            color: AppColors.vellum,
                          ),
                        ),
                      ),
                      IconButton(
                        style: IconButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        tooltip: 'Settings',
                        onPressed: () => context.push(Routes.settings),
                        icon: const Icon(Icons.tune, size: 22),
                      ),
                    ],
                  ),
                  SizedBox(height: desktop ? 52 : 32),
                  Text(
                    'The kinetic laboratory',
                    style: AppType.label.copyWith(
                      color: AppColors.inkMutedDark,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Make motion\nvisible.',
                    style: AppType.display.copyWith(
                      fontSize: desktop
                          ? ((constraints.maxWidth - 160) * 5 / 12 / 8).clamp(
                              40,
                              62,
                            )
                          : 42,
                      color: AppColors.vellum,
                      height: 1.04,
                    ),
                  ),
                  const SizedBox(height: 20),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Text(
                      'A real object. Your camera. The physics hidden in every movement.',
                      style: AppType.body.copyWith(
                        color: AppColors.inkMutedDark,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  SizedBox(height: desktop ? 44 : 28),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Choose an experiment',
                          style: AppType.label.copyWith(
                            color: AppColors.vellum,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${item.number} / 04',
                        style: AppType.readoutSmall.copyWith(
                          color: AppColors.inkMutedDark,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  InvestigationIndex(
                    selected: settings.mode,
                    onSelect: (mode) => ref
                        .read(experimentSettingsProvider.notifier)
                        .setMode(mode),
                  ),
                ],
              );
              final exhibit = LaboratoryExhibit(
                mode: settings.mode,
                onStart: () => context.push(Routes.calibrate),
              );
              return SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1600),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        gutter,
                        desktop ? 36 : 24,
                        gutter,
                        24,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (desktop)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(flex: 5, child: introduction),
                                const SizedBox(width: 64),
                                Expanded(
                                  flex: 7,
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 10),
                                    child: exhibit,
                                  ),
                                ),
                              ],
                            )
                          else ...[
                            introduction,
                            const SizedBox(height: 32),
                            exhibit,
                          ],
                          const SizedBox(height: 36),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.only(top: 20),
                            decoration: const BoxDecoration(
                              border: Border(
                                top: BorderSide(color: AppColors.ruleDark),
                              ),
                            ),
                            child: Wrap(
                              spacing: 40,
                              runSpacing: 20,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _Metadata(
                                  label: 'Selected concepts',
                                  value: item.concepts,
                                ),
                                const _Metadata(
                                  label: 'Method',
                                  value: 'Camera tracking / SI measurements',
                                ),
                                TextButton(
                                  onPressed: () =>
                                      context.push(Routes.settings),
                                  style: TextButton.styleFrom(
                                    foregroundColor: AppColors.inkMutedDark,
                                  ),
                                  child: Text(
                                    'Backend: ${Uri.tryParse(settings.backendUrl)?.authority ?? settings.backendUrl}',
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
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Metadata extends StatelessWidget {
  const _Metadata({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: AppType.caption.copyWith(color: AppColors.inkMutedDark),
      ),
      const SizedBox(height: 6),
      Text(value, style: AppType.label.copyWith(color: AppColors.vellum)),
    ],
  );
}
