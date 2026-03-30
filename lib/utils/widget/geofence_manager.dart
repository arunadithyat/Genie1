import 'package:flutter/material.dart';
import 'package:geofence_service/geofence_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// GeofenceManager wraps the `geofence_service` package and fires
/// local notifications + in-app callbacks when the user enters or
/// exits a defined geographic zone.
///
/// Usage:
///   1. Call [GeofenceManager.initialize()] once (e.g. in main.dart or initState).
///   2. Call [GeofenceManager.instance.startMonitoring(...)] with the event lat/lng.
///   3. Call [GeofenceManager.instance.stopMonitoring()] on dispose.
class GeofenceManager {
  // ── Singleton ──────────────────────────────────────────────────────────────
  GeofenceManager._();
  static final GeofenceManager instance = GeofenceManager._();

  // ── Local notifications ────────────────────────────────────────────────────
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  static bool _notificationsInitialized = false;

  // ── Geofence service ───────────────────────────────────────────────────────
  final GeofenceService _service = GeofenceService.instance.setup(
    interval: 5000,           // poll every 5 seconds
    accuracy: 100,            // metres accuracy threshold
    loiteringDelayMs: 60000,  // 60 s before DWELL fires
    statusChangeDelayMs: 1000,
    useActivityRecognition: false,
    allowMockLocations: false,
    printDevLog: true,
    geofenceRadiusSortType: GeofenceRadiusSortType.DESC,
  );

  bool _isRunning = false;

  /// Optional callback — set by the widget to receive in-app status updates.
  void Function(String eventId, GeofenceStatus status)? onStatusChange;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Initialise local notifications. Call once per app session.
  static Future<void> initialize() async {
    if (_notificationsInitialized) return;

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/launcher_icon');

    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _notificationsPlugin.initialize(
      const InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      ),
    );

    _notificationsInitialized = true;
    debugPrint('✅ GeofenceManager: notifications initialized');
  }

  /// Start monitoring a geographic zone centred on [latitude]/[longitude].
  ///
  /// [eventId]      – used as the geofence identifier (ERPNext Event name).
  /// [radiusMeters] – zone radius in metres (default 200 m).
  Future<void> startMonitoring({
    required String eventId,
    required double latitude,
    required double longitude,
    double radiusMeters = 200,
  }) async {
    if (_isRunning) await stopMonitoring();

    final geofence = Geofence(
      id: eventId,
      latitude: latitude,
      longitude: longitude,
      radius: [
        GeofenceRadius(id: '${eventId}_radius', length: radiusMeters),
      ],
    );

    _service.addGeofenceStatusChangeListener(_onStatusChange);
    _service.addStreamErrorListener(_onError);

    await _service.start([geofence]);
    _isRunning = true;

    debugPrint(
      '📍 GeofenceManager: started [$eventId] at ($latitude, $longitude) '
      'r=${radiusMeters}m',
    );
  }

  /// Stop all active geofence monitoring.
  Future<void> stopMonitoring() async {
    if (!_isRunning) return;
    _service.removeGeofenceStatusChangeListener(_onStatusChange);
    _service.removeStreamErrorListener(_onError);
    await _service.stop();
    _isRunning = false;
    debugPrint('🛑 GeofenceManager: monitoring stopped');
  }

  bool get isRunning => _isRunning;

  // ── Internal handlers ──────────────────────────────────────────────────────

  Future<void> _onStatusChange(
    Geofence geofence,
    GeofenceRadius geofenceRadius,
    GeofenceStatus status,
    Location location,
  ) async {
    debugPrint('📌 Geofence [${geofence.id}] → $status');

    String title;
    String body;

    switch (status) {
      case GeofenceStatus.ENTER:
        title = '📍 Entered Event Zone';
        body = 'You have entered the event location area.';
        break;
      case GeofenceStatus.EXIT:
        title = '🚪 Left Event Zone';
        body = 'You have left the event location area.';
        break;
      case GeofenceStatus.DWELL:
        title = '⏱ Still in Event Zone';
        body = 'You are still within the event location area.';
        break;
    }

    await _sendNotification(title: title, body: body);
    onStatusChange?.call(geofence.id, status);
  }

  void _onError(dynamic error) {
    debugPrint('❌ GeofenceManager error: $error');
  }

  Future<void> _sendNotification({
    required String title,
    required String body,
  }) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'geofence_channel',
      'Geofence Alerts',
      channelDescription: 'Alerts when you enter or exit an event zone',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/launcher_icon',
    );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    await _notificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      const NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      ),
    );
  }
}
