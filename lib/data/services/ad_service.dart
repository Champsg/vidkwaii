import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:unity_ads_plugin/unity_ads_plugin.dart';

import '../../core/config/ad_config.dart';

/// Manages Unity Ads initialisation and the rewarded video ad lifecycle.
///
/// The service is created once at app start so the SDK is warm and an ad is
/// loaded before the user reaches a screen that needs one.
class AdService {
  AdService();

  // ─── State ───────────────────────────────────────────────────────────
  Future<void>? _initFuture;
  bool _sdkInitialized = false;
  bool _adReady = false;
  bool _loading = false;
  DateTime? _lastAdShown;
  Completer<void>? _loadCompleter;
  Completer<bool>? _showCompleter;
  Timer? _retryTimer;
  Timer? _showWatchdog;
  DateTime? _showStartedAt;
  int _loadAttempts = 0;
  bool _rewardGranted = false;
  bool _adStarted = false;
  String _status = 'Not started';

  /// Whether an ad is loaded and ready to display right now.
  bool get isReady => _sdkInitialized && _adReady;

  /// Whether an ad is currently loading.
  bool get isLoading => _loading;

  /// Human-readable description of the last ad event, surfaced in the UI when
  /// [AdConfig.diagnosticsToUi] is enabled.
  String get status => _status;

  /// Multi-line summary used by the on-screen diagnostics dialog.
  String diagnosticsSummary() => [
        'Game ID: ${AdConfig.gameId}',
        'Placement: ${AdConfig.rewardedPlacementId}',
        'Test mode: ${AdConfig.testMode}',
        'SDK initialised: $_sdkInitialized',
        'Ad ready: $_adReady',
        'Loading: $_loading',
        'Status: $_status',
      ].join('\n');

  /// Initialise the SDK and start preloading a rewarded ad.
  ///
  /// Safe to call multiple times — the work happens once.
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    final done = Completer<void>();

    try {
      await UnityAds.init(
        gameId: AdConfig.gameId,
        testMode: AdConfig.testMode,
        onComplete: () {
          _sdkInitialized = true;
          _status = 'SDK ready';
          debugPrint('[AdService] Unity Ads initialised');
          _loadRewarded();
          if (!done.isCompleted) done.complete();
        },
        onFailed: (error, message) {
          _status = 'SDK init failed: ${error.name} $message';
          debugPrint('[AdService] Unity Ads init failed: $error $message');
          if (!done.isCompleted) done.complete();
        },
      )
          .timeout(const Duration(seconds: 10), onTimeout: () {})
          .catchError((Object _) {});
    } catch (error) {
      _status = 'SDK init error: $error';
      debugPrint('[AdService] Unity Ads init threw: $error');
      if (!done.isCompleted) done.complete();
    }

    // Guard against an init callback that never fires.
    await done.future.timeout(const Duration(seconds: 20), onTimeout: () {});
  }

  // ─── Rewarded lifecycle ──────────────────────────────────────────────

  void _loadRewarded() {
    if (!_sdkInitialized) return;

    _retryTimer?.cancel();
    _completeLoad();
    _adReady = false;
    _loading = true;
    _loadCompleter = Completer<void>();

    UnityAds.load(
      placementId: AdConfig.rewardedPlacementId,
      onComplete: (placementId) {
        _adReady = true;
        _loading = false;
        _loadAttempts = 0;
        _status = 'Rewarded ad loaded';
        debugPrint('[AdService] Loaded $placementId');
        _completeLoad();
      },
      onFailed: (placementId, error, message) {
        _adReady = false;
        _loading = false;
        _loadAttempts++;
        _status = 'Load failed: ${error.name} $message';
        debugPrint('[AdService] Load failed ($placementId): $error $message');
        _completeLoad();
        // New placements can take a while to start filling — retry with a
        // growing delay instead of hammering the SDK.
        final delay = Duration(seconds: (15 * _loadAttempts).clamp(15, 120));
        _retryTimer = Timer(delay, _loadRewarded);
      },
    );
  }

  /// Try to show a rewarded ad.
  ///
  /// Returns `true` when the ad was watched to completion and the reward was
  /// granted. Returns `false` when the SDK is not ready, no ad is loaded, the
  /// cooldown has not elapsed, or the user skipped the ad.
  Future<bool> showAd({
    Duration maxWait = AdConfig.maxReadyWait,
  }) async {
    if (_showCompleter != null) return false; // Already showing.

    await init();
    if (!_sdkInitialized) return false;

    if (AdConfig.cooldownSeconds > 0 && _lastAdShown != null) {
      final elapsed = DateTime.now().difference(_lastAdShown!).inSeconds;
      if (elapsed < AdConfig.cooldownSeconds) {
        _status =
            'Cooldown active (${AdConfig.cooldownSeconds - elapsed}s left)';
        return false;
      }
    }

    // A load may be in flight — give it a moment rather than skipping.
    if (!_adReady && _loadCompleter != null) {
      await _loadCompleter!.future.timeout(maxWait, onTimeout: () {});
    }
    if (!_adReady) return false;

    final completer = Completer<bool>();
    _showCompleter = completer;
    _showStartedAt = DateTime.now();
    _adReady = false;
    _rewardGranted = false;
    _adStarted = false;
    _status = 'Showing ad';

    // Safety net: playable ads, or ads that hand the user off to the Play
    // Store, can be dismissed without ever firing a callback. Without this the
    // app would stay stuck thinking an ad is still on screen and would stop
    // showing ads entirely.
    _showWatchdog?.cancel();
    _showWatchdog = Timer(AdConfig.maxShowDuration, () {
      if (_showCompleter == null) return;
      _status = 'Ad did not report back — continuing';
      _finishShow(false);
    });

    try {
      await UnityAds.showVideoAd(
        placementId: AdConfig.rewardedPlacementId,
        onStart: (placementId) {
          _adStarted = true;
          _status = 'Ad playing';
        },
        onClick: (placementId) => _status = 'Ad clicked',
        onSkipped: (placementId) {
          _status = 'Ad skipped';
          _finishShow(false);
        },
        onComplete: (placementId) {
          _rewardGranted = true;
          _status = 'Ad completed — reward granted';
          _finishShow(true);
        },
        onFailed: (placementId, error, message) {
          _status = 'Display failed: ${error.name} $message';
          debugPrint(
            '[AdService] Display failed ($placementId): $error $message',
          );
          _finishShow(false);
        },
      );
    } catch (error) {
      _status = 'Display error: $error';
      _finishShow(false);
    }

    // If the SDK never opened an ad (ad blocker, or nothing to show), stop
    // making the caller wait. Deliberately leave the SDK and its state alone:
    // no reload, no reset. A slow ad that does appear is still tracked, and
    // touching the SDK here is what used to break the ad's own close button.
    if (!_adStarted) {
      _status = 'Ad did not start';
      return false;
    }

    return completer.future;
  }

  void dispose() {
    _retryTimer?.cancel();
    _showWatchdog?.cancel();
  }

  void _completeLoad() {
    final completer = _loadCompleter;
    _loadCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _finishShow(bool rewarded) {
    final completer = _showCompleter;
    if (completer == null) return; // Already finished.

    _showCompleter = null;
    _showStartedAt = null;
    _showWatchdog?.cancel();
    _showWatchdog = null;
    _lastAdShown = DateTime.now();
    if (!completer.isCompleted) completer.complete(rewarded);
    // Prepare the next ad.
    _loadRewarded();
  }
}
