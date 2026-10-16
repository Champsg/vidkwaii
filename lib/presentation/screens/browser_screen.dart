import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/url_utils.dart';
import '../../data/models/download_task.dart';
import '../../data/services/web_sniffer.dart';
import '../../core/constants/app_strings.dart';
import '../../logic/providers.dart';
import '../widgets/floating_download_button.dart';
import '../widgets/format_picker_sheet.dart';

class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  late final WebViewController _webController;
  final TextEditingController _urlBarController = TextEditingController();
  int _progress = 0;
  String? _lastError;
  bool _urlBarFocused = false;

  @override
  void initState() {
    super.initState();
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppColors.background)
      ..addJavaScriptChannel(
        WebSniffer.channelName,
        onMessageReceived: (message) => ref
            .read(browserControllerProvider)
            .handleJsMessage(message.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            final scheme = uri?.scheme.toLowerCase() ?? '';
            // Keep everything inside this app's WebView. Only http/https may
            // navigate here; anything else (instagram://, intent://,
            // market://, etc.) is denied so Android never hands it to the
            // default browser or another app.
            return (scheme == 'http' || scheme == 'https')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageStarted: (url) {
            ref.read(browserControllerProvider).setUrl(url);
            setState(() {
              _lastError = null;
              if (!_urlBarFocused) _urlBarController.text = url;
            });
          },
          onProgress: (progress) => setState(() => _progress = progress),
          onPageFinished: (_) {
            setState(() => _progress = 100);
            _injectSniffer();
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? false) {
              setState(() => _lastError = error.description);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('https://www.instagram.com'));
  }

  @override
  void dispose() {
    _urlBarController.dispose();
    super.dispose();
  }

  Future<void> _injectSniffer() async {
    try {
      await _webController.runJavaScript(WebSniffer.injectionScript);
      ref.read(browserControllerProvider).setSnifferActive(true);
    } catch (_) {
      // Page may still be navigating; the sniffer is re-injected per page.
    }
  }

  Future<void> _goBack() async {
    try {
      await _webController.goBack();
    } catch (_) {}
  }

  Future<void> _goForward() async {
    try {
      await _webController.goForward();
    } catch (_) {}
  }

  Future<void> _reload() async {
    await _webController.reload();
  }

  void _navigateToUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      // Treat as search or add https
      if (url.contains('.') && !url.contains(' ')) {
        url = 'https://$url';
      } else {
        url = 'https://www.google.com/search?q=${Uri.encodeQueryComponent(url)}';
      }
    }
    _webController.loadRequest(Uri.parse(url));
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final browser = ref.watch(browserControllerProvider);
    final mediaCount = browser.media.length;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // ──── Top bar with URL + controls ────
            Container(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.92),
                border: Border(
                  bottom: BorderSide(
                    color: AppColors.border.withValues(alpha: 0.25),
                    width: 0.5,
                  ),
                ),
              ),
              child: Column(
                children: [
                  // URL input bar
                  Row(
                    children: [
                      // Back / Forward
                      _NavIconButton(
                        icon: Icons.arrow_back_ios_rounded,
                        onTap: _goBack,
                        size: 18,
                      ),
                      _NavIconButton(
                        icon: Icons.arrow_forward_ios_rounded,
                        onTap: _goForward,
                        size: 18,
                      ),
                      const SizedBox(width: 4),
                      // Status Icon (Shield/Language) separated
                      Icon(
                        browser.snifferActive
                            ? Icons.shield_rounded
                            : Icons.language_rounded,
                        size: 18,
                        color: browser.snifferActive
                            ? AppColors.success
                            : AppColors.textFaint,
                      ),
                      const SizedBox(width: 8),
                      // URL field
                      Expanded(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.surfaceHigher,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _urlBarFocused
                                  ? AppColors.primary.withValues(alpha: 0.6)
                                  : AppColors.border.withValues(alpha: 0.3),
                              width: 1,
                            ),
                          ),
                          child: Focus(
                            onFocusChange: (f) => setState(() => _urlBarFocused = f),
                            child: TextField(
                              controller: _urlBarController,
                              textInputAction: TextInputAction.go,
                              onSubmitted: _navigateToUrl,
                              textAlignVertical: TextAlignVertical.center,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textPrimary,
                              ),
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
                                hintText: 'Search or enter URL…',
                                hintStyle: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textFaint,
                                ),
                                isDense: true,
                                suffixIcon: _urlBarController.text.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.close_rounded, size: 16, color: AppColors.textFaint),
                                        onPressed: () {
                                          _urlBarController.clear();
                                          setState(() {});
                                        },
                                        splashRadius: 16,
                                      )
                                    : null,
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _NavIconButton(
                        icon: Icons.refresh_rounded,
                        onTap: _reload,
                      ),
                      if (mediaCount > 0)
                        _NavIconButton(
                          icon: Icons.cleaning_services_rounded,
                          onTap: () =>
                              ref.read(browserControllerProvider).clearMedia(),
                          size: 18,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            // Progress bar — kawaii gradient
            if (_progress < 100)
              SizedBox(
                height: 3,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.borderSubtle,
                  ),
                  child: ClipRRect(
                    child: LinearProgressIndicator(
                      value: _progress / 100,
                      backgroundColor: Colors.transparent,
                      color: AppColors.accent,
                    ),
                  ),
                ),
              ),
            // WebView
            Expanded(
              child: _lastError != null
                  ? _BrowserError(
                      message: _lastError!,
                      onRetry: () {
                        setState(() => _lastError = null);
                        _reload();
                      },
                    )
                  : WebViewWidget(controller: _webController),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingDownloadButton(
        count: mediaCount,
        visible: mediaCount > 0,
        onTap: () => _showSniffedSheet(context),
      ),
    );
  }

  Future<void> _showSniffedSheet(BuildContext context) async {
    final items = ref.read(browserControllerProvider).media.toList();
    if (items.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.62,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: AppTheme.accentGradient,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.accent.withValues(alpha: 0.25),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.sensors_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Detected Media',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.3,
                        ),
                      ),
                      Text(
                        '${items.length} stream${items.length == 1 ? '' : 's'} found on this page',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                itemCount: items.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHigh.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: AppColors.border.withValues(alpha: 0.4),
                        width: 0.8,
                      ),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(12, 2, 8, 2),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          gradient: AppTheme.accentGradient,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.movie_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      title: Text(
                        Uri.tryParse(item.url)?.pathSegments.isNotEmpty == true
                            ? Uri.parse(item.url).pathSegments.last
                            : item.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      subtitle: Text(
                        UrlUtils.displayHost(item.url),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textFaint,
                        ),
                      ),
                      trailing: Container(
                        decoration: BoxDecoration(
                          gradient: AppTheme.accentGradient,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.accent.withValues(alpha: 0.25),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              _handleSniffed(item);
                            },
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.download_rounded,
                                      size: 16, color: Colors.white),
                                  SizedBox(width: 4),
                                  Text(
                                    'Grab',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 12,
                                      color: Colors.white,
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
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Handles a sniffed media item using on-device merging (no server job).
  Future<void> _handleSniffed(SniffedMedia item) async {
    if (!UrlUtils.isInstagramUrl(item.url)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.instagramOnly)),
        );
      }
      return;
    }
    final downloads = ref.read(downloadControllerProvider);
    if (UrlUtils.isDirectMediaUrl(item.url)) {
      await downloads.start(
        url: item.url,
        fileName: _fileNameFor(item),
        isHls: UrlUtils.looksLikeHls(item.url),
      );
      ref.read(libraryControllerProvider).refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download started')),
        );
      }
      return;
    }

    final extract = ref.read(extractControllerProvider);
    await extract.extract(item.url);
    if (!mounted) return;
    final result = extract.state.valueOrNull;
    if (result != null && result.formats.isNotEmpty) {
      final selection = await showFormatPickerSheet(context, result);
      if (selection == null) return;

      final suggested = result.suggestedFilename;
      final base = suggested == null
          ? result.title
          : suggested.replaceAll(RegExp(r'\.[^.]*$'), '');

      if (selection.merged) {
        final bestVideo = result.bestVideoFormat;
        final bestAudio = result.bestAudioFormat;
        if (bestVideo != null) {
          if (!bestVideo.hasAudio && bestAudio != null) {
            await downloads.start(
              url: bestVideo.url,
              audioUrl: bestAudio.url,
              fileName: '$base.mp4',
            );
          } else {
            await downloads.start(
              url: bestVideo.url,
              fileName: '$base.mp4',
              isHls: bestVideo.isHls,
            );
          }
        }
      } else if (selection.audioOnly) {
        final bestAudio = result.bestAudioFormat;
        if (bestAudio != null) {
          await downloads.start(
            url: bestAudio.url,
            fileName: '$base.m4a',
          );
        }
      } else if (selection.format != null) {
        final format = selection.format!;
        final fileName = result.suggestedFilename ?? _fileNameFor(item);
        if (format.hasVideo && !format.hasAudio && result.bestAudioFormat != null) {
          await downloads.start(
            url: format.url,
            audioUrl: result.bestAudioFormat!.url,
            fileName: fileName,
          );
        } else {
          await downloads.start(
            url: format.url,
            fileName: fileName,
            isHls: format.isHls,
          );
        }
      }
      ref.read(libraryControllerProvider).refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download started')),
        );
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            extract.state.hasError
                ? 'Could not extract this media: ${extract.state.error}'
                : 'No playable media found at this URL.',
          ),
        ),
      );
    }
  }

  String _fileNameFor(SniffedMedia item) {
    final uri = Uri.tryParse(item.url);
    final lastSegment = uri?.pathSegments.isNotEmpty == true
        ? uri!.pathSegments.last
        : '';
    if (lastSegment.isNotEmpty && lastSegment.contains('.')) {
      return lastSegment;
    }
    final host = uri?.host ?? 'media';
    return '${host}_${item.detectedAt.millisecondsSinceEpoch}.mp4';
  }
}

class _NavIconButton extends StatelessWidget {
  const _NavIconButton({
    required this.icon,
    required this.onTap,
    this.size = 20,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: size, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}

class _BrowserError extends StatelessWidget {
  const _BrowserError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Mascot for error state
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.danger.withValues(alpha: 0.2),
                    blurRadius: 30,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: ClipOval(
                child: Image.asset(
                  'assets/mascot/mascot_browser.jpg',
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Could not load this page',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(
                gradient: AppTheme.accentGradient,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onRetry,
                  borderRadius: BorderRadius.circular(14),
                  child: const Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.refresh_rounded,
                            size: 18, color: Colors.white),
                        SizedBox(width: 8),
                        Text(
                          'Retry',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
