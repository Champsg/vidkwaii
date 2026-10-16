import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_strings.dart';
import '../../core/config/ad_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_logo.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/section_header.dart';
import '../../data/models/download_task.dart';
import '../../core/utils/url_utils.dart';
import '../../logic/extract_controller.dart';
import '../../logic/providers.dart';
import '../widgets/clipboard_banner.dart';
import '../widgets/download_tile.dart';
import '../widgets/extract_result_card.dart';
import '../widgets/url_input_bar.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  Future<void> _extract(String url) async {
    FocusScope.of(context).unfocus();
    if (!UrlUtils.isInstagramUrl(url)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.instagramOnly)),
      );
      return;
    }
    await ref.read(extractControllerProvider).extract(url);
  }

  @override
  Widget build(BuildContext context) {
    final extract = ref.watch(extractControllerProvider);
    final downloads = ref.watch(downloadControllerProvider);
    final active = downloads.activeTasks;
    final failed = downloads.tasks
        .where((task) => task.status == DownloadStatus.failed)
        .toList();
    final completed = downloads.tasks
        .where((task) => task.status == DownloadStatus.completed)
        .toList();

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 110),
          children: [
            // ─── Welcome header ───
            _WelcomeHeader(),
            const ClipboardBanner(),
            const SizedBox(height: 20),

            // ─── URL input ───
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: UrlInputBar(
                onSubmit: _extract,
                loading: extract.state.isLoading,
              ),
            ),

            // ─── Extract results ───
            _buildExtractSection(extract),

            // ─── Active downloads ───
            if (active.isNotEmpty) ...[
              const SizedBox(height: 24),
              const SectionHeader(title: 'Active Downloads'),
              for (final task in active)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: DownloadTile(task: task),
                ),
            ],

            // ─── Failed downloads ───
            if (failed.isNotEmpty) ...[
              const SizedBox(height: 18),
              const SectionHeader(title: 'Failed Downloads'),
              for (final task in failed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: DownloadTile(task: task),
                ),
            ],

            // ─── Quick Links ───
            const SizedBox(height: 28),
            const SectionHeader(title: 'Quick Links'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  _QuickLinkTile(
                    icon: Icons.info_outline_rounded,
                    title: 'How to Download',
                    onTap: () => _showHowToDownload(context),
                  ),
                  const SizedBox(height: 8),
                  _QuickLinkTile(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: 'FAQ',
                    onTap: () => _showFaq(context),
                  ),
                ],
              ),
            ),

            // ─── Recent downloads ───
            const SizedBox(height: 28),
            const SectionHeader(title: 'Recent Downloads'),
            if (completed.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: EmptyState(
                  icon: Icons.download_done_rounded,
                  title: 'No downloads yet',
                  subtitle:
                      'Paste a link above or use the Browser to grab media.',
                  showMascot: false,
                ),
              )
            else
              for (final task in completed.take(5))
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: DownloadTile(task: task),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildExtractSection(ExtractController extract) {
    return extract.state.when(
      data: (result) => result == null
          ? const SizedBox.shrink()
          : ExtractResultCard(result: result),
      loading: () => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.border.withValues(alpha: 0.4),
            ),
          ),
          child: const Column(
            children: [
              SizedBox(height: 20),
              CircularProgressIndicator(),
              SizedBox(height: 14),
              Text(
                'Resolving & extracting metadata...',
                style: TextStyle(color: AppColors.textSecondary),
              ),
              SizedBox(height: 20),
            ],
          ),
        ),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.danger.withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: AppColors.danger,
                size: 32,
              ),
              const SizedBox(height: 10),
              const Text(
                'Extraction failed',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: extract.lastUrl == null
                    ? null
                    : () => extract.extract(extract.lastUrl!),
                child: const Text(AppStrings.retry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Clean welcome header with app name and mascot avatar
class _WelcomeHeader extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'VidKwaii',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                    height: 1.2,
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onLongPress: AdConfig.diagnosticsToUi
                ? () => _showAdDiagnostics(context, ref)
                : null,
            child: const AppLogo(compact: true),
          ),
        ],
      ),
    );
  }
}

/// Quick link list tile
class _QuickLinkTile extends StatelessWidget {
  const _QuickLinkTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: AppColors.textFaint, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textFaint,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Bottom sheets ──────────────────────────────────────────────────────

void _showHowToDownload(BuildContext context) {
  showModalBottomSheet(
    context: context,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'How to Download',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            _stepTile('1', 'Copy the Instagram video or reel link'),
            _stepTile('2', 'Paste the link in the input field above'),
            _stepTile('3', 'Tap "Extract" to fetch the video details'),
            _stepTile('4', 'Choose your format and tap Download'),
            _stepTile('5', 'Find your video in the Library tab'),
          ],
        ),
      ),
    ),
  );
}

void _showFaq(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'FAQ',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            SizedBox(height: 16),
            _FaqItem(
              question: 'Is this app free?',
              answer: 'Yes, VidKwaii is completely free to use.',
            ),
            _FaqItem(
              question: 'Which platforms are supported?',
              answer: 'Currently we support Instagram videos, reels, and stories.',
            ),
            _FaqItem(
              question: 'Where are downloaded videos saved?',
              answer:
                  'Videos are saved to your device storage and can be found in the Library tab.',
            ),
            _FaqItem(
              question: 'Why do I see ads?',
              answer:
                  'Ads help us keep the app free. You can watch a short video ad before each download.',
            ),
            _FaqItem(
              question: 'Can I download private videos?',
              answer:
                  'No, you can only download videos from public accounts or content you have permission to save.',
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _stepTile(String number, String text) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            number,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.primary,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}

class _FaqItem extends StatelessWidget {
  const _FaqItem({required this.question, required this.answer});

  final String question;
  final String answer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            question,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            answer,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows the current ad SDK state.
Future<void> _showAdDiagnostics(BuildContext context, WidgetRef ref) {
  final summary = ref.read(adServiceProvider).diagnosticsSummary();
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Ad diagnostics'),
      content: Text(summary, style: const TextStyle(fontSize: 13)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
