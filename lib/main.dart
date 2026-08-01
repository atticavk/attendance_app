import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';
import 'package:workmanager/workmanager.dart';

import 'web_desktop_attendance_stub.dart'
    if (dart.library.html) 'web_desktop_attendance_web.dart'
    as web_desktop_attendance;

const String _adminNotificationBackgroundTaskName =
    'adminNotificationBackgroundSync';
const String _adminNotificationBackgroundPeriodicTaskUniqueName =
    'adminNotificationBackgroundPeriodicSync';
const String _adminNotificationBackgroundOneOffTaskUniqueName =
    'adminNotificationBackgroundOneOffSync';
const double _attendanceFraudConfidenceThreshold = 0.95;
const bool _allowNortonEmulatorCertificate = bool.fromEnvironment(
  'ALLOW_NORTON_EMULATOR_CA',
  defaultValue: false,
);

class _NortonEmulatorHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (certificate, host, port) {
      return host.toLowerCase() == 'atticagold.app' &&
          certificate.issuer.contains('Norton Web/Mail Shield Root');
    };
    return client;
  }
}

bool get _isAndroidPlatform => !kIsWeb && Platform.isAndroid;
bool get _isIosPlatform => !kIsWeb && Platform.isIOS;
bool get _isMacOsPlatform => !kIsWeb && Platform.isMacOS;
bool get _isWebDesktopPlatform =>
    kIsWeb &&
    defaultTargetPlatform != TargetPlatform.android &&
    defaultTargetPlatform != TargetPlatform.iOS;
bool get _supportsNotificationPlatforms =>
    _isAndroidPlatform || _isIosPlatform || _isMacOsPlatform;

@pragma('vm:entry-point')
void adminNotificationBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    if (!_isAndroidPlatform) {
      return true;
    }

    await ApiConfig.load();
    await AttendanceNotificationService.initializeForBackground();

    if (task == _adminNotificationBackgroundTaskName) {
      return AdminNotificationBackgroundService.runBackgroundSync();
    }

    return true;
  });
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await PushMessagingService.ensureFirebaseInitialized();
  await AttendanceNotificationService.initializeForBackground();

  final isAdminNotification =
      message.data['type']?.toString() == 'admin_notification';
  if (!isAdminNotification) {
    return;
  }

  final notification = EmployeePushNotification.fromRemoteMessage(message);
  if (notification.deliveryId <= 0) {
    return;
  }

  await AttendanceNotificationService.showAdminNotification(notification);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_isAndroidPlatform && _allowNortonEmulatorCertificate) {
    HttpOverrides.global = _NortonEmulatorHttpOverrides();
  }
  await ApiConfig.load();
  runApp(const EmployeePortalApp());
  unawaited(AndroidWorkmanagerService.initialize());
}

class AndroidWorkmanagerService {
  AndroidWorkmanagerService._();

  static Future<void>? _initialization;

  static Future<void> initialize() async {
    if (!_isAndroidPlatform) {
      return;
    }

    final currentInitialization = _initialization;
    if (currentInitialization != null) {
      await currentInitialization;
      return;
    }

    final initialization = () async {
      try {
        await Workmanager().initialize(adminNotificationBackgroundDispatcher);
      } catch (_) {
        _initialization = null;
      }
    }();
    _initialization = initialization;
    await initialization;
  }
}

class AttendanceNotificationService {
  AttendanceNotificationService._();

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static Future<void>? _initialization;
  static Future<void>? _backgroundInitialization;

  static const String _notificationIcon = 'ic_stat_attica';

  static const int _checkInReminderId = 1009;
  static const int _logoutReminderId = 1018;
  static const int _checkInCompletedId = 2009;
  static const int _checkOutCompletedId = 2018;
  static const int _adminNotificationBaseId = 300000;
  static const int _branchOpeningReminderBaseId = 400000;
  static const int _branchOpeningReminderMaxSlots = 32;
  static const int _legacyRunningNotificationId = 1000;
  static const int _legacyBreakReminderId = 1015;
  static const int _legacyCheckInReminderId = 900;
  static const int _legacyCheckOutReminderId = 1800;
  static const String _shownAdminNotificationIdsKey =
      'shown_admin_notification_delivery_ids_v1';
  static const String _checkInCompletedDateKey =
      'attendance_check_in_completed_date';
  static const String _checkOutCompletedDateKey =
      'attendance_check_out_completed_date';

  static final NotificationDetails _reminderNotificationDetails =
      NotificationDetails(
        android: AndroidNotificationDetails(
          'attendance_reminders',
          'Attendance reminders',
          channelDescription: 'Timed check-in and logout reminders',
          icon: _notificationIcon,
          importance: Importance.max,
          priority: Priority.max,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          additionalFlags: Int32List.fromList([32]),
        ),
      );

  static const NotificationDetails _completedNotificationDetails =
      NotificationDetails(
        android: AndroidNotificationDetails(
          'attendance_completed',
          'Attendance completed',
          channelDescription: 'Attendance completion confirmations',
          icon: _notificationIcon,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          timeoutAfter: 5000,
          autoCancel: true,
        ),
      );

  static const NotificationDetails _adminNotificationDetails =
      NotificationDetails(
        android: AndroidNotificationDetails(
          'admin_push_notifications',
          'Admin notifications',
          channelDescription: 'Notifications sent by admin',
          icon: _notificationIcon,
          importance: Importance.max,
          priority: Priority.max,
          autoCancel: true,
        ),
      );

  static const NotificationDetails _branchOpeningNotificationDetails =
      NotificationDetails(
        android: AndroidNotificationDetails(
          'branch_opening_reminders',
          'Branch opening reminders',
          channelDescription:
              'Reminders for employees assigned to open branches',
          icon: _notificationIcon,
          importance: Importance.max,
          priority: Priority.max,
          autoCancel: true,
        ),
      );

  static Future<void> initialize() async {
    if (!_supportsNotificationPlatforms) {
      return;
    }

    final currentInitialization = _initialization;
    if (currentInitialization != null) {
      await currentInitialization;
      return;
    }

    final initialization = () async {
      try {
        await _initializeForForeground();
      } catch (_) {
        _initialization = null;
      }
    }();
    _initialization = initialization;
    await initialization;
  }

  static Future<void> _initializeForForeground() async {
    await _configureLocalTimezone();
    await _initializeNotificationsPlugin();
    await _createNotificationChannels();

    if (_isAndroidPlatform) {
      final androidPlugin = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final permissionGranted = await androidPlugin
          ?.requestNotificationsPermission();
      if (permissionGranted == false) {
        return;
      }
      await _ensureExactAlarmPermission(androidPlugin);
    }

    await _scheduleDailyReminders();
  }

  static Future<void> initializeForBackground() async {
    if (!_isAndroidPlatform) {
      return;
    }

    final foregroundInitialization = _initialization;
    if (foregroundInitialization != null) {
      await foregroundInitialization;
      return;
    }

    final currentInitialization = _backgroundInitialization;
    if (currentInitialization != null) {
      await currentInitialization;
      return;
    }

    final initialization = () async {
      try {
        await _initializeForBackground();
      } catch (_) {
        _backgroundInitialization = null;
      }
    }();
    _backgroundInitialization = initialization;
    await initialization;
  }

  static Future<void> _initializeForBackground() async {
    await _configureLocalTimezone();
    await _initializeNotificationsPlugin();
    await _createNotificationChannels();
  }

  static Future<void> _ensureInitializedForNotificationWork() async {
    if (!_supportsNotificationPlatforms) {
      return;
    }

    final foregroundInitialization = _initialization;
    if (foregroundInitialization != null) {
      await foregroundInitialization;
      return;
    }

    await initializeForBackground();
  }

  static Future<void> _initializeNotificationsPlugin() async {
    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings(_notificationIcon),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
    );
    await _notifications.initialize(settings: initializationSettings);
  }

  static Future<void> _createNotificationChannels() async {
    if (!_isAndroidPlatform) {
      return;
    }

    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin == null) {
      return;
    }

    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'attendance_reminders',
        'Attendance reminders',
        description: 'Timed check-in and logout reminders',
        importance: Importance.max,
      ),
    );
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'attendance_completed',
        'Attendance completed',
        description: 'Attendance completion confirmations',
        importance: Importance.defaultImportance,
      ),
    );
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'admin_push_notifications',
        'Admin notifications',
        description: 'Notifications sent by admin',
        importance: Importance.max,
      ),
    );
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'branch_opening_reminders',
        'Branch opening reminders',
        description: 'Reminders for employees assigned to open branches',
        importance: Importance.max,
      ),
    );
  }

  static Future<void> _configureLocalTimezone() async {
    tzdata.initializeTimeZones();
    try {
      final timezone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezone.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));
    }
  }

  static Future<void> _scheduleDailyReminders() async {
    await _notifications.cancel(id: _legacyCheckInReminderId);
    await _notifications.cancel(id: _legacyCheckOutReminderId);
    await _notifications.cancel(id: _legacyRunningNotificationId);
    await _notifications.cancel(id: _legacyBreakReminderId);
    await _notifications.cancel(id: _checkInReminderId);
    await _notifications.cancel(id: _logoutReminderId);
    await _notifications.cancel(id: _checkInCompletedId);
    await _notifications.cancel(id: _checkOutCompletedId);
    await _stopActiveReminder();

    final attendanceState = await _readStoredAttendanceState();
    await _scheduleDailyReminder(
      _TimedReminder.checkIn,
      nextDay: attendanceState.hasCheckedInToday,
    );
    if (attendanceState.hasCheckedInToday &&
        !attendanceState.hasCheckedOutToday) {
      await _scheduleDailyReminder(_TimedReminder.logout);
    } else {
      await _notifications.cancel(id: _logoutReminderId);
    }
  }

  static Future<void> _scheduleDailyReminder(
    _TimedReminder reminder, {
    bool nextDay = false,
  }) async {
    final androidScheduleMode = await _resolveAndroidScheduleMode();
    await _notifications.zonedSchedule(
      id: reminder.id,
      title: 'Attica Attendance',
      body: reminder.message,
      scheduledDate: _nextInstanceOfTime(
        hour: reminder.hour,
        minute: 0,
        nextDay: nextDay,
      ),
      notificationDetails: _reminderNotificationDetails,
      androidScheduleMode: androidScheduleMode,
      matchDateTimeComponents: nextDay ? null : DateTimeComponents.time,
    );
  }

  static Future<void> _showReminderNotification(_TimedReminder reminder) async {
    await _notifications.show(
      id: reminder.id,
      title: 'Attica Attendance',
      body: reminder.message,
      notificationDetails: _reminderNotificationDetails,
    );
  }

  static Future<void> syncWithAttendance(AttendanceRecord? attendance) async {
    final todayDate = _todayDate();
    final hasCheckedInToday = _hasCheckedInToday(attendance, todayDate);
    final hasValidActiveAttendance = _hasValidActiveAttendance(
      attendance,
      todayDate,
    );
    final hasCheckedOutToday = _hasCheckedOutToday(attendance, todayDate);
    await _writeStoredAttendanceState(
      checkedInToday: hasCheckedInToday || hasValidActiveAttendance,
      checkedOutToday: hasCheckedOutToday,
    );

    if (!_supportsNotificationPlatforms) {
      return;
    }

    await _ensureInitializedForNotificationWork();

    if (hasCheckedInToday || hasValidActiveAttendance) {
      await _notifications.cancel(id: _checkInReminderId);
      await _scheduleDailyReminder(_TimedReminder.checkIn, nextDay: true);
    } else if (_shouldShowCheckInReminder()) {
      await _showReminderNotification(_TimedReminder.checkIn);
    }

    if (hasCheckedOutToday) {
      await _notifications.cancel(id: _logoutReminderId);
    } else if (hasValidActiveAttendance && _shouldShowCheckoutReminder()) {
      await _notifications.cancel(id: _logoutReminderId);
      await _showReminderNotification(_TimedReminder.logout);
    } else if (hasValidActiveAttendance) {
      await _scheduleDailyReminder(_TimedReminder.logout);
    } else {
      await _notifications.cancel(id: _logoutReminderId);
    }
  }

  static Future<void> disableAttendanceReminders() async {
    await _writeStoredAttendanceState(
      checkedInToday: false,
      checkedOutToday: false,
    );

    if (!_supportsNotificationPlatforms) {
      return;
    }

    await _ensureInitializedForNotificationWork();

    await _notifications.cancel(id: _checkInReminderId);
    await _notifications.cancel(id: _logoutReminderId);
    await _notifications.cancel(id: _checkInCompletedId);
    await _notifications.cancel(id: _checkOutCompletedId);
  }

  static Future<void> showAdminNotification(
    EmployeePushNotification notification,
  ) async {
    if (!_supportsNotificationPlatforms) {
      return;
    }

    await _ensureInitializedForNotificationWork();

    final wasMarkedAsShown = await _markAdminNotificationAsShown(
      notification.deliveryId,
    );
    if (!wasMarkedAsShown) {
      return;
    }

    await _notifications.show(
      id: _adminNotificationBaseId + notification.deliveryId,
      title: notification.title.trim().isEmpty
          ? 'Attica Pagar'
          : notification.title.trim(),
      body: notification.body,
      notificationDetails: _adminNotificationDetails,
    );
  }

  static Future<void> markCheckInCompleted() async {
    await _writeStoredAttendanceState(
      checkedInToday: true,
      checkedOutToday: false,
    );

    if (!_supportsNotificationPlatforms) {
      return;
    }

    await _ensureInitializedForNotificationWork();

    await _notifications.cancel(id: _checkInReminderId);
    await _notifications.cancel(id: _logoutReminderId);
    await _scheduleDailyReminder(_TimedReminder.checkIn, nextDay: true);
    if (_shouldShowCheckoutReminder()) {
      await _showReminderNotification(_TimedReminder.logout);
    } else {
      await _scheduleDailyReminder(_TimedReminder.logout);
    }
    await _showCompletedNotification(
      id: _checkInCompletedId,
      message: 'Check in completed.',
    );
  }

  static Future<void> markCheckOutCompleted() async {
    await _writeStoredAttendanceState(
      checkedInToday: true,
      checkedOutToday: true,
    );

    if (!_supportsNotificationPlatforms) {
      return;
    }

    await _ensureInitializedForNotificationWork();

    await _notifications.cancel(id: _logoutReminderId);
    await _showCompletedNotification(
      id: _checkOutCompletedId,
      message: 'Check out completed.',
    );
  }

  static Future<void> clearForLogout() async {
    if (!_supportsNotificationPlatforms) {
      await _writeStoredAttendanceState(
        checkedInToday: false,
        checkedOutToday: false,
      );
      return;
    }

    await _ensureInitializedForNotificationWork();

    await _notifications.cancel(id: _checkInReminderId);
    await _notifications.cancel(id: _logoutReminderId);
    await _notifications.cancel(id: _checkInCompletedId);
    await _notifications.cancel(id: _checkOutCompletedId);
    await _cancelBranchOpeningReminders();
    await _stopActiveReminder();
    await _writeStoredAttendanceState(
      checkedInToday: false,
      checkedOutToday: false,
    );
  }

  static Future<void> syncBranchOpeningReminders(Employee? employee) async {
    if (!_supportsNotificationPlatforms) {
      return;
    }

    await _ensureInitializedForNotificationWork();

    await _cancelBranchOpeningReminders();

    if (employee == null || !employee.isBranchOpeningEmployee) {
      return;
    }

    if (employee.branchOpeningNotificationsManagedByServer) {
      return;
    }

    final openingTime = _parseBranchOpeningTime(employee.branchOpeningTime);
    if (openingTime == null) {
      return;
    }

    final startMinutes = employee.branchOpeningReminderStartMinutes > 0
        ? employee.branchOpeningReminderStartMinutes
        : 120;
    final intervalMinutes = employee.branchOpeningReminderIntervalMinutes > 0
        ? employee.branchOpeningReminderIntervalMinutes
        : 15;
    final offsets = <int>[];
    for (var offset = startMinutes; offset > 0; offset -= intervalMinutes) {
      offsets.add(offset);
    }
    offsets.add(0);

    final openingLabel = _formatBranchOpeningTime(openingTime);
    final adminPhone = employee.branchOpeningAdminPhone.trim();
    final androidScheduleMode = await _resolveAndroidScheduleMode();

    for (
      var index = 0;
      index < offsets.length && index < _branchOpeningReminderMaxSlots;
      index += 1
    ) {
      final offset = offsets[index];
      final reminderTime = _branchOpeningTimeMinusMinutes(openingTime, offset);
      final isOpeningTime = offset == 0;
      await _notifications.zonedSchedule(
        id: _branchOpeningReminderBaseId + index,
        title: 'Branch opening reminder',
        body: isOpeningTime
            ? 'Branch needs to be opened at the given time: ${_formatBranchOpeningDisplayTime(openingLabel)}.\nYou need to reach in : 0 mins.\nIf you are late call admin now at: ${adminPhone.isNotEmpty ? adminPhone : 'admin'}.'
            : 'Branch needs to be opened at the given time: ${_formatBranchOpeningDisplayTime(openingLabel)}.\nYou need to reach in : ${_formatBranchOpeningOffset(offset)}.\nIf you are late call admin now at: ${adminPhone.isNotEmpty ? adminPhone : 'admin'}.',
        scheduledDate: _nextInstanceOfTime(
          hour: reminderTime.hour,
          minute: reminderTime.minute,
        ),
        notificationDetails: _branchOpeningNotificationDetails,
        androidScheduleMode: androidScheduleMode,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    }
  }

  static Future<void> _cancelBranchOpeningReminders() async {
    for (var index = 0; index < _branchOpeningReminderMaxSlots; index += 1) {
      await _notifications.cancel(id: _branchOpeningReminderBaseId + index);
    }
  }

  static Future<void> _stopActiveReminder() async {
    await _notifications.cancel(id: _checkInReminderId);
    await _notifications.cancel(id: _logoutReminderId);
  }

  static Future<bool> _markAdminNotificationAsShown(int deliveryId) async {
    final preferences = await SharedPreferences.getInstance();
    final shownIds =
        preferences
            .getStringList(_shownAdminNotificationIdsKey)
            ?.map(int.tryParse)
            .whereType<int>()
            .toList()
          ?..sort();

    final normalizedShownIds = shownIds ?? <int>[];
    if (normalizedShownIds.contains(deliveryId)) {
      return false;
    }

    normalizedShownIds.add(deliveryId);
    const maxStoredIds = 500;
    if (normalizedShownIds.length > maxStoredIds) {
      normalizedShownIds.removeRange(
        0,
        normalizedShownIds.length - maxStoredIds,
      );
    }

    await preferences.setStringList(
      _shownAdminNotificationIdsKey,
      normalizedShownIds.map((id) => id.toString()).toList(),
    );
    return true;
  }

  static Future<void> _ensureExactAlarmPermission(
    AndroidFlutterLocalNotificationsPlugin? androidPlugin,
  ) async {
    if (androidPlugin == null) {
      return;
    }

    final canScheduleExact = await androidPlugin
        .canScheduleExactNotifications();
    if (canScheduleExact == false) {
      await androidPlugin.requestExactAlarmsPermission();
    }
  }

  static Future<AndroidScheduleMode> _resolveAndroidScheduleMode() async {
    if (!_isAndroidPlatform) {
      return AndroidScheduleMode.inexactAllowWhileIdle;
    }

    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final canScheduleExact = await androidPlugin
        ?.canScheduleExactNotifications();
    if (canScheduleExact == true) {
      return AndroidScheduleMode.exactAllowWhileIdle;
    }
    return AndroidScheduleMode.inexactAllowWhileIdle;
  }

  static Future<void> _showCompletedNotification({
    required int id,
    required String message,
  }) async {
    await _notifications.show(
      id: id,
      title: 'Attica Attendance',
      body: message,
      notificationDetails: _completedNotificationDetails,
    );
    unawaited(
      Future<void>.delayed(const Duration(seconds: 5)).then((_) {
        return _notifications.cancel(id: id);
      }),
    );
  }

  static bool _shouldShowCheckInReminder() {
    final hour = tz.TZDateTime.now(tz.local).hour;
    return hour >= 8;
  }

  static bool _shouldShowCheckoutReminder() {
    final hour = tz.TZDateTime.now(tz.local).hour;
    return hour >= 18;
  }

  static bool _hasCheckedInToday(
    AttendanceRecord? attendance,
    String todayDate,
  ) {
    return attendance != null && attendance.checkInDate == todayDate;
  }

  static bool _hasValidActiveAttendance(
    AttendanceRecord? attendance,
    String todayDate,
  ) {
    if (attendance == null || attendance.hasCheckedOut) {
      return false;
    }

    return attendance.checkInDate == todayDate || attendance.isNightShift;
  }

  static bool _hasCheckedOutToday(
    AttendanceRecord? attendance,
    String todayDate,
  ) {
    if (attendance == null || !attendance.hasCheckedOut) {
      return false;
    }

    final checkOutDate = (attendance.checkOutDate ?? attendance.checkInDate)
        .trim();
    return checkOutDate == todayDate;
  }

  static String _todayDate() {
    if (!_supportsNotificationPlatforms) {
      final now = DateTime.now();
      final month = now.month.toString().padLeft(2, '0');
      final day = now.day.toString().padLeft(2, '0');
      return '${now.year}-$month-$day';
    }

    final now = tz.TZDateTime.now(tz.local);
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }

  static Future<_StoredAttendanceState> _readStoredAttendanceState() async {
    final todayDate = _todayDate();
    final preferences = await SharedPreferences.getInstance();
    return _StoredAttendanceState(
      hasCheckedInToday:
          preferences.getString(_checkInCompletedDateKey) == todayDate,
      hasCheckedOutToday:
          preferences.getString(_checkOutCompletedDateKey) == todayDate,
    );
  }

  static Future<void> _writeStoredAttendanceState({
    required bool checkedInToday,
    required bool checkedOutToday,
  }) async {
    final todayDate = _todayDate();
    final preferences = await SharedPreferences.getInstance();
    if (checkedInToday) {
      await preferences.setString(_checkInCompletedDateKey, todayDate);
    } else {
      await preferences.remove(_checkInCompletedDateKey);
    }

    if (checkedOutToday) {
      await preferences.setString(_checkOutCompletedDateKey, todayDate);
    } else {
      await preferences.remove(_checkOutCompletedDateKey);
    }
  }

  static tz.TZDateTime _nextInstanceOfTime({
    required int hour,
    required int minute,
    bool nextDay = false,
  }) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (nextDay ||
        scheduledDate.isBefore(now) ||
        scheduledDate.isAtSameMomentAs(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }
    return scheduledDate;
  }

  static _BranchOpeningTime? _parseBranchOpeningTime(String value) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(value.trim());
    if (match == null) {
      return null;
    }

    final hour = int.tryParse(match.group(1) ?? '');
    final minute = int.tryParse(match.group(2) ?? '');
    if (hour == null ||
        minute == null ||
        hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59) {
      return null;
    }

    return _BranchOpeningTime(hour: hour, minute: minute);
  }

  static _BranchOpeningTime _branchOpeningTimeMinusMinutes(
    _BranchOpeningTime time,
    int minutes,
  ) {
    const dayMinutes = 24 * 60;
    var totalMinutes = (time.hour * 60 + time.minute - minutes) % dayMinutes;
    if (totalMinutes < 0) {
      totalMinutes += dayMinutes;
    }

    return _BranchOpeningTime(
      hour: totalMinutes ~/ 60,
      minute: totalMinutes % 60,
    );
  }

  static String _formatBranchOpeningTime(_BranchOpeningTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  static String _formatBranchOpeningDisplayTime(String value) {
    return _formatCompactTime(value).toUpperCase();
  }

  static String _formatBranchOpeningOffset(int minutes) {
    if (minutes <= 0) {
      return '0 mins';
    }

    final hours = minutes ~/ 60;
    final remainingMinutes = minutes % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${remainingMinutes.toString().padLeft(2, '0')} hrs';
    }

    return '$remainingMinutes mins';
  }
}

class PushMessagingService {
  PushMessagingService._();

  static Future<void>? _initialization;
  static bool _available = false;

  static bool get isAvailable => _available;

  static Future<void> initialize() async {
    final currentInitialization = _initialization;
    if (currentInitialization != null) {
      await currentInitialization;
      return;
    }

    _initialization = _initializeInternal();
    await _initialization;
  }

  static Future<void> _initializeInternal() async {
    if (!_supportsNotificationPlatforms) {
      _available = false;
      return;
    }

    try {
      await ensureFirebaseInitialized();
      FirebaseMessaging.onBackgroundMessage(
        _firebaseMessagingBackgroundHandler,
      );
      await FirebaseMessaging.instance.setAutoInitEnabled(true);
      _available = true;
    } catch (_) {
      _available = false;
      _initialization = null;
    }
  }

  static Future<void> ensureFirebaseInitialized() async {
    if (Firebase.apps.isNotEmpty) {
      return;
    }

    await Firebase.initializeApp();
  }

  static Future<void> requestPermission() async {
    if (!_available) {
      return;
    }

    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (_) {
      // Keep the app usable even if Firebase permissions are unavailable.
    }
  }

  static Future<void> configureForegroundPresentation() async {
    if (!_available) {
      return;
    }

    try {
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
            alert: true,
            badge: true,
            sound: true,
          );
    } catch (_) {
      // Android ignores this; Apple platforms may throw before full setup.
    }
  }

  static Future<String?> currentToken() async {
    if (!_available) {
      return null;
    }

    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (_) {
      return null;
    }
  }

  static Future<RemoteMessage?> initialMessage() async {
    if (!_available) {
      return null;
    }

    try {
      return await FirebaseMessaging.instance.getInitialMessage();
    } catch (_) {
      return null;
    }
  }

  static Stream<RemoteMessage> get onMessage =>
      _available ? FirebaseMessaging.onMessage : Stream<RemoteMessage>.empty();

  static Stream<RemoteMessage> get onMessageOpenedApp => _available
      ? FirebaseMessaging.onMessageOpenedApp
      : Stream<RemoteMessage>.empty();

  static Stream<String> get onTokenRefresh => _available
      ? FirebaseMessaging.instance.onTokenRefresh
      : Stream<String>.empty();

  static String get platform {
    if (_isAndroidPlatform) {
      return 'android';
    }
    if (_isIosPlatform) {
      return 'ios';
    }
    if (_isMacOsPlatform) {
      return 'macos';
    }

    return 'web';
  }
}

class _BranchOpeningTime {
  const _BranchOpeningTime({required this.hour, required this.minute});

  final int hour;
  final int minute;
}

class _StoredAttendanceState {
  const _StoredAttendanceState({
    required this.hasCheckedInToday,
    required this.hasCheckedOutToday,
  });

  final bool hasCheckedInToday;
  final bool hasCheckedOutToday;
}

enum _TimedReminder {
  checkIn(1009, 8, 'Don\'t forget to check in.'),
  logout(1018, 18, 'Don\'t forget to logout.');

  const _TimedReminder(this.id, this.hour, this.message);

  final int id;
  final int hour;
  final String message;
}

class EmployeePortalApp extends StatelessWidget {
  const EmployeePortalApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseTextTheme = GoogleFonts.interTextTheme();
    final baseTheme = ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        primary: AppColors.primary,
        secondary: AppColors.secondary,
        surface: AppColors.background,
        brightness: Brightness.light,
      ),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Attica Attendance',
      theme: baseTheme.copyWith(
        appBarTheme: AppBarTheme(
          backgroundColor: AppColors.background,
          surfaceTintColor: Colors.transparent,
          foregroundColor: AppColors.text,
          titleTextStyle: GoogleFonts.manrope(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: AppColors.text,
          ),
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: AppColors.accent,
          circularTrackColor: AppColors.primarySoft,
          linearTrackColor: AppColors.primarySoft,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: AppColors.accent,
          foregroundColor: AppColors.text,
        ),
        textTheme: GoogleFonts.interTextTheme(baseTheme.textTheme).copyWith(
          bodyLarge: baseTextTheme.bodyLarge?.copyWith(color: AppColors.text),
          bodyMedium: baseTextTheme.bodyMedium?.copyWith(color: AppColors.text),
          bodySmall: baseTextTheme.bodySmall?.copyWith(
            color: AppColors.subtleText,
          ),
          displayLarge: GoogleFonts.manrope(
            fontSize: 36,
            fontWeight: FontWeight.w800,
            height: 1.1,
            color: AppColors.text,
          ),
          displayMedium: GoogleFonts.manrope(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            height: 1.1,
            color: AppColors.text,
          ),
          headlineMedium: GoogleFonts.manrope(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            height: 1.15,
            color: AppColors.text,
          ),
          titleLarge: GoogleFonts.manrope(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppColors.text,
          ),
          titleMedium: GoogleFonts.manrope(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.text,
          ),
          titleSmall: GoogleFonts.manrope(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppColors.text,
          ),
        ),
      ),
      home: const _StartupScreen(),
    );
  }
}

class _StartupScreen extends StatefulWidget {
  const _StartupScreen();

  @override
  State<_StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<_StartupScreen> {
  bool _showSplash = true;

  void _handleSplashFinished() {
    if (!mounted) {
      return;
    }

    setState(() {
      _showSplash = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      child: _showSplash
          ? _LaunchSplashScreen(
              key: const ValueKey('launch-splash'),
              onFinished: _handleSplashFinished,
            )
          : const AppShell(key: ValueKey('app-shell')),
    );
  }
}

class _LaunchSplashScreen extends StatefulWidget {
  const _LaunchSplashScreen({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<_LaunchSplashScreen> createState() => _LaunchSplashScreenState();
}

class _LaunchSplashScreenState extends State<_LaunchSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _splashController;
  Timer? _splashFallbackTimer;
  bool _didFinishSplash = false;

  @override
  void initState() {
    super.initState();
    _splashController = AnimationController(vsync: this);
    _splashFallbackTimer = Timer(const Duration(seconds: 3), _finishSplash);
  }

  @override
  void dispose() {
    _splashFallbackTimer?.cancel();
    _splashController.dispose();
    super.dispose();
  }

  void _finishSplash() {
    if (_didFinishSplash || !mounted) {
      return;
    }

    _didFinishSplash = true;
    _splashFallbackTimer?.cancel();
    widget.onFinished();
  }

  void _playSplashOnce(LottieComposition composition) {
    _splashFallbackTimer?.cancel();
    _splashController
      ..duration = composition.duration
      ..forward(from: 0).whenComplete(_finishSplash);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SizedBox(
          width: 320,
          height: 320,
          child: Lottie.asset(
            'assets/images/splash.json',
            controller: _splashController,
            repeat: false,
            fit: BoxFit.contain,
            onLoaded: _playSplashOnce,
          ),
        ),
      ),
    );
  }
}

class AppColors {
  static const background = Color(0xFFFFF7EA);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceTint = Color(0xFFFFE7C2);
  static const primary = Color(0xFFC62828);
  static const primaryDark = Color(0xFF8E1111);
  static const primarySoft = Color(0xFFFFD6C8);
  static const accent = Color(0xFFD4A017);
  static const secondary = Color(0xFF8A5B12);
  static const text = Color(0xFF2A1712);
  static const subtleText = Color(0xFF7A5A4B);
  static const success = Color(0xFF1F8F55);
}

class ApiConfig {
  static const hostedBaseUrl = 'https://atticagold.app/api';
  static const legacyHostedBaseUrl = 'https://abhibs.in/api';
  static const legacyEmulatorBaseUrl = 'http://10.0.2.2:8000/api';
  // static const legacyLanBaseUrl = 'http://192.168.1.28:8000/api';

  // Comment/uncomment one line below to switch the default API endpoint.
  // static const selectedBaseUrl = legacyEmulatorBaseUrl;
  static const selectedBaseUrl = hostedBaseUrl;

  static const defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: selectedBaseUrl,
  );
  static const _preferencesKey = 'api_base_url_v3';
  static const _legacyPreferencesKeys = <String>[
    'api_base_url_v2',
    'api_base_url',
  ];

  static String _baseUrl = resolvedDefaultBaseUrl;

  static String get baseUrl => _baseUrl;
  static String get resolvedDefaultBaseUrl => normalize(defaultBaseUrl);

  static Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    final savedValue = preferences.getString(_preferencesKey);
    final normalizedSavedValue = savedValue == null
        ? null
        : normalize(savedValue);
    final normalized = normalizedSavedValue == null
        ? resolvedDefaultBaseUrl
        : _migrateLegacyHostedBaseUrl(normalizedSavedValue);

    _baseUrl = normalized;

    if (savedValue != null && savedValue != normalized) {
      await preferences.setString(_preferencesKey, normalized);
    }

    for (final key in _legacyPreferencesKeys) {
      if (preferences.containsKey(key)) {
        await preferences.remove(key);
      }
    }
  }

  static Future<void> save(String value) async {
    final normalized = normalize(value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_preferencesKey, normalized);
    _baseUrl = normalized;
  }

  static Future<void> reset() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_preferencesKey);
    for (final key in _legacyPreferencesKeys) {
      await preferences.remove(key);
    }
    _baseUrl = resolvedDefaultBaseUrl;
  }

  static String normalize(String value) {
    var normalized = value.trim();

    if (normalized.isEmpty) {
      return defaultBaseUrl;
    }

    if (!normalized.startsWith('http://') &&
        !normalized.startsWith('https://')) {
      normalized = 'http://$normalized';
    }

    normalized = normalized.replaceAll(RegExp(r'/+$'), '');

    if (!normalized.endsWith('/api')) {
      normalized = '$normalized/api';
    }

    final parsed = Uri.tryParse(normalized);
    if (parsed == null) {
      return normalized;
    }

    return _normalizeLoopbackUri(parsed).toString();
  }

  static String _migrateLegacyHostedBaseUrl(String value) {
    if (value == normalize(legacyHostedBaseUrl)) {
      return resolvedDefaultBaseUrl;
    }

    return value;
  }

  static bool isValid(String value) {
    final parsed = Uri.tryParse(normalize(value));
    return parsed != null && parsed.hasScheme && parsed.host.isNotEmpty;
  }

  static Uri _normalizeLoopbackUri(Uri uri) {
    if (!_isAndroidPlatform) {
      return uri;
    }

    final host = uri.host.trim().toLowerCase();
    if (host != '127.0.0.1' && host != 'localhost') {
      return uri;
    }

    return uri.replace(host: '10.0.2.2');
  }
}

class Employee {
  const Employee({
    required this.id,
    required this.branchId,
    required this.branchTableId,
    required this.branchName,
    required this.branchLatitude,
    required this.branchLongitude,
    required this.empId,
    required this.name,
    required this.contact,
    required this.mailId,
    required this.address,
    required this.dateOfBirth,
    required this.gender,
    required this.maritalStatus,
    required this.aadhaarNumber,
    required this.panNumber,
    required this.location,
    required this.designation,
    required this.photo,
    required this.photoUrl,
    required this.rating,
    required this.status,
    required this.isOutsourced,
    required this.outsourceLocations,
    required this.isNightShift,
    required this.shiftTiming,
    required this.salary,
    required this.advance,
    required this.pf,
    required this.bankDetails,
    required this.isBranchOpeningAssigned,
    required this.isBranchOpeningEmployee,
    required this.branchOpeningHasDoorKey,
    required this.branchOpeningHasLockerKey,
    required this.branchOpeningTime,
    required this.branchOpeningAdminPhone,
    required this.branchOpeningStatus,
    required this.branchOpeningOpenedAt,
    required this.branchOpeningOpenedByLabel,
    required this.branchOpeningClosedAt,
    required this.branchOpeningClosedByLabel,
    required this.branchOpeningCanMarkOpened,
    required this.branchOpeningCanMarkClosed,
    required this.branchOpeningReminderStartMinutes,
    required this.branchOpeningReminderIntervalMinutes,
    required this.branchOpeningNotificationsManagedByServer,
  });

  final int id;
  final String branchId;
  final int? branchTableId;
  final String branchName;
  final double? branchLatitude;
  final double? branchLongitude;
  final String empId;
  final String name;
  final String contact;
  final String mailId;
  final String address;
  final String dateOfBirth;
  final String gender;
  final String maritalStatus;
  final String aadhaarNumber;
  final String panNumber;
  final String location;
  final String designation;
  final String photo;
  final String photoUrl;
  final int rating;
  final String status;
  final bool isOutsourced;
  final List<OutsourceLocation> outsourceLocations;
  final bool isNightShift;
  final String shiftTiming;
  final int? salary;
  final int? advance;
  final int? pf;
  final EmployeeBankDetails bankDetails;
  final bool isBranchOpeningAssigned;
  final bool isBranchOpeningEmployee;
  final bool branchOpeningHasDoorKey;
  final bool branchOpeningHasLockerKey;
  final String branchOpeningTime;
  final String branchOpeningAdminPhone;
  final String branchOpeningStatus;
  final String branchOpeningOpenedAt;
  final String branchOpeningOpenedByLabel;
  final String branchOpeningClosedAt;
  final String branchOpeningClosedByLabel;
  final bool branchOpeningCanMarkOpened;
  final bool branchOpeningCanMarkClosed;
  final int branchOpeningReminderStartMinutes;
  final int branchOpeningReminderIntervalMinutes;
  final bool branchOpeningNotificationsManagedByServer;

  bool get hasPhoto => photo.trim().isNotEmpty || photoUrl.trim().isNotEmpty;

  bool get canUseMobileAttendance => _isAndroidPlatform;

  bool get canMarkAttendance => kIsWeb || canUseMobileAttendance;

  List<String> get resolvedPhotoUrls =>
      _resolveAssetUrls(photoPath: photo, photoUrl: photoUrl);

  String get initials {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return 'EM';
    }

    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  factory Employee.fromJson(Map<String, dynamic> json) {
    int? parseNullableInt(dynamic value) {
      if (value == null) {
        return null;
      }
      return int.tryParse(value.toString());
    }

    double? parseNullableDouble(dynamic value) {
      if (value == null) {
        return null;
      }
      return double.tryParse(value.toString());
    }

    return Employee(
      id: parseNullableInt(json['id']) ?? 0,
      branchId: json['branchId']?.toString() ?? '',
      branchTableId: parseNullableInt(json['branchTableId']),
      branchName: json['branchName']?.toString() ?? '',
      branchLatitude: parseNullableDouble(json['branchLatitude']),
      branchLongitude: parseNullableDouble(json['branchLongitude']),
      empId: json['empId']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Employee',
      contact: json['contact']?.toString() ?? '',
      mailId: json['mailId']?.toString() ?? '',
      address: json['address']?.toString() ?? '',
      dateOfBirth:
          json['dateOfBirth']?.toString() ??
          json['date_of_birth']?.toString() ??
          json['dob']?.toString() ??
          '',
      gender: json['gender']?.toString() ?? '',
      maritalStatus:
          json['maritalStatus']?.toString() ??
          json['marital_status']?.toString() ??
          '',
      aadhaarNumber:
          json['aadhaarNumber']?.toString() ??
          json['aadhaar_number']?.toString() ??
          json['aadhaarNo']?.toString() ??
          '',
      panNumber:
          json['panNumber']?.toString() ??
          json['pan_number']?.toString() ??
          json['panNo']?.toString() ??
          '',
      location: json['location']?.toString() ?? '',
      designation: json['designation']?.toString() ?? '',
      photo: json['photo']?.toString() ?? '',
      photoUrl: json['photoUrl']?.toString() ?? '',
      rating: parseNullableInt(json['rating']) ?? 0,
      status: json['status']?.toString() ?? 'Inactive',
      isOutsourced: _parseBool(json['isOutsourced']),
      outsourceLocations: (json['outsourceLocations'] is List)
          ? (json['outsourceLocations'] as List)
                .whereType<Map>()
                .map(
                  (item) => OutsourceLocation.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList()
          : const <OutsourceLocation>[],
      isNightShift: _parseBool(json['isNightShift']),
      shiftTiming: json['shiftTiming']?.toString() ?? '',
      salary: parseNullableInt(json['salary']),
      advance: parseNullableInt(json['advance']),
      pf: parseNullableInt(json['pf']),
      bankDetails: EmployeeBankDetails.fromJson(
        json['bankDetails'] is Map<String, dynamic>
            ? json['bankDetails'] as Map<String, dynamic>
            : json['bankDetails'] is Map
            ? Map<String, dynamic>.from(json['bankDetails'] as Map)
            : const <String, dynamic>{},
      ),
      isBranchOpeningAssigned: _parseBool(json['isBranchOpeningAssigned']),
      isBranchOpeningEmployee: _parseBool(json['isBranchOpeningEmployee']),
      branchOpeningHasDoorKey: _parseBool(json['branchOpeningHasDoorKey']),
      branchOpeningHasLockerKey: _parseBool(json['branchOpeningHasLockerKey']),
      branchOpeningTime: json['branchOpeningTime']?.toString() ?? '',
      branchOpeningAdminPhone:
          json['branchOpeningAdminPhone']?.toString() ?? '',
      branchOpeningStatus: json['branchOpeningStatus']?.toString() ?? '',
      branchOpeningOpenedAt: json['branchOpeningOpenedAt']?.toString() ?? '',
      branchOpeningOpenedByLabel:
          json['branchOpeningOpenedByLabel']?.toString() ?? '',
      branchOpeningClosedAt: json['branchOpeningClosedAt']?.toString() ?? '',
      branchOpeningClosedByLabel:
          json['branchOpeningClosedByLabel']?.toString() ?? '',
      branchOpeningCanMarkOpened: _parseBool(
        json['branchOpeningCanMarkOpened'],
      ),
      branchOpeningCanMarkClosed: _parseBool(
        json['branchOpeningCanMarkClosed'],
      ),
      branchOpeningReminderStartMinutes:
          parseNullableInt(json['branchOpeningReminderStartMinutes']) ?? 120,
      branchOpeningReminderIntervalMinutes:
          parseNullableInt(json['branchOpeningReminderIntervalMinutes']) ?? 15,
      branchOpeningNotificationsManagedByServer: _parseBool(
        json['branchOpeningNotificationsManagedByServer'],
      ),
    );
  }

  Employee copyWith({
    int? id,
    String? branchId,
    int? branchTableId,
    String? branchName,
    double? branchLatitude,
    double? branchLongitude,
    String? empId,
    String? name,
    String? contact,
    String? mailId,
    String? address,
    String? dateOfBirth,
    String? gender,
    String? maritalStatus,
    String? aadhaarNumber,
    String? panNumber,
    String? location,
    String? designation,
    String? photo,
    String? photoUrl,
    int? rating,
    String? status,
    bool? isOutsourced,
    List<OutsourceLocation>? outsourceLocations,
    bool? isNightShift,
    String? shiftTiming,
    int? salary,
    int? advance,
    int? pf,
    EmployeeBankDetails? bankDetails,
    bool? isBranchOpeningAssigned,
    bool? isBranchOpeningEmployee,
    bool? branchOpeningHasDoorKey,
    bool? branchOpeningHasLockerKey,
    String? branchOpeningTime,
    String? branchOpeningAdminPhone,
    String? branchOpeningStatus,
    String? branchOpeningOpenedAt,
    String? branchOpeningOpenedByLabel,
    String? branchOpeningClosedAt,
    String? branchOpeningClosedByLabel,
    bool? branchOpeningCanMarkOpened,
    bool? branchOpeningCanMarkClosed,
    int? branchOpeningReminderStartMinutes,
    int? branchOpeningReminderIntervalMinutes,
    bool? branchOpeningNotificationsManagedByServer,
  }) {
    return Employee(
      id: id ?? this.id,
      branchId: branchId ?? this.branchId,
      branchTableId: branchTableId ?? this.branchTableId,
      branchName: branchName ?? this.branchName,
      branchLatitude: branchLatitude ?? this.branchLatitude,
      branchLongitude: branchLongitude ?? this.branchLongitude,
      empId: empId ?? this.empId,
      name: name ?? this.name,
      contact: contact ?? this.contact,
      mailId: mailId ?? this.mailId,
      address: address ?? this.address,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      gender: gender ?? this.gender,
      maritalStatus: maritalStatus ?? this.maritalStatus,
      aadhaarNumber: aadhaarNumber ?? this.aadhaarNumber,
      panNumber: panNumber ?? this.panNumber,
      location: location ?? this.location,
      designation: designation ?? this.designation,
      photo: photo ?? this.photo,
      photoUrl: photoUrl ?? this.photoUrl,
      rating: rating ?? this.rating,
      status: status ?? this.status,
      isOutsourced: isOutsourced ?? this.isOutsourced,
      outsourceLocations: outsourceLocations ?? this.outsourceLocations,
      isNightShift: isNightShift ?? this.isNightShift,
      shiftTiming: shiftTiming ?? this.shiftTiming,
      salary: salary ?? this.salary,
      advance: advance ?? this.advance,
      pf: pf ?? this.pf,
      bankDetails: bankDetails ?? this.bankDetails,
      isBranchOpeningAssigned:
          isBranchOpeningAssigned ?? this.isBranchOpeningAssigned,
      isBranchOpeningEmployee:
          isBranchOpeningEmployee ?? this.isBranchOpeningEmployee,
      branchOpeningHasDoorKey:
          branchOpeningHasDoorKey ?? this.branchOpeningHasDoorKey,
      branchOpeningHasLockerKey:
          branchOpeningHasLockerKey ?? this.branchOpeningHasLockerKey,
      branchOpeningTime: branchOpeningTime ?? this.branchOpeningTime,
      branchOpeningAdminPhone:
          branchOpeningAdminPhone ?? this.branchOpeningAdminPhone,
      branchOpeningStatus: branchOpeningStatus ?? this.branchOpeningStatus,
      branchOpeningOpenedAt:
          branchOpeningOpenedAt ?? this.branchOpeningOpenedAt,
      branchOpeningOpenedByLabel:
          branchOpeningOpenedByLabel ?? this.branchOpeningOpenedByLabel,
      branchOpeningClosedAt:
          branchOpeningClosedAt ?? this.branchOpeningClosedAt,
      branchOpeningClosedByLabel:
          branchOpeningClosedByLabel ?? this.branchOpeningClosedByLabel,
      branchOpeningCanMarkOpened:
          branchOpeningCanMarkOpened ?? this.branchOpeningCanMarkOpened,
      branchOpeningCanMarkClosed:
          branchOpeningCanMarkClosed ?? this.branchOpeningCanMarkClosed,
      branchOpeningReminderStartMinutes:
          branchOpeningReminderStartMinutes ??
          this.branchOpeningReminderStartMinutes,
      branchOpeningReminderIntervalMinutes:
          branchOpeningReminderIntervalMinutes ??
          this.branchOpeningReminderIntervalMinutes,
      branchOpeningNotificationsManagedByServer:
          branchOpeningNotificationsManagedByServer ??
          this.branchOpeningNotificationsManagedByServer,
    );
  }
}

class IdCardSubmission {
  const IdCardSubmission({
    required this.empId,
    required this.fullName,
    required this.designation,
    required this.dateOfBirth,
    required this.bloodGroup,
    required this.phone,
    required this.emergencyContact,
    required this.homeAddress,
    required this.photoUrl,
    required this.status,
  });

  final String empId;
  final String fullName;
  final String designation;
  final String dateOfBirth;
  final String bloodGroup;
  final String phone;
  final String emergencyContact;
  final String homeAddress;
  final String photoUrl;
  final String status;

  factory IdCardSubmission.fromJson(Map<String, dynamic> json) =>
      IdCardSubmission(
        empId: json['empId']?.toString() ?? '',
        fullName: json['fullName']?.toString() ?? '',
        designation: json['designation']?.toString() ?? '',
        dateOfBirth: json['dateOfBirth']?.toString() ?? '',
        bloodGroup: json['bloodGroup']?.toString() ?? '',
        phone: json['phone']?.toString() ?? '',
        emergencyContact: json['emergencyContact']?.toString() ?? '',
        homeAddress: json['homeAddress']?.toString() ?? '',
        photoUrl: json['photoUrl']?.toString() ?? '',
        status: json['status']?.toString() ?? 'pending',
      );
}

class IdCardAccess {
  const IdCardAccess({required this.enabled, required this.submission});

  final bool enabled;
  final IdCardSubmission? submission;
}

class OutsourceLocation {
  const OutsourceLocation({
    required this.id,
    required this.locationCode,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.addressline,
    required this.area,
    required this.city,
    required this.state,
    required this.pincode,
    required this.url,
  });

  final int id;
  final String locationCode;
  final String name;
  final double? latitude;
  final double? longitude;
  final String addressline;
  final String area;
  final String city;
  final String state;
  final String pincode;
  final String url;

  String get label {
    if (name.trim().isNotEmpty) {
      return name.trim();
    }
    if (locationCode.trim().isNotEmpty) {
      return locationCode.trim();
    }
    return 'Outsource location';
  }

  factory OutsourceLocation.fromJson(Map<String, dynamic> json) {
    int? parseNullableInt(dynamic value) {
      if (value == null) {
        return null;
      }
      return int.tryParse(value.toString());
    }

    double? parseNullableDouble(dynamic value) {
      if (value == null) {
        return null;
      }
      return double.tryParse(value.toString());
    }

    return OutsourceLocation(
      id: parseNullableInt(json['id']) ?? 0,
      locationCode:
          json['locationCode']?.toString() ??
          json['location_code']?.toString() ??
          '',
      name: json['name']?.toString() ?? '',
      latitude: parseNullableDouble(json['latitude']),
      longitude: parseNullableDouble(json['longitude']),
      addressline: json['addressline']?.toString() ?? '',
      area: json['area']?.toString() ?? '',
      city: json['city']?.toString() ?? '',
      state: json['state']?.toString() ?? '',
      pincode: json['pincode']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
    );
  }
}

class EmployeeBankDetails {
  const EmployeeBankDetails({
    required this.accountName,
    required this.bankName,
    required this.bankAccountNumber,
    required this.ifscCode,
    required this.uanNumber,
    required this.passbookDocUrl,
    required this.verificationStatus,
    required this.requestStatus,
    required this.requestNote,
    required this.adminNote,
    required this.canRequestEdit,
    required this.canEdit,
    required this.pendingAccountName,
    required this.pendingBankName,
    required this.pendingBankAccountNumber,
    required this.pendingIfscCode,
    required this.pendingUanNumber,
    required this.pendingPassbookDocUrl,
  });

  final String accountName;
  final String bankName;
  final String bankAccountNumber;
  final String ifscCode;
  final String uanNumber;
  final String passbookDocUrl;
  final String verificationStatus;
  final String requestStatus;
  final String requestNote;
  final String adminNote;
  final bool canRequestEdit;
  final bool canEdit;
  final String pendingAccountName;
  final String pendingBankName;
  final String pendingBankAccountNumber;
  final String pendingIfscCode;
  final String pendingUanNumber;
  final String pendingPassbookDocUrl;

  bool get hasCurrentDetails =>
      accountName.trim().isNotEmpty ||
      bankName.trim().isNotEmpty ||
      bankAccountNumber.trim().isNotEmpty ||
      ifscCode.trim().isNotEmpty ||
      uanNumber.trim().isNotEmpty;

  bool get hasPendingDetails =>
      pendingAccountName.trim().isNotEmpty ||
      pendingBankName.trim().isNotEmpty ||
      pendingBankAccountNumber.trim().isNotEmpty ||
      pendingIfscCode.trim().isNotEmpty ||
      pendingUanNumber.trim().isNotEmpty;

  bool get hasPassbookDocument => passbookDocUrl.trim().isNotEmpty;

  bool get hasPendingPassbookDocument =>
      pendingPassbookDocUrl.trim().isNotEmpty;

  factory EmployeeBankDetails.fromJson(Map<String, dynamic> json) {
    return EmployeeBankDetails(
      accountName: json['accountName']?.toString() ?? '',
      bankName: json['bankName']?.toString() ?? '',
      bankAccountNumber: json['bankAccountNumber']?.toString() ?? '',
      ifscCode: json['ifscCode']?.toString() ?? '',
      uanNumber: json['uanNumber']?.toString() ?? '',
      passbookDocUrl: json['passbookDocUrl']?.toString() ?? '',
      verificationStatus: json['verificationStatus']?.toString() ?? '',
      requestStatus: json['requestStatus']?.toString() ?? 'none',
      requestNote: json['requestNote']?.toString() ?? '',
      adminNote: json['adminNote']?.toString() ?? '',
      canRequestEdit: _parseBool(json['canRequestEdit']),
      canEdit: _parseBool(json['canEdit']),
      pendingAccountName: json['pendingAccountName']?.toString() ?? '',
      pendingBankName: json['pendingBankName']?.toString() ?? '',
      pendingBankAccountNumber:
          json['pendingBankAccountNumber']?.toString() ?? '',
      pendingIfscCode: json['pendingIfscCode']?.toString() ?? '',
      pendingUanNumber: json['pendingUanNumber']?.toString() ?? '',
      pendingPassbookDocUrl: json['pendingPassbookDocUrl']?.toString() ?? '',
    );
  }
}

class AttendanceRecord {
  const AttendanceRecord({
    required this.id,
    required this.empId,
    required this.branchId,
    required this.checkInBranchId,
    required this.checkOutBranchId,
    required this.photoPath,
    required this.photoUrl,
    required this.checkOutPhotoPath,
    required this.checkOutPhotoUrl,
    required this.latitude,
    required this.longitude,
    required this.checkInDate,
    required this.checkInTime,
    required this.checkOutDate,
    required this.checkOutTime,
    required this.status,
    required this.statusLabel,
    required this.isAdminOverride,
    required this.isNightShift,
    required this.isActiveSession,
  });

  final int id;
  final String empId;
  final String branchId;
  final String checkInBranchId;
  final String checkOutBranchId;
  final String photoPath;
  final String photoUrl;
  final String checkOutPhotoPath;
  final String checkOutPhotoUrl;
  final double? latitude;
  final double? longitude;
  final String checkInDate;
  final String checkInTime;
  final String? checkOutDate;
  final String? checkOutTime;
  final String status;
  final String statusLabel;
  final bool isAdminOverride;
  final bool isNightShift;
  final bool isActiveSession;

  bool get hasCheckedOut =>
      (checkOutDate ?? '').isNotEmpty && (checkOutTime ?? '').isNotEmpty;

  bool get hasPhoto => photoPath.isNotEmpty || photoUrl.isNotEmpty;

  bool get hasCheckOutPhoto =>
      checkOutPhotoPath.isNotEmpty || checkOutPhotoUrl.isNotEmpty;

  bool get isWeekOff {
    final normalizedStatus = status.trim().toLowerCase();
    final normalizedLabel = statusLabel.trim().toLowerCase();

    return normalizedStatus == 'week_off' ||
        normalizedStatus == 'weekoff' ||
        normalizedLabel == 'w/o' ||
        normalizedLabel == 'week off';
  }

  String get displayStatusLabel {
    if (isWeekOff) {
      return 'W/O';
    }

    final label = statusLabel.trim();

    if (isAdminOverride) {
      final baseLabel = label
          .replaceAll(RegExp(r'\s*\(Admin Override\)\s*'), '')
          .trim();

      return baseLabel.isNotEmpty ? 'Regularized - $baseLabel' : 'Regularized';
    }

    if (label.isNotEmpty) {
      return label;
    }

    return hasCheckedOut ? 'Completed' : 'Active';
  }

  String get resolvedPhotoUrl {
    if (photoUrl.trim().isNotEmpty) {
      return photoUrl.trim();
    }

    return _resolveAssetUrl(photoPath);
  }

  List<String> get resolvedPhotoUrls =>
      _resolveAssetUrls(photoPath: photoPath, photoUrl: photoUrl);

  List<String> get resolvedCheckOutPhotoUrls => _resolveAssetUrls(
    photoPath: checkOutPhotoPath,
    photoUrl: checkOutPhotoUrl,
  );

  Duration? get workedDuration {
    if (!hasCheckedOut) {
      return null;
    }

    final checkIn = _parseAttendanceDateTime(checkInDate, checkInTime);
    final checkOut = _parseAttendanceDateTime(
      checkOutDate ?? checkInDate,
      checkOutTime,
    );

    if (checkIn == null || checkOut == null) {
      return null;
    }

    final difference = checkOut.difference(checkIn);
    return difference.isNegative ? null : difference;
  }

  String get locationLabel {
    if (latitude == null || longitude == null) {
      return 'Location unavailable';
    }
    return '${latitude!.toStringAsFixed(6)}, ${longitude!.toStringAsFixed(6)}';
  }

  String get reportBranchLabel {
    final checkIn = checkInBranchId.trim();
    final checkOut = checkOutBranchId.trim();
    final fallback = branchId.trim();

    if (checkIn.isNotEmpty && checkOut.isNotEmpty) {
      if (checkIn == checkOut) {
        return checkIn;
      }

      return 'IN $checkIn / OUT $checkOut';
    }

    if (checkIn.isNotEmpty) {
      return checkIn;
    }

    if (checkOut.isNotEmpty) {
      return checkOut;
    }

    return fallback.isNotEmpty ? fallback : '--';
  }

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) {
    int? parseNullableInt(dynamic value) {
      if (value == null) {
        return null;
      }
      return int.tryParse(value.toString());
    }

    double? parseNullableDouble(dynamic value) {
      if (value == null) {
        return null;
      }
      return double.tryParse(value.toString());
    }

    return AttendanceRecord(
      id: parseNullableInt(json['id']) ?? 0,
      empId: json['empId']?.toString() ?? '',
      branchId:
          json['branchId']?.toString() ??
          json['checkOutBranchId']?.toString() ??
          json['checkInBranchId']?.toString() ??
          '',
      checkInBranchId: json['checkInBranchId']?.toString() ?? '',
      checkOutBranchId: json['checkOutBranchId']?.toString() ?? '',
      photoPath: json['photoPath']?.toString() ?? '',
      photoUrl: json['photoUrl']?.toString() ?? '',
      checkOutPhotoPath: json['checkOutPhotoPath']?.toString() ?? '',
      checkOutPhotoUrl: json['checkOutPhotoUrl']?.toString() ?? '',
      latitude: parseNullableDouble(json['latitude']),
      longitude: parseNullableDouble(json['longitude']),
      checkInDate: json['checkInDate']?.toString() ?? '',
      checkInTime: json['checkInTime']?.toString() ?? '',
      checkOutDate: json['checkOutDate']?.toString(),
      checkOutTime: json['checkOutTime']?.toString(),
      status: json['status']?.toString() ?? '',
      statusLabel: json['statusLabel']?.toString() ?? '',
      isAdminOverride: _parseBool(json['isAdminOverride']),
      isNightShift: _parseBool(json['isNightShift']),
      isActiveSession: _parseBool(json['isActiveSession']),
    );
  }
}

class EmployeePushNotification {
  const EmployeePushNotification({
    required this.deliveryId,
    required this.notificationId,
    required this.title,
    required this.body,
    required this.sentAt,
    required this.readAt,
  });

  final int deliveryId;
  final int notificationId;
  final String title;
  final String body;
  final String sentAt;
  final String readAt;

  bool get isRead => readAt.trim().isNotEmpty;

  factory EmployeePushNotification.fromJson(Map<String, dynamic> json) {
    return EmployeePushNotification(
      deliveryId: int.tryParse(json['deliveryId']?.toString() ?? '') ?? 0,
      notificationId:
          int.tryParse(json['notificationId']?.toString() ?? '') ?? 0,
      title: json['title']?.toString() ?? 'Attica Pagar',
      body: json['body']?.toString() ?? '',
      sentAt: json['sentAt']?.toString() ?? '',
      readAt: json['readAt']?.toString() ?? '',
    );
  }

  factory EmployeePushNotification.fromRemoteMessage(RemoteMessage message) {
    final data = message.data;
    final resolvedTitle = (data['title']?.toString() ?? '').trim();
    final resolvedBody = (data['body']?.toString() ?? '').trim();
    final fallbackTitle = (message.notification?.title ?? '').trim();

    return EmployeePushNotification(
      deliveryId: int.tryParse(data['deliveryId']?.toString() ?? '') ?? 0,
      notificationId:
          int.tryParse(data['notificationId']?.toString() ?? '') ?? 0,
      title: resolvedTitle.isNotEmpty
          ? resolvedTitle
          : (fallbackTitle.isNotEmpty ? fallbackTitle : 'Attica Pagar'),
      body: resolvedBody.isNotEmpty
          ? resolvedBody
          : (message.notification?.body ?? ''),
      sentAt:
          data['sentAt']?.toString() ??
          message.sentTime?.toIso8601String() ??
          '',
      readAt: '',
    );
  }

  EmployeePushNotification copyWith({String? readAt}) {
    return EmployeePushNotification(
      deliveryId: deliveryId,
      notificationId: notificationId,
      title: title,
      body: body,
      sentAt: sentAt,
      readAt: readAt ?? this.readAt,
    );
  }
}

class AuthResponse {
  const AuthResponse({required this.token, required this.employee});

  final String token;
  final Employee employee;

  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    return AuthResponse(
      token: json['token']?.toString() ?? '',
      employee: Employee.fromJson(json['employee'] as Map<String, dynamic>),
    );
  }
}

class AttendanceHistorySummary {
  const AttendanceHistorySummary({
    required this.totalRecords,
    required this.presentDays,
    required this.completedRecords,
    required this.activeRecords,
    required this.absentDays,
    required this.halfDays,
    required this.singlePunchDays,
  });

  final int totalRecords;
  final int presentDays;
  final int completedRecords;
  final int activeRecords;
  final int absentDays;
  final int halfDays;
  final int singlePunchDays;

  factory AttendanceHistorySummary.fromJson(Map<String, dynamic> json) {
    int parseCount(String key) =>
        int.tryParse(json[key]?.toString() ?? '') ?? 0;

    return AttendanceHistorySummary(
      totalRecords: parseCount('totalRecords'),
      presentDays: parseCount('presentDays'),
      completedRecords: parseCount('completedRecords'),
      activeRecords: parseCount('activeRecords'),
      absentDays: parseCount('absentDays'),
      halfDays: parseCount('halfDays'),
      singlePunchDays: parseCount('singlePunchDays'),
    );
  }
}

class AttendanceHistoryResponse {
  const AttendanceHistoryResponse({
    required this.records,
    required this.summary,
    required this.month,
  });

  final List<AttendanceRecord> records;
  final AttendanceHistorySummary summary;
  final String? month;

  factory AttendanceHistoryResponse.fromJson(Map<String, dynamic> json) {
    final attendance = json['attendance'];
    final summary = json['summary'];

    return AttendanceHistoryResponse(
      records: attendance is List
          ? attendance
                .whereType<Map>()
                .map(
                  (item) => AttendanceRecord.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList()
          : const <AttendanceRecord>[],
      summary: summary is Map
          ? AttendanceHistorySummary.fromJson(
              Map<String, dynamic>.from(summary),
            )
          : const AttendanceHistorySummary(
              totalRecords: 0,
              presentDays: 0,
              completedRecords: 0,
              activeRecords: 0,
              absentDays: 0,
              halfDays: 0,
              singlePunchDays: 0,
            ),
      month: json['month']?.toString(),
    );
  }
}

class LeaveRequestRecord {
  const LeaveRequestRecord({
    required this.id,
    required this.leaveDate,
    required this.reason,
    required this.status,
    required this.appliedAt,
  });

  final int id;
  final String leaveDate;
  final String reason;
  final String status;
  final String appliedAt;

  factory LeaveRequestRecord.fromJson(Map<String, dynamic> json) {
    int parseInt(dynamic value) => int.tryParse(value?.toString() ?? '') ?? 0;

    return LeaveRequestRecord(
      id: parseInt(json['id']),
      leaveDate: json['leaveDate']?.toString() ?? '',
      reason: json['reason']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      appliedAt: json['appliedAt']?.toString() ?? '',
    );
  }
}

class AdvanceRequestRecord {
  const AdvanceRequestRecord({
    required this.id,
    required this.requestDate,
    required this.amount,
    required this.requestNote,
    required this.status,
    required this.adminNote,
    required this.verifiedAt,
    required this.rejectedAt,
    required this.createdAt,
  });

  final int id;
  final String requestDate;
  final double amount;
  final String requestNote;
  final String status;
  final String adminNote;
  final String verifiedAt;
  final String rejectedAt;
  final String createdAt;

  factory AdvanceRequestRecord.fromJson(Map<String, dynamic> json) {
    int parseInt(dynamic value) => int.tryParse(value?.toString() ?? '') ?? 0;
    double parseDouble(dynamic value) =>
        double.tryParse(value?.toString() ?? '') ?? 0;

    return AdvanceRequestRecord(
      id: parseInt(json['id']),
      requestDate: json['requestDate']?.toString() ?? '',
      amount: parseDouble(json['amount']),
      requestNote: json['requestNote']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      adminNote: json['adminNote']?.toString() ?? '',
      verifiedAt: json['verifiedAt']?.toString() ?? '',
      rejectedAt: json['rejectedAt']?.toString() ?? '',
      createdAt: json['createdAt']?.toString() ?? '',
    );
  }
}

class SiteVisitRequestRecord {
  const SiteVisitRequestRecord({
    required this.id,
    required this.visitDate,
    required this.siteLocation,
    required this.reason,
    required this.approvedBy,
    required this.photoUrl,
    required this.status,
    required this.appliedAt,
  });

  final int id;
  final String visitDate;
  final String siteLocation;
  final String reason;
  final String approvedBy;
  final String photoUrl;
  final String status;
  final String appliedAt;

  factory SiteVisitRequestRecord.fromJson(Map<String, dynamic> json) {
    int parseInt(dynamic value) => int.tryParse(value?.toString() ?? '') ?? 0;

    return SiteVisitRequestRecord(
      id: parseInt(json['id']),
      visitDate: json['visitDate']?.toString() ?? '',
      siteLocation: json['siteLocation']?.toString() ?? '',
      reason: json['reason']?.toString() ?? '',
      approvedBy: json['approvedBy']?.toString() ?? '',
      photoUrl: json['photoUrl']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      appliedAt: json['appliedAt']?.toString() ?? '',
    );
  }
}

class TeTrackerBranch {
  const TeTrackerBranch({
    required this.branchId,
    required this.branchName,
    required this.address,
    required this.city,
    required this.state,
    required this.timings,
    required this.latitude,
    required this.longitude,
    required this.mapUrl,
  });

  final String branchId;
  final String branchName;
  final String address;
  final String city;
  final String state;
  final String timings;
  final double? latitude;
  final double? longitude;
  final String mapUrl;

  String get label =>
      branchName.trim().isNotEmpty ? '$branchId - $branchName' : branchId;

  factory TeTrackerBranch.fromJson(Map<String, dynamic> json) {
    double? parseNullableDouble(dynamic value) {
      if (value == null) {
        return null;
      }

      return double.tryParse(value.toString());
    }

    return TeTrackerBranch(
      branchId: json['branchId']?.toString() ?? '',
      branchName: json['branchName']?.toString() ?? '',
      address: json['address']?.toString() ?? '',
      city: json['city']?.toString() ?? '',
      state: json['state']?.toString() ?? '',
      timings: json['timings']?.toString() ?? '',
      latitude: parseNullableDouble(json['latitude']),
      longitude: parseNullableDouble(json['longitude']),
      mapUrl: json['mapUrl']?.toString() ?? '',
    );
  }
}

class TeTrackerVisitRecord {
  const TeTrackerVisitRecord({
    required this.id,
    required this.sequence,
    required this.branchId,
    required this.branchName,
    required this.visitDate,
    required this.visitTime,
    required this.photoUrl,
    required this.capturedLatitude,
    required this.capturedLongitude,
    required this.branchLatitude,
    required this.branchLongitude,
    required this.distanceFromBranchMeters,
    required this.distanceFromBranchLabel,
    required this.distanceFromPreviousMeters,
    required this.distanceFromPreviousLabel,
    required this.cumulativeDistanceMeters,
    required this.cumulativeDistanceLabel,
  });

  final int id;
  final int sequence;
  final String branchId;
  final String branchName;
  final String visitDate;
  final String visitTime;
  final String photoUrl;
  final double? capturedLatitude;
  final double? capturedLongitude;
  final double? branchLatitude;
  final double? branchLongitude;
  final double? distanceFromBranchMeters;
  final String distanceFromBranchLabel;
  final double? distanceFromPreviousMeters;
  final String distanceFromPreviousLabel;
  final double cumulativeDistanceMeters;
  final String cumulativeDistanceLabel;

  String get branchLabel =>
      branchName.trim().isNotEmpty ? '$branchId - $branchName' : branchId;

  factory TeTrackerVisitRecord.fromJson(Map<String, dynamic> json) {
    int parseInt(dynamic value) => int.tryParse(value?.toString() ?? '') ?? 0;

    double? parseNullableDouble(dynamic value) {
      if (value == null) {
        return null;
      }

      return double.tryParse(value.toString());
    }

    return TeTrackerVisitRecord(
      id: parseInt(json['id']),
      sequence: parseInt(json['sequence']),
      branchId: json['branchId']?.toString() ?? '',
      branchName: json['branchName']?.toString() ?? '',
      visitDate: json['visitDate']?.toString() ?? '',
      visitTime: json['visitTime']?.toString() ?? '',
      photoUrl: json['photoUrl']?.toString() ?? '',
      capturedLatitude: parseNullableDouble(json['capturedLatitude']),
      capturedLongitude: parseNullableDouble(json['capturedLongitude']),
      branchLatitude: parseNullableDouble(json['branchLatitude']),
      branchLongitude: parseNullableDouble(json['branchLongitude']),
      distanceFromBranchMeters: parseNullableDouble(
        json['distanceFromBranchMeters'],
      ),
      distanceFromBranchLabel:
          json['distanceFromBranchLabel']?.toString() ?? '--',
      distanceFromPreviousMeters: parseNullableDouble(
        json['distanceFromPreviousMeters'],
      ),
      distanceFromPreviousLabel:
          json['distanceFromPreviousLabel']?.toString() ?? 'Start',
      cumulativeDistanceMeters:
          parseNullableDouble(json['cumulativeDistanceMeters']) ?? 0,
      cumulativeDistanceLabel:
          json['cumulativeDistanceLabel']?.toString() ?? '0 m',
    );
  }
}

class TeTrackerHistorySummary {
  const TeTrackerHistorySummary({
    required this.totalVisits,
    required this.uniqueBranches,
    required this.totalDistanceMeters,
    required this.totalDistanceLabel,
    required this.startBranchLabel,
    required this.endBranchLabel,
  });

  final int totalVisits;
  final int uniqueBranches;
  final double totalDistanceMeters;
  final String totalDistanceLabel;
  final String startBranchLabel;
  final String endBranchLabel;

  factory TeTrackerHistorySummary.fromJson(Map<String, dynamic> json) {
    int parseInt(dynamic value) => int.tryParse(value?.toString() ?? '') ?? 0;
    double parseDouble(dynamic value) =>
        double.tryParse(value?.toString() ?? '') ?? 0;

    return TeTrackerHistorySummary(
      totalVisits: parseInt(json['totalVisits']),
      uniqueBranches: parseInt(json['uniqueBranches']),
      totalDistanceMeters: parseDouble(json['totalDistanceMeters']),
      totalDistanceLabel: json['totalDistanceLabel']?.toString() ?? '0 m',
      startBranchLabel: json['startBranchLabel']?.toString() ?? 'No visits',
      endBranchLabel: json['endBranchLabel']?.toString() ?? 'No visits',
    );
  }
}

class TeTrackerHistoryResponse {
  const TeTrackerHistoryResponse({
    required this.date,
    required this.visits,
    required this.summary,
  });

  final String date;
  final List<TeTrackerVisitRecord> visits;
  final TeTrackerHistorySummary summary;

  factory TeTrackerHistoryResponse.fromJson(Map<String, dynamic> json) {
    return TeTrackerHistoryResponse(
      date: json['date']?.toString() ?? '',
      visits: json['visits'] is List
          ? (json['visits'] as List)
                .whereType<Map>()
                .map(
                  (item) => TeTrackerVisitRecord.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList()
          : const <TeTrackerVisitRecord>[],
      summary: json['summary'] is Map
          ? TeTrackerHistorySummary.fromJson(
              Map<String, dynamic>.from(json['summary'] as Map),
            )
          : const TeTrackerHistorySummary(
              totalVisits: 0,
              uniqueBranches: 0,
              totalDistanceMeters: 0,
              totalDistanceLabel: '0 m',
              startBranchLabel: 'No visits',
              endBranchLabel: 'No visits',
            ),
    );
  }
}

class SalarySummary {
  const SalarySummary({
    required this.month,
    required this.monthLabel,
    required this.salary,
    required this.salaryPerDay,
    required this.advance,
    required this.pf,
    required this.fullDays,
    required this.halfDays,
    required this.singlePunchDays,
    required this.absentDays,
    required this.sundayLoggedDays,
    required this.adminOverrideDays,
    required this.payableDays,
    required this.grossPayableSalary,
    required this.netPayableSalary,
    required this.daysElapsed,
    required this.daysInMonth,
  });

  final String month;
  final String monthLabel;
  final double salary;
  final double salaryPerDay;
  final double advance;
  final double pf;
  final int fullDays;
  final int halfDays;
  final int singlePunchDays;
  final int absentDays;
  final int sundayLoggedDays;
  final int adminOverrideDays;
  final double payableDays;
  final double grossPayableSalary;
  final double netPayableSalary;
  final int daysElapsed;
  final int daysInMonth;

  factory SalarySummary.fromJson(Map<String, dynamic> json) {
    double parseDouble(dynamic value) =>
        double.tryParse(value?.toString() ?? '') ?? 0;
    int parseInt(dynamic value) => int.tryParse(value?.toString() ?? '') ?? 0;

    return SalarySummary(
      month: json['month']?.toString() ?? '',
      monthLabel: json['monthLabel']?.toString() ?? '',
      salary: parseDouble(json['salary']),
      salaryPerDay: parseDouble(json['salaryPerDay']),
      advance: parseDouble(json['advance']),
      pf: parseDouble(json['pf']),
      fullDays: parseInt(json['fullDays']),
      halfDays: parseInt(json['halfDays']),
      singlePunchDays: parseInt(json['singlePunchDays']),
      absentDays: parseInt(json['absentDays']),
      sundayLoggedDays: parseInt(json['sundayLoggedDays']),
      adminOverrideDays: parseInt(json['adminOverrideDays']),
      payableDays: parseDouble(json['payableDays']),
      grossPayableSalary: parseDouble(json['grossPayableSalary']),
      netPayableSalary: parseDouble(json['netPayableSalary']),
      daysElapsed: parseInt(json['daysElapsed']),
      daysInMonth: parseInt(json['daysInMonth']),
    );
  }
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.packageName,
    required this.latestVersion,
    required this.latestBuildNumber,
    required this.minimumSupportedBuildNumber,
    required this.forceUpdate,
    required this.downloadUrl,
    required this.title,
    required this.message,
    required this.releaseNotes,
  });

  final String packageName;
  final String latestVersion;
  final int latestBuildNumber;
  final int minimumSupportedBuildNumber;
  final bool forceUpdate;
  final String downloadUrl;
  final String title;
  final String message;
  final List<String> releaseNotes;

  bool get hasDownloadUrl => downloadUrl.trim().isNotEmpty;

  bool requiresImmediateUpdate(int currentBuildNumber) {
    if (minimumSupportedBuildNumber > 0 &&
        currentBuildNumber < minimumSupportedBuildNumber) {
      return true;
    }

    return forceUpdate && latestBuildNumber > currentBuildNumber;
  }

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    int parseInt(dynamic value) => int.tryParse(value?.toString() ?? '') ?? 0;
    final releaseNotes = json['releaseNotes'] is List
        ? (json['releaseNotes'] as List)
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .toList()
        : const <String>[];

    return AppUpdateInfo(
      packageName: json['packageName']?.toString() ?? '',
      latestVersion: json['latestVersion']?.toString() ?? '',
      latestBuildNumber: parseInt(json['latestBuildNumber']),
      minimumSupportedBuildNumber: parseInt(
        json['minimumSupportedBuildNumber'],
      ),
      forceUpdate: _parseBool(json['forceUpdate']),
      downloadUrl: json['downloadUrl']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Update required',
      message: json['message']?.toString() ?? '',
      releaseNotes: releaseNotes,
    );
  }
}

class ApiException implements Exception {
  ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PasswordSetupRequiredException extends ApiException {
  PasswordSetupRequiredException({
    required this.branchId,
    required this.empId,
    required String message,
  }) : super(message);

  final String branchId;
  final String empId;
}

class FakeLocationIssue {
  const FakeLocationIssue({required this.message});

  final String message;

  String get actionLabel => 'Open developer settings';
}

class FakeLocationException extends ApiException {
  FakeLocationException(this.issue) : super(issue.message);

  final FakeLocationIssue issue;
}

class AttendanceStateException extends ApiException {
  AttendanceStateException(super.message, this.attendance);

  final AttendanceRecord attendance;
}

class LocationIntegrityService {
  const LocationIntegrityService._();

  static const MethodChannel _channel = MethodChannel(
    'app.abhibs.locatoremployee/location_integrity',
  );

  static Future<void> ensureTrustedPosition(
    Position position, {
    required String actionLabel,
  }) async {
    if (position.isMocked) {
      throw FakeLocationException(
        FakeLocationIssue(
          message:
              'Fake location detected. Turn off mock location before $actionLabel.',
        ),
      );
    }
  }

  static Future<void> openIssueSettings(FakeLocationIssue issue) async {
    if (!_isAndroidPlatform) {
      return;
    }

    await _channel.invokeMethod<void>('openDeveloperSettings');
  }

  static Future<void> openLocationSettings() async {
    if (_isAndroidPlatform) {
      await _channel.invokeMethod<void>('openLocationSettings');
      return;
    }

    await Geolocator.openLocationSettings();
  }

  static Future<void> openWirelessSettings() async {
    if (!_isAndroidPlatform) {
      return;
    }

    await _channel.invokeMethod<void>('openWirelessSettings');
  }
}

class AdminNotificationBackgroundService {
  AdminNotificationBackgroundService._();

  static const Duration _periodicFrequency = Duration(minutes: 15);
  static const Duration _oneOffDelay = Duration(seconds: 5);
  static const Duration _followUpDelay = Duration(seconds: 15);
  static final Constraints _networkConstraints = Constraints(
    networkType: NetworkType.connected,
  );

  static Future<void> ensureScheduled() async {
    if (!_isAndroidPlatform) {
      return;
    }

    await AndroidWorkmanagerService.initialize();
    await Workmanager().registerPeriodicTask(
      _adminNotificationBackgroundPeriodicTaskUniqueName,
      _adminNotificationBackgroundTaskName,
      frequency: _periodicFrequency,
      constraints: _networkConstraints,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
    await scheduleImmediateSync();
  }

  static Future<void> scheduleImmediateSync() async {
    await _scheduleSyncWithDelay(_oneOffDelay);
  }

  static Future<void> scheduleFollowUpSync() async {
    await _scheduleSyncWithDelay(_followUpDelay);
  }

  static Future<void> _scheduleSyncWithDelay(Duration delay) async {
    if (!_isAndroidPlatform) {
      return;
    }

    await AndroidWorkmanagerService.initialize();
    await Workmanager().registerOneOffTask(
      _adminNotificationBackgroundOneOffTaskUniqueName,
      _adminNotificationBackgroundTaskName,
      initialDelay: delay,
      constraints: _networkConstraints,
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }

  static Future<void> cancelAll() async {
    if (!_isAndroidPlatform) {
      return;
    }

    await AndroidWorkmanagerService.initialize();
    await Workmanager().cancelByUniqueName(
      _adminNotificationBackgroundPeriodicTaskUniqueName,
    );
    await Workmanager().cancelByUniqueName(
      _adminNotificationBackgroundOneOffTaskUniqueName,
    );
  }

  static Future<bool> runBackgroundSync() async {
    try {
      final token = await const EmployeeSessionStore().readToken();
      if (token == null || token.isEmpty) {
        return true;
      }

      const apiClient = EmployeeApiClient();
      final notifications = await apiClient
          .pendingNotifications(token: token)
          .timeout(const Duration(seconds: 12));

      for (final notification in notifications) {
        await AttendanceNotificationService.showAdminNotification(notification);
      }

      await _syncAttendanceLocationIfActive(apiClient, token);

      if (notifications.isNotEmpty) {
        final employee = await apiClient
            .profile(token)
            .timeout(const Duration(seconds: 12));
        await AttendanceNotificationService.syncBranchOpeningReminders(
          employee,
        );
      }

      return true;
    } catch (_) {
      return false;
    } finally {
      unawaited(scheduleFollowUpSync());
    }
  }

  static Future<void> _syncAttendanceLocationIfActive(
    EmployeeApiClient apiClient,
    String token,
  ) async {
    try {
      final attendance = await apiClient
          .latestAttendance(token)
          .timeout(const Duration(seconds: 8));

      if (attendance == null ||
          !attendance.isActiveSession ||
          attendance.hasCheckedOut) {
        return;
      }

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return;
      }

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever ||
          permission == LocationPermission.unableToDetermine) {
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 12));

      await apiClient.trackAttendanceLocation(
        token: token,
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } catch (_) {
      // Background GPS sync is best-effort and must not fail the worker.
    }
  }
}

class EmployeeSessionStore {
  const EmployeeSessionStore();

  static const _tokenKey = 'employee_portal_token';
  static const _savedBranchIdKey = 'employee_portal_saved_branch_id';
  static const _savedEmpIdKey = 'employee_portal_saved_emp_id';
  static const _savedPasswordKey = 'employee_portal_saved_password';
  static const _rememberCredentialsKey = 'employee_portal_remember_credentials';
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const Duration _secureStorageTimeout = Duration(seconds: 2);

  Future<String?> readToken() async {
    final preferences = await SharedPreferences.getInstance();
    if (kIsWeb) {
      final token = preferences.getString(_tokenKey)?.trim() ?? '';
      return token.isEmpty ? null : token;
    }

    final secureToken = await _readSecureValue(_tokenKey);
    if (secureToken != null && secureToken.trim().isNotEmpty) {
      final normalizedToken = secureToken.trim();
      final sharedToken = preferences.getString(_tokenKey)?.trim() ?? '';
      if (sharedToken != normalizedToken) {
        await preferences.setString(_tokenKey, normalizedToken);
      }
      return normalizedToken;
    }

    final legacyToken = preferences.getString(_tokenKey)?.trim() ?? '';

    if (legacyToken.isEmpty) {
      return null;
    }

    await _writeSecureValue(_tokenKey, legacyToken);
    await preferences.remove(_tokenKey);

    return legacyToken;
  }

  Future<void> writeToken(String token) async {
    final normalizedToken = token.trim();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_tokenKey, normalizedToken);
    if (kIsWeb) {
      return;
    }
    await _writeSecureValue(_tokenKey, normalizedToken);
  }

  Future<void> clearToken() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_tokenKey);
    if (kIsWeb) {
      return;
    }
    await _deleteSecureValue(_tokenKey);
  }

  Future<Map<String, String>> readSavedCredentials() async {
    final preferences = await SharedPreferences.getInstance();
    final rememberCredentials =
        preferences.getBool(_rememberCredentialsKey) ?? false;

    if (!rememberCredentials) {
      return const <String, String>{};
    }

    if (kIsWeb) {
      return <String, String>{
        'branchId': preferences.getString(_savedBranchIdKey)?.trim() ?? '',
        'empId': preferences.getString(_savedEmpIdKey)?.trim() ?? '',
        'password': preferences.getString(_savedPasswordKey) ?? '',
      };
    }

    final secureBranchId = await _readSecureValue(_savedBranchIdKey);
    final secureEmpId = await _readSecureValue(_savedEmpIdKey);
    final securePassword = await _readSecureValue(_savedPasswordKey);
    final branchId = (secureBranchId ?? '').trim();
    final empId = (secureEmpId ?? '').trim();
    final password = securePassword ?? '';

    if (branchId.isNotEmpty || empId.isNotEmpty || password.isNotEmpty) {
      return <String, String>{
        'branchId': branchId,
        'empId': empId,
        'password': password,
      };
    }

    final legacyBranchId =
        preferences.getString(_savedBranchIdKey)?.trim() ?? '';
    final legacyEmpId = preferences.getString(_savedEmpIdKey)?.trim() ?? '';
    final legacyPassword = preferences.getString(_savedPasswordKey) ?? '';

    if (legacyBranchId.isNotEmpty ||
        legacyEmpId.isNotEmpty ||
        legacyPassword.isNotEmpty) {
      await _secureStorage.write(key: _savedBranchIdKey, value: legacyBranchId);
      await _secureStorage.write(key: _savedEmpIdKey, value: legacyEmpId);
      await _secureStorage.write(key: _savedPasswordKey, value: legacyPassword);
      await preferences.remove(_savedBranchIdKey);
      await preferences.remove(_savedEmpIdKey);
      await preferences.remove(_savedPasswordKey);

      return <String, String>{
        'branchId': legacyBranchId,
        'empId': legacyEmpId,
        'password': legacyPassword,
      };
    }

    return <String, String>{'branchId': '', 'empId': '', 'password': ''};
  }

  Future<bool> readRememberCredentials() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_rememberCredentialsKey) ?? false;
  }

  Future<void> writeSavedCredentials({
    required String branchId,
    required String empId,
    required String password,
    required bool rememberCredentials,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_rememberCredentialsKey, rememberCredentials);

    if (!rememberCredentials) {
      await preferences.remove(_savedBranchIdKey);
      await preferences.remove(_savedEmpIdKey);
      await preferences.remove(_savedPasswordKey);
      if (kIsWeb) {
        return;
      }
      await _deleteSecureValue(_savedBranchIdKey);
      await _deleteSecureValue(_savedEmpIdKey);
      await _deleteSecureValue(_savedPasswordKey);
      return;
    }

    await preferences.setString(_savedBranchIdKey, branchId.trim());
    await preferences.setString(_savedEmpIdKey, empId.trim());
    await preferences.setString(_savedPasswordKey, password);
    if (kIsWeb) {
      return;
    }
    await _writeSecureValue(_savedBranchIdKey, branchId.trim());
    await _writeSecureValue(_savedEmpIdKey, empId.trim());
    await _writeSecureValue(_savedPasswordKey, password);
    await preferences.remove(_savedBranchIdKey);
    await preferences.remove(_savedEmpIdKey);
    await preferences.remove(_savedPasswordKey);
  }

  Future<void> updateSavedPasswordIfRemembered(String password) async {
    final preferences = await SharedPreferences.getInstance();
    final rememberCredentials =
        preferences.getBool(_rememberCredentialsKey) ?? false;

    if (!rememberCredentials) {
      return;
    }

    if (kIsWeb) {
      await preferences.setString(_savedPasswordKey, password);
      return;
    }

    await _writeSecureValue(_savedPasswordKey, password);
  }

  Future<String?> _readSecureValue(String key) async {
    try {
      return await _secureStorage
          .read(key: key)
          .timeout(_secureStorageTimeout, onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSecureValue(String key, String value) async {
    try {
      await _secureStorage
          .write(key: key, value: value)
          .timeout(_secureStorageTimeout);
    } catch (_) {}
  }

  Future<void> _deleteSecureValue(String key) async {
    try {
      await _secureStorage.delete(key: key).timeout(_secureStorageTimeout);
    } catch (_) {}
  }
}

class EmployeeApiClient {
  const EmployeeApiClient();

  Future<AppUpdateInfo?> appUpdate() async {
    final response = await http
        .get(
          Uri.parse('${ApiConfig.baseUrl}/app/update'),
          headers: {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 10));

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final update = payload['update'];
      if (update is Map) {
        return AppUpdateInfo.fromJson(Map<String, dynamic>.from(update));
      }

      return null;
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to check for app updates right now.',
    );
  }

  Future<AuthResponse> login({
    required String branchId,
    required String empId,
    required String password,
    String? newPassword,
    String? newPasswordConfirmation,
  }) async {
    final body = <String, String>{
      'branchId': branchId,
      'empId': empId,
      'password': password,
    };

    if ((newPassword ?? '').trim().isNotEmpty) {
      body['newPassword'] = newPassword!.trim();
      body['newPasswordConfirmation'] = (newPasswordConfirmation ?? '').trim();
    }

    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/employee/login'),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));

    return _parseAuthResponse(response);
  }

  Future<void> logout(String token) async {
    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/employee/logout'),
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    throw _buildApiException(
      _decodePayload(response),
      fallback: 'Unable to sign out right now.',
    );
  }

  Future<Employee> profile(String token) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/employee/profile'),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final employee = payload['employee'];
      if (employee is Map) {
        return Employee.fromJson(Map<String, dynamic>.from(employee));
      }
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to restore your session right now.',
    );
  }

  Future<IdCardAccess> idCardAccess(String token) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/employee/id-card'),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );
    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final submission = payload['submission'];
      return IdCardAccess(
        enabled: payload['enabled'] == true,
        submission: submission is Map
            ? IdCardSubmission.fromJson(Map<String, dynamic>.from(submission))
            : null,
      );
    }
    throw _buildApiException(payload, fallback: 'Unable to load your ID Card.');
  }

  Future<IdCardSubmission> submitIdCard({
    required String token,
    required String fullName,
    required String designation,
    required String dateOfBirth,
    required String bloodGroup,
    required String phone,
    required String emergencyContact,
    required String homeAddress,
    required XFile photo,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiConfig.baseUrl}/employee/id-card'),
    );
    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    });
    request.fields.addAll({
      'fullName': fullName,
      'designation': designation,
      'dateOfBirth': dateOfBirth,
      'bloodGroup': bloodGroup,
      'phone': phone,
      'emergencyContact': emergencyContact,
      'homeAddress': homeAddress,
    });
    request.files.add(
      http.MultipartFile.fromBytes(
        'photo',
        await photo.readAsBytes(),
        filename: photo.name,
      ),
    );
    final response = await http.Response.fromStream(await request.send());
    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final submission = payload['submission'];
      if (submission is Map) {
        return IdCardSubmission.fromJson(Map<String, dynamic>.from(submission));
      }
    }
    throw _buildApiException(
      payload,
      fallback: 'Unable to submit your ID Card.',
    );
  }

  Future<Employee> updateProfilePhoto({
    required String token,
    required File photo,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiConfig.baseUrl}/employee/profile/photo'),
    );

    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    });
    request.files.add(await http.MultipartFile.fromPath('photo', photo.path));

    final response = await http.Response.fromStream(await request.send());
    final payload = _decodePayload(response);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final employee = payload['employee'];
      if (employee is Map) {
        return Employee.fromJson(Map<String, dynamic>.from(employee));
      }
      throw ApiException('Profile photo updated, but profile data is missing.');
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to update profile photo right now.',
    );
  }

  Future<Employee> updateProfile({
    required String token,
    required String name,
    required String contact,
    required String mailId,
    required String address,
    required String dateOfBirth,
    required String gender,
    required String maritalStatus,
    required String aadhaarNumber,
    required String panNumber,
  }) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/employee/profile'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'name': name,
        'contact': contact,
        'mailId': mailId,
        'address': address,
        'dateOfBirth': dateOfBirth,
        'gender': gender,
        'maritalStatus': maritalStatus,
        'aadhaarNumber': aadhaarNumber,
        'panNumber': panNumber,
      }),
    );

    final payload = _decodePayload(response);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final employee = payload['employee'];
      if (employee is Map) {
        return Employee.fromJson(Map<String, dynamic>.from(employee));
      }
      throw ApiException('Profile updated, but profile data is missing.');
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to update profile right now.',
    );
  }

  Future<String> changePassword({
    required String token,
    required String currentPassword,
    required String newPassword,
    required String newPasswordConfirmation,
  }) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/employee/password'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'currentPassword': currentPassword,
        'newPassword': newPassword,
        'newPassword_confirmation': newPasswordConfirmation,
      }),
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload['message']?.toString() ?? 'Password updated successfully.';
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to update password right now.',
    );
  }

  Future<Employee> requestBankDetailEdit({
    required String token,
    String requestNote = '',
  }) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/employee/bank-details/request'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'request_note': requestNote}),
    );

    final payload = _decodePayload(response);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return profile(token);
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to submit the bank edit request right now.',
    );
  }

  Future<Employee> submitInitialUanNumber({
    required String token,
    required String uanNumber,
  }) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/employee/uan-number'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'uan_number': uanNumber}),
    );

    final payload = _decodePayload(response);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return profile(token);
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to save UAN number right now.',
    );
  }

  Future<Employee> updateBankDetails({
    required String token,
    required String accountName,
    required String bankName,
    required String bankAccountNumber,
    required String ifscCode,
    required String uanNumber,
    String requestNote = '',
    File? passbookDoc,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiConfig.baseUrl}/employee/bank-details'),
    );

    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    });
    request.fields.addAll({
      'account_name': accountName,
      'bank_name': bankName,
      'bank_account_number': bankAccountNumber,
      'ifsc_code': ifscCode,
      'uan_number': uanNumber,
      'request_note': requestNote,
    });

    if (passbookDoc != null) {
      request.files.add(
        await http.MultipartFile.fromPath('passbook_doc', passbookDoc.path),
      );
    }

    final response = await http.Response.fromStream(await request.send());
    final payload = _decodePayload(response);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return profile(token);
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to submit bank details right now.',
    );
  }

  Future<AttendanceRecord?> latestAttendance(String token) async {
    final response = await http
        .get(
          Uri.parse('${ApiConfig.baseUrl}/attendance/latest'),
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(const Duration(seconds: 15));

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final attendance = payload['attendance'];
      if (attendance is Map<String, dynamic>) {
        return AttendanceRecord.fromJson(attendance);
      }
      return null;
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to load attendance right now.',
    );
  }

  Future<AttendanceHistoryResponse> attendanceHistory({
    required String token,
    required String month,
  }) async {
    final response = await http.get(
      Uri.parse(
        '${ApiConfig.baseUrl}/attendance/history',
      ).replace(queryParameters: {'month': month, 'limit': '31'}),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return AttendanceHistoryResponse.fromJson(payload);
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to load attendance reports right now.',
    );
  }

  Future<void> trackAttendanceLocation({
    required String token,
    required double latitude,
    required double longitude,
  }) async {
    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/attendance/location'),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'latitude': latitude,
            'longitude': longitude,
            'recorded_at': DateTime.now().toIso8601String(),
          }),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    throw _buildApiException(
      _decodePayload(response),
      fallback: 'Unable to sync attendance location right now.',
    );
  }

  Future<SalarySummary> salarySummary({
    required String token,
    required String month,
  }) async {
    final response = await http.get(
      Uri.parse(
        '${ApiConfig.baseUrl}/salary/summary',
      ).replace(queryParameters: {'month': month}),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final summary = payload['summary'];
      if (summary is Map) {
        return SalarySummary.fromJson(Map<String, dynamic>.from(summary));
      }
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to load salary summary right now.',
    );
  }

  Future<List<AdvanceRequestRecord>> advanceRequests({
    required String token,
  }) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/salary/advance-requests'),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final advanceRequests = payload['advanceRequests'];
      if (advanceRequests is List) {
        return advanceRequests
            .whereType<Map>()
            .map(
              (item) => AdvanceRequestRecord.fromJson(
                Map<String, dynamic>.from(item),
              ),
            )
            .toList();
      }

      return const <AdvanceRequestRecord>[];
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to load advance requests right now.',
    );
  }

  Future<String> submitAdvanceRequest({
    required String token,
    required double amount,
    String requestNote = '',
  }) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/salary/advance-requests'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'amount': amount, 'request_note': requestNote}),
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload['message']?.toString() ?? 'Advance request submitted.';
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to submit advance request right now.',
    );
  }

  Future<List<LeaveRequestRecord>> leaveRequests({
    required String token,
  }) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/leaves'),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final leaveRequests = payload['leaveRequests'];
      if (leaveRequests is List) {
        return leaveRequests
            .whereType<Map>()
            .map(
              (item) =>
                  LeaveRequestRecord.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList();
      }

      return const <LeaveRequestRecord>[];
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to load leave requests right now.',
    );
  }

  Future<String> submitLeave({
    required String token,
    required DateTime leaveDate,
    required String reason,
  }) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/leaves'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'leave_date': leaveDate.toIso8601String().split('T').first,
        'reason': reason,
      }),
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload['message']?.toString() ?? 'Leave request submitted.';
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to submit leave request right now.',
    );
  }

  Future<List<SiteVisitRequestRecord>> siteVisitRequests({
    required String token,
  }) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/site-visits'),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final siteVisitRequests = payload['siteVisitRequests'];
      if (siteVisitRequests is List) {
        return siteVisitRequests
            .whereType<Map>()
            .map(
              (item) => SiteVisitRequestRecord.fromJson(
                Map<String, dynamic>.from(item),
              ),
            )
            .toList();
      }

      return const <SiteVisitRequestRecord>[];
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to load site visit requests right now.',
    );
  }

  Future<List<EmployeePushNotification>> pendingNotifications({
    required String token,
  }) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/notifications/pending'),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final notifications = payload['notifications'];
      if (notifications is List) {
        return notifications
            .whereType<Map>()
            .map(
              (item) => EmployeePushNotification.fromJson(
                Map<String, dynamic>.from(item),
              ),
            )
            .where((notification) => notification.deliveryId > 0)
            .toList();
      }

      return const <EmployeePushNotification>[];
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to load notifications right now.',
    );
  }

  Future<List<EmployeePushNotification>> notifications({
    required String token,
  }) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/notifications'),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final notifications = payload['notifications'];
      if (notifications is List) {
        return notifications
            .whereType<Map>()
            .map(
              (item) => EmployeePushNotification.fromJson(
                Map<String, dynamic>.from(item),
              ),
            )
            .where((notification) => notification.deliveryId > 0)
            .toList();
      }

      return const <EmployeePushNotification>[];
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to load notifications right now.',
    );
  }

  Future<void> registerDeviceToken({
    required String token,
    required String deviceToken,
    required String platform,
  }) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/notifications/device-token'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'token': deviceToken, 'platform': platform}),
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to register notifications on this device right now.',
    );
  }

  Future<void> removeDeviceToken({
    required String token,
    required String deviceToken,
  }) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/notifications/device-token/remove'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'token': deviceToken}),
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to unregister notifications on this device right now.',
    );
  }

  Future<void> markNotificationsRead({
    required String token,
    required List<int> deliveryIds,
  }) async {
    if (deliveryIds.isEmpty) {
      return;
    }

    await http.post(
      Uri.parse('${ApiConfig.baseUrl}/notifications/read'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'deliveryIds': deliveryIds}),
    );
  }

  Future<String> submitSiteVisit({
    required String token,
    required DateTime visitDate,
    required String siteLocation,
    required double latitude,
    required double longitude,
    required String reason,
    required String approvedBy,
    File? photo,
    Uint8List? photoBytes,
    String? photoFilename,
  }) async {
    final hasPhotoFile = photo != null;
    final hasPhotoBytes = photoBytes != null && photoBytes.isNotEmpty;
    if (!hasPhotoFile && !hasPhotoBytes) {
      throw ApiException('Capture a site visit photo first.');
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiConfig.baseUrl}/site-visits'),
    );

    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    });
    request.fields['visit_date'] = visitDate.toIso8601String().split('T').first;
    request.fields['site_location'] = siteLocation;
    request.fields['latitude'] = latitude.toString();
    request.fields['longitude'] = longitude.toString();
    request.fields['reason'] = reason;
    request.fields['approved_by'] = approvedBy;
    if (hasPhotoBytes) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'photo',
          photoBytes,
          filename: (photoFilename ?? '').trim().isEmpty
              ? 'site-visit-${DateTime.now().millisecondsSinceEpoch}.jpg'
              : photoFilename,
        ),
      );
    } else {
      request.files.add(
        await http.MultipartFile.fromPath('photo', photo!.path),
      );
    }

    final response = await http.Response.fromStream(await request.send());
    final payload = _decodePayload(response);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload['message']?.toString() ?? 'Site visit request submitted.';
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to submit site visit request right now.',
    );
  }

  Future<List<TeTrackerBranch>> teTrackerBranches({
    required String token,
  }) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/te-tracker/branches'),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final branches = payload['branches'];
      if (branches is List) {
        return branches
            .whereType<Map>()
            .map(
              (item) =>
                  TeTrackerBranch.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList();
      }

      return const <TeTrackerBranch>[];
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to load TE tracker branches right now.',
    );
  }

  Future<TeTrackerHistoryResponse> teTrackerVisits({
    required String token,
    String? date,
  }) async {
    final queryParameters = <String, String>{};
    if ((date ?? '').trim().isNotEmpty) {
      queryParameters['date'] = date!.trim();
    }

    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/te-tracker/visits').replace(
        queryParameters: queryParameters.isEmpty ? null : queryParameters,
      ),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return TeTrackerHistoryResponse.fromJson(payload);
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to load TE tracker visits right now.',
    );
  }

  Future<String> teTrackerCheckIn({
    required String token,
    required String branchId,
    required double latitude,
    required double longitude,
    required File photo,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiConfig.baseUrl}/te-tracker/check-in'),
    );

    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    });
    request.fields['branch_id'] = branchId;
    request.fields['latitude'] = latitude.toString();
    request.fields['longitude'] = longitude.toString();
    request.files.add(await http.MultipartFile.fromPath('photo', photo.path));

    final response = await http.Response.fromStream(await request.send());
    final payload = _decodePayload(response);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload['message']?.toString() ??
          'TE tracker visit recorded successfully.';
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to record the TE tracker visit right now.',
    );
  }

  Future<AttendanceRecord> checkIn({
    required String token,
    required double? latitude,
    required double? longitude,
    required AttendanceUploadPhoto photo,
    bool useLoggedInBranchOnly = false,
    Size? webViewSize,
    bool hasFinePointer = false,
    bool hasTouchInput = true,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiConfig.baseUrl}/attendance/check-in'),
    );

    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    });
    if (latitude != null && longitude != null) {
      request.fields['latitude'] = latitude.toString();
      request.fields['longitude'] = longitude.toString();
    }
    if (useLoggedInBranchOnly) {
      request.fields['attendance_mode'] = 'web_desktop';
      if (webViewSize != null) {
        request.fields['web_view_width'] = webViewSize.width.toStringAsFixed(0);
        request.fields['web_view_height'] = webViewSize.height.toStringAsFixed(
          0,
        );
      }
      request.fields['web_has_fine_pointer'] = hasFinePointer ? '1' : '0';
      request.fields['web_has_touch_input'] = hasTouchInput ? '1' : '0';
    }
    request.files.add(
      http.MultipartFile.fromBytes(
        'photo',
        photo.bytes,
        filename: photo.filename,
      ),
    );

    final response = await http.Response.fromStream(await request.send());

    return _parseAttendanceResponse(
      response,
      fallback: 'Unable to check in attendance right now.',
    );
  }

  Future<AttendanceRecord> checkOut({
    required String token,
    required double? latitude,
    required double? longitude,
    required AttendanceUploadPhoto photo,
    bool useLoggedInBranchOnly = false,
    Size? webViewSize,
    bool hasFinePointer = false,
    bool hasTouchInput = true,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiConfig.baseUrl}/attendance/check-out'),
    );

    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    });
    if (latitude != null && longitude != null) {
      request.fields['latitude'] = latitude.toString();
      request.fields['longitude'] = longitude.toString();
    }
    if (useLoggedInBranchOnly) {
      request.fields['attendance_mode'] = 'web_desktop';
      if (webViewSize != null) {
        request.fields['web_view_width'] = webViewSize.width.toStringAsFixed(0);
        request.fields['web_view_height'] = webViewSize.height.toStringAsFixed(
          0,
        );
      }
      request.fields['web_has_fine_pointer'] = hasFinePointer ? '1' : '0';
      request.fields['web_has_touch_input'] = hasTouchInput ? '1' : '0';
    }
    request.files.add(
      http.MultipartFile.fromBytes(
        'photo',
        photo.bytes,
        filename: photo.filename,
      ),
    );

    final response = await http.Response.fromStream(await request.send());

    return _parseAttendanceResponse(
      response,
      fallback: 'Unable to check out attendance right now.',
    );
  }

  Future<String> reportAttendanceFraud({
    required String token,
    required AttendanceUploadPhoto photo,
    required String source,
    required double confidence,
    required String reason,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiConfig.baseUrl}/attendance/fraud-report'),
    );

    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    });
    request.fields['fraud_type'] = 'mobile_screen';
    request.fields['source'] = source;
    request.fields['confidence'] = confidence.toStringAsFixed(2);
    request.fields['reason'] = reason;
    request.files.add(
      http.MultipartFile.fromBytes(
        'photo',
        photo.bytes,
        filename: photo.filename,
      ),
    );

    final response = await http.Response.fromStream(await request.send());
    final payload = _decodePayload(response);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload['message']?.toString() ??
          'Fraud detected and reported to Zonal.';
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to report the fraud attempt right now.',
    );
  }

  Future<String> markBranchOpened({required String token}) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/branch-opening/open'),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload['message']?.toString() ?? 'Branch marked as opened.';
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to mark the branch as opened right now.',
    );
  }

  Future<String> markBranchClosed({required String token}) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/branch-opening/close'),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );

    final payload = _decodePayload(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload['message']?.toString() ?? 'Branch marked as closed.';
    }

    throw _buildApiException(
      payload,
      fallback: 'Unable to mark the branch as closed right now.',
    );
  }

  AuthResponse _parseAuthResponse(http.Response response) {
    final payload = _decodePayload(response);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return AuthResponse.fromJson(payload);
    }

    throw _buildApiException(payload, fallback: 'Unable to sign in right now.');
  }

  AttendanceRecord _parseAttendanceResponse(
    http.Response response, {
    required String fallback,
  }) {
    final payload = _decodePayload(response);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final attendance = payload['attendance'];
      if (attendance is Map<String, dynamic>) {
        return AttendanceRecord.fromJson(attendance);
      }
      throw ApiException(fallback);
    }

    final exception = _buildApiException(payload, fallback: fallback);
    final attendance = payload['attendance'];
    if (attendance is Map<String, dynamic>) {
      throw AttendanceStateException(
        exception.message,
        AttendanceRecord.fromJson(attendance),
      );
    }

    throw exception;
  }

  Map<String, dynamic> _decodePayload(http.Response response) {
    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      return <String, dynamic>{};
    }

    return <String, dynamic>{};
  }

  ApiException _buildApiException(
    Map<String, dynamic> payload, {
    required String fallback,
  }) {
    if (_parseBool(payload['passwordSetupRequired'])) {
      return PasswordSetupRequiredException(
        branchId: payload['branchId']?.toString() ?? '',
        empId: payload['empId']?.toString() ?? '',
        message:
            payload['message']?.toString() ?? 'Set a new password to continue.',
      );
    }

    if (payload['message'] case final String message when message.isNotEmpty) {
      final normalized = message.trim().toLowerCase();
      if (normalized == 'unauthenticated.' ||
          normalized == 'unauthenticated' ||
          normalized == 'unauthorized' ||
          normalized.contains('session expired') ||
          normalized.contains('sign in again') ||
          normalized.contains('login again') ||
          normalized.contains('log in again')) {
        return ApiException('Your session expired. Please sign in again.');
      }

      return ApiException(message);
    }

    if (payload['errors'] is Map<String, dynamic>) {
      final errors = payload['errors'] as Map<String, dynamic>;
      for (final value in errors.values) {
        if (value is List && value.isNotEmpty) {
          return ApiException(value.first.toString());
        }
      }
    }

    return ApiException(fallback);
  }
}

class AttendanceUploadPhoto {
  const AttendanceUploadPhoto({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String filename;
}

class AttendanceFraudDetectionResult {
  const AttendanceFraudDetectionResult({
    required this.isFraud,
    required this.confidence,
    required this.reason,
  });

  final bool isFraud;
  final double confidence;
  final String reason;
}

class AttendanceFraudDetector {
  const AttendanceFraudDetector._();

  static Future<AttendanceFraudDetectionResult> inspect(
    AttendanceUploadPhoto photo,
  ) async {
    final decoded = img.decodeImage(photo.bytes);

    if (decoded == null || decoded.width < 80 || decoded.height < 80) {
      return const AttendanceFraudDetectionResult(
        isFraud: false,
        confidence: 0,
        reason: 'Photo could not be evaluated.',
      );
    }

    final image = img.copyResize(decoded, width: 180);
    final width = image.width;
    final height = image.height;
    final edgeWidth = (width * 0.12).clamp(8, 28).round();
    final edgeHeight = (height * 0.12).clamp(8, 28).round();
    final left = _regionStats(image, 0, 0, edgeWidth, height);
    final right = _regionStats(image, width - edgeWidth, 0, edgeWidth, height);
    final top = _regionStats(image, 0, 0, width, edgeHeight);
    final bottom = _regionStats(
      image,
      0,
      height - edgeHeight,
      width,
      edgeHeight,
    );
    final center = _regionStats(
      image,
      (width * 0.24).round(),
      (height * 0.20).round(),
      (width * 0.52).round(),
      (height * 0.60).round(),
    );
    final cornerDarkRatio = _cornerDarkRatio(image, edgeWidth, edgeHeight);
    final verticalFrameRatio = _verticalDarkFrameRatio(image);
    final sideDarkRatio = left.darkRatio > right.darkRatio
        ? left.darkRatio
        : right.darkRatio;
    final sideBrightness = left.averageLuma < right.averageLuma
        ? left.averageLuma
        : right.averageLuma;
    final borderContrast = center.averageLuma - sideBrightness;
    final horizontalFrameRatio = top.darkRatio > bottom.darkRatio
        ? top.darkRatio
        : bottom.darkRatio;
    final screenFrameScore = [
      sideDarkRatio * 0.45,
      verticalFrameRatio * 0.35,
      cornerDarkRatio * 0.12,
      horizontalFrameRatio * 0.08,
    ].fold<double>(0, (sum, value) => sum + value);
    final hasPhoneFrame =
        (sideDarkRatio >= 0.28 && borderContrast >= 18) ||
        verticalFrameRatio >= 0.055 ||
        (cornerDarkRatio >= 0.42 && horizontalFrameRatio >= 0.20);
    final hasScreenLikeSurface =
        center.averageLuma >= 72 || center.highSaturationRatio >= 0.16;
    final rawConfidence =
        (screenFrameScore +
                (borderContrast.clamp(0, 80) / 80 * 0.20) +
                (center.highSaturationRatio * 0.12))
            .clamp(0, 0.99)
            .toDouble();
    final confidence = (hasPhoneFrame && hasScreenLikeSurface)
        ? rawConfidence.clamp(0.72, 0.99).toDouble()
        : rawConfidence;
    final isFraud =
        hasPhoneFrame &&
        hasScreenLikeSurface &&
        confidence >= _attendanceFraudConfidenceThreshold;

    return AttendanceFraudDetectionResult(
      isFraud: isFraud,
      confidence: confidence,
      reason: isFraud
          ? 'Mobile screen or phone-frame pattern detected in attendance photo.'
          : 'No high-confidence mobile screen pattern detected.',
    );
  }

  static _ImageRegionStats _regionStats(
    img.Image image,
    int startX,
    int startY,
    int regionWidth,
    int regionHeight,
  ) {
    final x0 = startX.clamp(0, image.width - 1).toInt();
    final y0 = startY.clamp(0, image.height - 1).toInt();
    final endX = (startX + regionWidth).clamp(0, image.width).toInt();
    final endY = (startY + regionHeight).clamp(0, image.height).toInt();
    var count = 0;
    var darkCount = 0;
    var saturatedCount = 0;
    var lumaTotal = 0.0;

    for (var y = y0; y < endY; y++) {
      for (var x = x0; x < endX; x++) {
        final pixel = image.getPixel(x, y);
        final red = pixel.r.toDouble();
        final green = pixel.g.toDouble();
        final blue = pixel.b.toDouble();
        final luma = _luma(red, green, blue);
        lumaTotal += luma;
        count++;

        if (luma < 45) {
          darkCount++;
        }

        if (_saturation(red, green, blue) > 0.45) {
          saturatedCount++;
        }
      }
    }

    if (count == 0) {
      return const _ImageRegionStats(
        darkRatio: 0,
        highSaturationRatio: 0,
        averageLuma: 0,
      );
    }

    return _ImageRegionStats(
      darkRatio: darkCount / count,
      highSaturationRatio: saturatedCount / count,
      averageLuma: lumaTotal / count,
    );
  }

  static double _verticalDarkFrameRatio(img.Image image) {
    final scanWidth = (image.width * 0.18).round();
    var frameColumns = 0;

    for (final range in [
      [0, scanWidth],
      [image.width - scanWidth, image.width],
    ]) {
      for (var x = range[0]; x < range[1]; x++) {
        var darkRows = 0;

        for (var y = 0; y < image.height; y++) {
          final pixel = image.getPixel(x, y);
          if (_luma(
                pixel.r.toDouble(),
                pixel.g.toDouble(),
                pixel.b.toDouble(),
              ) <
              38) {
            darkRows++;
          }
        }

        if (darkRows / image.height >= 0.52) {
          frameColumns++;
        }
      }
    }

    return frameColumns / image.width;
  }

  static double _cornerDarkRatio(
    img.Image image,
    int cornerWidth,
    int cornerHeight,
  ) {
    final corners = [
      _regionStats(image, 0, 0, cornerWidth, cornerHeight),
      _regionStats(
        image,
        image.width - cornerWidth,
        0,
        cornerWidth,
        cornerHeight,
      ),
      _regionStats(
        image,
        0,
        image.height - cornerHeight,
        cornerWidth,
        cornerHeight,
      ),
      _regionStats(
        image,
        image.width - cornerWidth,
        image.height - cornerHeight,
        cornerWidth,
        cornerHeight,
      ),
    ];

    return corners
        .map((stats) => stats.darkRatio)
        .fold<double>(
          0,
          (maxValue, value) => value > maxValue ? value : maxValue,
        );
  }

  static double _luma(double red, double green, double blue) {
    return (red * 0.299) + (green * 0.587) + (blue * 0.114);
  }

  static double _saturation(double red, double green, double blue) {
    final maxChannel = [red, green, blue].reduce((a, b) => a > b ? a : b);
    final minChannel = [red, green, blue].reduce((a, b) => a < b ? a : b);

    if (maxChannel <= 0) {
      return 0;
    }

    return (maxChannel - minChannel) / maxChannel;
  }
}

class _ImageRegionStats {
  const _ImageRegionStats({
    required this.darkRatio,
    required this.highSaturationRatio,
    required this.averageLuma,
  });

  final double darkRatio;
  final double highSaturationRatio;
  final double averageLuma;
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final EmployeeApiClient _apiClient = const EmployeeApiClient();
  final EmployeeSessionStore _sessionStore = const EmployeeSessionStore();
  static const Duration _sessionRestoreTimeout = Duration(seconds: 5);
  static const Duration _appUpdateRecheckInterval = Duration(minutes: 15);

  String? _token;
  Employee? _employee;
  bool _isRestoringSession = true;
  bool _isCheckingAppUpdate = true;
  bool _isOpeningAppUpdate = false;
  StreamSubscription<RemoteMessage>? _pushMessageSubscription;
  StreamSubscription<RemoteMessage>? _pushMessageOpenedSubscription;
  StreamSubscription<String>? _pushTokenRefreshSubscription;
  StreamSubscription<Position>? _attendanceLocationSubscription;
  List<EmployeePushNotification> _adminNotifications =
      const <EmployeePushNotification>[];
  AppUpdateInfo? _requiredAppUpdate;
  String? _appUpdateErrorText;
  PackageInfo? _packageInfo;
  DateTime? _lastAppUpdateCheckAt;
  DateTime? _lastAttendanceLocationPingAt;
  bool _isSendingAttendanceLocation = false;
  bool _isHandlingSessionExpiry = false;

  int get _unreadAdminNotificationCount =>
      _adminNotifications.where((notification) => !notification.isRead).length;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_bootstrapApp());
  }

  Future<void> _bootstrapApp() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      return;
    }

    unawaited(AttendanceNotificationService.initialize());
    try {
      await _initializePushMessaging().timeout(const Duration(seconds: 8));
    } catch (_) {
      // Firebase/Google Play services can be unavailable on a fresh emulator.
      // Push setup must not prevent the hosted API version check or login.
    }
    await _checkForAppUpdate();

    if (!mounted || _requiredAppUpdate != null) {
      if (mounted) {
        setState(() {
          _isRestoringSession = false;
        });
      }
      return;
    }

    await _restoreSession();
  }

  Future<void> _initializePushMessaging() async {
    await PushMessagingService.initialize();
    if (!PushMessagingService.isAvailable) {
      return;
    }

    await PushMessagingService.requestPermission();
    await PushMessagingService.configureForegroundPresentation();

    _pushMessageSubscription = PushMessagingService.onMessage.listen((message) {
      unawaited(
        _handleIncomingPushMessage(message, showLocalNotification: true),
      );
    });
    _pushMessageOpenedSubscription = PushMessagingService.onMessageOpenedApp
        .listen((message) {
          unawaited(_handleIncomingPushMessage(message));
        });
    _pushTokenRefreshSubscription = PushMessagingService.onTokenRefresh.listen((
      deviceToken,
    ) {
      final authToken = _token;
      if (authToken == null || authToken.isEmpty) {
        return;
      }

      unawaited(
        _apiClient.registerDeviceToken(
          token: authToken,
          deviceToken: deviceToken,
          platform: PushMessagingService.platform,
        ),
      );
    });

    final initialMessage = await PushMessagingService.initialMessage();
    if (initialMessage != null) {
      unawaited(_handleIncomingPushMessage(initialMessage));
    }

    final authToken = _token;
    if (authToken != null && authToken.isNotEmpty) {
      unawaited(_syncCurrentPushToken(authToken));
    }
  }

  Future<void> _checkForAppUpdate() async {
    if (!_isAndroidPlatform) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isCheckingAppUpdate = false;
      });
      return;
    }

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final updateInfo = await _apiClient.appUpdate();
      final currentBuildNumber =
          int.tryParse(packageInfo.buildNumber.trim()) ?? 0;
      final requiredUpdate =
          updateInfo != null &&
              updateInfo.requiresImmediateUpdate(currentBuildNumber)
          ? updateInfo
          : null;

      if (!mounted) {
        return;
      }

      setState(() {
        _packageInfo = packageInfo;
        _requiredAppUpdate = requiredUpdate;
      });
    } catch (_) {
      // Update checks must never block access when the endpoint is unavailable.
    } finally {
      _lastAppUpdateCheckAt = DateTime.now();
      if (mounted) {
        setState(() {
          _isCheckingAppUpdate = false;
        });
      }
    }
  }

  bool get _shouldRecheckAppUpdate {
    if (_lastAppUpdateCheckAt == null) {
      return true;
    }

    return DateTime.now().difference(_lastAppUpdateCheckAt!) >=
        _appUpdateRecheckInterval;
  }

  Future<void> _openRequiredUpdate() async {
    final update = _requiredAppUpdate;

    if (update == null) {
      return;
    }

    final updateUrl = update.downloadUrl.trim();
    final uri = Uri.tryParse(updateUrl);

    if (updateUrl.isEmpty || uri == null) {
      setState(() {
        _appUpdateErrorText =
            'The update link is not configured. Contact your administrator.';
      });
      return;
    }

    setState(() {
      _isOpeningAppUpdate = true;
      _appUpdateErrorText = null;
    });

    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (!launched && mounted) {
        setState(() {
          _appUpdateErrorText =
              'Unable to open the update link. Contact your administrator.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _appUpdateErrorText =
              'Unable to open the update link. Contact your administrator.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isOpeningAppUpdate = false;
        });
      }
    }
  }

  Future<void> _restoreSession() async {
    try {
      await _clearSessionForFreshLoginLaunch();

      final token = await _sessionStore.readToken().timeout(
        _sessionRestoreTimeout,
        onTimeout: () => null,
      );

      if (token == null || token.isEmpty) {
        await _clearLocalSessionState();
        if (!mounted) {
          return;
        }
        setState(() {
          _isRestoringSession = false;
        });
        return;
      }

      unawaited(AdminNotificationBackgroundService.ensureScheduled());

      final hasInternet = await _hasInternetConnection().timeout(
        const Duration(seconds: 3),
        onTimeout: () => true,
      );
      if (!hasInternet) {
        if (!mounted) {
          return;
        }
        setState(() {
          _isRestoringSession = false;
        });
        return;
      }

      final employee = await _apiClient
          .profile(token)
          .timeout(const Duration(seconds: 10));
      if (!mounted) {
        return;
      }
      setState(() {
        _token = token;
        _employee = employee;
        _isRestoringSession = false;
      });
      await AttendanceNotificationService.syncBranchOpeningReminders(employee);
      unawaited(_syncCurrentPushToken(token));
      unawaited(_syncAttendanceForNotifications(token));
      unawaited(_refreshAdminNotifications(token));
    } catch (_) {
      await _handleRestoreSessionFailure();
    }
  }

  Future<void> _clearSessionForFreshLoginLaunch() async {
    if (!kIsWeb) {
      return;
    }

    final forceFreshLogin =
        {
          Uri.base.queryParameters['fresh_login'],
          Uri.base.queryParameters['force_login'],
          Uri.base.queryParameters['logout'],
        }.any((value) {
          final normalized = value?.trim().toLowerCase() ?? '';

          return normalized == '1' ||
              normalized == 'true' ||
              normalized == 'yes';
        });

    if (!forceFreshLogin) {
      return;
    }

    web_desktop_attendance.clearFreshLoginBrowserStorage();
    await _sessionStore.clearToken().timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    );
    await _clearLocalSessionState();
  }

  Future<void> _handleRestoreSessionFailure() async {
    final stillHasInternet = await _hasInternetConnection().timeout(
      const Duration(seconds: 4),
      onTimeout: () => false,
    );
    if (stillHasInternet) {
      await _sessionStore.clearToken().timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
      await _clearLocalSessionState();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      if (stillHasInternet) {
        _token = null;
        _employee = null;
      }
      _isRestoringSession = false;
    });
  }

  Future<void> _clearLocalSessionState() async {
    try {
      await AdminNotificationBackgroundService.cancelAll().timeout(
        const Duration(seconds: 2),
      );
    } catch (_) {}

    try {
      await AttendanceNotificationService.clearForLogout().timeout(
        const Duration(seconds: 2),
      );
    } catch (_) {}
  }

  Future<void> _handleLogin(
    String branchId,
    String empId, {
    required String password,
    String? newPassword,
    String? newPasswordConfirmation,
    required bool rememberCredentials,
  }) async {
    final auth = await _apiClient.login(
      branchId: branchId,
      empId: empId,
      password: password,
      newPassword: newPassword,
      newPasswordConfirmation: newPasswordConfirmation,
    );
    await _sessionStore.writeToken(auth.token);
    await _sessionStore.writeSavedCredentials(
      branchId: branchId,
      empId: empId,
      password: (newPassword ?? password),
      rememberCredentials: rememberCredentials,
    );
    setState(() {
      _token = auth.token;
      _employee = auth.employee;
      _adminNotifications = const <EmployeePushNotification>[];
    });
    try {
      await _syncAttendanceForNotifications(auth.token);
    } catch (_) {
      // Login should not fail if attendance sync is temporarily unavailable.
    }
    unawaited(AdminNotificationBackgroundService.ensureScheduled());
    await AttendanceNotificationService.syncBranchOpeningReminders(
      auth.employee,
    );
    unawaited(_syncCurrentPushToken(auth.token));
    unawaited(_refreshAdminNotifications(auth.token));
  }

  Future<void> _syncAttendanceForNotifications(String token) async {
    try {
      final attendance = await _apiClient
          .latestAttendance(token)
          .timeout(const Duration(seconds: 6));
      if (_employee?.canMarkAttendance != true) {
        await AttendanceNotificationService.disableAttendanceReminders();
        await _syncAttendanceLocationTracking(null);
        return;
      }

      await AttendanceNotificationService.syncWithAttendance(attendance);
      await _syncAttendanceLocationTracking(attendance);
    } catch (_) {
      // Attendance notification sync must never block app navigation.
    }
  }

  Future<void> _syncAttendanceLocationTracking(
    AttendanceRecord? attendance,
  ) async {
    final token = _token;
    if (token == null ||
        token.isEmpty ||
        _employee?.canUseMobileAttendance != true ||
        attendance == null) {
      await _stopAttendanceLocationTracking();
      return;
    }

    if (attendance.isActiveSession && !attendance.hasCheckedOut) {
      await _startAttendanceLocationTracking(token);
    } else {
      await _stopAttendanceLocationTracking();
    }
  }

  Future<void> _startAttendanceLocationTracking(String token) async {
    if (_attendanceLocationSubscription != null) {
      return;
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return;
      }

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever ||
          permission == LocationPermission.unableToDetermine) {
        return;
      }

      _attendanceLocationSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 100,
            ),
          ).listen((position) {
            unawaited(_sendAttendanceLocationPing(token, position));
          });

      final currentPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      unawaited(_sendAttendanceLocationPing(token, currentPosition));
    } catch (_) {
      await _stopAttendanceLocationTracking();
    }
  }

  Future<void> _stopAttendanceLocationTracking() async {
    await _attendanceLocationSubscription?.cancel();
    _attendanceLocationSubscription = null;
    _lastAttendanceLocationPingAt = null;
    _isSendingAttendanceLocation = false;
  }

  Future<void> _sendAttendanceLocationPing(
    String token,
    Position position,
  ) async {
    if (_isSendingAttendanceLocation) {
      return;
    }

    final lastPingAt = _lastAttendanceLocationPingAt;
    if (lastPingAt != null &&
        DateTime.now().difference(lastPingAt) < const Duration(minutes: 2)) {
      return;
    }

    _isSendingAttendanceLocation = true;
    try {
      await _apiClient.trackAttendanceLocation(
        token: token,
        latitude: position.latitude,
        longitude: position.longitude,
      );
      _lastAttendanceLocationPingAt = DateTime.now();
    } on ApiException catch (error) {
      if (error.message.toLowerCase().contains('no active attendance')) {
        await _stopAttendanceLocationTracking();
      }
    } catch (_) {
      // Location tracking should never interrupt the employee app.
    } finally {
      _isSendingAttendanceLocation = false;
    }
  }

  Future<void> _handleLogout() async {
    final token = _token;
    if (mounted) {
      setState(() {
        _token = null;
        _employee = null;
        _adminNotifications = const <EmployeePushNotification>[];
      });
    }

    try {
      await AdminNotificationBackgroundService.cancelAll();
      await _stopAttendanceLocationTracking();
      await _sessionStore.clearToken();
      await AttendanceNotificationService.clearForLogout();
      if (token != null && token.isNotEmpty) {
        try {
          await _removeCurrentPushToken(
            token,
          ).timeout(const Duration(seconds: 5));
        } catch (_) {}
        try {
          await _apiClient.logout(token);
        } catch (_) {}
      }
    } catch (_) {
      // Local sign-out should still succeed even if cleanup partially fails.
    }
  }

  Future<void> _handleSessionExpired() async {
    if (_isHandlingSessionExpiry) {
      return;
    }

    _isHandlingSessionExpiry = true;
    try {
      await _handleLogout();
      if (!mounted) {
        return;
      }

      final navigator = Navigator.of(context, rootNavigator: true);
      navigator.popUntil((route) => route.isFirst);
    } finally {
      _isHandlingSessionExpiry = false;
    }
  }

  void _handleEmployeeUpdated(Employee employee) {
    setState(() {
      _employee = employee;
    });
    unawaited(
      AttendanceNotificationService.syncBranchOpeningReminders(employee),
    );
  }

  Future<void> _handleIncomingPushMessage(
    RemoteMessage message, {
    bool showLocalNotification = false,
  }) async {
    final isAdminNotification =
        message.data['type']?.toString() == 'admin_notification';
    final notification = isAdminNotification
        ? EmployeePushNotification.fromRemoteMessage(message)
        : null;

    if (notification != null && notification.deliveryId > 0 && mounted) {
      setState(() {
        _adminNotifications = _mergeAdminNotifications(_adminNotifications, [
          notification,
        ]);
      });
    }

    if (showLocalNotification &&
        notification != null &&
        notification.deliveryId > 0) {
      await AttendanceNotificationService.showAdminNotification(notification);
    }

    final authToken = _token;
    if (authToken == null || authToken.isEmpty) {
      return;
    }

    unawaited(_refreshAdminNotifications(authToken));
    unawaited(_syncEmployeeForBranchOpeningReminders(authToken));
  }

  Future<void> _syncCurrentPushToken(String token) async {
    await PushMessagingService.initialize();
    if (!PushMessagingService.isAvailable) {
      return;
    }

    final deviceToken = await PushMessagingService.currentToken();
    if (deviceToken == null || deviceToken.isEmpty) {
      return;
    }

    try {
      await _apiClient.registerDeviceToken(
        token: token,
        deviceToken: deviceToken,
        platform: PushMessagingService.platform,
      );
    } catch (_) {
      // Push token sync must never block the employee workflow.
    }
  }

  Future<void> _removeCurrentPushToken(String token) async {
    await PushMessagingService.initialize();
    if (!PushMessagingService.isAvailable) {
      return;
    }

    final deviceToken = await PushMessagingService.currentToken();
    if (deviceToken == null || deviceToken.isEmpty) {
      return;
    }

    try {
      await _apiClient.removeDeviceToken(
        token: token,
        deviceToken: deviceToken,
      );
    } catch (_) {
      // Token removal is best-effort during logout.
    }
  }

  Future<void> _syncEmployeeForBranchOpeningReminders(String token) async {
    try {
      final employee = await _apiClient
          .profile(token)
          .timeout(const Duration(seconds: 8));
      await AttendanceNotificationService.syncBranchOpeningReminders(employee);
      if (!mounted) {
        return;
      }
      setState(() {
        _employee = employee;
      });
    } catch (_) {
      // Reminder sync must not interrupt notification polling.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    final token = _token;
    if (token == null || token.isEmpty || _employee == null) {
      return;
    }

    switch (state) {
      case AppLifecycleState.resumed:
        if (_shouldRecheckAppUpdate) {
          unawaited(_checkForAppUpdate());
        }
        unawaited(_syncCurrentPushToken(token));
        unawaited(_refreshAdminNotifications(token));
        unawaited(_syncEmployeeForBranchOpeningReminders(token));
        unawaited(_syncAttendanceForNotifications(token));
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(AdminNotificationBackgroundService.scheduleImmediateSync());
        break;
    }
  }

  Future<void> _refreshAdminNotifications(String token) async {
    try {
      final notifications = await _apiClient
          .notifications(token: token)
          .timeout(const Duration(seconds: 8));
      for (final notification in notifications) {
        if (!notification.isRead && notification.deliveryId > 0) {
          await AttendanceNotificationService.showAdminNotification(
            notification,
          );
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _adminNotifications = _mergeAdminNotifications(
          _adminNotifications,
          notifications,
        );
      });
    } catch (_) {
      // Notification history should not interrupt the employee workflow.
    }
  }

  Future<void> _handleAdminNotificationsViewed() async {
    final token = _token;
    final unreadDeliveryIds = _adminNotifications
        .where((notification) => !notification.isRead)
        .map((notification) => notification.deliveryId)
        .toList();

    if (unreadDeliveryIds.isEmpty) {
      return;
    }

    final readAt = DateTime.now().toIso8601String();
    setState(() {
      _adminNotifications = _adminNotifications
          .map(
            (notification) =>
                unreadDeliveryIds.contains(notification.deliveryId)
                ? notification.copyWith(readAt: readAt)
                : notification,
          )
          .toList();
    });

    if (token == null || token.isEmpty) {
      return;
    }

    try {
      await _apiClient.markNotificationsRead(
        token: token,
        deliveryIds: unreadDeliveryIds,
      );
    } catch (_) {
      // Keep the bell cleared locally; the next refresh can reconcile state.
    }
  }

  @override
  void dispose() {
    _pushMessageSubscription?.cancel();
    _pushMessageOpenedSubscription?.cancel();
    _pushTokenRefreshSubscription?.cancel();
    _attendanceLocationSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_requiredAppUpdate != null) {
      return _RequiredUpdateScreen(
        update: _requiredAppUpdate!,
        currentVersion: _packageInfo == null
            ? ''
            : '${_packageInfo!.version} (${_packageInfo!.buildNumber})',
        isOpeningUpdate: _isOpeningAppUpdate,
        errorText: _appUpdateErrorText,
        onUpdateNow: _openRequiredUpdate,
      );
    }

    if (_isCheckingAppUpdate) {
      return const _SessionBootstrapScreen(
        title: 'Checking app version',
        subtitle: 'Verifying whether an update is required.',
      );
    }

    if (_isRestoringSession) {
      return const _SessionBootstrapScreen();
    }

    return _employee == null
        ? LoginScreen(onLogin: _handleLogin)
        : DashboardScreen(
            employee: _employee!,
            token: _token!,
            notifications: _adminNotifications,
            unreadNotificationCount: _unreadAdminNotificationCount,
            onLogout: _handleLogout,
            onSessionExpired: _handleSessionExpired,
            onEmployeeUpdated: _handleEmployeeUpdated,
            onNotificationsViewed: _handleAdminNotificationsViewed,
            onAttendanceChanged: _syncAttendanceLocationTracking,
          );
  }
}

List<EmployeePushNotification> _mergeAdminNotifications(
  List<EmployeePushNotification> current,
  List<EmployeePushNotification> incoming,
) {
  final byDeliveryId = <int, EmployeePushNotification>{
    for (final notification in current) notification.deliveryId: notification,
  };

  for (final notification in incoming) {
    final existing = byDeliveryId[notification.deliveryId];
    byDeliveryId[notification.deliveryId] =
        existing != null && existing.isRead && !notification.isRead
        ? existing
        : notification;
  }

  final merged = byDeliveryId.values.toList()
    ..sort((left, right) => right.deliveryId.compareTo(left.deliveryId));
  return merged;
}

class _SessionBootstrapScreen extends StatelessWidget {
  const _SessionBootstrapScreen({
    this.title = 'Restoring session',
    this.subtitle = 'Checking your employee access token.',
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.primaryDark,
              AppColors.primary,
              AppColors.background,
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 124,
                height: 124,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(34),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x26000000),
                      blurRadius: 30,
                      offset: Offset(0, 18),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Image.asset(
                  'assets/images/attica_logo.png',
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.82),
                ),
              ),
              const SizedBox(height: 18),
              const SizedBox(
                width: 140,
                child: LinearProgressIndicator(
                  minHeight: 4,
                  borderRadius: BorderRadius.all(Radius.circular(99)),
                  color: Colors.white,
                  backgroundColor: Color(0x4DFFFFFF),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RequiredUpdateScreen extends StatelessWidget {
  const _RequiredUpdateScreen({
    required this.update,
    required this.currentVersion,
    required this.isOpeningUpdate,
    required this.errorText,
    required this.onUpdateNow,
  });

  final AppUpdateInfo update;
  final String currentVersion;
  final bool isOpeningUpdate;
  final String? errorText;
  final Future<void> Function() onUpdateNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final releaseNotes = update.releaseNotes;

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.primaryDark,
              AppColors.primary,
              AppColors.background,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Container(
                width: 420,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x26000000),
                      blurRadius: 24,
                      offset: Offset(0, 14),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: 104,
                        height: 104,
                        child: Image.asset(
                          'assets/images/attica_logo.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      update.title.trim().isEmpty
                          ? 'Update required'
                          : update.title.trim(),
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      update.message.trim().isEmpty
                          ? 'A newer version of the app is available. Please update to continue.'
                          : update.message.trim(),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppColors.subtleText,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 18),
                    _ProfileDetailsCard(
                      entries: [
                        _ProfileEntry(
                          label: 'Installed',
                          value: currentVersion.isEmpty ? '--' : currentVersion,
                        ),
                        _ProfileEntry(
                          label: 'Latest',
                          value: update.latestVersion.trim().isEmpty
                              ? update.latestBuildNumber.toString()
                              : '${update.latestVersion} (${update.latestBuildNumber})',
                        ),
                      ],
                    ),
                    if (releaseNotes.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      const _SectionTitle(title: 'Release Notes'),
                      const SizedBox(height: 10),
                      _ProfileDetailsCard(
                        entries: releaseNotes
                            .map(
                              (note) =>
                                  _ProfileEntry(label: 'Note', value: note),
                            )
                            .toList(),
                      ),
                    ],
                    if (errorText != null) ...[
                      const SizedBox(height: 16),
                      _InlineInfoCard(
                        backgroundColor: const Color(0xFFFFE7E7),
                        icon: Icons.error_outline_rounded,
                        iconColor: const Color(0xFFD84A4A),
                        title: 'Update failed',
                        subtitle: errorText!,
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: isOpeningUpdate || !update.hasDownloadUrl
                            ? null
                            : onUpdateNow,
                        icon: isOpeningUpdate
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.system_update_alt_rounded),
                        label: Text(
                          isOpeningUpdate ? 'Opening update...' : 'Update now',
                        ),
                      ),
                    ),
                    if (!update.hasDownloadUrl) ...[
                      const SizedBox(height: 12),
                      Text(
                        'The update link is not configured yet. Contact your administrator.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFD84A4A),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
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

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLogin});

  final Future<void> Function(
    String branchId,
    String empId, {
    required String password,
    String? newPassword,
    String? newPasswordConfirmation,
    required bool rememberCredentials,
  })
  onLogin;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _noInternetMessage =
      'No internet connection. Check your mobile network or Wi-Fi and try again.';
  static const _slowConnectionMessage =
      'The connection is taking longer than expected. Check your internet connection and try again.';

  final _formKey = GlobalKey<FormState>();
  final _branchIdController = TextEditingController();
  final _empIdController = TextEditingController();
  final _passwordController = TextEditingController();
  final EmployeeSessionStore _sessionStore = const EmployeeSessionStore();

  bool _isCheckingInternet = true;
  bool _hasInternet = true;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _rememberCredentials = true;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _restoreSavedCredentials();
    _refreshInternetStatus();
  }

  @override
  void dispose() {
    _branchIdController.dispose();
    _empIdController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _restoreSavedCredentials() async {
    final rememberCredentials = await _sessionStore.readRememberCredentials();
    final savedCredentials = await _sessionStore.readSavedCredentials();
    final launchBranchId = _launchBranchId();

    if (!mounted) {
      return;
    }

    _branchIdController.text = launchBranchId.isNotEmpty
        ? launchBranchId
        : savedCredentials['branchId'] ?? '';
    _empIdController.text = savedCredentials['empId'] ?? '';
    _passwordController.text = savedCredentials['password'] ?? '';
    setState(() {
      _rememberCredentials = rememberCredentials;
    });
  }

  String _launchBranchId() {
    if (!kIsWeb) {
      return '';
    }

    return (Uri.base.queryParameters['branch_id'] ??
            Uri.base.queryParameters['branchId'] ??
            Uri.base.queryParameters['branch'] ??
            '')
        .trim()
        .toUpperCase();
  }

  Future<void> _refreshInternetStatus() async {
    if (mounted) {
      setState(() {
        _isCheckingInternet = true;
      });
    }

    final hasInternet = await _hasInternetConnection();

    if (!mounted) {
      return;
    }

    setState(() {
      _hasInternet = hasInternet;
      _isCheckingInternet = false;
      if (hasInternet && _errorText == _noInternetMessage) {
        _errorText = null;
      }
    });
  }

  Future<void> _submit() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    await _refreshInternetStatus();
    if (!mounted) {
      return;
    }
    if (!_hasInternet) {
      setState(() {
        _errorText = _noInternetMessage;
      });
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      await widget.onLogin(
        _branchIdController.text.trim(),
        _empIdController.text.trim(),
        password: _passwordController.text,
        rememberCredentials: _rememberCredentials,
      );
    } on PasswordSetupRequiredException catch (error) {
      if (!mounted) {
        return;
      }

      final newPassword = await _showPasswordSetupDialog(error);
      if (newPassword == null || newPassword.isEmpty) {
        setState(() {
          _errorText = error.message;
        });
        return;
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _isLoading = true;
        _errorText = null;
      });

      try {
        await widget.onLogin(
          _branchIdController.text.trim(),
          _empIdController.text.trim(),
          password: _passwordController.text,
          newPassword: newPassword,
          newPasswordConfirmation: newPassword,
          rememberCredentials: _rememberCredentials,
        );
        _passwordController.text = newPassword;
      } on ApiException catch (setupError) {
        setState(() {
          _errorText = setupError.message;
        });
      } on TimeoutException {
        setState(() {
          _errorText = _slowConnectionMessage;
        });
      } catch (_) {
        setState(() {
          _errorText = _slowConnectionMessage;
        });
      }
    } on ApiException catch (error) {
      setState(() {
        _errorText = error.message;
      });
    } on TimeoutException {
      setState(() {
        _errorText = _slowConnectionMessage;
      });
    } catch (_) {
      setState(() {
        _errorText = _slowConnectionMessage;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<String?> _showPasswordSetupDialog(
    PasswordSetupRequiredException error,
  ) {
    final formKey = GlobalKey<FormState>();
    final passwordController = TextEditingController(
      text: _passwordController.text,
    );
    final confirmController = TextEditingController();

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('Set new password'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Create a password for ${error.empId} at ${error.branchId}. You will need it for app and web login.',
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: passwordController,
                  autofocus: true,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'New password',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  validator: (value) {
                    final password = value?.trim() ?? '';
                    if (password.length < 6) {
                      return 'Use at least 6 characters.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: confirmController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirm password',
                    prefixIcon: Icon(Icons.lock_reset_outlined),
                  ),
                  validator: (value) {
                    if ((value ?? '') != passwordController.text) {
                      return 'Passwords do not match.';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) {
                  return;
                }

                Navigator.of(context).pop(passwordController.text.trim());
              },
              child: const Text('Save password'),
            ),
          ],
        );
      },
    ).whenComplete(() {
      passwordController.dispose();
      confirmController.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.primaryDark,
              AppColors.primary,
              AppColors.background,
              AppColors.background,
            ],
            stops: [0.0, 0.3, 0.3, 1.0],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxHeight < 720;
              final horizontalPadding = constraints.maxWidth < 380
                  ? 18.0
                  : 24.0;
              final cardPadding = isCompact
                  ? const EdgeInsets.fromLTRB(18, 16, 18, 18)
                  : const EdgeInsets.fromLTRB(22, 24, 22, 22);

              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: horizontalPadding,
                  vertical: isCompact ? 12 : 20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.center,
                      child: Image.asset(
                        'assets/images/attica_logo.png',
                        height: isCompact ? 48 : 72,
                        fit: BoxFit.contain,
                      ),
                    ),
                    SizedBox(height: isCompact ? 8 : 12),
                    Text(
                      'Attica Attendance',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontSize: isCompact ? 24 : null,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: isCompact ? 4 : 12),
                    SizedBox(
                      width: double.infinity,
                      child: Text(
                        isCompact
                            ? 'Attendance, salary, and leave details.'
                            : 'Track attendance, salary, and\nleave details in one place.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: isCompact ? 13 : null,
                          height: 1.35,
                        ),
                      ),
                    ),
                    SizedBox(height: isCompact ? 12 : 28),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(
                            isCompact ? 24 : 28,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x1A2D0A6D),
                              blurRadius: 40,
                              offset: Offset(0, 20),
                            ),
                          ],
                        ),
                        padding: cardPadding,
                        child: Form(
                          key: _formKey,
                          child: SingleChildScrollView(
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (!isCompact) ...[
                                  const _InsightBanner(
                                    title: 'CHECK IN FASTER',
                                    subtitle:
                                        'Attendance, documents, and expense actions in one employee app.',
                                  ),
                                  const SizedBox(height: 24),
                                ],
                                Text(
                                  'Welcome back',
                                  style: theme.textTheme.headlineMedium
                                      ?.copyWith(
                                        fontSize: isCompact ? 24 : null,
                                      ),
                                ),
                                SizedBox(height: isCompact ? 12 : 20),
                                _LabeledField(
                                  label: 'Branch Id',
                                  child: TextFormField(
                                    controller: _branchIdController,
                                    textCapitalization:
                                        TextCapitalization.characters,
                                    textInputAction: TextInputAction.next,
                                    decoration: _inputDecoration(
                                      hintText: 'Branch Id',
                                      prefixIcon: Icons.account_circle_outlined,
                                      compact: isCompact,
                                    ),
                                    validator: (value) {
                                      if (value == null ||
                                          value.trim().isEmpty) {
                                        return 'Branch ID is required.';
                                      }
                                      return null;
                                    },
                                  ),
                                ),
                                SizedBox(height: isCompact ? 10 : 16),
                                _LabeledField(
                                  label: 'Employee ID',
                                  child: TextFormField(
                                    controller: _empIdController,
                                    textCapitalization:
                                        TextCapitalization.characters,
                                    textInputAction: TextInputAction.next,
                                    decoration: _inputDecoration(
                                      hintText: 'Employee ID',
                                      prefixIcon: Icons.badge_outlined,
                                      compact: isCompact,
                                    ),
                                    validator: (value) {
                                      if (value == null ||
                                          value.trim().isEmpty) {
                                        return 'Employee ID is required.';
                                      }
                                      return null;
                                    },
                                  ),
                                ),
                                SizedBox(height: isCompact ? 10 : 16),
                                _LabeledField(
                                  label: 'Password',
                                  child: TextFormField(
                                    controller: _passwordController,
                                    obscureText: _obscurePassword,
                                    textInputAction: TextInputAction.done,
                                    onFieldSubmitted: (_) =>
                                        _isLoading ? null : _submit(),
                                    decoration: _inputDecoration(
                                      hintText: 'Password',
                                      prefixIcon: Icons.lock_outline,
                                      compact: isCompact,
                                      suffixIcon: IconButton(
                                        onPressed: () {
                                          setState(() {
                                            _obscurePassword =
                                                !_obscurePassword;
                                          });
                                        },
                                        icon: Icon(
                                          _obscurePassword
                                              ? Icons.visibility_outlined
                                              : Icons.visibility_off_outlined,
                                        ),
                                      ),
                                    ),
                                    validator: (value) {
                                      if (value == null ||
                                          value.trim().isEmpty) {
                                        return 'Password is required.';
                                      }
                                      return null;
                                    },
                                  ),
                                ),
                                SizedBox(height: isCompact ? 8 : 12),
                                SwitchListTile.adaptive(
                                  dense: isCompact,
                                  contentPadding: EdgeInsets.zero,
                                  value: _rememberCredentials,
                                  onChanged: _isLoading
                                      ? null
                                      : (value) {
                                          setState(() {
                                            _rememberCredentials = value;
                                          });
                                        },
                                  title: Text(
                                    'Remember login details',
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  subtitle: isCompact
                                      ? null
                                      : Text(
                                          'Auto-fill branch ID and employee ID after a successful login.',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: AppColors.subtleText,
                                              ),
                                        ),
                                ),
                                if ((_isCheckingInternet && !isCompact) ||
                                    !_hasInternet) ...[
                                  SizedBox(height: isCompact ? 8 : 12),
                                  Container(
                                    width: double.infinity,
                                    decoration: BoxDecoration(
                                      color: _hasInternet
                                          ? const Color(0xFFF2ECFF)
                                          : const Color(0xFFFFF1F1),
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    padding: const EdgeInsets.all(14),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 1,
                                          ),
                                          child: Icon(
                                            _hasInternet
                                                ? Icons.wifi_find_rounded
                                                : Icons.wifi_off_rounded,
                                            color: _hasInternet
                                                ? AppColors.primary
                                                : const Color(0xFF9A1B1B),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            _hasInternet
                                                ? 'Checking internet connection...'
                                                : _noInternetMessage,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  color: _hasInternet
                                                      ? AppColors.primary
                                                      : const Color(0xFF9A1B1B),
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ),
                                        if (!_hasInternet)
                                          TextButton(
                                            onPressed: _refreshInternetStatus,
                                            child: const Text('Retry'),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                                if (_errorText != null) ...[
                                  SizedBox(height: isCompact ? 8 : 14),
                                  Container(
                                    width: double.infinity,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFFF1F1),
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    padding: const EdgeInsets.all(14),
                                    child: Text(
                                      _errorText!,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: const Color(0xFF9A1B1B),
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ),
                                ],
                                SizedBox(height: isCompact ? 12 : 22),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed:
                                        (_isLoading ||
                                            _isCheckingInternet ||
                                            !_hasInternet)
                                        ? null
                                        : _submit,
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Colors.transparent,
                                      foregroundColor: Colors.white,
                                      padding: EdgeInsets.zero,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                    ),
                                    child: Ink(
                                      decoration: BoxDecoration(
                                        gradient: const LinearGradient(
                                          colors: [
                                            AppColors.primaryDark,
                                            AppColors.primary,
                                            AppColors.accent,
                                          ],
                                        ),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Container(
                                        alignment: Alignment.center,
                                        padding: EdgeInsets.symmetric(
                                          vertical: isCompact ? 14 : 16,
                                        ),
                                        child: _isLoading
                                            ? const SizedBox(
                                                width: 22,
                                                height: 22,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2.4,
                                                      color: Colors.white,
                                                    ),
                                              )
                                            : Text(
                                                'Sign In',
                                                style: theme
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                              ),
                                      ),
                                    ),
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
              );
            },
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String hintText,
    required IconData prefixIcon,
    bool compact = false,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hintText,
      prefixIcon: Icon(prefixIcon),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: AppColors.surfaceTint,
      contentPadding: EdgeInsets.symmetric(
        horizontal: 18,
        vertical: compact ? 14 : 18,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFD84A4A)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFD84A4A), width: 1.5),
      ),
    );
  }
}

class MyAttendancePage extends StatefulWidget {
  const MyAttendancePage({
    super.key,
    required this.employee,
    required this.token,
    required this.apiClient,
    required this.onSessionExpired,
    required this.onAttendanceChanged,
  });

  final Employee employee;
  final String token;
  final EmployeeApiClient apiClient;
  final Future<void> Function() onSessionExpired;
  final Future<void> Function(AttendanceRecord? attendance) onAttendanceChanged;

  @override
  State<MyAttendancePage> createState() => _MyAttendancePageState();
}

class _MyAttendancePageState extends State<MyAttendancePage> {
  static const String _headOfficeBranchId = 'AGPL000';
  static const double _headOfficeAllowedRadiusMeters = 150;
  static const double _defaultRequiredRadiusMeters = 350;
  static const double _defaultAllowedRadiusMeters = 350;
  static const double _outsourceAllowedRadiusMeters = 300;
  static const Duration _minimumCheckOutAfterCheckIn = Duration(hours: 2);
  static const Duration _recommendedCheckOutAfterCheckIn = Duration(hours: 8);

  AttendanceRecord? _attendance;
  Position? _position;
  Future<void>? _locationRefresh;
  AttendanceUploadPhoto? _facePhoto;
  AttendanceUploadPhoto? _checkOutPhoto;
  bool _isLoading = true;
  bool _isCapturingFace = false;
  bool _isSubmitting = false;
  bool _isFetchingLocation = false;
  bool _isMarkingAttendanceLoadingVisible = false;
  bool _showOpenLocationSettingsAction = false;
  bool _showOpenInternetSettingsAction = false;
  BuildContext? _attendanceMarkingDialogContext;
  String? _errorText;
  FakeLocationIssue? _fakeLocationIssue;

  @override
  void initState() {
    super.initState();
    _initializePage();
  }

  Future<void> _initializePage() async {
    await _loadAttendance();
    if (!mounted) {
      return;
    }

    if (!_usesLoggedInBranchOnlyForAttendance) {
      unawaited(_refreshAttendanceLocation(silent: true));
    }
  }

  Future<void> _refreshPage() async {
    await _loadAttendance(showLoader: false);
    if (!mounted) {
      return;
    }

    if (!_usesLoggedInBranchOnlyForAttendance) {
      await _refreshAttendanceLocation(silent: true);
    }
  }

  String get _todayDate {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }

  bool get _hasTodayAttendance =>
      _attendance != null &&
      (_attendance?.checkInDate == _todayDate ||
          (_isNightShiftAttendance &&
              (_attendance?.isActiveSession ?? false) &&
              !(_attendance?.hasCheckedOut ?? true)));

  bool get _hasActiveAttendance =>
      _attendance != null &&
      !(_attendance?.hasCheckedOut ?? false) &&
      ((_attendance?.isActiveSession ?? false) ||
          (!_isNightShiftAttendance && _attendance?.checkInDate == _todayDate));

  DateTime? get _activeCheckInDateTime {
    final attendance = _attendance;
    if (attendance == null) {
      return null;
    }

    return _parseAttendanceDateTime(
      attendance.checkInDate,
      attendance.checkInTime,
    );
  }

  Duration? get _elapsedSinceCheckIn {
    final checkInAt = _activeCheckInDateTime;
    if (checkInAt == null) {
      return null;
    }

    final elapsed = DateTime.now().difference(checkInAt);
    if (elapsed.isNegative) {
      return Duration.zero;
    }

    return elapsed;
  }

  Duration? get _remainingUntilCheckOutAllowed {
    final elapsed = _elapsedSinceCheckIn;
    if (elapsed == null) {
      return null;
    }

    final remaining = _minimumCheckOutAfterCheckIn - elapsed;
    if (remaining.isNegative || remaining == Duration.zero) {
      return null;
    }

    return remaining;
  }

  bool get _isCheckOutBlockedForMinimumDuration {
    final remaining = _remainingUntilCheckOutAllowed;
    return _hasActiveAttendance && remaining != null;
  }

  bool get _needsEarlyCheckOutConfirmation {
    if (!_hasActiveAttendance || _isCheckOutBlockedForMinimumDuration) {
      return false;
    }

    final elapsed = _elapsedSinceCheckIn;
    if (elapsed == null) {
      return false;
    }

    return elapsed < _recommendedCheckOutAfterCheckIn;
  }

  bool get _hasCompletedAttendance {
    final attendance = _attendance;
    if (attendance == null || !attendance.hasCheckedOut) {
      return false;
    }

    final checkOutDate = attendance.checkOutDate ?? attendance.checkInDate;
    return attendance.checkInDate == _todayDate || checkOutDate == _todayDate;
  }

  bool get _isNightShiftAttendance =>
      _attendance != null &&
      (_attendance?.isNightShift == true || widget.employee.isNightShift);

  bool get _isOutsourcedEmployee => widget.employee.isOutsourced;

  Size get _attendanceViewportSize {
    final view = View.of(context);
    return view.physicalSize / view.devicePixelRatio;
  }

  bool get _hasDesktopAttendanceViewport {
    final size = _attendanceViewportSize;
    final shortestSide = size.shortestSide;
    final longestSide = size.longestSide;

    return shortestSide >= 600 && longestSide >= 900;
  }

  bool get _hasFinePointerForAttendance =>
      web_desktop_attendance.hasFinePointerForAttendance();

  bool get _hasTouchInputForAttendance =>
      web_desktop_attendance.hasTouchInputForAttendance();

  bool get _usesLoggedInBranchOnlyForAttendance =>
      _isWebDesktopPlatform &&
      _hasDesktopAttendanceViewport &&
      _hasFinePointerForAttendance &&
      !_hasTouchInputForAttendance;

  List<OutsourceLocation> get _outsourceLocationsWithCoordinates => widget
      .employee
      .outsourceLocations
      .where(
        (location) => location.latitude != null && location.longitude != null,
      )
      .toList(growable: false);

  bool get _hasBranchCoordinates => _isOutsourcedEmployee
      ? _outsourceLocationsWithCoordinates.isNotEmpty
      : widget.employee.branchLatitude != null &&
            widget.employee.branchLongitude != null;

  double? get _distanceFromBranchMeters {
    final position = _position;
    if (position == null) {
      return null;
    }

    if (_isOutsourcedEmployee) {
      double? nearestDistance;
      for (final location in _outsourceLocationsWithCoordinates) {
        final latitude = location.latitude;
        final longitude = location.longitude;
        if (latitude == null || longitude == null) {
          continue;
        }
        final distance = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          latitude,
          longitude,
        );
        if (nearestDistance == null || distance < nearestDistance) {
          nearestDistance = distance;
        }
      }
      return nearestDistance;
    }

    final branchLatitude = widget.employee.branchLatitude;
    final branchLongitude = widget.employee.branchLongitude;
    if (branchLatitude == null || branchLongitude == null) {
      return null;
    }

    return Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      branchLatitude,
      branchLongitude,
    );
  }

  String get _branchLabel {
    if (_usesLoggedInBranchOnlyForAttendance) {
      final branchName = widget.employee.branchName.trim();
      if (branchName.isNotEmpty) {
        return branchName;
      }

      final branchId = widget.employee.branchId.trim();
      return branchId.isEmpty ? 'logged-in branch' : branchId;
    }

    if (_isOutsourcedEmployee) {
      final nearestLocation = _nearestOutsourceLocation;
      if (nearestLocation != null) {
        return nearestLocation.label;
      }
      if (widget.employee.outsourceLocations.isNotEmpty) {
        return 'assigned outsource location';
      }
    }

    final branchName = widget.employee.branchName.trim();
    if (branchName.isNotEmpty) {
      return branchName;
    }

    final branchId = widget.employee.branchId.trim();
    return branchId.isEmpty ? 'assigned branch' : branchId;
  }

  bool get _isHeadOfficeBranch =>
      !_isOutsourcedEmployee &&
      widget.employee.branchId.trim().toUpperCase() == _headOfficeBranchId;

  double get _requiredBranchRadiusMeters => _isHeadOfficeBranch
      ? _headOfficeAllowedRadiusMeters
      : (_isOutsourcedEmployee
            ? _outsourceAllowedRadiusMeters
            : _defaultRequiredRadiusMeters);

  double get _allowedBranchRadiusMeters => _isHeadOfficeBranch
      ? _headOfficeAllowedRadiusMeters
      : (_isOutsourcedEmployee
            ? _outsourceAllowedRadiusMeters
            : _defaultAllowedRadiusMeters);

  OutsourceLocation? get _nearestOutsourceLocation {
    final position = _position;
    if (position == null) {
      return null;
    }

    OutsourceLocation? nearestLocation;
    double? nearestDistance;
    for (final location in _outsourceLocationsWithCoordinates) {
      final latitude = location.latitude;
      final longitude = location.longitude;
      if (latitude == null || longitude == null) {
        continue;
      }
      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        latitude,
        longitude,
      );
      if (nearestDistance == null || distance < nearestDistance) {
        nearestDistance = distance;
        nearestLocation = location;
      }
    }

    return nearestLocation;
  }

  bool get _isLocationInReviewRange {
    if (_isHeadOfficeBranch || _isOutsourcedEmployee) {
      return false;
    }

    final distance = _distanceFromBranchMeters;
    if (distance == null) {
      return false;
    }

    return distance > _requiredBranchRadiusMeters &&
        distance <= _allowedBranchRadiusMeters;
  }

  bool get _isLocationAllowed {
    final distance = _distanceFromBranchMeters;
    return distance != null && distance <= _allowedBranchRadiusMeters;
  }

  String? get _locationValidationMessage {
    if (_usesLoggedInBranchOnlyForAttendance) {
      return null;
    }

    if (!_hasBranchCoordinates) {
      if (_isOutsourcedEmployee) {
        return 'Outsource locations are unavailable for this employee.';
      }
      return null;
    }

    final distance = _distanceFromBranchMeters;
    if (distance == null) {
      return 'Current location is required for attendance.';
    }

    // Backend is the source of truth for final radius validation to avoid
    // frontend/backend distance mismatch.
    return null;
  }

  bool get _isCapturingForCheckOut => _hasActiveAttendance;

  AttendanceUploadPhoto? get _currentAttendancePhoto =>
      _isCapturingForCheckOut ? _checkOutPhoto : _facePhoto;

  String get _captureTitle =>
      _isCapturingForCheckOut ? 'Check-Out Photo' : 'Check-In Photo';

  String get _captureSubtitle {
    if (_isCapturingForCheckOut) {
      final checkInTime = _formatCompactTime(_attendance?.checkInTime);
      return kIsWeb
          ? 'Checked in at $checkInTime. Capture a photo to check out.'
          : 'Checked in at $checkInTime. Capture a selfie to check out.';
    }

    return kIsWeb
        ? 'Capture a fresh photo to check in.'
        : 'Capture a fresh selfie to check in.';
  }

  String get _captureButtonText {
    if (_isCapturingFace) {
      return 'Opening camera...';
    }

    if (_isSubmitting) {
      return 'Saving attendance...';
    }

    if (_isCapturingForCheckOut && _isCheckOutBlockedForMinimumDuration) {
      final remaining = _remainingUntilCheckOutAllowed;
      if (remaining != null) {
        return 'Checkout in ${_formatDuration(remaining)}';
      }
      return 'Checkout available after 2h';
    }

    return 'Capture Photo';
  }

  String get _statusText {
    if (_hasCompletedAttendance) {
      return 'Checked in at ${_formatCompactTime(_attendance!.checkInTime)}. Checked out at ${_formatCompactTime(_attendance!.checkOutTime)}.';
    }
    if (_hasActiveAttendance) {
      return _isNightShiftAttendance && _attendance!.checkInDate != _todayDate
          ? 'Night shift check-in active from ${_attendance!.checkInDate} at ${_attendance!.checkInTime}.'
          : 'Checked in today at ${_attendance!.checkInTime}.';
    }
    if (_attendance != null &&
        _isNightShiftAttendance &&
        !_attendance!.hasCheckedOut &&
        !(_attendance!.isActiveSession)) {
      return 'Previous night shift missed the morning check-out and is now treated as a single punch.';
    }
    if (_hasTodayAttendance) {
      return 'Today attendance completed at ${_attendance!.checkOutTime ?? '-'}';
    }
    if (_usesLoggedInBranchOnlyForAttendance) {
      return 'Ready for today. Photo capture will mark attendance in $_branchLabel.';
    }
    return 'Ready for today. Face capture and auto-location are required.';
  }

  String get _locationStatusText {
    if (_usesLoggedInBranchOnlyForAttendance) {
      return 'In Branch: $_branchLabel';
    }

    if (_isFetchingLocation) {
      return 'Detecting your current location automatically.';
    }

    if (!_hasBranchCoordinates) {
      if (_isOutsourcedEmployee) {
        return 'Outsource location coordinates are unavailable. Contact HR.';
      }
      return 'Branch coordinates are unavailable for $_branchLabel.';
    }

    final distance = _distanceFromBranchMeters;
    if (distance != null) {
      if (_isOutsourcedEmployee) {
        return _isLocationAllowed
            ? 'Within outsource radius. ${_formatDistanceMeters(distance)} from $_branchLabel.'
            : 'Outside outsource radius. ${_formatDistanceMeters(distance)} from $_branchLabel. Allowed: ${_formatDistanceMeters(_allowedBranchRadiusMeters)}.';
      }

      if (_isLocationAllowed && !_isLocationInReviewRange) {
        return 'Within branch radius. ${_formatDistanceMeters(distance)} from $_branchLabel.';
      }

      if (_isLocationInReviewRange) {
        return 'Required radius is ${_formatDistanceMeters(_requiredBranchRadiusMeters)}, allowed up to ${_formatDistanceMeters(_allowedBranchRadiusMeters)}. HR will look into your image to verify.';
      }

      if (_isHeadOfficeBranch) {
        return 'Outside branch radius. ${_formatDistanceMeters(distance)} from $_branchLabel. Allowed: ${_formatDistanceMeters(_allowedBranchRadiusMeters)}.';
      }

      return 'Outside branch radius. ${_formatDistanceMeters(distance)} from $_branchLabel. Allowed: ${_formatDistanceMeters(_allowedBranchRadiusMeters)}.';
    }

    if (_isHeadOfficeBranch) {
      return 'Location will be captured automatically and matched with $_branchLabel within ${_formatDistanceMeters(_allowedBranchRadiusMeters)}.';
    }

    return 'Location will be captured automatically and matched with $_branchLabel.';
  }

  Color get _locationStatusColor {
    if (_usesLoggedInBranchOnlyForAttendance) {
      return AppColors.success;
    }

    if (_isFetchingLocation) {
      return AppColors.subtleText;
    }

    if (!_hasBranchCoordinates) {
      return const Color(0xFF9A1B1B);
    }

    final distance = _distanceFromBranchMeters;
    if (distance == null) {
      return AppColors.subtleText;
    }

    if (_isLocationInReviewRange) {
      return const Color(0xFFB98400);
    }

    return _isLocationAllowed ? AppColors.success : const Color(0xFF9A1B1B);
  }

  bool _isSessionExpiredError(ApiException error) {
    final normalized = error.message.trim().toLowerCase();
    return normalized == 'unauthenticated.' ||
        normalized == 'unauthenticated' ||
        normalized == 'unauthorized' ||
        normalized.contains('session expired') ||
        normalized.contains('sign in again') ||
        normalized.contains('login again') ||
        normalized.contains('log in again');
  }

  Future<bool> _handleSessionExpiryIfNeeded(ApiException error) async {
    if (!_isSessionExpiredError(error)) {
      return false;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Session expired. Redirecting to login...'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    await widget.onSessionExpired();
    return true;
  }

  Future<bool> _confirmEarlyCheckOutIfNeeded() async {
    if (!_needsEarlyCheckOutConfirmation) {
      return true;
    }

    if (!mounted) {
      return false;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('You have not completed 8hrs today.'),
        behavior: SnackBarBehavior.floating,
      ),
    );

    final shouldContinue = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Early Checkout'),
          content: const Text(
            "You haven't completed 8hrs today. Do you want to checkout?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('No'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Yes, Checkout'),
            ),
          ],
        );
      },
    );

    return shouldContinue ?? false;
  }

  Future<void> _loadAttendance({bool showLoader = true}) async {
    if (showLoader) {
      setState(() {
        _isLoading = true;
        _errorText = null;
        _fakeLocationIssue = null;
      });
    }

    try {
      final attendance = await widget.apiClient.latestAttendance(widget.token);
      if (!mounted) {
        return;
      }
      setState(() {
        _attendance = attendance;
        if (!_hasActiveAttendance) {
          _checkOutPhoto = null;
        }
      });
      await AttendanceNotificationService.syncWithAttendance(attendance);
      await widget.onAttendanceChanged(attendance);
    } on ApiException catch (error) {
      if (await _handleSessionExpiryIfNeeded(error)) {
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = error.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to load attendance right now.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _refreshAttendanceLocation({bool silent = false}) {
    if (_usesLoggedInBranchOnlyForAttendance) {
      return Future<void>.value();
    }

    final currentRefresh = _locationRefresh;
    if (currentRefresh != null) {
      return currentRefresh;
    }

    final refresh = _fetchLocation(silent: silent);
    _locationRefresh = refresh.whenComplete(() {
      _locationRefresh = null;
    });
    return _locationRefresh!;
  }

  Future<void> _ensureAttendanceLocationReady({bool silent = false}) async {
    await _refreshAttendanceLocation(silent: silent);
  }

  Future<void> _fetchLocation({bool silent = false}) async {
    if (mounted) {
      setState(() {
        _isFetchingLocation = true;
        _fakeLocationIssue = null;
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        if (!silent) {
          _errorText = null;
        }
      });
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            _position = null;
            _fakeLocationIssue = null;
            _showOpenLocationSettingsAction = true;
            _showOpenInternetSettingsAction = false;
            _errorText = 'Location services are disabled.';
          });
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw ApiException('Location permission is required for attendance.');
      }

      Position position;
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 20),
          ),
        );
      } on TimeoutException {
        // Fallback to medium accuracy if high-accuracy GPS lock is slow.
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 12),
          ),
        );
      }
      await LocationIntegrityService.ensureTrustedPosition(
        position,
        actionLabel: 'marking attendance',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _position = position;
        _fakeLocationIssue = null;
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = null;
      });
    } on FakeLocationException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _position = null;
        _fakeLocationIssue = error.issue;
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = error.message;
      });
    } on TimeoutException {
      if (!mounted) {
        return;
      }
      setState(() {
        _position = null;
        _fakeLocationIssue = null;
        _showOpenLocationSettingsAction = true;
        _showOpenInternetSettingsAction = false;
        _errorText =
            'Location request timed out. Please move to open sky and try again.';
      });
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      final errorText = (error.message ?? error.code).toLowerCase();
      final likelyInternetIssue =
          errorText.contains('network') ||
          errorText.contains('provider') ||
          errorText.contains('unavailable');
      setState(() {
        _position = null;
        _fakeLocationIssue = null;
        _showOpenLocationSettingsAction = true;
        _showOpenInternetSettingsAction = likelyInternetIssue;
        _errorText = (error.message ?? 'Unable to fetch current location.')
            .trim();
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _position = null;
        _fakeLocationIssue = null;
        _showOpenLocationSettingsAction = true;
        _showOpenInternetSettingsAction = false;
        _errorText = error.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _position = null;
        _fakeLocationIssue = null;
        _showOpenLocationSettingsAction = true;
        _showOpenInternetSettingsAction = false;
        _errorText = 'Unable to fetch current location.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isFetchingLocation = false;
        });
      }
    }
  }

  Future<void> _captureFace({required bool forCheckOut}) async {
    if (_isCapturingFace || _isSubmitting || _hasCompletedAttendance) {
      return;
    }

    setState(() {
      _isCapturingFace = true;
      _errorText = null;
      _showOpenLocationSettingsAction = false;
      _showOpenInternetSettingsAction = false;
    });

    try {
      if (forCheckOut && _isCheckOutBlockedForMinimumDuration) {
        final remaining = _remainingUntilCheckOutAllowed;
        setState(() {
          _showOpenLocationSettingsAction = false;
          _showOpenInternetSettingsAction = false;
          _errorText = remaining == null
              ? 'Check-out is allowed only after 2 hours from check-in.'
              : 'Check-out is allowed after 2 hours from check-in. Try again in ${_formatDuration(remaining)}.';
        });
        return;
      }

      if (forCheckOut) {
        final shouldContinue = await _confirmEarlyCheckOutIfNeeded();
        if (!shouldContinue || !mounted) {
          return;
        }
      }

      if (!_usesLoggedInBranchOnlyForAttendance) {
        await _ensureAttendanceLocationReady(silent: true);
      }
      if (!mounted) {
        return;
      }

      final locationValidationMessage = _locationValidationMessage;
      if (locationValidationMessage != null) {
        setState(() {
          _showOpenLocationSettingsAction = false;
          _showOpenInternetSettingsAction = false;
          _errorText = locationValidationMessage;
        });
        return;
      }

      final capturedPhoto = await _captureAttendancePhoto(forCheckOut);
      if (capturedPhoto == null || !mounted) {
        return;
      }

      final canContinueAfterFraudCheck =
          await _warnAndReportAttendanceFraudIfDetected(
            capturedPhoto,
            forCheckOut: forCheckOut,
          );
      if (!canContinueAfterFraudCheck || !mounted) {
        return;
      }

      _setAttendancePhoto(capturedPhoto, forCheckOut: forCheckOut);
      if (forCheckOut) {
        await _checkOut(hasConfirmedEarlyCheckOut: true);
      } else {
        await _checkIn();
      }
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = _frontCameraErrorMessage(error);
      });
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = _frontCameraPlatformErrorMessage(error);
      });
    } on ApiException catch (error) {
      if (await _handleSessionExpiryIfNeeded(error)) {
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = error.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = 'Unable to capture face photo.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isCapturingFace = false;
        });
      }
    }
  }

  Future<bool> _warnAndReportAttendanceFraudIfDetected(
    AttendanceUploadPhoto photo, {
    required bool forCheckOut,
  }) async {
    final detection = await AttendanceFraudDetector.inspect(photo);

    if (!detection.isFraud) {
      return true;
    }

    var message =
        'A high-confidence mobile screen/photo was detected. Attendance will still be submitted, and this attempt has been reported to Zonal with the captured proof image.';

    try {
      await widget.apiClient.reportAttendanceFraud(
        token: widget.token,
        photo: photo,
        source: forCheckOut ? 'check_out' : 'check_in',
        confidence: detection.confidence,
        reason: detection.reason,
      );
    } on ApiException catch (error) {
      if (await _handleSessionExpiryIfNeeded(error)) {
        return false;
      }
      message =
          'A high-confidence mobile screen/photo was detected. Attendance will still be submitted, but the report could not be uploaded: ${error.message}';
    } catch (_) {
      message =
          'A high-confidence mobile screen/photo was detected. Attendance will still be submitted, but the report could not be uploaded. Please check your internet connection.';
    }

    if (!mounted) {
      return false;
    }

    setState(() {
      _fakeLocationIssue = null;
      _showOpenLocationSettingsAction = false;
      _showOpenInternetSettingsAction = false;
      _errorText = null;
    });
    await _showAttendanceFraudWarningDialog(message);

    return true;
  }

  Future<void> _showAttendanceFraudWarningDialog(String message) async {
    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Attendance Warning'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<AttendanceUploadPhoto?> _captureAttendancePhoto(
    bool forCheckOut,
  ) async {
    if (kIsWeb) {
      final capturedBytes = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute<Uint8List>(
          builder: (_) => _WebCameraCapturePage(
            title: forCheckOut ? 'Check-Out Photo' : 'Check-In Photo',
            subtitle: forCheckOut
                ? 'Checked in. Capture a photo to check out.'
                : 'Capture a fresh photo to check in.',
            preferredLensDirection: CameraLensDirection.front,
          ),
          fullscreenDialog: true,
        ),
      );
      if (capturedBytes == null || capturedBytes.isEmpty) {
        return null;
      }

      return AttendanceUploadPhoto(
        bytes: capturedBytes,
        filename: _attendancePhotoFilename(forCheckOut),
      );
    }

    final capturedFile = await Navigator.of(context).push<File>(
      MaterialPageRoute<File>(
        builder: (_) => FrontCameraCapturePage(
          title: forCheckOut ? 'Check-Out Photo' : 'Check-In Photo',
          subtitle: forCheckOut
              ? 'Use the selfie camera to capture your check-out photo.'
              : 'Use the selfie camera to capture your check-in photo.',
        ),
        fullscreenDialog: true,
      ),
    );

    if (capturedFile == null) {
      return null;
    }

    return AttendanceUploadPhoto(
      bytes: await capturedFile.readAsBytes(),
      filename: _attendancePhotoFilename(forCheckOut),
    );
  }

  String _attendancePhotoFilename(bool forCheckOut) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return forCheckOut
        ? 'attendance-checkout-$timestamp.jpg'
        : 'attendance-checkin-$timestamp.jpg';
  }

  String _frontCameraErrorMessage(CameraException error) {
    switch (error.code) {
      case 'CameraAccessDenied':
      case 'cameraPermission':
        return 'Camera permission was denied.';
      case 'CameraAccessRestricted':
        return 'Camera access is restricted on this device.';
      case 'NoAvailableCamera':
        return 'No front camera is available on this device.';
      default:
        final description = error.description?.trim();
        if (description != null && description.isNotEmpty) {
          return description;
        }

        return 'Unable to capture face photo.';
    }
  }

  String _frontCameraPlatformErrorMessage(PlatformException error) {
    switch (error.code) {
      case 'camera_access_denied':
        return 'Camera permission was denied.';
      case 'no_available_camera':
        return 'No front camera is available on this device.';
      default:
        final message = error.message?.trim();
        if (message != null && message.isNotEmpty) {
          return message;
        }

        return 'Unable to capture face photo.';
    }
  }

  void _setAttendancePhoto(
    AttendanceUploadPhoto photo, {
    required bool forCheckOut,
  }) {
    if (!mounted) {
      return;
    }

    setState(() {
      if (forCheckOut) {
        _checkOutPhoto = photo;
      } else {
        _facePhoto = photo;
      }
      _errorText = null;
      _fakeLocationIssue = null;
    });
  }

  Future<void> _openFakeLocationSettings() async {
    final issue = _fakeLocationIssue;
    if (issue == null) {
      return;
    }

    try {
      await LocationIntegrityService.openIssueSettings(issue);
    } on PlatformException {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to open settings on this device.';
      });
    }
  }

  Future<void> _openLocationServicesSettings() async {
    try {
      await LocationIntegrityService.openLocationSettings();
    } on PlatformException {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to open location settings on this device.';
      });
    }
  }

  Future<void> _openInternetSettings() async {
    try {
      await LocationIntegrityService.openWirelessSettings();
    } on PlatformException {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to open internet settings on this device.';
      });
    }
  }

  Future<void> _checkIn() async {
    if (_hasTodayAttendance) {
      setState(() {
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = 'Attendance already captured for today.';
      });
      return;
    }

    if (!_usesLoggedInBranchOnlyForAttendance) {
      await _ensureAttendanceLocationReady(silent: true);
    }
    if (!_usesLoggedInBranchOnlyForAttendance && _position == null) {
      setState(() {
        _showOpenLocationSettingsAction = true;
        _showOpenInternetSettingsAction = false;
        _errorText = 'Current location is required for attendance.';
      });
      return;
    }

    final locationValidationMessage = _locationValidationMessage;
    if (locationValidationMessage != null) {
      setState(() {
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = locationValidationMessage;
      });
      return;
    }

    if (_facePhoto == null) {
      setState(() {
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = 'Capture face photo before check-in.';
      });
      return;
    }

    final hasInternet = await _hasInternetConnection();
    if (!hasInternet) {
      if (!mounted) {
        return;
      }
      setState(() {
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = true;
        _errorText =
            'No internet connection. Turn on mobile data or Wi-Fi and try again.';
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
      _fakeLocationIssue = null;
      _showOpenLocationSettingsAction = false;
      _showOpenInternetSettingsAction = false;
    });
    _showAttendanceMarkingLoadingOverlay();

    try {
      final attendance = await widget.apiClient.checkIn(
        token: widget.token,
        latitude: _usesLoggedInBranchOnlyForAttendance
            ? null
            : _position!.latitude,
        longitude: _usesLoggedInBranchOnlyForAttendance
            ? null
            : _position!.longitude,
        photo: _facePhoto!,
        useLoggedInBranchOnly: _usesLoggedInBranchOnlyForAttendance,
        webViewSize: _usesLoggedInBranchOnlyForAttendance
            ? _attendanceViewportSize
            : null,
        hasFinePointer: _usesLoggedInBranchOnlyForAttendance
            ? _hasFinePointerForAttendance
            : false,
        hasTouchInput: _usesLoggedInBranchOnlyForAttendance
            ? _hasTouchInputForAttendance
            : true,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _attendance = attendance;
        _facePhoto = null;
        _checkOutPhoto = null;
        _fakeLocationIssue = null;
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
      });
      await AttendanceNotificationService.markCheckInCompleted();
      await widget.onAttendanceChanged(attendance);
      if (!mounted) {
        return;
      }

      await _dismissAttendanceMarkingLoadingOverlay();
      await _showAttendanceMarkedAnimation();
    } on AttendanceStateException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _attendance = error.attendance;
        _facePhoto = null;
        _checkOutPhoto = null;
        _fakeLocationIssue = null;
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = error.message;
      });
      await widget.onAttendanceChanged(error.attendance);
    } on FakeLocationException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _fakeLocationIssue = error.issue;
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = error.message;
      });
    } on ApiException catch (error) {
      if (await _handleSessionExpiryIfNeeded(error)) {
        return;
      }
      if (!mounted) {
        return;
      }
      final hasInternet = await _hasInternetConnection();
      setState(() {
        _fakeLocationIssue = null;
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = !hasInternet;
        _errorText = error.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      final hasInternet = await _hasInternetConnection();
      setState(() {
        _fakeLocationIssue = null;
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = !hasInternet;
        _errorText = 'Unable to check in attendance.';
      });
    } finally {
      await _dismissAttendanceMarkingLoadingOverlay();
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _checkOut({bool hasConfirmedEarlyCheckOut = false}) async {
    if (!_hasActiveAttendance) {
      setState(() {
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = 'No active attendance is available for check-out.';
      });
      return;
    }

    if (_isCheckOutBlockedForMinimumDuration) {
      final remaining = _remainingUntilCheckOutAllowed;
      setState(() {
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = remaining == null
            ? 'Check-out is allowed only after 2 hours from check-in.'
            : 'Check-out is allowed after 2 hours from check-in. Try again in ${_formatDuration(remaining)}.';
      });
      return;
    }

    if (!hasConfirmedEarlyCheckOut && _needsEarlyCheckOutConfirmation) {
      final shouldContinue = await _confirmEarlyCheckOutIfNeeded();
      if (!shouldContinue) {
        return;
      }
    }

    if (_checkOutPhoto == null) {
      setState(() {
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = 'Capture face photo before check-out.';
      });
      return;
    }

    if (!_usesLoggedInBranchOnlyForAttendance) {
      await _ensureAttendanceLocationReady(silent: true);
    }
    if (!_usesLoggedInBranchOnlyForAttendance && _position == null) {
      setState(() {
        _showOpenLocationSettingsAction = true;
        _showOpenInternetSettingsAction = false;
        _errorText = 'Current location is required for attendance.';
      });
      return;
    }

    final locationValidationMessage = _locationValidationMessage;
    if (locationValidationMessage != null) {
      setState(() {
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = locationValidationMessage;
      });
      return;
    }

    final hasInternet = await _hasInternetConnection();
    if (!hasInternet) {
      if (!mounted) {
        return;
      }
      setState(() {
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = true;
        _errorText =
            'No internet connection. Turn on mobile data or Wi-Fi and try again.';
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
      _fakeLocationIssue = null;
      _showOpenLocationSettingsAction = false;
      _showOpenInternetSettingsAction = false;
    });
    _showAttendanceMarkingLoadingOverlay();

    try {
      final attendance = await widget.apiClient.checkOut(
        token: widget.token,
        latitude: _usesLoggedInBranchOnlyForAttendance
            ? null
            : _position!.latitude,
        longitude: _usesLoggedInBranchOnlyForAttendance
            ? null
            : _position!.longitude,
        photo: _checkOutPhoto!,
        useLoggedInBranchOnly: _usesLoggedInBranchOnlyForAttendance,
        webViewSize: _usesLoggedInBranchOnlyForAttendance
            ? _attendanceViewportSize
            : null,
        hasFinePointer: _usesLoggedInBranchOnlyForAttendance
            ? _hasFinePointerForAttendance
            : false,
        hasTouchInput: _usesLoggedInBranchOnlyForAttendance
            ? _hasTouchInputForAttendance
            : true,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _attendance = attendance;
        _checkOutPhoto = null;
        _fakeLocationIssue = null;
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
      });
      await AttendanceNotificationService.markCheckOutCompleted();
      await widget.onAttendanceChanged(attendance);
      if (!mounted) {
        return;
      }

      await _dismissAttendanceMarkingLoadingOverlay();
      await _showAttendanceMarkedAnimation();
    } on FakeLocationException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _fakeLocationIssue = error.issue;
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = false;
        _errorText = error.message;
      });
    } on ApiException catch (error) {
      if (await _handleSessionExpiryIfNeeded(error)) {
        return;
      }
      if (!mounted) {
        return;
      }
      final hasInternet = await _hasInternetConnection();
      setState(() {
        _fakeLocationIssue = null;
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = !hasInternet;
        _errorText = error.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      final hasInternet = await _hasInternetConnection();
      setState(() {
        _fakeLocationIssue = null;
        _showOpenLocationSettingsAction = false;
        _showOpenInternetSettingsAction = !hasInternet;
        _errorText = 'Unable to check out attendance.';
      });
    } finally {
      await _dismissAttendanceMarkingLoadingOverlay();
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  void _showAttendanceMarkingLoadingOverlay() {
    if (!mounted || _isMarkingAttendanceLoadingVisible) {
      return;
    }

    _isMarkingAttendanceLoadingVisible = true;

    unawaited(
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black.withValues(alpha: 0.48),
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (dialogContext, animation, secondaryAnimation) {
          _attendanceMarkingDialogContext = dialogContext;
          return const _AttendanceMarkingOverlay();
        },
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: child,
          );
        },
      ).whenComplete(() {
        _isMarkingAttendanceLoadingVisible = false;
        _attendanceMarkingDialogContext = null;
      }),
    );
  }

  Future<void> _dismissAttendanceMarkingLoadingOverlay() async {
    if (!mounted || !_isMarkingAttendanceLoadingVisible) {
      return;
    }

    final dialogContext = _attendanceMarkingDialogContext;
    if (dialogContext != null && Navigator.of(dialogContext).canPop()) {
      Navigator.of(dialogContext).pop();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  Future<void> _showAttendanceMarkedAnimation() async {
    if (!mounted) {
      return;
    }

    unawaited(
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black.withValues(alpha: 0.48),
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, animation, secondaryAnimation) {
          return const _AttendanceMarkedOverlay();
        },
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
              ),
              child: child,
            ),
          );
        },
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 1200));

    if (!mounted) {
      return;
    }

    final rootNavigator = Navigator.of(context, rootNavigator: true);
    if (rootNavigator.canPop()) {
      rootNavigator.pop();
    }

    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Attendance'),
        surfaceTintColor: Colors.transparent,
        backgroundColor: AppColors.background,
        actions: [
          IconButton(
            onPressed: () {
              _loadAttendance(showLoader: false);
              _refreshAttendanceLocation(silent: true);
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshPage,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(28),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            AppColors.primaryDark,
                            AppColors.primary,
                            Color(0xFF7B48D9),
                          ],
                        ),
                      ),
                      padding: const EdgeInsets.all(22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: widget.employee.name,
                                  style: theme.textTheme.headlineMedium
                                      ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                      ),
                                ),
                                TextSpan(
                                  text:
                                      '  Branch : ${widget.employee.branchName.isNotEmpty ? widget.employee.branchName : 'Branch name unavailable'}',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.85),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Emp ID: ${widget.employee.empId} • Branch: ${widget.employee.branchId}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white.withValues(alpha: 0.85),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            _statusText,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_errorText != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF1F1),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _errorText!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: const Color(0xFF9A1B1B),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (_fakeLocationIssue != null) ...[
                              const SizedBox(height: 10),
                              OutlinedButton.icon(
                                onPressed: _openFakeLocationSettings,
                                icon: const Icon(Icons.settings_outlined),
                                label: Text(_fakeLocationIssue!.actionLabel),
                              ),
                            ],
                            if (_showOpenLocationSettingsAction) ...[
                              const SizedBox(height: 10),
                              OutlinedButton.icon(
                                onPressed: _openLocationServicesSettings,
                                icon: const Icon(Icons.location_on_outlined),
                                label: const Text('Open location settings'),
                              ),
                            ],
                            if (_showOpenInternetSettingsAction) ...[
                              const SizedBox(height: 10),
                              OutlinedButton.icon(
                                onPressed: _openInternetSettings,
                                icon: const Icon(Icons.wifi_find_rounded),
                                label: const Text('Open internet settings'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                    if (_hasCompletedAttendance) ...[
                      const SizedBox(height: 18),
                      _AttendancePanel(
                        title: 'Attendance Completed',
                        subtitle:
                            'Checked in at ${_formatCompactTime(_attendance!.checkInTime)}\n'
                            'Checked out at ${_formatCompactTime(_attendance!.checkOutTime)}',
                        leading: Icons.task_alt_rounded,
                        subtitleColor: AppColors.secondary,
                        trailing: const Icon(
                          Icons.check_circle_rounded,
                          color: AppColors.success,
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 18),
                      _AttendancePanel(
                        title: _usesLoggedInBranchOnlyForAttendance
                            ? 'In Branch'
                            : 'Auto Location',
                        subtitle: _locationStatusText,
                        subtitleColor: _locationStatusColor,
                        leading: _usesLoggedInBranchOnlyForAttendance
                            ? Icons.storefront_rounded
                            : Icons.location_on_outlined,
                        trailing: _isFetchingLocation
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                ),
                              )
                            : _usesLoggedInBranchOnlyForAttendance
                            ? const Icon(
                                Icons.check_circle_rounded,
                                color: AppColors.success,
                              )
                            : Icon(
                                !_hasBranchCoordinates
                                    ? Icons.error_outline_rounded
                                    : _position != null
                                    ? _isLocationAllowed
                                          ? Icons.check_circle_rounded
                                          : Icons.cancel_rounded
                                    : Icons.gps_fixed_rounded,
                                color: !_hasBranchCoordinates
                                    ? const Color(0xFF9A1B1B)
                                    : _position != null
                                    ? _isLocationAllowed
                                          ? (_isLocationInReviewRange
                                                ? const Color(0xFFB98400)
                                                : AppColors.success)
                                          : const Color(0xFF9A1B1B)
                                    : AppColors.primary,
                              ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x12000000),
                              blurRadius: 16,
                              offset: Offset(0, 8),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AppColors.primarySoft,
                                  ),
                                  child: const Icon(
                                    Icons.face_retouching_natural_outlined,
                                    color: AppColors.primary,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _captureTitle,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                      Text(
                                        _captureSubtitle,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: AppColors.subtleText,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: _currentAttendancePhoto != null
                                  ? Image.memory(
                                      _currentAttendancePhoto!.bytes,
                                      width: double.infinity,
                                      height: 190,
                                      fit: BoxFit.cover,
                                    )
                                  : Container(
                                      width: double.infinity,
                                      height: 190,
                                      color: AppColors.surfaceTint,
                                      alignment: Alignment.center,
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          const Icon(
                                            Icons.camera_alt_outlined,
                                            size: 34,
                                            color: AppColors.secondary,
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            'Front camera capture',
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  color: AppColors.secondary,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.tonal(
                                onPressed:
                                    _isCapturingFace ||
                                        _isSubmitting ||
                                        (_isCapturingForCheckOut &&
                                            _isCheckOutBlockedForMinimumDuration)
                                    ? null
                                    : () => _captureFace(
                                        forCheckOut: _isCapturingForCheckOut,
                                      ),
                                child: _isSubmitting
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                        ),
                                      )
                                    : Text(_captureButtonText),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

class EmployeeIdCardPage extends StatefulWidget {
  const EmployeeIdCardPage({
    super.key,
    required this.employee,
    required this.token,
    required this.apiClient,
  });

  final Employee employee;
  final String token;
  final EmployeeApiClient apiClient;

  @override
  State<EmployeeIdCardPage> createState() => _EmployeeIdCardPageState();
}

class _EmployeeIdCardPageState extends State<EmployeeIdCardPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _designation;
  late final TextEditingController _phone;
  late final TextEditingController _emergency;
  late final TextEditingController _address;
  String _bloodGroup = '';
  XFile? _photo;
  IdCardSubmission? _submission;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.employee.name);
    _designation = TextEditingController(text: widget.employee.designation);
    _phone = TextEditingController(text: widget.employee.contact);
    _emergency = TextEditingController();
    _address = TextEditingController(text: widget.employee.address);
    _load();
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _designation,
      _phone,
      _emergency,
      _address,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final access = await widget.apiClient.idCardAccess(widget.token);
      if (!access.enabled) {
        throw ApiException(
          'The ID Card feature is not enabled for this employee.',
        );
      }
      if (mounted) setState(() => _submission = access.submission);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickPhoto() async {
    final photo = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 1200,
    );
    if (photo != null && mounted) setState(() => _photo = photo);
  }

  String? _required(String? value) =>
      (value ?? '').trim().isEmpty ? 'This field is required.' : null;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_bloodGroup.isEmpty || _photo == null) {
      setState(
        () => _error = _photo == null
            ? 'Please upload a passport-size photo.'
            : 'Please select your blood group.',
      );
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final submission = await widget.apiClient.submitIdCard(
        token: widget.token,
        fullName: _name.text.trim(),
        designation: _designation.text.trim(),
        dateOfBirth: '',
        bloodGroup: _bloodGroup,
        phone: _phone.text.trim(),
        emergencyContact: _emergency.text.trim(),
        homeAddress: _address.text.trim(),
        photo: _photo!,
      );
      if (mounted) setState(() => _submission = submission);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ID Card')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _submission != null
                  ? _buildCard(_submission!)
                  : _buildForm(),
            ),
    );
  }

  Widget _buildForm() {
    InputDecoration decoration(String label) =>
        InputDecoration(labelText: label, border: const OutlineInputBorder());
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Employee ID: ${widget.employee.empId}',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          const Text(
            'Your employee ID is filled from your login and cannot be changed.',
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          const SizedBox(height: 18),
          TextFormField(
            controller: _name,
            decoration: decoration('Full name'),
            validator: _required,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _designation,
            decoration: decoration('Designation'),
            validator: _required,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _bloodGroup.isEmpty ? null : _bloodGroup,
            decoration: decoration('Blood group'),
            items: ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-']
                .map(
                  (value) => DropdownMenuItem(value: value, child: Text(value)),
                )
                .toList(),
            onChanged: (value) => setState(() => _bloodGroup = value ?? ''),
            validator: _required,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            maxLength: 10,
            decoration: decoration('Phone'),
            validator: (v) => RegExp(r'^[0-9]{10}$').hasMatch(v ?? '')
                ? null
                : 'Enter exactly 10 digits.',
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _emergency,
            keyboardType: TextInputType.phone,
            maxLength: 10,
            decoration: decoration('Emergency contact'),
            validator: (v) => RegExp(r'^[0-9]{10}$').hasMatch(v ?? '')
                ? null
                : 'Enter exactly 10 digits.',
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _address,
            maxLines: 3,
            decoration: decoration('Home address'),
            validator: _required,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickPhoto,
            icon: const Icon(Icons.upload_file_outlined),
            label: Text(
              _photo == null
                  ? 'Upload passport-size photo'
                  : 'Photo selected — choose another',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Submit ID Card'),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(IdCardSubmission card) {
    return Center(
      child: Container(
        width: 340,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(26),
          boxShadow: const [
            BoxShadow(
              color: Color(0x26000000),
              blurRadius: 30,
              offset: Offset(0, 14),
            ),
          ],
        ),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 72),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF5B0717), Color(0xFF951A36)],
                ),
              ),
              child: Column(
                children: [
                  Image.asset(
                    'assets/images/attica_id_card_logo.png',
                    width: 220,
                    height: 82,
                    fit: BoxFit.contain,
                  ),
                  const Text(
                    'EMPLOYEE IDENTITY CARD',
                    style: TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
            Transform.translate(
              offset: const Offset(0, -55),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.network(
                      card.photoUrl,
                      headers: {
                        'Accept': 'image/*',
                        'Authorization': 'Bearer ${widget.token}',
                      },
                      width: 138,
                      height: 168,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 138,
                        height: 168,
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.person, size: 70),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    card.fullName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF5B0717),
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    card.designation,
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 25,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8EDF0),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'EMP ID: ${card.empId}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Blood group: ${card.bloodGroup}   •   Status: ${card.status.toUpperCase()}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttendanceMarkingOverlay extends StatelessWidget {
  const _AttendanceMarkingOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 280,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 26),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: Color(0x26000000),
                blurRadius: 28,
                offset: Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 132,
                height: 132,
                child: Lottie.asset(
                  'assets/images/splash.json',
                  repeat: true,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Marking Attendance',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Please wait...',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.subtleText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttendanceMarkedOverlay extends StatelessWidget {
  const _AttendanceMarkedOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 260,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: Color(0x26000000),
                blurRadius: 28,
                offset: Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0.72, end: 1),
                duration: const Duration(milliseconds: 520),
                curve: Curves.elasticOut,
                builder: (context, value, child) {
                  return Transform.scale(scale: value, child: child);
                },
                child: Container(
                  width: 86,
                  height: 86,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.success.withValues(alpha: 0.12),
                  ),
                  child: const Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.success,
                    size: 58,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Attendance Marked',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Returning to main page',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.subtleText,
                ),
              ),
              const SizedBox(height: 20),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: 1),
                duration: const Duration(seconds: 2),
                curve: Curves.linear,
                builder: (context, value, child) {
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      minHeight: 5,
                      value: value,
                      backgroundColor: AppColors.surfaceTint,
                      color: AppColors.success,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttendancePanel extends StatelessWidget {
  const _AttendancePanel({
    required this.title,
    required this.subtitle,
    required this.leading,
    this.trailing,
    this.subtitleColor = AppColors.subtleText,
  });

  final String title;
  final String subtitle;
  final IconData leading;
  final Widget? trailing;
  final Color subtitleColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primarySoft,
            ),
            child: Icon(leading, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: subtitleColor,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing ?? const SizedBox.shrink(),
        ],
      ),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.employee,
    required this.token,
    required this.notifications,
    required this.unreadNotificationCount,
    required this.onLogout,
    required this.onSessionExpired,
    required this.onEmployeeUpdated,
    required this.onNotificationsViewed,
    required this.onAttendanceChanged,
  });

  final Employee employee;
  final String token;
  final List<EmployeePushNotification> notifications;
  final int unreadNotificationCount;
  final Future<void> Function() onLogout;
  final Future<void> Function() onSessionExpired;
  final ValueChanged<Employee> onEmployeeUpdated;
  final Future<void> Function() onNotificationsViewed;
  final Future<void> Function(AttendanceRecord? attendance) onAttendanceChanged;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Employee get employee => widget.employee;
  String get token => widget.token;
  List<EmployeePushNotification> get notifications => widget.notifications;
  int get unreadNotificationCount => widget.unreadNotificationCount;
  Future<void> Function() get onLogout => widget.onLogout;
  Future<void> Function() get onSessionExpired => widget.onSessionExpired;
  ValueChanged<Employee> get onEmployeeUpdated => widget.onEmployeeUpdated;
  Future<void> Function() get onNotificationsViewed =>
      widget.onNotificationsViewed;
  Future<void> Function(AttendanceRecord? attendance) get onAttendanceChanged =>
      widget.onAttendanceChanged;

  bool? _idCardEnabled;
  bool? _hasIdCardSubmission;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshIdCardVisibility());
  }

  Future<void> _refreshIdCardVisibility() async {
    try {
      final access = await const EmployeeApiClient().idCardAccess(token);
      if (mounted) {
        setState(() {
          _idCardEnabled = access.enabled;
          _hasIdCardSubmission = access.submission != null;
        });
      }
    } on ApiException catch (error) {
      final normalized = error.message.trim().toLowerCase();
      if (normalized.contains('session expired') ||
          normalized.contains('sign in again') ||
          normalized.contains('login again') ||
          normalized == 'unauthenticated' ||
          normalized == 'unauthenticated.') {
        await onSessionExpired();
      }
    }
  }

  Future<void> _openIdCardPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EmployeeIdCardPage(
          employee: employee,
          token: token,
          apiClient: const EmployeeApiClient(),
        ),
      ),
    );
    await _refreshIdCardVisibility();
  }

  Future<void> _refreshDashboard() async {
    try {
      final employee = await const EmployeeApiClient().profile(token);
      onEmployeeUpdated(employee);
    } on ApiException catch (error) {
      final normalized = error.message.trim().toLowerCase();
      if (normalized.contains('session expired') ||
          normalized.contains('sign in again') ||
          normalized.contains('login again') ||
          normalized.contains('log in again') ||
          normalized == 'unauthenticated' ||
          normalized == 'unauthenticated.' ||
          normalized == 'unauthorized') {
        await onSessionExpired();
      }
    } catch (_) {}
    await _refreshIdCardVisibility();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final birthdayDate = _parseYmdDate(employee.dateOfBirth);
    final isBirthdayToday =
        birthdayDate != null &&
        birthdayDate.month == now.month &&
        birthdayDate.day == now.day;
    final headerTextColor = isBirthdayToday
        ? const Color(0xFF4B1F73)
        : AppColors.text;
    final headerSubtleColor = isBirthdayToday
        ? const Color(0xFF7A5670)
        : AppColors.subtleText;
    final shortcuts = <DashboardShortcut>[
      if (employee.canMarkAttendance)
        DashboardShortcut(
          title: 'My Attendance',
          icon: Icons.fingerprint,
          highlight: true,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MyAttendancePage(
                  employee: employee,
                  token: token,
                  apiClient: const EmployeeApiClient(),
                  onSessionExpired: onSessionExpired,
                  onAttendanceChanged: onAttendanceChanged,
                ),
              ),
            );
          },
        ),
      if (_idCardEnabled == true)
        DashboardShortcut(
          title: _hasIdCardSubmission == true
              ? 'ID Card'
              : 'Submit ID Card Details',
          icon: Icons.badge_outlined,
          highlight: false,
          onTap: _openIdCardPage,
        ),
      DashboardShortcut(
        title: 'Attendance Reports',
        icon: Icons.insert_chart_outlined,
        highlight: false,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ReportsPage(
                employee: employee,
                token: token,
                apiClient: const EmployeeApiClient(),
              ),
            ),
          );
        },
      ),
      if (!employee.isOutsourced)
        DashboardShortcut(
          title: 'Salary',
          icon: Icons.account_balance_wallet_outlined,
          highlight: false,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SalaryPage(
                  employee: employee,
                  token: token,
                  apiClient: const EmployeeApiClient(),
                ),
              ),
            );
          },
        ),
      if (employee.isBranchOpeningAssigned)
        DashboardShortcut(
          title: 'Branch Opening',
          icon: Icons.key_rounded,
          highlight:
              employee.branchOpeningStatus.trim().toLowerCase() == 'not_opened',
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => BranchOpeningPage(
                  employee: employee,
                  token: token,
                  apiClient: const EmployeeApiClient(),
                  onEmployeeUpdated: onEmployeeUpdated,
                ),
              ),
            );
          },
        ),
      DashboardShortcut(
        title: 'Leaves',
        icon: Icons.event_available_outlined,
        highlight: false,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => LeaveRequestPage(
                token: token,
                apiClient: const EmployeeApiClient(),
              ),
            ),
          );
        },
      ),
      if (!employee.isOutsourced)
        DashboardShortcut(
          title: 'Site Visit',
          icon: Icons.pin_drop_outlined,
          highlight: false,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SiteVisitRequestPage(
                  employee: employee,
                  token: token,
                  apiClient: const EmployeeApiClient(),
                ),
              ),
            );
          },
        ),
      if (_isTeDesignation(employee.designation))
        DashboardShortcut(
          title: 'TE Tracker',
          icon: Icons.route_rounded,
          highlight: false,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => TeTrackerPage(
                  employee: employee,
                  token: token,
                  apiClient: const EmployeeApiClient(),
                ),
              ),
            );
          },
        ),
      DashboardShortcut(
        title: 'Notifications',
        icon: unreadNotificationCount > 0
            ? Icons.notifications_active_rounded
            : Icons.notifications_none_rounded,
        highlight: unreadNotificationCount > 0,
        glow: unreadNotificationCount > 0,
        badgeCount: unreadNotificationCount,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => NotificationsPage(
                token: token,
                apiClient: const EmployeeApiClient(),
                initialNotifications: notifications,
                onNotificationsViewed: onNotificationsViewed,
              ),
            ),
          );
        },
      ),
      DashboardShortcut(
        title: 'My Profile',
        icon: Icons.badge_outlined,
        highlight: false,
        onTap: () {
          Navigator.of(context)
              .push<Employee>(
                MaterialPageRoute<Employee>(
                  builder: (_) => ProfilePage(
                    employee: employee,
                    token: token,
                    apiClient: const EmployeeApiClient(),
                  ),
                ),
              )
              .then((updatedEmployee) {
                if (updatedEmployee != null) {
                  onEmployeeUpdated(updatedEmployee);
                }
              });
        },
      ),
    ];

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: isBirthdayToday
                    ? const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xFFFFF7E8),
                          Color(0xFFFFE8D4),
                          AppColors.background,
                          AppColors.background,
                        ],
                        stops: [0.0, 0.24, 0.24, 1.0],
                      )
                    : null,
                color: isBirthdayToday ? null : AppColors.background,
              ),
              child: SafeArea(
                child: RefreshIndicator(
                  onRefresh: _refreshDashboard,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  _EmployeeAvatar(
                                    employee: employee,
                                    size: 54,
                                    textStyle: theme.textTheme.titleLarge
                                        ?.copyWith(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w800,
                                        ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          employee.name,
                                          style: theme.textTheme.headlineMedium
                                              ?.copyWith(
                                                color: headerTextColor,
                                                fontWeight: FontWeight.w800,
                                              ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          'Emp ID: ${employee.empId}',
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(
                                                color: headerSubtleColor,
                                              ),
                                        ),
                                        Text(
                                          'Branch ID: ${employee.branchId} • ${employee.branchName.isNotEmpty ? employee.branchName : 'Branch name unavailable'}',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: headerSubtleColor,
                                              ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton.filledTonal(
                                    onPressed: onLogout,
                                    style: IconButton.styleFrom(
                                      backgroundColor: isBirthdayToday
                                          ? const Color(0x33FFFFFF)
                                          : null,
                                      foregroundColor: isBirthdayToday
                                          ? const Color(0xFF4B1F73)
                                          : AppColors.secondary,
                                    ),
                                    icon: const Icon(Icons.logout_rounded),
                                  ),
                                ],
                              ),
                              if (isBirthdayToday) ...[
                                const SizedBox(height: 16),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(22),
                                    gradient: const LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Color(0xFFFFA06A),
                                        Color(0xFFFF6D8E),
                                        Color(0xFF6F40D8),
                                      ],
                                    ),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x1F8D275A),
                                        blurRadius: 26,
                                        offset: Offset(0, 14),
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.2,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                        alignment: Alignment.center,
                                        child: const Icon(
                                          Icons.cake_rounded,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Happy Birthday',
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'Wishing you joy, good health, and a fantastic year ahead.',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: Colors.white
                                                        .withValues(
                                                          alpha: 0.88,
                                                        ),
                                                    height: 1.45,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ] else
                                const SizedBox(height: 8),
                            ],
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            return Padding(
                              padding: EdgeInsets.only(
                                bottom: index == shortcuts.length - 1 ? 0 : 14,
                              ),
                              child: _ShortcutCard(item: shortcuts[index]),
                            );
                          }, childCount: shortcuts.length),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (isBirthdayToday)
            const Positioned.fill(
              child: IgnorePointer(child: _BirthdayBurstOverlay()),
            ),
        ],
      ),
    );
  }
}

class BranchOpeningPage extends StatefulWidget {
  const BranchOpeningPage({
    super.key,
    required this.employee,
    required this.token,
    required this.apiClient,
    required this.onEmployeeUpdated,
  });

  final Employee employee;
  final String token;
  final EmployeeApiClient apiClient;
  final ValueChanged<Employee> onEmployeeUpdated;

  @override
  State<BranchOpeningPage> createState() => _BranchOpeningPageState();
}

class _BranchOpeningPageState extends State<BranchOpeningPage> {
  late Employee _employee;
  bool _isRefreshing = false;
  bool _isSubmitting = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _employee = widget.employee;
    unawaited(_refreshEmployee(showLoader: false));
  }

  Future<void> _refreshEmployee({bool showLoader = true}) async {
    if (showLoader) {
      setState(() {
        _isRefreshing = true;
        _errorText = null;
      });
    }

    try {
      final employee = await widget.apiClient.profile(widget.token);
      if (!mounted) {
        return;
      }
      setState(() {
        _employee = employee;
        _errorText = null;
      });
      widget.onEmployeeUpdated(employee);
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = error.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to refresh branch opening details.';
      });
    } finally {
      if (mounted && showLoader) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  Future<void> _submitAction(Future<String> Function() action) async {
    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    try {
      final message = await action();
      final employee = await widget.apiClient.profile(widget.token);
      if (!mounted) {
        return;
      }
      setState(() {
        _employee = employee;
      });
      widget.onEmployeeUpdated(employee);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = error.message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to update branch opening status.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to update branch opening status.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final employee = _employee;
    final assignedKeys = <String>[
      if (employee.branchOpeningHasDoorKey) 'Door keys',
      if (employee.branchOpeningHasLockerKey) 'Locker keys',
      if (employee.isBranchOpeningEmployee) 'Branch opening',
    ];
    final assignedKeysLabel = assignedKeys.isEmpty
        ? 'No branch opening keys assigned'
        : assignedKeys.join(', ');
    final openingTimeLabel = employee.branchOpeningTime.trim().isEmpty
        ? '--'
        : _formatCompactTime(employee.branchOpeningTime).toUpperCase();
    final statusLabel = _branchOpeningStatusLabel(employee.branchOpeningStatus);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Branch Opening'),
        surfaceTintColor: Colors.transparent,
        backgroundColor: AppColors.background,
        actions: [
          IconButton(
            onPressed: _isRefreshing ? null : () => _refreshEmployee(),
            icon: _isRefreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refreshEmployee(showLoader: false),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _InsightBanner(
                title: 'Branch opening duties',
                subtitle:
                    'See your assigned keys, confirm when the branch is opened, and close the day from one place.',
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 16),
                _InlineInfoCard(
                  backgroundColor: const Color(0xFFFFE7E7),
                  icon: Icons.error_outline_rounded,
                  iconColor: const Color(0xFFD84A4A),
                  title: 'Could not update branch opening',
                  subtitle: _errorText!,
                ),
              ],
              const SizedBox(height: 18),
              const _SectionTitle(title: 'Current Assignment'),
              const SizedBox(height: 10),
              _ProfileDetailsCard(
                entries: [
                  _ProfileEntry(label: 'Branch', value: employee.branchId),
                  _ProfileEntry(
                    label: 'Branch Name',
                    value: employee.branchName.isNotEmpty
                        ? employee.branchName
                        : '--',
                  ),
                  _ProfileEntry(
                    label: 'Assigned Keys',
                    value: assignedKeysLabel,
                  ),
                  _ProfileEntry(label: 'Opening Time', value: openingTimeLabel),
                  _ProfileEntry(
                    label: 'Admin Number',
                    value: employee.branchOpeningAdminPhone.trim().isNotEmpty
                        ? employee.branchOpeningAdminPhone
                        : '--',
                  ),
                  _ProfileEntry(label: 'Status', value: statusLabel),
                  _ProfileEntry(
                    label: 'Opened At',
                    value: _formatBranchOpeningDateTime(
                      employee.branchOpeningOpenedAt,
                    ),
                  ),
                  _ProfileEntry(
                    label: 'Opened By',
                    value: employee.branchOpeningOpenedByLabel.trim().isNotEmpty
                        ? employee.branchOpeningOpenedByLabel
                        : '--',
                  ),
                  _ProfileEntry(
                    label: 'Closed At',
                    value: _formatBranchOpeningDateTime(
                      employee.branchOpeningClosedAt,
                    ),
                  ),
                  _ProfileEntry(
                    label: 'Closed By',
                    value: employee.branchOpeningClosedByLabel.trim().isNotEmpty
                        ? employee.branchOpeningClosedByLabel
                        : '--',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _InlineInfoCard(
                backgroundColor: _branchOpeningStatusColor(
                  employee.branchOpeningStatus,
                ),
                icon: Icons.storefront_rounded,
                iconColor: AppColors.primaryDark,
                title: 'Branch opening status',
                subtitle:
                    'Opening time ${openingTimeLabel == '--' ? 'is not configured yet' : 'is $openingTimeLabel'}. ${employee.branchOpeningAdminPhone.trim().isNotEmpty ? 'Call admin at ${employee.branchOpeningAdminPhone} if needed.' : 'Contact admin if timing changes are needed.'}',
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed:
                      _isSubmitting || !employee.branchOpeningCanMarkOpened
                      ? null
                      : () => _submitAction(
                          () => widget.apiClient.markBranchOpened(
                            token: widget.token,
                          ),
                        ),
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_open_rounded),
                  label: const Text('Mark Branch Opened'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed:
                      _isSubmitting || !employee.branchOpeningCanMarkClosed
                      ? null
                      : () => _submitAction(
                          () => widget.apiClient.markBranchClosed(
                            token: widget.token,
                          ),
                        ),
                  icon: const Icon(Icons.lock_clock_rounded),
                  label: const Text('Mark Branch Closed'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SalaryPage extends StatefulWidget {
  const SalaryPage({
    super.key,
    required this.employee,
    required this.token,
    required this.apiClient,
  });

  final Employee employee;
  final String token;
  final EmployeeApiClient apiClient;

  @override
  State<SalaryPage> createState() => _SalaryPageState();
}

class _SalaryPageState extends State<SalaryPage> {
  final _advanceRequestFormKey = GlobalKey<FormState>();
  final _advanceAmountController = TextEditingController();
  final _advanceRequestNoteController = TextEditingController();
  SalarySummary? _summary;
  List<AdvanceRequestRecord> _advanceRequests = const <AdvanceRequestRecord>[];
  bool _isLoading = true;
  bool _isSubmittingAdvanceRequest = false;
  String? _errorText;
  DateTime _selectedMonth = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  @override
  void dispose() {
    _advanceAmountController.dispose();
    _advanceRequestNoteController.dispose();
    super.dispose();
  }

  bool get _canMoveForward {
    final now = DateTime.now();
    return _selectedMonth.year < now.year ||
        (_selectedMonth.year == now.year && _selectedMonth.month < now.month);
  }

  String get _selectedMonthKey => _formatMonthKey(_selectedMonth);

  int get _selectedMonthDaysInMonth =>
      DateTime(_selectedMonth.year, _selectedMonth.month + 1, 0).day;

  int get _selectedMonthDaysElapsed {
    final now = DateTime.now();
    final isCurrentMonth =
        _selectedMonth.year == now.year && _selectedMonth.month == now.month;
    return isCurrentMonth ? now.day : _selectedMonthDaysInMonth;
  }

  double get _pendingAdvanceRequestTotal => _advanceRequests
      .where((request) => request.status.trim().toLowerCase() == 'pending')
      .fold<double>(0, (total, request) => total + request.amount);

  bool get _isOutsourcedEmployee => widget.employee.isOutsourced;

  Future<void> _loadSummary({bool showLoader = true}) async {
    if (showLoader) {
      setState(() {
        _isLoading = true;
        _errorText = null;
      });
    } else {
      setState(() {
        _errorText = null;
      });
    }

    try {
      final summary = await widget.apiClient.salarySummary(
        token: widget.token,
        month: _selectedMonthKey,
      );
      final advanceRequests = _isOutsourcedEmployee
          ? const <AdvanceRequestRecord>[]
          : await widget.apiClient.advanceRequests(token: widget.token);

      if (!mounted) {
        return;
      }
      setState(() {
        _summary = summary;
        _advanceRequests = advanceRequests;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = error.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to load salary summary.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _moveMonth(int offset) async {
    setState(() {
      _selectedMonth = DateTime(
        _selectedMonth.year,
        _selectedMonth.month + offset,
      );
    });
    await _loadSummary(showLoader: false);
  }

  Future<void> _submitAdvanceRequest() async {
    if (_advanceRequestFormKey.currentState?.validate() != true) {
      return;
    }

    final amount = double.tryParse(_advanceAmountController.text.trim());

    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid advance amount.')),
      );
      return;
    }
    if (amount > 5000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Advance requests cannot exceed ₹5,000.')),
      );
      return;
    }

    setState(() {
      _isSubmittingAdvanceRequest = true;
    });

    try {
      final message = await widget.apiClient.submitAdvanceRequest(
        token: widget.token,
        amount: amount,
        requestNote: _advanceRequestNoteController.text.trim(),
      );

      if (!mounted) {
        return;
      }

      _advanceAmountController.clear();
      _advanceRequestNoteController.clear();
      await _loadSummary(showLoader: false);
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to submit advance request.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmittingAdvanceRequest = false;
        });
      }
    }
  }

  Color _advanceRequestStatusBackground(String status) {
    switch (status.trim().toLowerCase()) {
      case 'verified':
        return const Color(0xFFE8F7ED);
      case 'rejected':
        return const Color(0xFFFFEFEF);
      default:
        return const Color(0xFFFFF6E8);
    }
  }

  Color _advanceRequestStatusText(String status) {
    switch (status.trim().toLowerCase()) {
      case 'verified':
        return const Color(0xFF177245);
      case 'rejected':
        return const Color(0xFFB43737);
      default:
        return const Color(0xFF8B5A0B);
    }
  }

  String _advanceRequestStatusLabel(String status) {
    switch (status.trim().toLowerCase()) {
      case 'verified':
        return 'Verified';
      case 'rejected':
        return 'Rejected';
      default:
        return 'Pending';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = _summary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Salary'),
        surfaceTintColor: Colors.transparent,
        backgroundColor: AppColors.background,
        actions: [
          IconButton(
            onPressed: () => _loadSummary(showLoader: false),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _isLoading && summary == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _loadSummary(showLoader: false),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x12000000),
                            blurRadius: 16,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              IconButton.filledTonal(
                                onPressed: () => _moveMonth(-1),
                                icon: const Icon(Icons.chevron_left_rounded),
                              ),
                              Expanded(
                                child: Column(
                                  children: [
                                    Text(
                                      _formatMonthLabel(_selectedMonth),
                                      style: theme.textTheme.titleLarge
                                          ?.copyWith(
                                            color: AppColors.text,
                                            fontWeight: FontWeight.w800,
                                          ),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      widget.employee.name,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: AppColors.subtleText,
                                          ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              ),
                              IconButton.filledTonal(
                                onPressed: _canMoveForward
                                    ? () => _moveMonth(1)
                                    : null,
                                icon: const Icon(Icons.chevron_right_rounded),
                              ),
                            ],
                          ),
                          if (_isLoading) ...[
                            const SizedBox(height: 12),
                            const LinearProgressIndicator(),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(28),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            AppColors.primaryDark,
                            AppColors.primary,
                            Color(0xFF7B48D9),
                          ],
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            summary?.monthLabel ??
                                _formatMonthLabel(_selectedMonth),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: Colors.white.withValues(alpha: 0.82),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _formatCurrencyValue(summary?.netPayableSalary),
                            style: theme.textTheme.displayMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Payable estimate for ${summary?.monthLabel ?? _formatMonthLabel(_selectedMonth)}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white.withValues(alpha: 0.82),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_errorText != null) ...[
                      const SizedBox(height: 16),
                      _InlineInfoCard(
                        backgroundColor: const Color(0xFFFFE7E7),
                        icon: Icons.error_outline_rounded,
                        iconColor: const Color(0xFFD84A4A),
                        title: 'Could not refresh salary summary',
                        subtitle: _errorText!,
                      ),
                    ],
                    const SizedBox(height: 18),
                    const _SectionTitle(title: 'Monthly Snapshot'),
                    const SizedBox(height: 10),
                    _ProfileDetailsCard(
                      entries: [
                        _ProfileEntry(
                          label: 'Base Salary',
                          value: _formatCurrencyValue(
                            summary?.salary ??
                                widget.employee.salary?.toDouble(),
                          ),
                        ),
                        _ProfileEntry(
                          label: 'Salary / Day',
                          value: _formatCurrencyValue(summary?.salaryPerDay),
                        ),
                        _ProfileEntry(
                          label: 'Advance Deduction',
                          value: _formatCurrencyValue(summary?.advance),
                        ),
                        _ProfileEntry(
                          label: 'PF',
                          value: _formatCurrencyValue(
                            summary?.pf ?? widget.employee.pf?.toDouble(),
                          ),
                        ),
                        _ProfileEntry(
                          label: 'Gross Payable',
                          value: _formatCurrencyValue(
                            summary?.grossPayableSalary,
                          ),
                        ),
                        _ProfileEntry(
                          label: 'Net Payable',
                          value: _formatCurrencyValue(
                            summary?.netPayableSalary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const _SectionTitle(title: 'Advance Requests'),
                    const SizedBox(height: 10),
                    if (_isOutsourcedEmployee)
                      const _InlineInfoCard(
                        backgroundColor: Color(0xFFFFF0F0),
                        icon: Icons.block_rounded,
                        iconColor: Color(0xFFD84A4A),
                        title: 'Advance requests are unavailable',
                        subtitle:
                            'Outsourced employees cannot request salary advance from the app.',
                      )
                    else ...[
                      Form(
                        key: _advanceRequestFormKey,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x12000000),
                                blurRadius: 16,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Request advance from admin',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: AppColors.text,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Only verified requests are deducted in this month\'s salary and shown in Advance Deduction.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppColors.subtleText,
                                ),
                              ),
                              const SizedBox(height: 14),
                              TextFormField(
                                controller: _advanceAmountController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: _fieldDecoration(
                                  hintText: 'Advance amount (maximum ₹5,000)',
                                  prefixIcon: Icons.currency_rupee_rounded,
                                ),
                                validator: (value) {
                                  final parsed = double.tryParse(
                                    (value ?? '').trim(),
                                  );
                                  if (parsed == null || parsed <= 0) {
                                    return 'Enter a valid amount.';
                                  }
                                  if (parsed > 5000) {
                                    return 'Maximum request amount is ₹5,000.';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _advanceRequestNoteController,
                                minLines: 2,
                                maxLines: 3,
                                decoration: _fieldDecoration(
                                  hintText: 'Reason (optional)',
                                  prefixIcon: Icons.edit_note_rounded,
                                ),
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: _isSubmittingAdvanceRequest
                                      ? null
                                      : _submitAdvanceRequest,
                                  icon: _isSubmittingAdvanceRequest
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.send_rounded),
                                  label: const Text('Submit Advance Request'),
                                ),
                              ),
                              if (_pendingAdvanceRequestTotal > 0) ...[
                                const SizedBox(height: 10),
                                Text(
                                  'Pending requested advance: ${_formatCurrencyValue(_pendingAdvanceRequestTotal)}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFF8B5A0B),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x12000000),
                              blurRadius: 16,
                              offset: Offset(0, 8),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(16),
                        child: _advanceRequests.isEmpty
                            ? Text(
                                'No advance requests yet.',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: AppColors.subtleText,
                                ),
                              )
                            : Column(
                                children: _advanceRequests
                                    .map(
                                      (request) => Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 10,
                                        ),
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF8F6FC),
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    _formatCurrencyValue(
                                                      request.amount,
                                                    ),
                                                    style: theme
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          color: AppColors.text,
                                                          fontWeight:
                                                              FontWeight.w800,
                                                        ),
                                                  ),
                                                ),
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 10,
                                                        vertical: 4,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color:
                                                        _advanceRequestStatusBackground(
                                                          request.status,
                                                        ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          99,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    _advanceRequestStatusLabel(
                                                      request.status,
                                                    ),
                                                    style: theme
                                                        .textTheme
                                                        .labelMedium
                                                        ?.copyWith(
                                                          color:
                                                              _advanceRequestStatusText(
                                                                request.status,
                                                              ),
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              'Request date: ${_formatIsoDate(request.requestDate)}',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: AppColors.subtleText,
                                                  ),
                                            ),
                                            if (request.requestNote
                                                .trim()
                                                .isNotEmpty) ...[
                                              const SizedBox(height: 4),
                                              Text(
                                                request.requestNote.trim(),
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      color: AppColors.text,
                                                    ),
                                              ),
                                            ],
                                            if (request.adminNote
                                                .trim()
                                                .isNotEmpty) ...[
                                              const SizedBox(height: 4),
                                              Text(
                                                'Admin note: ${request.adminNote.trim()}',
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      color:
                                                          AppColors.subtleText,
                                                    ),
                                              ),
                                            ],
                                            if (request.createdAt
                                                .trim()
                                                .isNotEmpty) ...[
                                              const SizedBox(height: 4),
                                              Text(
                                                'Submitted: ${_formatBranchOpeningDateTime(request.createdAt)}',
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      color:
                                                          AppColors.subtleText,
                                                    ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    const _SectionTitle(title: 'Attendance Impact'),
                    const SizedBox(height: 10),
                    _ProfileDetailsCard(
                      entries: [
                        _ProfileEntry(
                          label: 'Full Days',
                          value: '${summary?.fullDays ?? 0}',
                        ),
                        _ProfileEntry(
                          label: 'Admin Overrides',
                          value: '${summary?.adminOverrideDays ?? 0}',
                        ),
                        _ProfileEntry(
                          label: 'Half Days',
                          value: '${summary?.halfDays ?? 0}',
                        ),
                        _ProfileEntry(
                          label: 'Single Punch Days',
                          value: '${summary?.singlePunchDays ?? 0}',
                        ),
                        _ProfileEntry(
                          label: 'Absent Days',
                          value: '${summary?.absentDays ?? 0}',
                        ),
                        _ProfileEntry(
                          label: 'Sunday Logins',
                          value: '${summary?.sundayLoggedDays ?? 0}',
                        ),
                        _ProfileEntry(
                          label: 'Payable Days',
                          value: _formatDecimalValue(summary?.payableDays),
                        ),
                        _ProfileEntry(
                          label: 'Progress',
                          value:
                              '${summary?.daysElapsed ?? _selectedMonthDaysElapsed}/${summary?.daysInMonth ?? _selectedMonthDaysInMonth}',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class LeaveRequestPage extends StatefulWidget {
  const LeaveRequestPage({
    super.key,
    required this.token,
    required this.apiClient,
  });

  final String token;
  final EmployeeApiClient apiClient;

  @override
  State<LeaveRequestPage> createState() => _LeaveRequestPageState();
}

class _LeaveRequestPageState extends State<LeaveRequestPage> {
  final _formKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  List<LeaveRequestRecord> _leaveRequests = const <LeaveRequestRecord>[];
  bool _isLoadingRequests = true;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _loadLeaveRequests();
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _loadLeaveRequests({bool showLoader = true}) async {
    if (showLoader && mounted) {
      setState(() {
        _isLoadingRequests = true;
      });
    }

    try {
      final requests = await widget.apiClient.leaveRequests(
        token: widget.token,
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _leaveRequests = requests;
        _isLoadingRequests = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isLoadingRequests = false;
      });
    }
  }

  Future<void> _pickDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final initialDate = _selectedDate.isBefore(today) ? today : _selectedDate;
    final selected = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: today,
      lastDate: DateTime(today.year + 1, 12, 31),
    );

    if (selected == null || !mounted) {
      return;
    }

    setState(() {
      _selectedDate = selected;
    });
  }

  Future<void> _submit() async {
    if (_formKey.currentState?.validate() != true) {
      return;
    }

    final today = DateUtils.dateOnly(DateTime.now());
    if (DateUtils.dateOnly(_selectedDate).isBefore(today)) {
      setState(() {
        _selectedDate = today;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Leave date cannot be earlier than today.'),
        ),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isSubmitting = true;
    });

    try {
      final message = await widget.apiClient.submitLeave(
        token: widget.token,
        leaveDate: _selectedDate,
        reason: _reasonController.text.trim(),
      );
      if (!mounted) {
        return;
      }

      _reasonController.clear();
      await _loadLeaveRequests(showLoader: false);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to submit leave request.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Apply Leave'),
        surfaceTintColor: Colors.transparent,
        backgroundColor: AppColors.background,
      ),
      body: RefreshIndicator(
        onRefresh: () => _loadLeaveRequests(showLoader: false),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _InsightBanner(
                  title: 'Plan your leave',
                  subtitle:
                      'Choose the leave date, add the reason, and send it to HR for review.',
                ),
                const SizedBox(height: 18),
                _LabeledField(
                  label: 'Leave Date',
                  child: InkWell(
                    onTap: _pickDate,
                    borderRadius: BorderRadius.circular(18),
                    child: Ink(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 18,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceTint,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_today_outlined),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _formatIsoDate(_selectedDate.toIso8601String()),
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _LabeledField(
                  label: 'Reason',
                  child: TextFormField(
                    controller: _reasonController,
                    maxLines: 5,
                    decoration: _fieldDecoration(
                      hintText: 'Describe the leave request',
                      prefixIcon: Icons.notes_rounded,
                    ),
                    validator: (value) {
                      if (value == null || value.trim().length < 5) {
                        return 'Enter a valid reason.';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isSubmitting ? null : _submit,
                    icon: _isSubmitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                    label: Text(
                      _isSubmitting ? 'Submitting...' : 'Submit Leave Request',
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                _RequestHistoryHeader(
                  title: 'Your leave requests',
                  onRefresh: _isLoadingRequests
                      ? null
                      : () => _loadLeaveRequests(showLoader: true),
                ),
                const SizedBox(height: 12),
                if (_isLoadingRequests)
                  const Center(child: CircularProgressIndicator())
                else if (_leaveRequests.isEmpty)
                  const _EmptyRequestState(
                    message:
                        'Your leave requests will appear here after submission.',
                  )
                else
                  Column(
                    children: _leaveRequests
                        .map(
                          (request) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _LeaveRequestHistoryCard(request: request),
                          ),
                        )
                        .toList(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SiteVisitRequestPage extends StatefulWidget {
  const SiteVisitRequestPage({
    super.key,
    required this.employee,
    required this.token,
    required this.apiClient,
  });

  final Employee employee;
  final String token;
  final EmployeeApiClient apiClient;

  @override
  State<SiteVisitRequestPage> createState() => _SiteVisitRequestPageState();
}

class _SiteVisitRequestPageState extends State<SiteVisitRequestPage> {
  final _formKey = GlobalKey<FormState>();
  final _siteLocationController = TextEditingController();
  final _reasonController = TextEditingController();
  final _approvedByController = TextEditingController();

  DateTime _selectedDate = DateTime.now();
  File? _photo;
  Uint8List? _photoBytes;
  String? _photoFilename;
  Position? _position;
  List<SiteVisitRequestRecord> _siteVisitRequests =
      const <SiteVisitRequestRecord>[];
  bool _isPickingPhoto = false;
  bool _isFetchingLocation = false;
  bool _isLoadingRequests = true;
  bool _isSubmitting = false;
  FakeLocationIssue? _fakeLocationIssue;

  @override
  void initState() {
    super.initState();
    _loadSiteVisitRequests();
  }

  @override
  void dispose() {
    _siteLocationController.dispose();
    _reasonController.dispose();
    _approvedByController.dispose();
    super.dispose();
  }

  Future<void> _loadSiteVisitRequests({bool showLoader = true}) async {
    if (showLoader && mounted) {
      setState(() {
        _isLoadingRequests = true;
      });
    }

    try {
      final requests = await widget.apiClient.siteVisitRequests(
        token: widget.token,
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _siteVisitRequests = requests;
        _isLoadingRequests = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isLoadingRequests = false;
      });
    }
  }

  double? get _distanceFromBranchMeters {
    final position = _position;
    final branchLatitude = widget.employee.branchLatitude;
    final branchLongitude = widget.employee.branchLongitude;

    if (position == null || branchLatitude == null || branchLongitude == null) {
      return null;
    }

    return Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      branchLatitude,
      branchLongitude,
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1, 12, 31),
    );

    if (selected == null || !mounted) {
      return;
    }

    setState(() {
      _selectedDate = selected;
    });
  }

  Future<void> _capturePhoto() async {
    setState(() {
      _isPickingPhoto = true;
    });

    try {
      if (kIsWeb) {
        final capturedBytes = await Navigator.of(context).push<Uint8List>(
          MaterialPageRoute<Uint8List>(
            builder: (_) => _WebCameraCapturePage(
              title: 'Site Visit Photo',
              subtitle:
                  'Capture a clear site photo. You can switch between front and back camera.',
              preferredLensDirection: CameraLensDirection.front,
            ),
            fullscreenDialog: true,
          ),
        );

        if (capturedBytes == null || capturedBytes.isEmpty || !mounted) {
          return;
        }

        setState(() {
          _photo = null;
          _photoBytes = capturedBytes;
          _photoFilename =
              'site-visit-${DateTime.now().millisecondsSinceEpoch}.jpg';
        });
      } else {
        final image = await Navigator.of(context).push<File>(
          MaterialPageRoute<File>(
            builder: (_) => const FrontCameraCapturePage(
              title: 'Site Visit Photo',
              subtitle:
                  'Use the selfie camera only. The back camera is disabled in this app.',
            ),
            fullscreenDialog: true,
          ),
        );

        if (image == null || !mounted) {
          return;
        }

        setState(() {
          _photo = image;
          _photoBytes = null;
          _photoFilename = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isPickingPhoto = false;
        });
      }
    }
  }

  Future<void> _openFakeLocationSettings() async {
    final issue = _fakeLocationIssue;
    if (issue == null) {
      return;
    }

    try {
      await LocationIntegrityService.openIssueSettings(issue);
    } on PlatformException {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to open settings on this device.'),
        ),
      );
    }
  }

  Future<void> _fetchLocation() async {
    setState(() {
      _isFetchingLocation = true;
      _position = null;
      _fakeLocationIssue = null;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw ApiException('Location services are disabled.');
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw ApiException('Location permission is required for site visits.');
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      await LocationIntegrityService.ensureTrustedPosition(
        position,
        actionLabel: 'submitting the site visit',
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _position = position;
        _fakeLocationIssue = null;
      });
    } on FakeLocationException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _position = null;
        _fakeLocationIssue = error.issue;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _position = null;
        _fakeLocationIssue = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _position = null;
        _fakeLocationIssue = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to fetch current location.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isFetchingLocation = false;
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_formKey.currentState?.validate() != true) {
      return;
    }

    if (_photo == null && (_photoBytes == null || _photoBytes!.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Capture a site visit photo first.')),
      );
      return;
    }

    if (_position == null) {
      await _fetchLocation();
    }

    final position = _position;
    if (position == null) {
      return;
    }

    if (!mounted) {
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isSubmitting = true;
      _fakeLocationIssue = null;
    });

    try {
      final message = await widget.apiClient.submitSiteVisit(
        token: widget.token,
        visitDate: _selectedDate,
        siteLocation: _siteLocationController.text.trim(),
        latitude: position.latitude,
        longitude: position.longitude,
        reason: _reasonController.text.trim(),
        approvedBy: _approvedByController.text.trim(),
        photo: _photo,
        photoBytes: _photoBytes,
        photoFilename: _photoFilename,
      );
      if (!mounted) {
        return;
      }

      _siteLocationController.clear();
      _reasonController.clear();
      _approvedByController.clear();
      setState(() {
        _photo = null;
        _photoBytes = null;
        _photoFilename = null;
        _fakeLocationIssue = null;
      });
      await _loadSiteVisitRequests(showLoader: false);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on FakeLocationException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _fakeLocationIssue = error.issue;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _fakeLocationIssue = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _fakeLocationIssue = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to submit site visit request.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final distance = _distanceFromBranchMeters;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Site Visit Request'),
        surfaceTintColor: Colors.transparent,
        backgroundColor: AppColors.background,
      ),
      body: RefreshIndicator(
        onRefresh: () => _loadSiteVisitRequests(showLoader: false),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _InsightBanner(
                  title: 'Request remote work visit',
                  subtitle:
                      'Submit your off-site visit with GPS, photo, and manager assignment details for HR review.',
                ),
                const SizedBox(height: 18),
                _LabeledField(
                  label: 'Visit Date',
                  child: InkWell(
                    onTap: _pickDate,
                    borderRadius: BorderRadius.circular(18),
                    child: Ink(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 18,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceTint,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_today_outlined),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _formatIsoDate(_selectedDate.toIso8601String()),
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _LabeledField(
                  label: 'Site Location',
                  child: TextFormField(
                    controller: _siteLocationController,
                    decoration: _fieldDecoration(
                      hintText: 'Enter the client or site location',
                      prefixIcon: Icons.location_on_outlined,
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Site location is required.';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(height: 16),
                _LabeledField(
                  label: 'Assigned By',
                  child: TextFormField(
                    controller: _approvedByController,
                    decoration: _fieldDecoration(
                      hintText: 'Manager or assigner name',
                      prefixIcon: Icons.person_outline_rounded,
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Assigned by is required.';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(height: 16),
                _LabeledField(
                  label: 'Reason',
                  child: TextFormField(
                    controller: _reasonController,
                    maxLines: 5,
                    decoration: _fieldDecoration(
                      hintText: 'Why is this site visit needed?',
                      prefixIcon: Icons.notes_rounded,
                    ),
                    validator: (value) {
                      if (value == null || value.trim().length < 5) {
                        return 'Enter a valid reason.';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(height: 16),
                if (_fakeLocationIssue != null) ...[
                  _InlineInfoCard(
                    backgroundColor: const Color(0xFFFFE7E7),
                    icon: Icons.gpp_bad_outlined,
                    iconColor: const Color(0xFFD84A4A),
                    title: 'Fake location detected',
                    subtitle: _fakeLocationIssue!.message,
                    titleColor: const Color(0xFF9A1B1B),
                    subtitleColor: const Color(0xFF9A1B1B),
                    action: TextButton.icon(
                      onPressed: _openFakeLocationSettings,
                      icon: const Icon(Icons.settings_outlined),
                      label: Text(_fakeLocationIssue!.actionLabel),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _InlineInfoCard(
                  backgroundColor: AppColors.surface,
                  icon: Icons.my_location_rounded,
                  iconColor: AppColors.primary,
                  title: _position == null
                      ? 'Current GPS not captured yet'
                      : '${_position!.latitude.toStringAsFixed(6)}, ${_position!.longitude.toStringAsFixed(6)}',
                  subtitle: distance == null
                      ? 'Use current GPS before submitting the request.'
                      : 'Current distance from branch: ${_formatDistanceMeters(distance)}',
                  action: TextButton(
                    onPressed: _isFetchingLocation ? null : _fetchLocation,
                    child: Text(
                      _isFetchingLocation ? 'Fetching...' : 'Use Current GPS',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _InlineInfoCard(
                  backgroundColor: AppColors.surface,
                  icon: Icons.camera_alt_outlined,
                  iconColor: AppColors.primary,
                  title:
                      (_photo == null &&
                          (_photoBytes == null || _photoBytes!.isEmpty))
                      ? 'Site photo not captured yet'
                      : 'Photo ready to upload',
                  subtitle:
                      (_photo == null &&
                          (_photoBytes == null || _photoBytes!.isEmpty))
                      ? 'Capture an on-site photo before submitting.'
                      : (_photoFilename?.trim().isNotEmpty ?? false)
                      ? _photoFilename!
                      : _photo!.path.split(Platform.pathSeparator).last,
                  action: TextButton(
                    onPressed: _isPickingPhoto ? null : _capturePhoto,
                    child: Text(
                      _isPickingPhoto ? 'Opening...' : 'Capture Photo',
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isSubmitting ? null : _submit,
                    icon: _isSubmitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                    label: Text(
                      _isSubmitting
                          ? 'Submitting...'
                          : 'Submit Site Visit Request',
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                _RequestHistoryHeader(
                  title: 'Your site visit requests',
                  onRefresh: _isLoadingRequests
                      ? null
                      : () => _loadSiteVisitRequests(showLoader: true),
                ),
                const SizedBox(height: 12),
                if (_isLoadingRequests)
                  const Center(child: CircularProgressIndicator())
                else if (_siteVisitRequests.isEmpty)
                  const _EmptyRequestState(
                    message:
                        'Your site visit requests will appear here after submission.',
                  )
                else
                  Column(
                    children: _siteVisitRequests
                        .map(
                          (request) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _SiteVisitRequestHistoryCard(
                              request: request,
                            ),
                          ),
                        )
                        .toList(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TeTrackerPage extends StatefulWidget {
  const TeTrackerPage({
    super.key,
    required this.employee,
    required this.token,
    required this.apiClient,
  });

  final Employee employee;
  final String token;
  final EmployeeApiClient apiClient;

  @override
  State<TeTrackerPage> createState() => _TeTrackerPageState();
}

class _TeTrackerPageState extends State<TeTrackerPage> {
  List<TeTrackerBranch> _branches = const <TeTrackerBranch>[];
  TeTrackerHistoryResponse? _history;
  String? _selectedBranchId;
  Position? _position;
  File? _photo;
  bool _isLoading = true;
  bool _isFetchingLocation = false;
  bool _isPickingPhoto = false;
  bool _isSubmitting = false;
  String? _errorText;
  FakeLocationIssue? _fakeLocationIssue;

  @override
  void initState() {
    super.initState();
    _initializePage();
  }

  Future<void> _initializePage() async {
    await _loadTrackerData();
    if (!mounted) {
      return;
    }

    _fetchLocation(silent: true);
  }

  TeTrackerBranch? get _selectedBranch {
    final selectedBranchId = (_selectedBranchId ?? '').trim();
    if (selectedBranchId.isEmpty) {
      return null;
    }

    for (final branch in _branches) {
      if (branch.branchId == selectedBranchId) {
        return branch;
      }
    }

    return null;
  }

  double? get _distanceFromSelectedBranchMeters {
    final position = _position;
    final selectedBranch = _selectedBranch;

    if (position == null ||
        selectedBranch == null ||
        selectedBranch.latitude == null ||
        selectedBranch.longitude == null) {
      return null;
    }

    return Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      selectedBranch.latitude!,
      selectedBranch.longitude!,
    );
  }

  Future<void> _loadTrackerData({bool showLoader = true}) async {
    if (showLoader) {
      setState(() {
        _isLoading = true;
        _errorText = null;
      });
    }

    try {
      final branches = await widget.apiClient.teTrackerBranches(
        token: widget.token,
      );
      final history = await widget.apiClient.teTrackerVisits(
        token: widget.token,
      );

      if (!mounted) {
        return;
      }

      final existingSelection = (_selectedBranchId ?? '').trim();
      final hasExistingSelection = branches.any(
        (branch) => branch.branchId == existingSelection,
      );
      final lastVisitedBranchId = history.visits.isNotEmpty
          ? history.visits.last.branchId.trim()
          : '';
      final hasLastVisitedBranch = branches.any(
        (branch) => branch.branchId == lastVisitedBranchId,
      );

      setState(() {
        _branches = branches;
        _history = history;
        _selectedBranchId = hasExistingSelection
            ? existingSelection
            : hasLastVisitedBranch
            ? lastVisitedBranchId
            : branches.isNotEmpty
            ? branches.first.branchId
            : null;
        _errorText = null;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorText = error.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorText = 'Unable to load TE tracker details right now.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchLocation({bool silent = false}) async {
    setState(() {
      _isFetchingLocation = true;
      _position = null;
      _fakeLocationIssue = null;
      if (!silent) {
        _errorText = null;
      }
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw ApiException('Location services are disabled.');
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw ApiException('Location permission is required for TE tracker.');
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      await LocationIntegrityService.ensureTrustedPosition(
        position,
        actionLabel: 'recording the TE tracker visit',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _position = position;
        _fakeLocationIssue = null;
      });
    } on FakeLocationException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _position = null;
        _fakeLocationIssue = error.issue;
        _errorText = error.message;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _position = null;
        _fakeLocationIssue = null;
        _errorText = error.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _position = null;
        _fakeLocationIssue = null;
        _errorText = 'Unable to fetch current location.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isFetchingLocation = false;
        });
      }
    }
  }

  Future<void> _capturePhoto() async {
    setState(() {
      _isPickingPhoto = true;
    });

    try {
      final image = await Navigator.of(context).push<File>(
        MaterialPageRoute<File>(
          builder: (_) => const FrontCameraCapturePage(
            title: 'TE Tracker Photo',
            subtitle:
                'Use the selfie camera only. The back camera is disabled in this app.',
          ),
          fullscreenDialog: true,
        ),
      );

      if (image == null || !mounted) {
        return;
      }

      setState(() {
        _photo = image;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isPickingPhoto = false;
        });
      }
    }
  }

  Future<void> _openFakeLocationSettings() async {
    final issue = _fakeLocationIssue;
    if (issue == null) {
      return;
    }

    try {
      await LocationIntegrityService.openIssueSettings(issue);
    } on PlatformException {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to open settings on this device.'),
        ),
      );
    }
  }

  Future<void> _submit() async {
    final selectedBranch = _selectedBranch;
    if (selectedBranch == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select the branch you reached first.')),
      );
      return;
    }

    if (_photo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Capture a TE tracker photo first.')),
      );
      return;
    }

    if (_position == null) {
      await _fetchLocation();
    }

    final position = _position;
    if (position == null) {
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _isSubmitting = true;
      _fakeLocationIssue = null;
      _errorText = null;
    });

    try {
      final message = await widget.apiClient.teTrackerCheckIn(
        token: widget.token,
        branchId: selectedBranch.branchId,
        latitude: position.latitude,
        longitude: position.longitude,
        photo: _photo!,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _photo = null;
        _fakeLocationIssue = null;
      });

      await _loadTrackerData(showLoader: false);
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on FakeLocationException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fakeLocationIssue = error.issue;
        _errorText = error.message;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fakeLocationIssue = null;
        _errorText = error.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _fakeLocationIssue = null;
        _errorText = 'Unable to record the TE tracker visit.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = _history;
    final selectedBranch = _selectedBranch;
    final distance = _distanceFromSelectedBranchMeters;

    return Scaffold(
      appBar: AppBar(
        title: const Text('TE Tracker'),
        surfaceTintColor: Colors.transparent,
        backgroundColor: AppColors.background,
        actions: [
          IconButton(
            onPressed: _isLoading
                ? null
                : () => _loadTrackerData(showLoader: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _isLoading && history == null && _branches.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _loadTrackerData(showLoader: false),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _InsightBanner(
                      title: 'Track every branch visit',
                      subtitle:
                          'Select the branch you reached, capture GPS and a selfie, and record the TE travel path for today.',
                    ),
                    if (_errorText != null) ...[
                      const SizedBox(height: 16),
                      _InlineInfoCard(
                        backgroundColor: const Color(0xFFFFE7E7),
                        icon: Icons.error_outline_rounded,
                        iconColor: const Color(0xFFD84A4A),
                        title: 'TE tracker needs attention',
                        subtitle: _errorText!,
                        titleColor: const Color(0xFF9A1B1B),
                        subtitleColor: const Color(0xFF9A1B1B),
                        action: _fakeLocationIssue == null
                            ? null
                            : TextButton.icon(
                                onPressed: _openFakeLocationSettings,
                                icon: const Icon(Icons.settings_outlined),
                                label: Text(_fakeLocationIssue!.actionLabel),
                              ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    _LabeledField(
                      label: 'Reached Branch',
                      child: _SearchableSelectionField<String>(
                        hintText: 'Select the branch you reached',
                        prefixIcon: Icons.apartment_rounded,
                        selectedValue: selectedBranch?.branchId,
                        enabled: !_isSubmitting,
                        emptyMessage: 'No branches match your search.',
                        options: _branches
                            .map(
                              (branch) => _SearchableOption<String>(
                                value: branch.branchId,
                                label: branch.label,
                                searchText:
                                    '${branch.branchId} ${branch.branchName} ${branch.city} ${branch.state}',
                              ),
                            )
                            .toList(),
                        onSelected: (value) {
                          setState(() {
                            _selectedBranchId = value;
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    _InlineInfoCard(
                      backgroundColor: AppColors.surface,
                      icon: Icons.my_location_rounded,
                      iconColor: AppColors.primary,
                      title: _position == null
                          ? 'Current GPS not captured yet'
                          : '${_position!.latitude.toStringAsFixed(6)}, ${_position!.longitude.toStringAsFixed(6)}',
                      subtitle: _isFetchingLocation
                          ? 'Fetching your current GPS position.'
                          : selectedBranch == null
                          ? 'Choose a branch to compare your distance from it.'
                          : selectedBranch.latitude == null ||
                                selectedBranch.longitude == null
                          ? 'Selected branch coordinates are unavailable.'
                          : distance == null
                          ? 'Current distance to ${selectedBranch.label} will appear here.'
                          : 'Current distance to ${selectedBranch.label}: ${_formatDistanceMeters(distance)}',
                      action: TextButton(
                        onPressed: _isFetchingLocation
                            ? null
                            : () => _fetchLocation(silent: false),
                        child: Text(
                          _isFetchingLocation
                              ? 'Fetching...'
                              : 'Use Current GPS',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _InlineInfoCard(
                      backgroundColor: AppColors.surface,
                      icon: Icons.camera_alt_outlined,
                      iconColor: AppColors.primary,
                      title: _photo == null
                          ? 'TE tracker photo not captured yet'
                          : 'Photo ready to upload',
                      subtitle: _photo == null
                          ? 'Capture a selfie at the branch before recording the visit.'
                          : _photo!.path.split(Platform.pathSeparator).last,
                      action: TextButton(
                        onPressed: _isPickingPhoto ? null : _capturePhoto,
                        child: Text(
                          _isPickingPhoto ? 'Opening...' : 'Capture Photo',
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _isSubmitting ? null : _submit,
                        icon: _isSubmitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.route_rounded),
                        label: Text(
                          _isSubmitting
                              ? 'Recording visit...'
                              : 'Record TE Tracker Visit',
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    const _SectionTitle(title: 'Today\'s Route'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _TeTrackerMetricCard(
                          label: 'Visits',
                          value: '${history?.summary.totalVisits ?? 0}',
                        ),
                        _TeTrackerMetricCard(
                          label: 'Unique Branches',
                          value: '${history?.summary.uniqueBranches ?? 0}',
                        ),
                        _TeTrackerMetricCard(
                          label: 'Distance',
                          value: history?.summary.totalDistanceLabel ?? '0 m',
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _InlineInfoCard(
                      backgroundColor: AppColors.surface,
                      icon: Icons.timeline_rounded,
                      iconColor: AppColors.primary,
                      title:
                          'Start: ${history?.summary.startBranchLabel ?? 'No visits'}',
                      subtitle:
                          'End: ${history?.summary.endBranchLabel ?? 'No visits'}',
                    ),
                    const SizedBox(height: 18),
                    _RequestHistoryHeader(
                      title: 'Recorded branch visits',
                      onRefresh: _isLoading
                          ? null
                          : () => _loadTrackerData(showLoader: true),
                    ),
                    const SizedBox(height: 12),
                    if (history == null || history.visits.isEmpty)
                      const _EmptyRequestState(
                        message:
                            'Your TE route for today will appear here after you start recording branch visits.',
                      )
                    else
                      Column(
                        children: history.visits
                            .map(
                              (visit) => Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _TeTrackerVisitCard(visit: visit),
                              ),
                            )
                            .toList(),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _RequestHistoryHeader extends StatelessWidget {
  const _RequestHistoryHeader({required this.title, this.onRefresh});

  final String title;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        IconButton(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh_rounded),
          tooltip: 'Refresh',
        ),
      ],
    );
  }
}

class _EmptyRequestState extends StatelessWidget {
  const _EmptyRequestState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: AppColors.subtleText,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _RequestStatusChip extends StatelessWidget {
  const _RequestStatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final normalizedStatus = status.trim().toLowerCase();
    final color = _requestStatusColor(normalizedStatus);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _requestStatusLabel(normalizedStatus),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _LeaveRequestHistoryCard extends StatelessWidget {
  const _LeaveRequestHistoryCard({required this.request});

  final LeaveRequestRecord request;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _formatIsoDate(request.leaveDate),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppColors.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _RequestStatusChip(status: request.status),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            request.reason,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w600,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Applied ${_formatAppliedAt(request.appliedAt)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.subtleText,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SiteVisitRequestHistoryCard extends StatelessWidget {
  const _SiteVisitRequestHistoryCard({required this.request});

  final SiteVisitRequestRecord request;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _formatIsoDate(request.visitDate),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppColors.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _RequestStatusChip(status: request.status),
            ],
          ),
          const SizedBox(height: 8),
          _RequestHistoryLine(label: 'Location', value: request.siteLocation),
          const SizedBox(height: 6),
          _RequestHistoryLine(label: 'Assigned By', value: request.approvedBy),
          const SizedBox(height: 6),
          _RequestHistoryLine(label: 'Reason', value: request.reason),
          const SizedBox(height: 10),
          Text(
            'Applied ${_formatAppliedAt(request.appliedAt)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.subtleText,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _TeTrackerMetricCard extends StatelessWidget {
  const _TeTrackerMetricCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 120),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.subtleText,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _TeTrackerVisitCard extends StatelessWidget {
  const _TeTrackerVisitCard({required this.visit});

  final TeTrackerVisitRecord visit;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${visit.sequence}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      visit.branchLabel,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppColors.text,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_formatIsoDate(visit.visitDate)} at ${visit.visitTime}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.subtleText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _RequestHistoryLine(
            label: 'Distance From Branch',
            value: visit.distanceFromBranchLabel,
          ),
          const SizedBox(height: 6),
          _RequestHistoryLine(
            label: 'Distance From Previous',
            value: visit.distanceFromPreviousLabel,
          ),
          const SizedBox(height: 6),
          _RequestHistoryLine(
            label: 'Cumulative Distance',
            value: visit.cumulativeDistanceLabel,
          ),
          const SizedBox(height: 6),
          _RequestHistoryLine(
            label: 'Captured Location',
            value:
                visit.capturedLatitude != null &&
                    visit.capturedLongitude != null
                ? '${visit.capturedLatitude!.toStringAsFixed(6)}, ${visit.capturedLongitude!.toStringAsFixed(6)}'
                : 'Location unavailable',
          ),
        ],
      ),
    );
  }
}

class _RequestHistoryLine extends StatelessWidget {
  const _RequestHistoryLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: AppColors.text, height: 1.45),
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(
              color: AppColors.subtleText,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(
            text: value.isEmpty ? 'Not available' : value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    required this.employee,
    required this.token,
    required this.apiClient,
  });

  final Employee employee;
  final String token;
  final EmployeeApiClient apiClient;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> with WidgetsBindingObserver {
  final ImagePicker _imagePicker = ImagePicker();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  static const List<String> _genderOptions = <String>[
    'Male',
    'Female',
    'Other',
  ];
  static const List<String> _maritalStatusOptions = <String>[
    'Single',
    'Married',
    'Divorced',
    'Widowed',
  ];

  late Employee _employee;
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  late final TextEditingController _addressController;
  late final TextEditingController _dateOfBirthController;
  late final TextEditingController _aadhaarController;
  late final TextEditingController _panController;
  bool _isUploadingPhoto = false;
  bool _isSavingProfile = false;
  bool _isSavingUanNumber = false;
  bool _isRequestingBankEdit = false;
  bool _isSavingBankDetails = false;
  bool _isRefreshingProfile = false;
  bool _isChangingPassword = false;
  String? _selectedGender;
  String? _selectedMaritalStatus;
  DateTime? _selectedDateOfBirth;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _employee = widget.employee;
    _nameController = TextEditingController();
    _phoneController = TextEditingController();
    _emailController = TextEditingController();
    _addressController = TextEditingController();
    _dateOfBirthController = TextEditingController();
    _aadhaarController = TextEditingController();
    _panController = TextEditingController();
    _syncFormWithEmployee(_employee);
    unawaited(_refreshProfile(silent: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _addressController.dispose();
    _dateOfBirthController.dispose();
    _aadhaarController.dispose();
    _panController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshProfile(silent: true));
    }
  }

  void _syncFormWithEmployee(Employee employee) {
    _nameController.text = employee.name;
    _phoneController.text = employee.contact;
    _emailController.text = employee.mailId;
    _addressController.text = employee.address;
    _aadhaarController.text = employee.aadhaarNumber;
    _panController.text = employee.panNumber;
    _selectedDateOfBirth = _parseYmdDate(employee.dateOfBirth);
    _dateOfBirthController.text = _selectedDateOfBirth == null
        ? ''
        : _formatDisplayDate(_selectedDateOfBirth!);
    _selectedGender = _matchOption(employee.gender, _genderOptions);
    _selectedMaritalStatus = _matchOption(
      employee.maritalStatus,
      _maritalStatusOptions,
    );
  }

  Future<void> _pickDateOfBirth() async {
    final now = DateTime.now();
    final initialDate =
        _selectedDateOfBirth ?? DateTime(now.year - 21, now.month, now.day);
    final selected = await showDatePicker(
      context: context,
      initialDate: initialDate.isAfter(now) ? now : initialDate,
      firstDate: DateTime(1950, 1, 1),
      lastDate: now,
    );

    if (selected == null || !mounted) {
      return;
    }

    setState(() {
      _selectedDateOfBirth = selected;
      _dateOfBirthController.text = _formatDisplayDate(selected);
    });
  }

  void _applyEmployee(Employee employee, {bool syncForm = true}) {
    setState(() {
      _employee = employee;
      if (syncForm) {
        _syncFormWithEmployee(employee);
      }
    });
  }

  bool _hasUnsavedProfileChanges() {
    return _nameController.text.trim() != _employee.name.trim() ||
        _phoneController.text.trim() != _employee.contact.trim() ||
        _emailController.text.trim() != _employee.mailId.trim() ||
        _addressController.text.trim() != _employee.address.trim() ||
        _formatApiDate(_selectedDateOfBirth).trim() !=
            _employee.dateOfBirth.trim() ||
        (_selectedGender ?? '').trim() != _employee.gender.trim() ||
        (_selectedMaritalStatus ?? '').trim() !=
            _employee.maritalStatus.trim() ||
        _aadhaarController.text.trim() != _employee.aadhaarNumber.trim() ||
        _panController.text.trim().toUpperCase() !=
            _employee.panNumber.trim().toUpperCase();
  }

  Future<void> _refreshProfile({bool silent = false}) async {
    if (_isRefreshingProfile) {
      return;
    }

    final shouldSyncForm = !silent || !_hasUnsavedProfileChanges();

    setState(() {
      _isRefreshingProfile = true;
    });

    try {
      final updatedEmployee = await widget.apiClient.profile(widget.token);
      if (!mounted) {
        return;
      }

      _applyEmployee(updatedEmployee, syncForm: shouldSyncForm);
      if (!silent) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Profile refreshed.')));
      }
    } on ApiException catch (error) {
      if (!mounted || silent) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted || silent) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to refresh profile right now.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshingProfile = false;
        });
      }
    }
  }

  String? _matchOption(String value, List<String> options) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    for (final option in options) {
      if (option.toLowerCase() == trimmed.toLowerCase()) {
        return option;
      }
    }

    return trimmed;
  }

  List<String> _resolvedOptions(
    List<String> baseOptions,
    String? currentValue,
  ) {
    final resolved = List<String>.from(baseOptions);
    final trimmed = currentValue?.trim() ?? '';
    if (trimmed.isNotEmpty &&
        !resolved.any(
          (option) => option.toLowerCase() == trimmed.toLowerCase(),
        )) {
      resolved.add(trimmed);
    }

    return resolved;
  }

  Future<void> _pickAndUploadPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Update profile photo',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: AppColors.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(Icons.camera_alt_outlined),
                  title: const Text('Take photo'),
                  onTap: () => Navigator.of(context).pop(ImageSource.camera),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Choose from gallery'),
                  onTap: () => Navigator.of(context).pop(ImageSource.gallery),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (source == null || !mounted) {
      return;
    }

    try {
      final File? imageFile;
      if (source == ImageSource.gallery) {
        final image = await _imagePicker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 85,
        );
        imageFile = image == null ? null : File(image.path);
      } else {
        imageFile = await Navigator.of(context).push<File>(
          MaterialPageRoute<File>(
            builder: (_) => const FrontCameraCapturePage(
              title: 'Profile Photo',
              subtitle:
                  'Use the selfie camera only. The back camera is disabled in this app.',
            ),
            fullscreenDialog: true,
          ),
        );
      }

      if (imageFile == null || !mounted) {
        return;
      }

      setState(() {
        _isUploadingPhoto = true;
      });

      final updatedEmployee = await widget.apiClient.updateProfilePhoto(
        token: widget.token,
        photo: imageFile,
      );

      if (!mounted) {
        return;
      }

      _applyEmployee(updatedEmployee, syncForm: false);

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile photo updated.')));
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to update profile photo.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingPhoto = false;
        });
      }
    }
  }

  Future<void> _saveProfile() async {
    if (_isSavingProfile || !_formKey.currentState!.validate()) {
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _isSavingProfile = true;
    });

    try {
      final updatedEmployee = await widget.apiClient.updateProfile(
        token: widget.token,
        name: _nameController.text.trim(),
        contact: _phoneController.text.trim(),
        mailId: _emailController.text.trim(),
        address: _addressController.text.trim(),
        dateOfBirth: _formatApiDate(_selectedDateOfBirth),
        gender: (_selectedGender ?? '').trim(),
        maritalStatus: (_selectedMaritalStatus ?? '').trim(),
        aadhaarNumber: _aadhaarController.text.trim(),
        panNumber: _panController.text.trim().toUpperCase(),
      );

      if (!mounted) {
        return;
      }

      _applyEmployee(updatedEmployee);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile updated.')));
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to update profile right now.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSavingProfile = false;
        });
      }
    }
  }

  Future<void> _showChangePasswordDialog() async {
    if (_isChangingPassword) {
      return;
    }

    final formKey = GlobalKey<FormState>();
    final currentPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    bool obscureCurrent = true;
    bool obscureNew = true;
    bool obscureConfirm = true;

    try {
      final result = await showDialog<Map<String, String>>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                title: const Text('Change password'),
                content: Form(
                  key: formKey,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextFormField(
                          controller: currentPasswordController,
                          obscureText: obscureCurrent,
                          decoration: InputDecoration(
                            labelText: 'Current password',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              onPressed: () => setDialogState(() {
                                obscureCurrent = !obscureCurrent;
                              }),
                              icon: Icon(
                                obscureCurrent
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: newPasswordController,
                          obscureText: obscureNew,
                          decoration: InputDecoration(
                            labelText: 'New password',
                            prefixIcon: const Icon(Icons.lock_reset_outlined),
                            suffixIcon: IconButton(
                              onPressed: () => setDialogState(() {
                                obscureNew = !obscureNew;
                              }),
                              icon: Icon(
                                obscureNew
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                          validator: (value) {
                            final password = value?.trim() ?? '';
                            if (password.length < 6) {
                              return 'Use at least 6 characters.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: confirmPasswordController,
                          obscureText: obscureConfirm,
                          decoration: InputDecoration(
                            labelText: 'Confirm new password',
                            prefixIcon: const Icon(Icons.lock_person_outlined),
                            suffixIcon: IconButton(
                              onPressed: () => setDialogState(() {
                                obscureConfirm = !obscureConfirm;
                              }),
                              icon: Icon(
                                obscureConfirm
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                          validator: (value) {
                            if ((value ?? '') != newPasswordController.text) {
                              return 'Passwords do not match.';
                            }
                            return null;
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () {
                      if (formKey.currentState?.validate() != true) {
                        return;
                      }

                      Navigator.of(context).pop({
                        'currentPassword': currentPasswordController.text,
                        'newPassword': newPasswordController.text.trim(),
                        'newPasswordConfirmation': confirmPasswordController
                            .text
                            .trim(),
                      });
                    },
                    child: const Text('Update'),
                  ),
                ],
              );
            },
          );
        },
      );

      if (result == null || !mounted) {
        return;
      }

      setState(() {
        _isChangingPassword = true;
      });

      final message = await widget.apiClient.changePassword(
        token: widget.token,
        currentPassword: result['currentPassword'] ?? '',
        newPassword: result['newPassword'] ?? '',
        newPasswordConfirmation: result['newPasswordConfirmation'] ?? '',
      );

      await const EmployeeSessionStore().updateSavedPasswordIfRemembered(
        result['newPassword'] ?? '',
      );

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to update password right now.')),
      );
    } finally {
      currentPasswordController.dispose();
      newPasswordController.dispose();
      confirmPasswordController.dispose();

      if (mounted) {
        setState(() {
          _isChangingPassword = false;
        });
      }
    }
  }

  Future<void> _requestBankEditAccess() async {
    if (_isRequestingBankEdit) {
      return;
    }

    final noteController = TextEditingController();

    try {
      final shouldSubmit = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Request Bank Detail Edit'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Send an approval request before editing your bank details.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Request Note',
                    hintText: 'Optional reason for the request',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Submit Request'),
              ),
            ],
          );
        },
      );

      if (shouldSubmit != true || !mounted) {
        return;
      }

      setState(() {
        _isRequestingBankEdit = true;
      });

      final updatedEmployee = await widget.apiClient.requestBankDetailEdit(
        token: widget.token,
        requestNote: noteController.text.trim(),
      );

      if (!mounted) {
        return;
      }

      _applyEmployee(updatedEmployee, syncForm: false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bank edit request submitted.')),
      );
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to submit the bank edit request.'),
        ),
      );
    } finally {
      noteController.dispose();
      if (mounted) {
        setState(() {
          _isRequestingBankEdit = false;
        });
      }
    }
  }

  Future<void> _showInitialUanEditor() async {
    if (_isSavingUanNumber) {
      return;
    }

    final uanController = TextEditingController();
    final dialogFormKey = GlobalKey<FormState>();

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: !_isSavingUanNumber,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              final rootNavigator = Navigator.of(this.context);
              final rootMessenger = ScaffoldMessenger.of(this.context);

              Future<void> submit() async {
                if (_isSavingUanNumber ||
                    !(dialogFormKey.currentState?.validate() ?? false)) {
                  return;
                }

                setState(() {
                  _isSavingUanNumber = true;
                });
                setDialogState(() {});

                try {
                  final updatedEmployee = await widget.apiClient
                      .submitInitialUanNumber(
                        token: widget.token,
                        uanNumber: uanController.text.trim(),
                      );

                  if (!mounted) {
                    return;
                  }

                  _applyEmployee(updatedEmployee, syncForm: false);
                  rootNavigator.pop();
                  rootMessenger.showSnackBar(
                    const SnackBar(content: Text('UAN number saved.')),
                  );
                } on ApiException catch (error) {
                  if (!mounted) {
                    return;
                  }
                  rootMessenger.showSnackBar(
                    SnackBar(content: Text(error.message)),
                  );
                } catch (_) {
                  if (!mounted) {
                    return;
                  }
                  rootMessenger.showSnackBar(
                    const SnackBar(
                      content: Text('Unable to save UAN number right now.'),
                    ),
                  );
                } finally {
                  if (mounted) {
                    setState(() {
                      _isSavingUanNumber = false;
                    });
                    setDialogState(() {});
                  }
                }
              }

              return AlertDialog(
                title: const Text('Add UAN Number'),
                content: SizedBox(
                  width: 420,
                  child: Form(
                    key: dialogFormKey,
                    child: TextFormField(
                      controller: uanController,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(12),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'UAN Number',
                        helperText:
                            'You can save this once. Future changes need approval.',
                      ),
                      validator: (value) {
                        final trimmed = value?.trim() ?? '';
                        if (trimmed.isEmpty) {
                          return 'UAN number is required.';
                        }
                        if (!RegExp(r'^\d{12}$').hasMatch(trimmed)) {
                          return 'Enter a valid 12-digit UAN number.';
                        }
                        return null;
                      },
                      onFieldSubmitted: (_) => submit(),
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: _isSavingUanNumber
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: _isSavingUanNumber ? null : submit,
                    child: _isSavingUanNumber
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save UAN'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      uanController.dispose();
    }
  }

  Future<void> _showBankDetailsEditor() async {
    final bankDetails = _employee.bankDetails;
    final accountNameController = TextEditingController(
      text: bankDetails.pendingAccountName.trim().isNotEmpty
          ? bankDetails.pendingAccountName
          : bankDetails.accountName,
    );
    final bankNameController = TextEditingController(
      text: bankDetails.pendingBankName.trim().isNotEmpty
          ? bankDetails.pendingBankName
          : bankDetails.bankName,
    );
    final accountNumberController = TextEditingController(
      text: bankDetails.pendingBankAccountNumber.trim().isNotEmpty
          ? bankDetails.pendingBankAccountNumber
          : bankDetails.bankAccountNumber,
    );
    final ifscController = TextEditingController(
      text: bankDetails.pendingIfscCode.trim().isNotEmpty
          ? bankDetails.pendingIfscCode
          : bankDetails.ifscCode,
    );
    final uanController = TextEditingController(
      text: bankDetails.pendingUanNumber.trim().isNotEmpty
          ? bankDetails.pendingUanNumber
          : bankDetails.uanNumber,
    );
    final noteController = TextEditingController();
    File? selectedPassbookDoc;
    final dialogFormKey = GlobalKey<FormState>();

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: !_isSavingBankDetails,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              final rootNavigator = Navigator.of(this.context);
              final rootMessenger = ScaffoldMessenger.of(this.context);

              Future<void> pickPassbookDoc() async {
                try {
                  final image = await _imagePicker.pickImage(
                    source: ImageSource.gallery,
                    imageQuality: 82,
                  );

                  if (image == null) {
                    return;
                  }

                  setDialogState(() {
                    selectedPassbookDoc = File(image.path);
                  });
                } catch (_) {
                  if (!mounted) {
                    return;
                  }
                  rootMessenger.showSnackBar(
                    const SnackBar(
                      content: Text('Unable to pick bank document right now.'),
                    ),
                  );
                }
              }

              String selectedPassbookDocLabel() {
                final file = selectedPassbookDoc;
                if (file == null) {
                  return '';
                }

                final segments = file.path.split(RegExp(r'[\\/]'));
                return segments.isNotEmpty ? segments.last : file.path;
              }

              Future<void> submit() async {
                if (_isSavingBankDetails ||
                    !(dialogFormKey.currentState?.validate() ?? false)) {
                  return;
                }

                setState(() {
                  _isSavingBankDetails = true;
                });
                setDialogState(() {});

                try {
                  final updatedEmployee = await widget.apiClient
                      .updateBankDetails(
                        token: widget.token,
                        accountName: accountNameController.text.trim(),
                        bankName: bankNameController.text.trim(),
                        bankAccountNumber: accountNumberController.text.trim(),
                        ifscCode: ifscController.text.trim(),
                        uanNumber: uanController.text.trim(),
                        requestNote: noteController.text.trim(),
                        passbookDoc: selectedPassbookDoc,
                      );

                  if (!mounted) {
                    return;
                  }

                  _applyEmployee(updatedEmployee, syncForm: false);
                  rootNavigator.pop();
                  rootMessenger.showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Bank details submitted and pending verification.',
                      ),
                    ),
                  );
                } on ApiException catch (error) {
                  if (!mounted) {
                    return;
                  }
                  rootMessenger.showSnackBar(
                    SnackBar(content: Text(error.message)),
                  );
                } catch (_) {
                  if (!mounted) {
                    return;
                  }
                  rootMessenger.showSnackBar(
                    const SnackBar(
                      content: Text('Unable to submit bank details right now.'),
                    ),
                  );
                } finally {
                  if (mounted) {
                    setState(() {
                      _isSavingBankDetails = false;
                    });
                    setDialogState(() {});
                  }
                }
              }

              return AlertDialog(
                title: const Text('Edit Bank Details'),
                content: SizedBox(
                  width: 420,
                  child: Form(
                    key: dialogFormKey,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextFormField(
                            controller: accountNameController,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              labelText: 'Name as per Bank A/C',
                            ),
                            validator: (value) =>
                                (value == null || value.trim().isEmpty)
                                ? 'Account name is required.'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: bankNameController,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              labelText: 'Bank Name',
                            ),
                            validator: (value) =>
                                (value == null || value.trim().isEmpty)
                                ? 'Bank name is required.'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: accountNumberController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Bank Account Number',
                            ),
                            validator: (value) =>
                                (value == null || value.trim().isEmpty)
                                ? 'Account number is required.'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: ifscController,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              labelText: 'IFSC Code',
                            ),
                            validator: (value) =>
                                (value == null || value.trim().isEmpty)
                                ? 'IFSC code is required.'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: uanController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(12),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'UAN Number',
                              helperText: 'Required for PF, if applicable',
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _isSavingBankDetails
                                      ? null
                                      : pickPassbookDoc,
                                  icon: const Icon(Icons.file_upload_outlined),
                                  label: Text(
                                    selectedPassbookDoc == null
                                        ? 'Upload Bank Document (Optional)'
                                        : 'Change Bank Document',
                                  ),
                                ),
                              ),
                              if (selectedPassbookDoc != null) ...[
                                const SizedBox(width: 8),
                                IconButton(
                                  tooltip: 'Remove selected document',
                                  onPressed: _isSavingBankDetails
                                      ? null
                                      : () {
                                          setDialogState(() {
                                            selectedPassbookDoc = null;
                                          });
                                        },
                                  icon: const Icon(Icons.close_rounded),
                                ),
                              ],
                            ],
                          ),
                          if (selectedPassbookDoc != null) ...[
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                selectedPassbookDocLabel(),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: AppColors.subtleText,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: noteController,
                            minLines: 2,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              labelText: 'Submission Note',
                              hintText: 'Optional note for verification',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: _isSavingBankDetails
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: _isSavingBankDetails ? null : submit,
                    child: _isSavingBankDetails
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Submit Changes'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      accountNameController.dispose();
      bankNameController.dispose();
      accountNumberController.dispose();
      ifscController.dispose();
      uanController.dispose();
      noteController.dispose();
    }
  }

  Future<void> _openDocument(String url) async {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);

    if (trimmed.isEmpty || uri == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Document link is not available.')),
      );
      return;
    }

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);

    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to open the document.')),
      );
    }
  }

  String _bankRequestStatusLabel(String status) {
    switch (status.trim().toLowerCase()) {
      case 'pending':
        return 'Pending Approval';
      case 'approved':
        return 'Approved For Edit';
      case 'submitted':
        return 'Pending Verification';
      case 'verified':
        return 'Verified';
      case 'rejected':
        return 'Rejected';
      default:
        return 'No Request';
    }
  }

  bool _shouldShowBankRequestStatus(EmployeeBankDetails bankDetails) {
    return bankDetails.requestStatus.trim().isNotEmpty &&
        bankDetails.requestStatus.trim().toLowerCase() != 'none';
  }

  String _bankRequestStatusTitle(EmployeeBankDetails bankDetails) {
    switch (bankDetails.requestStatus.trim().toLowerCase()) {
      case 'pending':
        return 'Edit Access Requested';
      case 'approved':
        return 'Edit Access Approved';
      case 'submitted':
        return 'Pending Admin Verification';
      case 'verified':
        return 'Bank Details Verified';
      case 'rejected':
        return 'Edit Access Rejected';
      default:
        return 'Bank Detail Request';
    }
  }

  String _bankRequestStatusMessage(EmployeeBankDetails bankDetails) {
    switch (bankDetails.requestStatus.trim().toLowerCase()) {
      case 'pending':
        return 'Admin approval is required before you can edit these details.';
      case 'approved':
        return 'You can edit and submit updated bank details in the app. Submitted changes will wait for admin verification before DB update.';
      case 'submitted':
        return 'Your changes are submitted for admin verification. Current saved bank details stay unchanged until admin verifies them.';
      case 'verified':
        return 'Admin verified your submitted changes and the saved bank details have been updated.';
      case 'rejected':
        return 'Admin rejected the edit request. You can send another request if changes are still needed.';
      default:
        return '';
    }
  }

  void _handleBackNavigation(bool didPop, Object? result) {
    if (didPop) {
      return;
    }

    Navigator.of(context).pop(_employee);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final employee = _employee;
    final bottomSafePadding = MediaQuery.of(context).viewPadding.bottom;
    final bankRequestStatus = employee.bankDetails.requestStatus
        .trim()
        .toLowerCase();
    final genderOptions = _resolvedOptions(_genderOptions, _selectedGender);
    final maritalStatusOptions = _resolvedOptions(
      _maritalStatusOptions,
      _selectedMaritalStatus,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _handleBackNavigation,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('My Profile'),
          surfaceTintColor: Colors.transparent,
          backgroundColor: AppColors.background,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).pop(_employee),
          ),
          actions: [
            IconButton(
              tooltip: 'Refresh profile',
              onPressed: _isRefreshingProfile
                  ? null
                  : () => _refreshProfile(silent: false),
              icon: _isRefreshingProfile
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: () => _refreshProfile(silent: false),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, 12, 20, 48 + bottomSafePadding),
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppColors.primaryDark,
                      AppColors.primary,
                      Color(0xFF6E35D7),
                    ],
                  ),
                ),
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            _EmployeeAvatar(
                              employee: employee,
                              size: 64,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.18,
                              ),
                              textStyle: theme.textTheme.titleLarge?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: InkWell(
                                onTap: _isUploadingPhoto
                                    ? null
                                    : _pickAndUploadPhoto,
                                borderRadius: BorderRadius.circular(999),
                                child: Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x19000000),
                                        blurRadius: 10,
                                        offset: Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  alignment: Alignment.center,
                                  child: _isUploadingPhoto
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.camera_alt_rounded,
                                          size: 16,
                                          color: AppColors.primaryDark,
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                employee.name,
                                style: theme.textTheme.headlineMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _stringOrFallback(
                                  employee.designation,
                                  fallback: 'Designation unavailable',
                                ),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.84),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _ProfileBadge(
                          label: 'Emp ID ${employee.empId}',
                          backgroundColor: Colors.white.withValues(alpha: 0.12),
                        ),
                        _ProfileBadge(
                          label: _stringOrFallback(
                            employee.status,
                            fallback: 'Status unavailable',
                          ),
                          backgroundColor:
                              employee.status.toLowerCase() == 'active'
                              ? const Color(0x2637DB88)
                              : Colors.white.withValues(alpha: 0.12),
                        ),
                        _ProfileBadge(
                          label: _stringOrFallback(
                            employee.branchName.isNotEmpty
                                ? employee.branchName
                                : employee.branchId,
                            fallback: 'Branch unavailable',
                          ),
                          backgroundColor: Colors.white.withValues(alpha: 0.12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _InlineInfoCard(
                      backgroundColor: Colors.white.withValues(alpha: 0.12),
                      icon: Icons.camera_alt_outlined,
                      iconColor: AppColors.primaryDark,
                      title: employee.hasPhoto
                          ? 'Profile photo is visible in the employee app.'
                          : 'Add your profile photo for quicker identification.',
                      subtitle: employee.hasPhoto
                          ? 'Tap the camera icon to replace the current photo.'
                          : 'Use a clear front-facing image.',
                      titleColor: Colors.white,
                      subtitleColor: Colors.white.withValues(alpha: 0.82),
                      action: TextButton(
                        onPressed: _isUploadingPhoto
                            ? null
                            : _pickAndUploadPhoto,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                        child: Text(
                          _isUploadingPhoto ? 'Uploading...' : 'Update Photo',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const _SectionTitle(title: 'Profile Details'),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x12000000),
                      blurRadius: 18,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(18),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _LabeledField(
                        label: 'Full Name',
                        child: TextFormField(
                          controller: _nameController,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          decoration: _fieldDecoration(
                            hintText: 'Enter your full name',
                            prefixIcon: Icons.person_outline_rounded,
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Name is required.';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      _LabeledField(
                        label: 'Phone',
                        child: TextFormField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.next,
                          decoration: _fieldDecoration(
                            hintText: 'Enter your phone number',
                            prefixIcon: Icons.phone_outlined,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _LabeledField(
                        label: 'Email',
                        child: TextFormField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          decoration: _fieldDecoration(
                            hintText: 'Enter your email address',
                            prefixIcon: Icons.alternate_email_rounded,
                          ),
                          validator: (value) {
                            final trimmed = value?.trim() ?? '';
                            if (trimmed.isEmpty) {
                              return null;
                            }

                            final emailPattern = RegExp(
                              r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                            );
                            if (!emailPattern.hasMatch(trimmed)) {
                              return 'Enter a valid email address.';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      _LabeledField(
                        label: 'Date of Birth',
                        child: TextFormField(
                          controller: _dateOfBirthController,
                          readOnly: true,
                          onTap: _pickDateOfBirth,
                          decoration: _fieldDecoration(
                            hintText: 'Select your date of birth',
                            prefixIcon: Icons.cake_outlined,
                            suffixIcon: IconButton(
                              onPressed: _pickDateOfBirth,
                              icon: const Icon(Icons.calendar_month_rounded),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _LabeledField(
                        label: 'Aadhaar Number',
                        child: TextFormField(
                          controller: _aadhaarController,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.next,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(12),
                          ],
                          decoration: _fieldDecoration(
                            hintText: 'Enter 12-digit Aadhaar number',
                            prefixIcon: Icons.credit_card_rounded,
                          ),
                          validator: (value) {
                            final trimmed = value?.trim() ?? '';
                            if (trimmed.isEmpty) {
                              return null;
                            }
                            if (!RegExp(r'^\d{12}$').hasMatch(trimmed)) {
                              return 'Enter a valid 12-digit Aadhaar number.';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      _LabeledField(
                        label: 'PAN Number',
                        child: TextFormField(
                          controller: _panController,
                          textCapitalization: TextCapitalization.characters,
                          textInputAction: TextInputAction.next,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(10),
                          ],
                          decoration: _fieldDecoration(
                            hintText: 'Enter PAN number',
                            prefixIcon: Icons.badge_outlined,
                          ),
                          validator: (value) {
                            final trimmed = (value ?? '').trim().toUpperCase();
                            if (trimmed.isEmpty) {
                              return null;
                            }
                            if (!RegExp(
                              r'^[A-Z]{5}[0-9]{4}[A-Z]$',
                            ).hasMatch(trimmed)) {
                              return 'Enter a valid PAN number.';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final useVerticalLayout = constraints.maxWidth < 420;

                          final genderField = _LabeledField(
                            label: 'Gender',
                            child: _SearchableSelectionField<String>(
                              hintText: 'Select Gender',
                              prefixIcon: Icons.wc_rounded,
                              selectedValue: _selectedGender,
                              options: genderOptions
                                  .map(
                                    (option) => _SearchableOption<String>(
                                      value: option,
                                      label: option,
                                    ),
                                  )
                                  .toList(),
                              onSelected: (value) {
                                setState(() {
                                  _selectedGender = value;
                                });
                              },
                            ),
                          );

                          final maritalStatusField = _LabeledField(
                            label: 'Marital Status',
                            child: _SearchableSelectionField<String>(
                              hintText: 'Select Marital Status',
                              prefixIcon: Icons.favorite_border_rounded,
                              selectedValue: _selectedMaritalStatus,
                              options: maritalStatusOptions
                                  .map(
                                    (option) => _SearchableOption<String>(
                                      value: option,
                                      label: option,
                                    ),
                                  )
                                  .toList(),
                              onSelected: (value) {
                                setState(() {
                                  _selectedMaritalStatus = value;
                                });
                              },
                            ),
                          );

                          if (useVerticalLayout) {
                            return Column(
                              children: [
                                genderField,
                                const SizedBox(height: 14),
                                maritalStatusField,
                              ],
                            );
                          }

                          return Row(
                            children: [
                              Expanded(child: genderField),
                              const SizedBox(width: 12),
                              Expanded(child: maritalStatusField),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 14),
                      _LabeledField(
                        label: 'Address',
                        child: TextFormField(
                          controller: _addressController,
                          keyboardType: TextInputType.streetAddress,
                          textInputAction: TextInputAction.done,
                          minLines: 3,
                          maxLines: 4,
                          decoration: _fieldDecoration(
                            hintText: 'Enter your address',
                            prefixIcon: Icons.home_outlined,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _isSavingProfile ? null : _saveProfile,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                          child: _isSavingProfile
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Save Profile'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const _SectionTitle(title: 'Security'),
              const SizedBox(height: 10),
              _InlineInfoCard(
                backgroundColor: AppColors.surface,
                icon: Icons.lock_reset_rounded,
                iconColor: AppColors.primary,
                title: 'Change password',
                subtitle:
                    'This password is required for app and web login with your Branch ID and Employee ID.',
                action: FilledButton.icon(
                  onPressed: _isChangingPassword
                      ? null
                      : _showChangePasswordDialog,
                  icon: _isChangingPassword
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_reset_rounded),
                  label: Text(_isChangingPassword ? 'Updating...' : 'Change'),
                ),
              ),
              if (!employee.isOutsourced) ...[
                const SizedBox(height: 18),
                const _SectionTitle(title: 'Employment'),
                const SizedBox(height: 10),
                _ProfileDetailsCard(
                  entries: [
                    _ProfileEntry(label: 'Employee ID', value: employee.empId),
                    _ProfileEntry(label: 'Branch ID', value: employee.branchId),
                    _ProfileEntry(
                      label: 'Branch Name',
                      value: _stringOrFallback(employee.branchName),
                    ),
                    _ProfileEntry(
                      label: 'Designation',
                      value: _stringOrFallback(employee.designation),
                    ),
                    _ProfileEntry(
                      label: 'Salary',
                      value: _formatCurrency(employee.salary),
                    ),
                    _ProfileEntry(
                      label: 'Date of Birth',
                      value: _stringOrFallback(
                        _formatDisplayDate(_parseYmdDate(employee.dateOfBirth)),
                      ),
                    ),
                    _ProfileEntry(
                      label: 'Status',
                      value: _stringOrFallback(employee.status),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const _SectionTitle(title: 'Bank Details'),
                const SizedBox(height: 10),
                if (_shouldShowBankRequestStatus(employee.bankDetails)) ...[
                  _InlineInfoCard(
                    backgroundColor: bankRequestStatus == 'submitted'
                        ? const Color(0xFFFFF7E8)
                        : AppColors.surface,
                    icon: bankRequestStatus == 'approved'
                        ? Icons.edit_note_rounded
                        : bankRequestStatus == 'verified'
                        ? Icons.verified_rounded
                        : Icons.info_outline_rounded,
                    iconColor: bankRequestStatus == 'rejected'
                        ? const Color(0xFFC73B3B)
                        : AppColors.primary,
                    title: _bankRequestStatusTitle(employee.bankDetails),
                    subtitle: _bankRequestStatusMessage(employee.bankDetails),
                  ),
                  const SizedBox(height: 10),
                ],
                _ProfileDetailsCard(
                  entries: [
                    _ProfileEntry(
                      label: 'Name as per A/C',
                      value: _stringOrFallback(
                        employee.bankDetails.accountName,
                      ),
                    ),
                    _ProfileEntry(
                      label: 'Bank Name',
                      value: _stringOrFallback(employee.bankDetails.bankName),
                    ),
                    _ProfileEntry(
                      label: 'A/C Number',
                      value: _stringOrFallback(
                        employee.bankDetails.bankAccountNumber,
                      ),
                    ),
                    _ProfileEntry(
                      label: 'IFSC Code',
                      value: _stringOrFallback(employee.bankDetails.ifscCode),
                    ),
                    _ProfileEntry(
                      label: 'UAN Number',
                      value: _stringOrFallback(employee.bankDetails.uanNumber),
                    ),
                    _ProfileEntry(
                      label: 'Verification',
                      value: _stringOrFallback(
                        employee.bankDetails.verificationStatus,
                        fallback: 'Not Submitted',
                      ),
                    ),
                    _ProfileEntry(
                      label: 'Edit Status',
                      value: _bankRequestStatusLabel(
                        employee.bankDetails.requestStatus,
                      ),
                    ),
                  ],
                ),
                if (employee.bankDetails.hasPendingDetails) ...[
                  const SizedBox(height: 14),
                  _ProfileDetailsCard(
                    entries: [
                      _ProfileEntry(
                        label: 'Pending Name',
                        value: _stringOrFallback(
                          employee.bankDetails.pendingAccountName,
                        ),
                      ),
                      _ProfileEntry(
                        label: 'Pending Bank',
                        value: _stringOrFallback(
                          employee.bankDetails.pendingBankName,
                        ),
                      ),
                      _ProfileEntry(
                        label: 'Pending A/C',
                        value: _stringOrFallback(
                          employee.bankDetails.pendingBankAccountNumber,
                        ),
                      ),
                      _ProfileEntry(
                        label: 'Pending IFSC',
                        value: _stringOrFallback(
                          employee.bankDetails.pendingIfscCode,
                        ),
                      ),
                      _ProfileEntry(
                        label: 'Pending UAN',
                        value: _stringOrFallback(
                          employee.bankDetails.pendingUanNumber,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                if (employee.bankDetails.hasPassbookDocument ||
                    employee.bankDetails.hasPendingPassbookDocument)
                  _InlineInfoCard(
                    backgroundColor: AppColors.surface,
                    icon: Icons.description_outlined,
                    iconColor: AppColors.primary,
                    title: employee.bankDetails.hasPendingPassbookDocument
                        ? 'A pending passbook document is available.'
                        : 'Your verified passbook document is available.',
                    subtitle: employee.bankDetails.hasPendingPassbookDocument
                        ? 'Open the pending document that will be verified by admin.'
                        : 'Open the currently verified passbook document.',
                    action: TextButton(
                      onPressed: () => _openDocument(
                        employee.bankDetails.hasPendingPassbookDocument
                            ? employee.bankDetails.pendingPassbookDocUrl
                            : employee.bankDetails.passbookDocUrl,
                      ),
                      child: const Text('Open Document'),
                    ),
                  ),
                if ((employee.bankDetails.requestNote.trim().isNotEmpty ||
                        employee.bankDetails.adminNote.trim().isNotEmpty) &&
                    bankRequestStatus != 'verified') ...[
                  const SizedBox(height: 12),
                  _ProfileDetailsCard(
                    entries: [
                      _ProfileEntry(
                        label: 'Request Note',
                        value: _stringOrFallback(
                          employee.bankDetails.requestNote,
                          fallback: '--',
                        ),
                      ),
                      _ProfileEntry(
                        label: 'Admin Note',
                        value: _stringOrFallback(
                          employee.bankDetails.adminNote,
                          fallback: '--',
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                if (employee.bankDetails.uanNumber.trim().isEmpty &&
                    employee.bankDetails.pendingUanNumber.trim().isEmpty)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _isSavingUanNumber
                          ? null
                          : _showInitialUanEditor,
                      child: _isSavingUanNumber
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Add UAN Number'),
                    ),
                  ),
                if (employee.bankDetails.uanNumber.trim().isEmpty &&
                    employee.bankDetails.pendingUanNumber.trim().isEmpty)
                  const SizedBox(height: 10),
                if (employee.bankDetails.canRequestEdit)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _isRequestingBankEdit
                          ? null
                          : _requestBankEditAccess,
                      child: _isRequestingBankEdit
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              bankRequestStatus == 'rejected'
                                  ? 'Request Edit Again'
                                  : 'Request Edit Access',
                            ),
                    ),
                  ),
                if (employee.bankDetails.canEdit) ...[
                  if (employee.bankDetails.canRequestEdit)
                    const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _isSavingBankDetails
                          ? null
                          : _showBankDetailsEditor,
                      child: const Text('Edit Bank Details'),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({
    super.key,
    required this.token,
    required this.apiClient,
    required this.initialNotifications,
    required this.onNotificationsViewed,
  });

  final String token;
  final EmployeeApiClient apiClient;
  final List<EmployeePushNotification> initialNotifications;
  final Future<void> Function() onNotificationsViewed;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  late List<EmployeePushNotification> _notifications;
  bool _isLoading = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final openedAt = DateTime.now().toIso8601String();
    _notifications = widget.initialNotifications
        .map(
          (notification) => notification.isRead
              ? notification
              : notification.copyWith(readAt: openedAt),
        )
        .toList();
    _isLoading = _notifications.isEmpty;
    unawaited(_markViewedAndLoad());
  }

  Future<void> _markViewedAndLoad() async {
    await widget.onNotificationsViewed();
    await _loadNotifications(showLoader: _notifications.isEmpty);
  }

  Future<void> _loadNotifications({bool showLoader = false}) async {
    if (showLoader) {
      setState(() {
        _isLoading = true;
        _errorText = null;
      });
    }

    try {
      final notifications = await widget.apiClient
          .notifications(token: widget.token)
          .timeout(const Duration(seconds: 8));
      final unreadDeliveryIds = notifications
          .where((notification) => !notification.isRead)
          .map((notification) => notification.deliveryId)
          .toList();
      final readAt = DateTime.now().toIso8601String();
      final visibleNotifications = notifications
          .map(
            (notification) =>
                unreadDeliveryIds.contains(notification.deliveryId)
                ? notification.copyWith(readAt: readAt)
                : notification,
          )
          .toList();

      if (unreadDeliveryIds.isNotEmpty) {
        unawaited(() async {
          try {
            await widget.apiClient.markNotificationsRead(
              token: widget.token,
              deliveryIds: unreadDeliveryIds,
            );
          } catch (_) {
            // The next refresh can reconcile notification read state.
          }
        }());
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _notifications = visibleNotifications;
        _errorText = null;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = error.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to load notifications right now.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            onPressed: _isLoading
                ? null
                : () => _loadNotifications(showLoader: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: () => _loadNotifications(),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                  children: [
                    if (_errorText != null) ...[
                      _InlineInfoCard(
                        backgroundColor: const Color(0xFFFFF0F0),
                        icon: Icons.error_outline_rounded,
                        iconColor: const Color(0xFFC73B3B),
                        title: 'Notifications unavailable',
                        subtitle: _errorText!,
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (_notifications.isEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 36,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x12000000),
                              blurRadius: 16,
                              offset: Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            Container(
                              width: 72,
                              height: 72,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primarySoft,
                              ),
                              child: const Icon(
                                Icons.notifications_none_rounded,
                                color: AppColors.primary,
                                size: 34,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No notifications yet',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: AppColors.text,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Admin notifications sent to you will appear here.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: AppColors.subtleText,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      ..._notifications.map(
                        (notification) => Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: _NotificationCard(notification: notification),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({required this.notification});

  final EmployeePushNotification notification;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUnread = !notification.isRead;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isUnread ? AppColors.primary : const Color(0xFFE8E1EF),
          width: isUnread ? 1.4 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isUnread ? const Color(0x24C62828) : const Color(0x10000000),
            blurRadius: isUnread ? 22 : 12,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isUnread ? AppColors.primarySoft : AppColors.surfaceTint,
            ),
            child: Icon(
              isUnread
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_none_rounded,
              color: isUnread ? AppColors.primary : AppColors.secondary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        notification.title.trim().isEmpty
                            ? 'Attica Pagar'
                            : notification.title.trim(),
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: AppColors.text,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (isUnread)
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFFE5446D),
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  notification.body.trim().isEmpty
                      ? 'No message content.'
                      : notification.body.trim(),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppColors.text,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _formatNotificationSentAt(notification.sentAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.subtleText,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ReportsPage extends StatefulWidget {
  const ReportsPage({
    super.key,
    required this.employee,
    required this.token,
    required this.apiClient,
  });

  final Employee employee;
  final String token;
  final EmployeeApiClient apiClient;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  AttendanceHistoryResponse? _history;
  bool _isLoading = true;
  String? _errorText;
  DateTime _selectedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  String _activeAttendanceFilter = 'all';

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  bool get _canMoveForward {
    final now = DateTime.now();
    return _selectedMonth.year < now.year ||
        (_selectedMonth.year == now.year && _selectedMonth.month < now.month);
  }

  String get _selectedMonthKey => _formatMonthKey(_selectedMonth);

  String get _attendanceReportTitle {
    return switch (_activeAttendanceFilter) {
      'present' => 'Complete Present Days',
      'single_punch' => 'Single Punches',
      'absent' => 'Absent Days',
      'half_day' => 'Half Days',
      _ => 'Attendance Report',
    };
  }

  Future<void> _loadHistory({bool showLoader = true}) async {
    if (showLoader) {
      setState(() {
        _isLoading = true;
        _errorText = null;
      });
    }

    try {
      final history = await widget.apiClient.attendanceHistory(
        token: widget.token,
        month: _selectedMonthKey,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _history = history;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = error.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to load attendance reports.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _moveMonth(int offset) async {
    setState(() {
      _selectedMonth = DateTime(
        _selectedMonth.year,
        _selectedMonth.month + offset,
      );
      _activeAttendanceFilter = 'all';
    });
    await _loadHistory();
  }

  void _setAttendanceFilter(String filter) {
    setState(() {
      _activeAttendanceFilter = _activeAttendanceFilter == filter
          ? 'all'
          : filter;
    });
  }

  List<AttendanceRecord> _recordsForActiveFilter(
    List<AttendanceRecord> records,
  ) {
    final monthRecords = _recordsWithDerivedAbsences(records);

    return switch (_activeAttendanceFilter) {
      'present' =>
        monthRecords
            .where(
              (record) =>
                  record.status == 'full_day' ||
                  record.status == 'full_day_remote',
            )
            .toList(),
      'single_punch' =>
        monthRecords
            .where((record) => record.status == 'single_punch')
            .toList(),
      'absent' =>
        monthRecords.where((record) => record.status == 'absent').toList(),
      'half_day' =>
        monthRecords.where((record) => record.status == 'half_day').toList(),
      _ => monthRecords,
    };
  }

  List<AttendanceRecord> _recordsWithDerivedAbsences(
    List<AttendanceRecord> records,
  ) {
    final recordsByDate = <String, AttendanceRecord>{};

    for (final record in records) {
      final date = record.checkInDate.trim();
      if (date.isNotEmpty) {
        recordsByDate[date] = record;
      }
    }

    final today = DateTime.now();
    final monthStart = DateTime(_selectedMonth.year, _selectedMonth.month);
    final monthEnd = DateTime(_selectedMonth.year, _selectedMonth.month + 1, 0);
    final summaryEnd = monthEnd.isBefore(today)
        ? monthEnd
        : DateTime(today.year, today.month, today.day);
    final mergedRecords = List<AttendanceRecord>.from(records);

    for (
      var cursor = monthStart;
      !cursor.isAfter(summaryEnd);
      cursor = cursor.add(const Duration(days: 1))
    ) {
      final dateKey = _formatDateKey(cursor);
      if (!recordsByDate.containsKey(dateKey)) {
        mergedRecords.add(
          !widget.employee.isNightShift && cursor.weekday == DateTime.sunday
              ? _weekOffAttendanceRecord(dateKey)
              : _absentAttendanceRecord(dateKey),
        );
      }
    }

    if (widget.employee.isNightShift) {
      final weekOffDates =
          mergedRecords
              .where((record) => record.status == 'absent')
              .map((record) => record.checkInDate)
              .where((date) => date.trim().isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      final creditedWeekOffDates = weekOffDates.take(4).toSet();

      for (var index = 0; index < mergedRecords.length; index++) {
        final record = mergedRecords[index];

        if (record.status == 'absent' &&
            creditedWeekOffDates.contains(record.checkInDate)) {
          mergedRecords[index] = _nightShiftWeekOffAttendanceRecord(record);
        }
      }
    }

    mergedRecords.sort((first, second) {
      final firstDate = DateTime.tryParse(first.checkInDate);
      final secondDate = DateTime.tryParse(second.checkInDate);

      if (firstDate == null || secondDate == null) {
        return second.checkInDate.compareTo(first.checkInDate);
      }

      return secondDate.compareTo(firstDate);
    });

    return mergedRecords;
  }

  AttendanceRecord _absentAttendanceRecord(String date) {
    return AttendanceRecord(
      id: 0,
      empId: widget.employee.empId,
      branchId: '',
      checkInBranchId: '',
      checkOutBranchId: '',
      photoPath: '',
      photoUrl: '',
      checkOutPhotoPath: '',
      checkOutPhotoUrl: '',
      latitude: null,
      longitude: null,
      checkInDate: date,
      checkInTime: '',
      checkOutDate: null,
      checkOutTime: null,
      status: 'absent',
      statusLabel: 'Absent',
      isAdminOverride: false,
      isNightShift: widget.employee.isNightShift,
      isActiveSession: false,
    );
  }

  AttendanceRecord _nightShiftWeekOffAttendanceRecord(AttendanceRecord record) {
    return AttendanceRecord(
      id: record.id,
      empId: record.empId,
      branchId: record.branchId,
      checkInBranchId: record.checkInBranchId,
      checkOutBranchId: record.checkOutBranchId,
      photoPath: record.photoPath,
      photoUrl: record.photoUrl,
      checkOutPhotoPath: record.checkOutPhotoPath,
      checkOutPhotoUrl: record.checkOutPhotoUrl,
      latitude: record.latitude,
      longitude: record.longitude,
      checkInDate: record.checkInDate,
      checkInTime: record.checkInTime,
      checkOutDate: record.checkOutDate,
      checkOutTime: record.checkOutTime,
      status: 'week_off',
      statusLabel: 'W/O',
      isAdminOverride: record.isAdminOverride,
      isNightShift: true,
      isActiveSession: record.isActiveSession,
    );
  }

  AttendanceRecord _weekOffAttendanceRecord(String date) {
    return AttendanceRecord(
      id: 0,
      empId: widget.employee.empId,
      branchId: '',
      checkInBranchId: '',
      checkOutBranchId: '',
      photoPath: '',
      photoUrl: '',
      checkOutPhotoPath: '',
      checkOutPhotoUrl: '',
      latitude: null,
      longitude: null,
      checkInDate: date,
      checkInTime: '',
      checkOutDate: null,
      checkOutTime: null,
      status: 'week_off',
      statusLabel: 'W/O',
      isAdminOverride: false,
      isNightShift: widget.employee.isNightShift,
      isActiveSession: false,
    );
  }

  Future<void> _showRecordDetails(AttendanceRecord record) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final theme = Theme.of(context);

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.82,
          minChildSize: 0.45,
          maxChildSize: 0.94,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: AppColors.secondary.withValues(alpha: 0.32),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Attendance Details',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: AppColors.text,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _AttendanceHistoryCard(record: record),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary =
        _history?.summary ??
        const AttendanceHistorySummary(
          totalRecords: 0,
          presentDays: 0,
          completedRecords: 0,
          activeRecords: 0,
          absentDays: 0,
          halfDays: 0,
          singlePunchDays: 0,
        );
    final records = _history?.records ?? const <AttendanceRecord>[];
    final visibleRecords = _recordsForActiveFilter(records);

    if (_isLoading && _history == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Reports'),
        surfaceTintColor: Colors.transparent,
        backgroundColor: AppColors.background,
        actions: [
          IconButton(
            onPressed: () => _loadHistory(showLoader: false),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return RefreshIndicator(
            triggerMode: RefreshIndicatorTriggerMode.anywhere,
            onRefresh: () => _loadHistory(showLoader: false),
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 32,
                ),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x12000000),
                              blurRadius: 16,
                              offset: Offset(0, 8),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                IconButton.filledTonal(
                                  onPressed: () => _moveMonth(-1),
                                  icon: const Icon(Icons.chevron_left_rounded),
                                ),
                                Expanded(
                                  child: Column(
                                    children: [
                                      Text(
                                        _formatMonthLabel(_selectedMonth),
                                        style: theme.textTheme.titleLarge
                                            ?.copyWith(
                                              color: AppColors.text,
                                              fontWeight: FontWeight.w800,
                                            ),
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        widget.employee.name,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: AppColors.subtleText,
                                            ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton.filledTonal(
                                  onPressed: _canMoveForward
                                      ? () => _moveMonth(1)
                                      : null,
                                  icon: const Icon(Icons.chevron_right_rounded),
                                ),
                              ],
                            ),
                            if (_isLoading) ...[
                              const SizedBox(height: 12),
                              const LinearProgressIndicator(),
                            ],
                          ],
                        ),
                      ),
                      if (_errorText != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF1F1),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          padding: const EdgeInsets.all(14),
                          child: Text(
                            _errorText!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFF9A1B1B),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: _SummaryCard(
                              label: 'Present Days',
                              value: summary.presentDays.toString(),
                              isSelected: _activeAttendanceFilter == 'present',
                              onTap: () => _setAttendanceFilter('present'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _SummaryCard(
                              label: 'Single Punches',
                              value: summary.singlePunchDays.toString(),
                              isSelected:
                                  _activeAttendanceFilter == 'single_punch',
                              onTap: () => _setAttendanceFilter('single_punch'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _SummaryCard(
                              label: 'Absent Days',
                              value: summary.absentDays.toString(),
                              isSelected: _activeAttendanceFilter == 'absent',
                              onTap: () => _setAttendanceFilter('absent'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _SummaryCard(
                              label: 'Half Days',
                              value: summary.halfDays.toString(),
                              isSelected: _activeAttendanceFilter == 'half_day',
                              onTap: () => _setAttendanceFilter('half_day'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _attendanceReportTitle,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: AppColors.text,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: visibleRecords.isEmpty
                            ? Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(24),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Color(0x12000000),
                                      blurRadius: 16,
                                      offset: Offset(0, 8),
                                    ),
                                  ],
                                ),
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.calendar_month_outlined,
                                      size: 36,
                                      color: AppColors.secondary,
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      _activeAttendanceFilter == 'all'
                                          ? 'No attendance records for ${_formatMonthLabel(_selectedMonth)}.'
                                          : 'No $_attendanceReportTitle records for ${_formatMonthLabel(_selectedMonth)}.',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: AppColors.secondary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              )
                            : _AttendanceHistoryTable(
                                records: visibleRecords,
                                onViewDetails: _showRecordDetails,
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
    );
  }
}

class _WebCameraCapturePage extends StatefulWidget {
  const _WebCameraCapturePage({
    required this.title,
    required this.subtitle,
    required this.preferredLensDirection,
  });

  final String title;
  final String subtitle;
  final CameraLensDirection preferredLensDirection;

  @override
  State<_WebCameraCapturePage> createState() => _WebCameraCapturePageState();
}

class _WebCameraCapturePageState extends State<_WebCameraCapturePage> {
  static final Map<CameraLensDirection, String> _cameraNamePreference = {};

  CameraController? _controller;
  final ImagePicker _imagePicker = ImagePicker();
  List<CameraDescription> _cameras = const [];
  int _activeCameraIndex = -1;
  bool _isInitializing = true;
  bool _isCapturing = false;
  bool _isOpeningBrowserCamera = false;
  bool _canUploadPhotoFallback = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    setState(() {
      _isInitializing = true;
      _canUploadPhotoFallback = false;
      _errorText = null;
    });

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw ApiException('No camera is available on this device.');
      }

      final preferredIndex = await _resolvePreferredCameraIndex(
        cameras,
        widget.preferredLensDirection,
      );

      if (preferredIndex == null) {
        final selectedLabel =
            widget.preferredLensDirection == CameraLensDirection.front
            ? 'front'
            : 'back';
        throw ApiException(
          'Selected $selectedLabel camera is not available on this browser/device.',
        );
      }

      final cameraTryOrder = _buildCameraTryOrder(
        cameras,
        preferredIndex,
        widget.preferredLensDirection,
      );

      CameraException? lastCameraError;
      for (final cameraIndex in cameraTryOrder) {
        try {
          await _activateCamera(cameras, cameraIndex);
          return;
        } on CameraException catch (error) {
          lastCameraError = error;
        }
      }

      if (lastCameraError != null) {
        throw lastCameraError;
      }
      throw ApiException('No camera is available on this device.');
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = _cameraErrorMessage(error, forCapture: false);
        _canUploadPhotoFallback = _isCameraUnavailableError(error);
        _isInitializing = false;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = error.message;
        _canUploadPhotoFallback = _isCameraUnavailableMessage(error.message);
        _isInitializing = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to start the camera.';
        _canUploadPhotoFallback = false;
        _isInitializing = false;
      });
    }
  }

  Future<int?> _resolvePreferredCameraIndex(
    List<CameraDescription> cameras,
    CameraLensDirection preferredDirection,
  ) async {
    final cachedName = _cameraNamePreference[preferredDirection];
    if (cachedName != null) {
      for (var i = 0; i < cameras.length; i += 1) {
        if (cameras[i].name == cachedName) {
          return i;
        }
      }
    }

    final directionMatches = _findCameraIndicesByDirection(
      cameras,
      preferredDirection,
    );
    if (directionMatches.isNotEmpty) {
      final index = _bestCameraIndex(
        cameras,
        preferredDirection,
        directionMatches,
      );
      _cameraNamePreference[preferredDirection] = cameras[index].name;
      return index;
    }

    final keywordMatches = _findCameraIndicesByName(
      cameras,
      preferredDirection,
    );
    if (keywordMatches.isNotEmpty) {
      final index = _bestCameraIndex(
        cameras,
        preferredDirection,
        keywordMatches,
      );
      _cameraNamePreference[preferredDirection] = cameras[index].name;
      return index;
    }

    final webcamMatches = _findWebcamIndices(cameras);
    if (webcamMatches.isNotEmpty) {
      return webcamMatches.first;
    }

    // On some mobile browsers, lens metadata can be incomplete.
    // Fallback to first available camera instead of failing to open.
    return 0;
  }

  List<int> _findCameraIndicesByDirection(
    List<CameraDescription> cameras,
    CameraLensDirection preferredDirection,
  ) {
    final indices = <int>[];

    for (var i = 0; i < cameras.length; i += 1) {
      if (cameras[i].lensDirection == preferredDirection) {
        indices.add(i);
      }
    }

    return indices;
  }

  List<int> _findCameraIndicesByName(
    List<CameraDescription> cameras,
    CameraLensDirection preferredDirection,
  ) {
    final keywordPatterns = preferredDirection == CameraLensDirection.front
        ? <RegExp>[
            RegExp(r'front', caseSensitive: false),
            RegExp(r'user', caseSensitive: false),
          ]
        : <RegExp>[
            RegExp(r'back', caseSensitive: false),
            RegExp(r'rear', caseSensitive: false),
            RegExp(r'environment', caseSensitive: false),
          ];

    final indices = <int>[];
    for (var i = 0; i < cameras.length; i += 1) {
      final name = cameras[i].name;
      if (keywordPatterns.any((pattern) => pattern.hasMatch(name))) {
        indices.add(i);
      }
    }

    return indices;
  }

  List<int> _findWebcamIndices(List<CameraDescription> cameras) {
    final indices = <int>[];

    for (var i = 0; i < cameras.length; i += 1) {
      final description = cameras[i];
      final name = description.name.toLowerCase();
      final isExternal =
          description.lensDirection == CameraLensDirection.external;
      final looksLikeWebcam =
          name.contains('webcam') ||
          name.contains('facetime') ||
          name.contains('integrated') ||
          name.contains('usb');

      if (isExternal || looksLikeWebcam) {
        indices.add(i);
      }
    }

    return indices;
  }

  int _bestCameraIndex(
    List<CameraDescription> cameras,
    CameraLensDirection preferredDirection,
    List<int> candidateIndices,
  ) {
    var bestIndex = candidateIndices.first;
    var bestScore = -1000000;

    for (final index in candidateIndices) {
      final name = cameras[index].name.toLowerCase();
      var score = 0;

      if (preferredDirection == CameraLensDirection.front) {
        if (name.contains('front')) {
          score += 10;
        }
        if (name.contains('user')) {
          score += 8;
        }
        if (name.contains('camera 1')) {
          score += 4;
        }
      } else {
        if (name.contains('back')) {
          score += 10;
        }
        if (name.contains('rear')) {
          score += 10;
        }
        if (name.contains('environment')) {
          score += 8;
        }
        if (name.contains('camera 0')) {
          score += 7;
        }
      }

      if (name.contains('tele') || name.contains('zoom')) {
        score -= 10;
      }
      if (name.contains('virtual')) {
        score -= 5;
      }
      if (name.contains('depth')) {
        score -= 3;
      }

      if (score > bestScore) {
        bestScore = score;
        bestIndex = index;
      }
    }

    return bestIndex;
  }

  List<int> _buildCameraTryOrder(
    List<CameraDescription> cameras,
    int preferredIndex,
    CameraLensDirection preferredDirection,
  ) {
    final ordered = <int>[preferredIndex];
    void addIfMissing(int index) {
      if (index < 0 || index >= cameras.length || ordered.contains(index)) {
        return;
      }
      ordered.add(index);
    }

    final directionMatches = _findCameraIndicesByDirection(
      cameras,
      preferredDirection,
    );
    for (final index in directionMatches) {
      addIfMissing(index);
    }

    final keywordMatches = _findCameraIndicesByName(
      cameras,
      preferredDirection,
    );
    for (final index in keywordMatches) {
      addIfMissing(index);
    }

    final webcamMatches = _findWebcamIndices(cameras);
    for (final index in webcamMatches) {
      addIfMissing(index);
    }

    for (var index = 0; index < cameras.length; index += 1) {
      addIfMissing(index);
    }

    return ordered;
  }

  Future<CameraController> _initializeCameraController(
    CameraDescription description,
  ) async {
    final presets = <ResolutionPreset>[
      ResolutionPreset.medium,
      ResolutionPreset.low,
    ];
    final useJpegFormat = <bool>[true, false];
    CameraException? lastError;

    for (final preset in presets) {
      for (final withJpegFormat in useJpegFormat) {
        final controller = withJpegFormat
            ? CameraController(
                description,
                preset,
                enableAudio: false,
                imageFormatGroup: ImageFormatGroup.jpeg,
              )
            : CameraController(description, preset, enableAudio: false);
        try {
          await controller.initialize();
          await _resetToMinimumZoom(controller);
          return controller;
        } on CameraException catch (error) {
          lastError = error;
          await controller.dispose();
        } catch (_) {
          await controller.dispose();
          rethrow;
        }
      }
    }

    throw lastError ??
        CameraException(
          'CameraInitializationFailed',
          'Unable to initialize the selected camera.',
        );
  }

  Future<void> _resetToMinimumZoom(CameraController controller) async {
    try {
      final minZoomLevel = await controller.getMinZoomLevel();
      await controller.setZoomLevel(minZoomLevel);
    } catch (_) {
      // Ignore unsupported zoom controls on browsers that don't expose them.
    }
  }

  Future<void> _activateCamera(
    List<CameraDescription> cameras,
    int cameraIndex,
  ) async {
    final previousController = _controller;
    final description = cameras[cameraIndex];
    final controller = await _initializeCameraController(description);

    if (!mounted) {
      await controller.dispose();
      return;
    }

    await previousController?.dispose();

    setState(() {
      _cameras = cameras;
      _controller = controller;
      _activeCameraIndex = cameraIndex;
      _isInitializing = false;
      _canUploadPhotoFallback = false;
      _errorText = null;
    });
  }

  Future<void> _toggleCamera() async {
    if (_isInitializing || _isCapturing || _cameras.length < 2) {
      return;
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    final currentDirection = _cameras[_activeCameraIndex].lensDirection;
    final preferredDirection = currentDirection == CameraLensDirection.front
        ? CameraLensDirection.back
        : CameraLensDirection.front;
    final nextIndex = await _resolvePreferredCameraIndex(
      _cameras,
      preferredDirection,
    );
    if (nextIndex == null || nextIndex == _activeCameraIndex) {
      return;
    }

    setState(() {
      _isInitializing = true;
      _errorText = null;
    });

    try {
      await _activateCamera(_cameras, nextIndex);
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = _cameraErrorMessage(error, forCapture: false);
        _canUploadPhotoFallback = _isCameraUnavailableError(error);
        _isInitializing = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to switch camera.';
        _canUploadPhotoFallback = false;
        _isInitializing = false;
      });
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) {
      return;
    }

    setState(() {
      _isCapturing = true;
    });

    try {
      final image = await controller.takePicture();
      final bytes = await image.readAsBytes();
      if (!mounted) {
        return;
      }

      if (bytes.isEmpty) {
        throw ApiException('Unable to capture photo.');
      }

      Navigator.of(context).pop(bytes);
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = _cameraErrorMessage(error, forCapture: true);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to capture photo.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isCapturing = false;
        });
      }
    }
  }

  Future<void> _openBrowserCameraFallback() async {
    if (_isOpeningBrowserCamera || _isCapturing) {
      return;
    }

    setState(() {
      _isOpeningBrowserCamera = true;
    });

    try {
      final facingMode =
          widget.preferredLensDirection == CameraLensDirection.back
          ? 'environment'
          : 'user';
      final bytes = await web_desktop_attendance.capturePhotoWithBrowserCamera(
        facingMode: facingMode,
      );

      if (!mounted) {
        return;
      }

      if (bytes != null && bytes.isNotEmpty) {
        Navigator.of(context).pop(bytes);
        return;
      }
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        final message = error.toString().replaceFirst('Bad state: ', '');
        _errorText = message;
        _canUploadPhotoFallback = _isCameraUnavailableMessage(message);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isOpeningBrowserCamera = false;
        });
      }
    }
  }

  Future<void> _uploadPhotoFallback() async {
    if (!_canUploadPhotoFallback || _isCapturing || _isOpeningBrowserCamera) {
      return;
    }

    setState(() {
      _isCapturing = true;
      _errorText = null;
    });

    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 88,
      );

      if (!mounted) {
        return;
      }

      if (image == null) {
        setState(() {
          _errorText = 'No camera was detected. Upload a photo to continue.';
          _canUploadPhotoFallback = true;
        });
        return;
      }

      final bytes = await image.readAsBytes();
      if (bytes.isEmpty) {
        throw ApiException('Unable to read selected photo.');
      }

      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(bytes);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Unable to upload selected photo.';
        _canUploadPhotoFallback = true;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isCapturing = false;
        });
      }
    }
  }

  bool _isCameraUnavailableError(CameraException error) {
    final normalizedCode = error.code.toLowerCase();
    final normalizedDescription = (error.description ?? '').toLowerCase();

    return normalizedCode.contains('noavailablecamera') ||
        normalizedCode.contains('notfound') ||
        normalizedCode.contains('not_found') ||
        normalizedDescription.contains('no camera') ||
        normalizedDescription.contains('not found') ||
        normalizedDescription.contains('no video input');
  }

  bool _isCameraUnavailableMessage(String message) {
    final normalized = message.toLowerCase();

    if (normalized.contains('permission') ||
        normalized.contains('denied') ||
        normalized.contains('notallowed') ||
        normalized.contains('security') ||
        normalized.contains('https') ||
        normalized.contains('origin')) {
      return false;
    }

    return normalized.contains('no camera') ||
        normalized.contains('not detected') ||
        normalized.contains('not found') ||
        normalized.contains('not supported') ||
        normalized.contains('no video input');
  }

  String _cameraErrorMessage(
    CameraException error, {
    required bool forCapture,
  }) {
    switch (error.code) {
      case 'CameraAccessDenied':
      case 'cameraPermission':
        return 'Camera permission was denied.';
      case 'CameraAccessRestricted':
        return 'Camera access is restricted on this device.';
      case 'NoAvailableCamera':
        return 'No camera is available on this device.';
      default:
        final description = error.description?.trim();
        final normalizedDescription = description?.toLowerCase() ?? '';
        final normalizedCode = error.code.toLowerCase();
        if ((normalizedCode.contains('notallowed') ||
                normalizedCode.contains('security')) &&
            (normalizedDescription.contains('secure') ||
                normalizedDescription.contains('https') ||
                normalizedDescription.contains('origin') ||
                normalizedDescription.contains('permission'))) {
          return 'Camera access is blocked by this browser. Open the app over HTTPS and allow camera permission.';
        }
        if (description != null && description.isNotEmpty) {
          return description;
        }

        return forCapture
            ? 'Unable to capture photo.'
            : 'Unable to start the camera.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;
    final canSwitchCamera =
        !_isInitializing &&
        !_isCapturing &&
        _cameras.length > 1 &&
        _errorText == null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.82),
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: canSwitchCamera ? _toggleCamera : null,
                    icon: const Icon(
                      Icons.flip_camera_ios_rounded,
                      color: Colors.white,
                    ),
                    tooltip: 'Switch camera',
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: ColoredBox(
                    color: const Color(0xFF111111),
                    child: _isInitializing
                        ? const Center(child: CircularProgressIndicator())
                        : _errorText != null
                        ? _FrontCameraErrorState(
                            message: _errorText!,
                            actionLabel: kIsWeb
                                ? (_isOpeningBrowserCamera
                                      ? 'Opening browser camera...'
                                      : 'Open Browser Camera')
                                : null,
                            onActionPressed: kIsWeb && !_isOpeningBrowserCamera
                                ? _openBrowserCameraFallback
                                : null,
                            secondaryActionLabel:
                                kIsWeb && _canUploadPhotoFallback
                                ? (_isCapturing
                                      ? 'Opening upload...'
                                      : 'Upload Photo')
                                : null,
                            onSecondaryActionPressed:
                                kIsWeb &&
                                    _canUploadPhotoFallback &&
                                    !_isCapturing
                                ? _uploadPhotoFallback
                                : null,
                          )
                        : controller == null || !controller.value.isInitialized
                        ? _FrontCameraErrorState(
                            message: 'Unable to start the camera.',
                            actionLabel: kIsWeb
                                ? (_isOpeningBrowserCamera
                                      ? 'Opening browser camera...'
                                      : 'Open Browser Camera')
                                : null,
                            onActionPressed: kIsWeb && !_isOpeningBrowserCamera
                                ? _openBrowserCameraFallback
                                : null,
                            secondaryActionLabel:
                                kIsWeb && _canUploadPhotoFallback
                                ? (_isCapturing
                                      ? 'Opening upload...'
                                      : 'Upload Photo')
                                : null,
                            onSecondaryActionPressed:
                                kIsWeb &&
                                    _canUploadPhotoFallback &&
                                    !_isCapturing
                                ? _uploadPhotoFallback
                                : null,
                          )
                        : _WebCameraPreview(controller: controller),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed:
                      _isInitializing || _errorText != null || _isCapturing
                      ? null
                      : _capture,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.primaryDark,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: _isCapturing
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : const Text(
                          'Capture Photo',
                          style: TextStyle(fontWeight: FontWeight.w800),
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

class FrontCameraCapturePage extends StatefulWidget {
  const FrontCameraCapturePage({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  State<FrontCameraCapturePage> createState() => _FrontCameraCapturePageState();
}

class _FrontCameraCapturePageState extends State<FrontCameraCapturePage> {
  CameraController? _controller;
  bool _isInitializing = true;
  bool _isCapturing = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _initializeFrontCamera();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initializeFrontCamera() async {
    try {
      final cameras = await availableCameras();
      final frontCamera = cameras
          .where((camera) => camera.lensDirection == CameraLensDirection.front)
          .cast<CameraDescription?>()
          .firstWhere((camera) => camera != null, orElse: () => null);

      if (frontCamera == null) {
        throw ApiException('No front camera is available on this device.');
      }

      final controller = CameraController(
        frontCamera,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _isInitializing = false;
      });
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorText = _cameraSetupErrorMessage(error);
        _isInitializing = false;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorText = error.message;
        _isInitializing = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorText = 'Unable to start the front camera.';
        _isInitializing = false;
      });
    }
  }

  String _cameraSetupErrorMessage(CameraException error) {
    switch (error.code) {
      case 'CameraAccessDenied':
      case 'cameraPermission':
        return 'Camera permission was denied.';
      case 'CameraAccessRestricted':
        return 'Camera access is restricted on this device.';
      case 'NoAvailableCamera':
        return 'No front camera is available on this device.';
      default:
        final description = error.description?.trim();
        if (description != null && description.isNotEmpty) {
          return description;
        }

        return 'Unable to start the front camera.';
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) {
      return;
    }

    setState(() {
      _isCapturing = true;
      _errorText = null;
    });

    try {
      final image = await controller.takePicture();
      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(File(image.path));
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorText = _cameraSetupErrorMessage(error);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorText = 'Unable to capture photo.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isCapturing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.82),
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: ColoredBox(
                    color: const Color(0xFF111111),
                    child: _isInitializing
                        ? const Center(child: CircularProgressIndicator())
                        : _errorText != null
                        ? _FrontCameraErrorState(message: _errorText!)
                        : controller == null || !controller.value.isInitialized
                        ? const _FrontCameraErrorState(
                            message: 'Unable to start the front camera.',
                          )
                        : Stack(
                            fit: StackFit.expand,
                            children: [
                              _FrontCameraPreview(controller: controller),
                              IgnorePointer(
                                child: Center(
                                  child: Container(
                                    width: 250,
                                    height: 330,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(28),
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: 0.9,
                                        ),
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 16,
                                right: 16,
                                bottom: 18,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.58),
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  child: Text(
                                    'Front camera only. Center your face in the frame before capturing.',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed:
                      _isInitializing || _errorText != null || _isCapturing
                      ? null
                      : _capture,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.primaryDark,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: _isCapturing
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : const Text(
                          'Capture Selfie',
                          style: TextStyle(fontWeight: FontWeight.w800),
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

class _FrontCameraErrorState extends StatelessWidget {
  const _FrontCameraErrorState({
    required this.message,
    this.actionLabel,
    this.onActionPressed,
    this.secondaryActionLabel,
    this.onSecondaryActionPressed,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onActionPressed;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryActionPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.no_photography_outlined,
              color: Colors.white70,
              size: 40,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onActionPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.primaryDark,
                ),
                child: Text(actionLabel!),
              ),
            ],
            if (secondaryActionLabel != null) ...[
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: onSecondaryActionPressed,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.72)),
                ),
                child: Text(secondaryActionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WebCameraPreview extends StatelessWidget {
  const _WebCameraPreview({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final previewSize = controller.value.previewSize;

    if (previewSize == null) {
      return Center(child: CameraPreview(controller));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final frameAspectRatio = constraints.maxWidth / constraints.maxHeight;
        final directWidth = previewSize.width;
        final directHeight = previewSize.height;
        final swappedWidth = previewSize.height;
        final swappedHeight = previewSize.width;

        final directAspectRatio = directWidth / directHeight;
        final swappedAspectRatio = swappedWidth / swappedHeight;
        final useSwappedOrientation =
            (swappedAspectRatio - frameAspectRatio).abs() <
            (directAspectRatio - frameAspectRatio).abs();

        final previewWidth = useSwappedOrientation ? swappedWidth : directWidth;
        final previewHeight = useSwappedOrientation
            ? swappedHeight
            : directHeight;

        return ClipRect(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: previewWidth,
              height: previewHeight,
              child: CameraPreview(controller),
            ),
          ),
        );
      },
    );
  }
}

class _FrontCameraPreview extends StatelessWidget {
  const _FrontCameraPreview({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final previewSize = controller.value.previewSize;

    if (previewSize == null) {
      return Center(child: CameraPreview(controller));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isPortraitFrame = constraints.maxHeight >= constraints.maxWidth;
        final previewWidth = isPortraitFrame
            ? previewSize.height
            : previewSize.width;
        final previewHeight = isPortraitFrame
            ? previewSize.width
            : previewSize.height;

        return ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: previewWidth,
              height: previewHeight,
              child: CameraPreview(controller),
            ),
          ),
        );
      },
    );
  }
}

class DashboardShortcut {
  const DashboardShortcut({
    required this.title,
    required this.icon,
    required this.highlight,
    this.enabled = true,
    this.glow = false,
    this.badgeCount = 0,
    this.onTap,
  });

  final String title;
  final IconData icon;
  final bool highlight;
  final bool enabled;
  final bool glow;
  final int badgeCount;
  final VoidCallback? onTap;
}

class _EmployeeAvatar extends StatefulWidget {
  const _EmployeeAvatar({
    required this.employee,
    required this.size,
    this.backgroundColor,
    this.textStyle,
  });

  final Employee employee;
  final double size;
  final Color? backgroundColor;
  final TextStyle? textStyle;

  @override
  State<_EmployeeAvatar> createState() => _EmployeeAvatarState();
}

class _EmployeeAvatarState extends State<_EmployeeAvatar> {
  int _currentPhotoIndex = 0;

  @override
  void didUpdateWidget(covariant _EmployeeAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!_samePhotoUrls(
      oldWidget.employee.resolvedPhotoUrls,
      widget.employee.resolvedPhotoUrls,
    )) {
      _currentPhotoIndex = 0;
    } else if (_currentPhotoIndex >= widget.employee.resolvedPhotoUrls.length) {
      _currentPhotoIndex = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final employee = widget.employee;
    final size = widget.size;
    final backgroundColor = widget.backgroundColor;
    final textStyle = widget.textStyle;

    Widget fallbackAvatar() {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: backgroundColor,
          gradient: backgroundColor == null
              ? const LinearGradient(
                  colors: [AppColors.primary, AppColors.accent],
                )
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          employee.initials,
          style:
              textStyle ??
              Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
        ),
      );
    }

    final photoUrls = employee.resolvedPhotoUrls;
    if (!employee.hasPhoto ||
        photoUrls.isEmpty ||
        _currentPhotoIndex >= photoUrls.length) {
      return fallbackAvatar();
    }

    return ClipOval(
      child: Image.network(
        photoUrls[_currentPhotoIndex],
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          if (_currentPhotoIndex < photoUrls.length - 1) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) {
                return;
              }

              setState(() {
                _currentPhotoIndex += 1;
              });
            });

            return fallbackAvatar();
          }

          return fallbackAvatar();
        },
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) {
            return child;
          }

          return fallbackAvatar();
        },
      ),
    );
  }
}

class _ProfileBadge extends StatelessWidget {
  const _ProfileBadge({required this.label, required this.backgroundColor});

  final String label;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(99),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ProfileEntry {
  const _ProfileEntry({required this.label, required this.value});

  final String label;
  final String value;
}

class _ProfileDetailsCard extends StatelessWidget {
  const _ProfileDetailsCard({required this.entries});

  final List<_ProfileEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        children: entries
            .map(
              (entry) =>
                  _ProfileDetailRow(label: entry.label, value: entry.value),
            )
            .toList(),
      ),
    );
  }
}

class _ProfileDetailRow extends StatelessWidget {
  const _ProfileDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.subtleText,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        color: AppColors.text,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.label,
    required this.value,
    this.isSelected = false,
    this.onTap,
  });

  final String label;
  final String value;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primary : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isSelected ? AppColors.primary : Colors.transparent,
              width: 1.5,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x12000000),
                blurRadius: 16,
                offset: Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: isSelected ? Colors.white : AppColors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isSelected ? Colors.white : AppColors.subtleText,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttendanceHistoryTable extends StatelessWidget {
  const _AttendanceHistoryTable({
    required this.records,
    required this.onViewDetails,
  });

  final List<AttendanceRecord> records;
  final ValueChanged<AttendanceRecord> onViewDetails;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            color: AppColors.surfaceTint,
            child: const Row(
              children: [
                _AttendanceReportHeaderCell(label: 'No', flex: 1),
                _AttendanceReportHeaderCell(label: 'Date', flex: 2),
                _AttendanceReportHeaderCell(label: 'In', flex: 2),
                _AttendanceReportHeaderCell(label: 'Out', flex: 2),
                _AttendanceReportHeaderCell(label: 'Status', flex: 2),
                _AttendanceReportHeaderCell(label: 'View', flex: 1),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: records.length,
              separatorBuilder: (context, index) => Divider(
                height: 1,
                color: AppColors.surfaceTint.withValues(alpha: 0.9),
              ),
              itemBuilder: (context, index) {
                final record = records[index];

                return _AttendanceReportRow(
                  serialNumber: index + 1,
                  record: record,
                  onTap: () => onViewDetails(record),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AttendanceReportHeaderCell extends StatelessWidget {
  const _AttendanceReportHeaderCell({required this.label, required this.flex});

  final String label;
  final int flex;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppColors.subtleText,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _AttendanceReportRow extends StatelessWidget {
  const _AttendanceReportRow({
    required this.serialNumber,
    required this.record,
    required this.onTap,
  });

  final int serialNumber;
  final AttendanceRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isRedStatus = record.status == 'absent' || record.isWeekOff;
    final valueColor = isRedStatus ? AppColors.primary : AppColors.text;

    return SizedBox(
      height: 52,
      child: Row(
        children: [
          _AttendanceReportValueCell(
            value: serialNumber.toString(),
            flex: 1,
            color: valueColor,
          ),
          _AttendanceReportValueCell(
            value: _formatTableDate(record.checkInDate),
            flex: 2,
            color: valueColor,
          ),
          _AttendanceReportValueCell(
            value: isRedStatus ? '--' : _formatTime(record.checkInTime),
            flex: 2,
            color: valueColor,
          ),
          _AttendanceReportValueCell(
            value: isRedStatus ? '--' : _formatTime(record.checkOutTime),
            flex: 2,
            color: valueColor,
          ),
          _AttendanceReportValueCell(
            value: record.displayStatusLabel,
            flex: 2,
            color: valueColor,
          ),
          Expanded(
            flex: 1,
            child: Center(
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Image.asset(
                    'assets/images/window.png',
                    width: 18,
                    height: 18,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttendanceReportValueCell extends StatelessWidget {
  const _AttendanceReportValueCell({
    required this.value,
    required this.flex,
    this.color,
  });

  final String value;
  final int flex;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: color ?? AppColors.text,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _AttendanceHistoryCard extends StatelessWidget {
  const _AttendanceHistoryCard({required this.record});

  final AttendanceRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRedStatus = record.status == 'absent' || record.isWeekOff;
    final statusColor = isRedStatus
        ? AppColors.primary
        : record.isAdminOverride || record.hasCheckedOut
        ? AppColors.success
        : AppColors.primary;
    final photoUrls = record.resolvedPhotoUrls;
    final checkOutPhotoUrls = record.resolvedCheckOutPhotoUrls;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _formatIsoDate(record.checkInDate),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: AppColors.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(99),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Text(
                  record.displayStatusLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _HistoryFact(label: 'Status', value: record.displayStatusLabel),
          const SizedBox(height: 8),
          _HistoryFact(
            label: 'Check In',
            value: _formatTime(record.checkInTime),
          ),
          const SizedBox(height: 8),
          _HistoryFact(
            label: 'In Branch',
            value: _stringOrFallback(
              record.checkInBranchId,
              fallback: 'Not available',
            ),
          ),
          const SizedBox(height: 8),
          _HistoryFact(
            label: 'Check Out',
            value: _formatTime(record.checkOutTime),
          ),
          const SizedBox(height: 8),
          _HistoryFact(
            label: 'Out Branch',
            value: _stringOrFallback(
              record.checkOutBranchId,
              fallback: 'Not available',
            ),
          ),
          const SizedBox(height: 8),
          _HistoryFact(
            label: 'Worked Hours',
            value: _formatDuration(record.workedDuration),
          ),
          const SizedBox(height: 8),
          _HistoryFact(label: 'Location', value: record.locationLabel),
          const SizedBox(height: 8),
          Text(
            'Check-In Image',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.subtleText,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: record.hasPhoto && photoUrls.isNotEmpty
                ? _AttendanceNetworkImage(photoUrls: photoUrls)
                : _AttendanceImagePlaceholder(
                    message: record.isAdminOverride
                        ? 'Marked present by admin. No punch image available.'
                        : 'Attendance image not available.',
                  ),
          ),
          if (record.hasCheckedOut || record.hasCheckOutPhoto) ...[
            const SizedBox(height: 14),
            Text(
              'Check-Out Image',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.subtleText,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: record.hasCheckOutPhoto && checkOutPhotoUrls.isNotEmpty
                  ? _AttendanceNetworkImage(photoUrls: checkOutPhotoUrls)
                  : const _AttendanceImagePlaceholder(
                      message: 'Check-out image not available.',
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AttendanceNetworkImage extends StatefulWidget {
  const _AttendanceNetworkImage({required this.photoUrls});

  final List<String> photoUrls;

  @override
  State<_AttendanceNetworkImage> createState() =>
      _AttendanceNetworkImageState();
}

class _AttendanceNetworkImageState extends State<_AttendanceNetworkImage> {
  int _currentIndex = 0;

  @override
  void didUpdateWidget(covariant _AttendanceNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!_samePhotoUrls(oldWidget.photoUrls, widget.photoUrls)) {
      _currentIndex = 0;
    } else if (_currentIndex >= widget.photoUrls.length) {
      _currentIndex = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.photoUrls.isEmpty || _currentIndex >= widget.photoUrls.length) {
      return const _AttendanceImagePlaceholder(
        message: 'Attendance image not available.',
      );
    }

    final photoUrl = widget.photoUrls[_currentIndex];

    return Image.network(
      photoUrl,
      width: double.infinity,
      height: 190,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        if (_currentIndex < widget.photoUrls.length - 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }

            setState(() {
              _currentIndex += 1;
            });
          });

          return const SizedBox(
            width: double.infinity,
            height: 190,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        return const _AttendanceImagePlaceholder(
          message: 'Attendance image not available.',
        );
      },
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) {
          return child;
        }

        return const SizedBox(
          width: double.infinity,
          height: 190,
          child: Center(child: CircularProgressIndicator()),
        );
      },
    );
  }
}

class _AttendanceImagePlaceholder extends StatelessWidget {
  const _AttendanceImagePlaceholder({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 190,
      color: AppColors.surfaceTint,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.image_not_supported_outlined,
            size: 34,
            color: AppColors.secondary,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppColors.secondary,
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _HistoryFact extends StatelessWidget {
  const _HistoryFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 82,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.subtleText,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppColors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _InsightBanner extends StatelessWidget {
  const _InsightBanner({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF1E7FF), Color(0xFFE4D3FF)],
        ),
      ),
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: AppColors.primaryDark,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.secondary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Container(
            width: 74,
            height: 112,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                colors: [AppColors.primaryDark, AppColors.primary],
              ),
            ),
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.smartphone, color: Colors.white),
                const Spacer(),
                Container(
                  height: 8,
                  width: 38,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 8,
                  width: 26,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineInfoCard extends StatelessWidget {
  const _InlineInfoCard({
    required this.backgroundColor,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.action,
    this.titleColor = AppColors.text,
    this.subtitleColor = AppColors.subtleText,
  });

  final Color backgroundColor;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget? action;
  final Color titleColor;
  final Color subtitleColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: iconColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: titleColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: subtitleColor,
                    height: 1.45,
                  ),
                ),
                if (action != null) ...[const SizedBox(height: 8), action!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _SearchableOption<T> {
  const _SearchableOption({
    required this.value,
    required this.label,
    String? searchText,
  }) : searchText = searchText ?? label;

  final T value;
  final String label;
  final String searchText;
}

class _SearchableSelectionField<T> extends StatelessWidget {
  const _SearchableSelectionField({
    required this.hintText,
    required this.prefixIcon,
    required this.options,
    required this.onSelected,
    this.selectedValue,
    this.enabled = true,
    this.emptyMessage = 'No options found.',
  });

  final String hintText;
  final IconData prefixIcon;
  final List<_SearchableOption<T>> options;
  final T? selectedValue;
  final ValueChanged<T?> onSelected;
  final bool enabled;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    _SearchableOption<T>? selectedOption;
    for (final option in options) {
      if (option.value == selectedValue) {
        selectedOption = option;
        break;
      }
    }
    final hasSelection = selectedOption != null;

    return InkWell(
      onTap: enabled ? () => _openPicker(context) : null,
      borderRadius: BorderRadius.circular(18),
      child: InputDecorator(
        decoration: _fieldDecoration(
          hintText: hintText,
          prefixIcon: prefixIcon,
          suffixIcon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        isEmpty: !hasSelection,
        child: Text(
          selectedOption?.label ?? hintText,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: hasSelection ? AppColors.text : AppColors.subtleText,
          ),
        ),
      ),
    );
  }

  Future<void> _openPicker(BuildContext context) async {
    final searchController = TextEditingController();
    await showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        var query = '';

        return StatefulBuilder(
          builder: (context, setSheetState) {
            final filteredOptions = options.where((option) {
              final normalizedQuery = query.trim().toLowerCase();
              if (normalizedQuery.isEmpty) {
                return true;
              }

              return option.searchText.toLowerCase().contains(normalizedQuery);
            }).toList();

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 16,
                  bottom: MediaQuery.of(context).viewInsets.bottom + 20,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hintText,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: AppColors.text,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: searchController,
                      autofocus: true,
                      decoration: _fieldDecoration(
                        hintText: 'Type to search',
                        prefixIcon: Icons.search_rounded,
                      ),
                      onChanged: (value) {
                        setSheetState(() {
                          query = value;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: filteredOptions.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(vertical: 24),
                              child: Center(
                                child: Text(
                                  emptyMessage,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(color: AppColors.subtleText),
                                ),
                              ),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              itemCount: filteredOptions.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final option = filteredOptions[index];
                                final isSelected =
                                    option.value == selectedValue;
                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(option.label),
                                  trailing: isSelected
                                      ? const Icon(
                                          Icons.check_circle_rounded,
                                          color: AppColors.primary,
                                        )
                                      : null,
                                  onTap: () {
                                    Navigator.of(context).pop();
                                    onSelected(option.value);
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _BirthdayBurstOverlay extends StatelessWidget {
  const _BirthdayBurstOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1700),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        final clamped = value.clamp(0.0, 1.0);
        final fadeOut = 1 - ((clamped - 0.6) / 0.4).clamp(0.0, 1.0);

        Widget burstIcon({
          required double left,
          required double topStart,
          required double topTravel,
          required double rotationTurns,
          required IconData icon,
          required Color color,
          required double size,
        }) {
          return Positioned(
            left: left,
            top: topStart + (topTravel * clamped),
            child: Opacity(
              opacity: fadeOut,
              child: Transform.rotate(
                angle: rotationTurns * 6.28318 * clamped,
                child: Icon(icon, color: color, size: size),
              ),
            ),
          );
        }

        return Stack(
          children: [
            burstIcon(
              left: 18,
              topStart: 12,
              topTravel: 126,
              rotationTurns: -0.2,
              icon: Icons.celebration_rounded,
              color: const Color(0xFFFF7A59),
              size: 30,
            ),
            burstIcon(
              left: 54,
              topStart: 26,
              topTravel: 152,
              rotationTurns: 0.3,
              icon: Icons.auto_awesome,
              color: const Color(0xFFFFC247),
              size: 18,
            ),
            burstIcon(
              left: 96,
              topStart: 18,
              topTravel: 172,
              rotationTurns: -0.4,
              icon: Icons.stars_rounded,
              color: const Color(0xFFFF5D8F),
              size: 20,
            ),
            burstIcon(
              left: MediaQuery.of(context).size.width - 50,
              topStart: 16,
              topTravel: 134,
              rotationTurns: 0.25,
              icon: Icons.celebration_rounded,
              color: const Color(0xFF6F40D8),
              size: 30,
            ),
            burstIcon(
              left: MediaQuery.of(context).size.width - 88,
              topStart: 32,
              topTravel: 166,
              rotationTurns: -0.28,
              icon: Icons.auto_awesome,
              color: const Color(0xFFFFD35F),
              size: 18,
            ),
            burstIcon(
              left: MediaQuery.of(context).size.width - 126,
              topStart: 24,
              topTravel: 184,
              rotationTurns: 0.42,
              icon: Icons.stars_rounded,
              color: const Color(0xFFFF7B7B),
              size: 20,
            ),
            Positioned(
              top: 102 + (18 * clamped),
              left: 20,
              right: 20,
              child: Opacity(
                opacity: (0.92 * fadeOut).clamp(0.0, 1.0),
                child: Text(
                  'Celebrate your day',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: const Color(0x80FFFFFF),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ShortcutCard extends StatelessWidget {
  const _ShortcutCard({required this.item});

  final DashboardShortcut item;

  @override
  Widget build(BuildContext context) {
    final interactive = item.enabled && item.onTap != null;

    return GestureDetector(
      onTap: interactive ? item.onTap : null,
      child: Container(
        decoration: BoxDecoration(
          color: item.enabled ? Colors.white : const Color(0xFFF1EEF6),
          borderRadius: BorderRadius.circular(24),
          boxShadow: item.glow
              ? const [
                  BoxShadow(
                    color: Color(0x55C62828),
                    blurRadius: 28,
                    spreadRadius: 1,
                    offset: Offset(0, 12),
                  ),
                  BoxShadow(
                    color: Color(0x24E2B94E),
                    blurRadius: 18,
                    spreadRadius: 2,
                  ),
                ]
              : const [
                  BoxShadow(
                    color: Color(0x12000000),
                    blurRadius: 16,
                    offset: Offset(0, 8),
                  ),
                ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: item.enabled
                        ? item.highlight
                              ? AppColors.primarySoft
                              : AppColors.surfaceTint
                        : const Color(0xFFE7E1EE),
                    boxShadow: item.glow
                        ? const [
                            BoxShadow(
                              color: Color(0x66D4A017),
                              blurRadius: 18,
                              spreadRadius: 2,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    item.icon,
                    color: item.enabled
                        ? item.highlight
                              ? AppColors.primary
                              : AppColors.secondary
                        : AppColors.secondary,
                  ),
                ),
                if (item.badgeCount > 0)
                  Positioned(
                    top: -5,
                    right: -5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE5446D),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: Text(
                        item.badgeCount > 99
                            ? '99+'
                            : item.badgeCount.toString(),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                item.title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: item.enabled ? AppColors.text : AppColors.secondary,
                ),
              ),
            ),
            if (item.enabled)
              Icon(
                Icons.chevron_right_rounded,
                color: item.highlight ? AppColors.primary : AppColors.secondary,
              )
            else
              Text(
                'Soon',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.subtleText,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

const List<String> _monthNames = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _stringOrFallback(String value, {String fallback = 'Not available'}) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? fallback : trimmed;
}

String _formatCurrency(int? amount) {
  if (amount == null) {
    return 'Not available';
  }

  return 'Rs $amount';
}

String _formatCurrencyValue(num? amount) {
  if (amount == null) {
    return 'Not available';
  }

  return 'Rs ${amount.round()}';
}

String _formatDecimalValue(num? value) {
  if (value == null) {
    return '--';
  }

  final rounded = value.toDouble();
  if (rounded == rounded.truncateToDouble()) {
    return rounded.toStringAsFixed(0);
  }

  return rounded.toStringAsFixed(1);
}

InputDecoration _fieldDecoration({
  required String hintText,
  required IconData prefixIcon,
  Widget? suffixIcon,
}) {
  return InputDecoration(
    hintText: hintText,
    prefixIcon: Icon(prefixIcon),
    suffixIcon: suffixIcon,
    filled: true,
    fillColor: AppColors.surfaceTint,
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: Color(0xFFD84A4A)),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: Color(0xFFD84A4A), width: 1.5),
    ),
  );
}

String _formatMonthKey(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  return '${value.year}-$month';
}

String _formatMonthLabel(DateTime value) {
  return '${_monthNames[value.month - 1]} ${value.year}';
}

String _formatDateKey(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}-$month-$day';
}

String _formatIsoDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    return value;
  }

  return '${parsed.day.toString().padLeft(2, '0')} ${_monthNames[parsed.month - 1].substring(0, 3)} ${parsed.year}';
}

String _formatBranchOpeningDateTime(String value) {
  final parsed = DateTime.tryParse(value)?.toLocal();
  if (parsed == null) {
    return '--';
  }

  final hour = parsed.hour % 12 == 0 ? 12 : parsed.hour % 12;
  final minute = parsed.minute.toString().padLeft(2, '0');
  final meridiem = parsed.hour >= 12 ? 'PM' : 'AM';
  return '${_formatIsoDate(parsed.toIso8601String())} ${hour.toString().padLeft(2, '0')}:$minute $meridiem';
}

String _branchOpeningStatusLabel(String value) {
  switch (value.trim().toLowerCase()) {
    case 'opened':
    case 'on_time':
      return 'Opened';
    case 'closed':
      return 'Closed';
    case 'late':
      return 'Opened Late';
    case 'not_opened':
      return 'Not Opened';
    case 'pending':
      return 'Pending';
    default:
      return value.trim().isEmpty ? 'Pending' : value;
  }
}

Color _branchOpeningStatusColor(String value) {
  switch (value.trim().toLowerCase()) {
    case 'closed':
      return const Color(0xFFE8F7ED);
    case 'opened':
    case 'on_time':
      return const Color(0xFFE8F4FF);
    case 'late':
    case 'not_opened':
      return const Color(0xFFFFEFE7);
    default:
      return const Color(0xFFF4F0FF);
  }
}

String _formatTableDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    return value;
  }

  final day = parsed.day.toString().padLeft(2, '0');
  final month = parsed.month.toString().padLeft(2, '0');
  final year = (parsed.year % 100).toString().padLeft(2, '0');
  return '$day/$month/$year';
}

String _formatTime(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Pending';
  }

  final trimmed = value.trim();
  if (trimmed.length >= 5) {
    return trimmed.substring(0, 5);
  }

  return trimmed;
}

String _formatDistanceMeters(double value) {
  if (value >= 1000) {
    return '${(value / 1000).toStringAsFixed(2)} km';
  }

  return '${value.round()} m';
}

String _formatDuration(Duration? value) {
  if (value == null) {
    return 'Pending';
  }

  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);

  if (hours == 0) {
    return '${minutes}m';
  }

  if (minutes == 0) {
    return '${hours}h';
  }

  return '${hours}h ${minutes}m';
}

Future<bool> _hasInternetConnection() async {
  if (kIsWeb) {
    return true;
  }

  try {
    final result = await InternetAddress.lookup(
      'one.one.one.one',
    ).timeout(const Duration(seconds: 3));
    return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  }
}

String _formatCompactTime(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Pending';
  }

  final trimmed = value.trim().toLowerCase();
  final match = RegExp(
    r'^(\d{1,2}):(\d{2})(?::\d{2})?\s*([ap]m)?$',
    caseSensitive: false,
  ).firstMatch(trimmed);

  if (match == null) {
    return trimmed.replaceAll(' ', '');
  }

  var hour = int.tryParse(match.group(1) ?? '');
  final minute = match.group(2) ?? '00';
  var meridiem = match.group(3);

  if (hour == null) {
    return trimmed.replaceAll(' ', '');
  }

  if (meridiem == null) {
    meridiem = hour >= 12 ? 'pm' : 'am';
    hour = hour % 12;
    if (hour == 0) {
      hour = 12;
    }
  }

  final hourText = hour.toString().padLeft(2, '0');
  return '$hourText:$minute${meridiem.toLowerCase()}';
}

String _formatAppliedAt(String value) {
  final parsed = DateTime.tryParse(value)?.toLocal();
  if (parsed == null) {
    return 'recently';
  }

  final hour = parsed.hour % 12 == 0 ? 12 : parsed.hour % 12;
  final minute = parsed.minute.toString().padLeft(2, '0');
  final meridiem = parsed.hour >= 12 ? 'pm' : 'am';
  return '${_formatIsoDate(parsed.toIso8601String())} at ${hour.toString().padLeft(2, '0')}:$minute$meridiem';
}

String _formatNotificationSentAt(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return 'Recently';
  }

  return _formatAppliedAt(trimmed);
}

Color _requestStatusColor(String status) {
  switch (status.trim().toLowerCase()) {
    case 'approved':
      return AppColors.success;
    case 'rejected':
      return const Color(0xFFC73B3B);
    case 'pending':
    default:
      return AppColors.primary;
  }
}

String _requestStatusLabel(String status) {
  final trimmed = status.trim().toLowerCase();
  if (trimmed.isEmpty) {
    return 'Pending';
  }

  return '${trimmed[0].toUpperCase()}${trimmed.substring(1)}';
}

bool _isTeDesignation(String value) {
  return value.trim().toUpperCase() == 'TE';
}

DateTime? _parseAttendanceTime(String? value) {
  if (value == null || value.trim().isEmpty) {
    return null;
  }

  final match = RegExp(
    r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$',
  ).firstMatch(value.trim());

  if (match == null) {
    return null;
  }

  final hour = int.tryParse(match.group(1) ?? '');
  final minute = int.tryParse(match.group(2) ?? '');
  final second = int.tryParse(match.group(3) ?? '0');

  if (hour == null || minute == null || second == null) {
    return null;
  }

  return DateTime(2000, 1, 1, hour, minute, second);
}

DateTime? _parseAttendanceDateTime(String? date, String? time) {
  final parsedTime = _parseAttendanceTime(time);
  final trimmedDate = date?.trim() ?? '';

  if (trimmedDate.isEmpty || parsedTime == null) {
    return null;
  }

  final parsedDate = DateTime.tryParse(trimmedDate);

  if (parsedDate == null) {
    return null;
  }

  return DateTime(
    parsedDate.year,
    parsedDate.month,
    parsedDate.day,
    parsedTime.hour,
    parsedTime.minute,
    parsedTime.second,
  );
}

bool _parseBool(dynamic value) {
  final normalized = value?.toString().trim().toLowerCase() ?? '';

  return normalized == '1' || normalized == 'true' || normalized == 'yes';
}

String _resolveAssetUrl(String path) {
  final trimmed = _withPublicAssetSegment(path).trim();
  if (trimmed.isEmpty) {
    return '';
  }

  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.hasScheme) {
    return _normalizeAssetCandidate(trimmed);
  }

  final apiUri = Uri.parse(ApiConfig.baseUrl);
  final segments = List<String>.from(apiUri.pathSegments);
  if (segments.isNotEmpty && segments.last == 'api') {
    segments.removeLast();
  }

  final baseUri = apiUri.replace(pathSegments: segments);
  final relativePath = trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;

  return _normalizeAssetCandidate(baseUri.resolve(relativePath).toString());
}

DateTime? _parseYmdDate(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final parts = trimmed.split('-');
  if (parts.length != 3) {
    return null;
  }

  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);

  if (year == null || month == null || day == null) {
    return null;
  }

  return DateTime(year, month, day);
}

String _formatApiDate(DateTime? date) {
  if (date == null) {
    return '';
  }

  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');

  return '$year-$month-$day';
}

String _formatDisplayDate(DateTime? date) {
  if (date == null) {
    return '';
  }

  const monthNames = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  return '${date.day.toString().padLeft(2, '0')} ${monthNames[date.month - 1]} ${date.year}';
}

List<String> _resolveAssetUrls({
  required String photoPath,
  required String photoUrl,
}) {
  final urls = <String>[];

  void addCandidate(String value) {
    final trimmed = _normalizeAssetCandidate(value);
    if (trimmed.isEmpty || urls.contains(trimmed)) {
      return;
    }

    urls.add(trimmed);
  }

  addCandidate(_resolveAssetUrl(photoPath));
  addCandidate(_withPublicAssetSegment(photoUrl));

  return urls;
}

String _withPublicAssetSegment(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '';
  }

  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.hasScheme) {
    final segments = List<String>.from(parsed.pathSegments);
    if (segments.isEmpty || segments.first == 'public') {
      return trimmed;
    }

    // Keep standard Laravel public-disk URLs intact:
    // https://host/storage/...
    if (segments.first == 'storage') {
      return trimmed;
    }

    return trimmed;
  }

  if (trimmed.startsWith('public/')) {
    return trimmed;
  }

  if (trimmed.startsWith('storage/')) {
    return trimmed;
  }

  return trimmed;
}

String _normalizeAssetCandidate(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '';
  }

  final parsed = Uri.tryParse(trimmed);
  if (parsed == null) {
    return trimmed;
  }

  if (!parsed.hasScheme) {
    return trimmed;
  }

  final apiUri = Uri.parse(ApiConfig.baseUrl);
  final pathSegments = List<String>.from(parsed.pathSegments);

  final needsHostRewrite = _shouldRewriteAssetHost(
    candidateUri: parsed,
    apiUri: apiUri,
  );

  final normalizedUri = parsed.replace(
    scheme: needsHostRewrite ? apiUri.scheme : parsed.scheme,
    host: needsHostRewrite ? apiUri.host : parsed.host,
    port: needsHostRewrite
        ? apiUri.port
        : parsed.hasPort
        ? parsed.port
        : null,
    pathSegments: pathSegments,
  );

  return normalizedUri.toString();
}

bool _shouldRewriteAssetHost({required Uri candidateUri, required Uri apiUri}) {
  final host = candidateUri.host.trim().toLowerCase();
  if (host.isEmpty) {
    return false;
  }

  if (host == '127.0.0.1' || host == 'localhost' || host == '10.0.2.2') {
    return true;
  }

  if (_isPrivateIpv4Host(host)) {
    return true;
  }

  if (host.endsWith('.local')) {
    return true;
  }

  return false;
}

bool _isPrivateIpv4Host(String host) {
  final parts = host.split('.');
  if (parts.length != 4) {
    return false;
  }

  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) {
      return false;
    }
    octets.add(value);
  }

  if (octets[0] == 10) {
    return true;
  }

  if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) {
    return true;
  }

  if (octets[0] == 192 && octets[1] == 168) {
    return true;
  }

  return false;
}

bool _samePhotoUrls(List<String> first, List<String> second) {
  if (identical(first, second)) {
    return true;
  }

  if (first.length != second.length) {
    return false;
  }

  for (var index = 0; index < first.length; index += 1) {
    if (first[index] != second[index]) {
      return false;
    }
  }

  return true;
}
