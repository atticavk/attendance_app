import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:workmanager/workmanager.dart';

const String _adminNotificationBackgroundTaskName =
    'adminNotificationBackgroundSync';
const String _adminNotificationBackgroundPeriodicTaskUniqueName =
    'adminNotificationBackgroundPeriodicSync';
const String _adminNotificationBackgroundOneOffTaskUniqueName =
    'adminNotificationBackgroundOneOffSync';

@pragma('vm:entry-point')
void adminNotificationBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    if (!Platform.isAndroid) {
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
  await PushMessagingService.initialize();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    await Workmanager().initialize(adminNotificationBackgroundDispatcher);
    await AdminNotificationBackgroundService.cancelAll();
  }
  await ApiConfig.load();
  await AttendanceNotificationService.initialize();
  await PushMessagingService.initialize();
  runApp(const EmployeePortalApp());
}

class AttendanceNotificationService {
  AttendanceNotificationService._();

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

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
          importance: Importance.high,
          priority: Priority.high,
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
          importance: Importance.high,
          priority: Priority.high,
          autoCancel: true,
        ),
      );

  static const NotificationDetails _branchOpeningNotificationDetails =
      NotificationDetails(
        android: AndroidNotificationDetails(
          'branch_opening_reminders',
          'Branch opening reminders',
          channelDescription: 'Reminders for employees assigned to open branches',
          icon: _notificationIcon,
          importance: Importance.high,
          priority: Priority.high,
          autoCancel: true,
        ),
      );

  static Future<void> initialize() async {
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) {
      return;
    }

    await _configureLocalTimezone();
    await _initializeNotificationsPlugin();
    await _createNotificationChannels();

    if (Platform.isAndroid) {
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
    if (!Platform.isAndroid) {
      return;
    }

    await _configureLocalTimezone();
    await _initializeNotificationsPlugin();
    await _createNotificationChannels();
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
    if (!Platform.isAndroid) {
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
        importance: Importance.high,
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
        importance: Importance.high,
      ),
    );
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'branch_opening_reminders',
        'Branch opening reminders',
        description: 'Reminders for employees assigned to open branches',
        importance: Importance.high,
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

    if (hasCheckedInToday || hasValidActiveAttendance) {
      await _notifications.cancel(id: _checkInReminderId);
      await _scheduleDailyReminder(_TimedReminder.checkIn, nextDay: true);
    } else if (_shouldShowCheckInReminder()) {
      await _showReminderNotification(_TimedReminder.checkIn);
    }

    if (hasCheckedOutToday) {
      await _notifications.cancel(id: _logoutReminderId);
    } else if (hasValidActiveAttendance &&
        _shouldShowCheckoutReminder()) {
      await _notifications.cancel(id: _logoutReminderId);
      await _showReminderNotification(_TimedReminder.logout);
    } else if (hasValidActiveAttendance) {
      await _scheduleDailyReminder(_TimedReminder.logout);
    } else {
      await _notifications.cancel(id: _logoutReminderId);
    }
  }

  static Future<void> showAdminNotification(
    EmployeePushNotification notification,
  ) async {
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
    await _notifications.cancel(id: _logoutReminderId);
    await _showCompletedNotification(
      id: _checkOutCompletedId,
      message: 'Check out completed.',
    );
  }

  static Future<void> clearForLogout() async {
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
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) {
      return;
    }

    await _cancelBranchOpeningReminders();

    if (employee == null || !employee.isBranchOpeningEmployee) {
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

    final branchName = employee.branchName.trim();
    final branchId = employee.branchId.trim();
    final branchLabel = branchName.isNotEmpty
        ? branchName
        : (branchId.isNotEmpty ? branchId : 'your branch');
    final openingLabel = _formatBranchOpeningTime(openingTime);
    final androidScheduleMode = await _resolveAndroidScheduleMode();

    for (var index = 0;
        index < offsets.length && index < _branchOpeningReminderMaxSlots;
        index += 1) {
      final offset = offsets[index];
      final reminderTime = _branchOpeningTimeMinusMinutes(
        openingTime,
        offset,
      );
      final isOpeningTime = offset == 0;
      await _notifications.zonedSchedule(
        id: _branchOpeningReminderBaseId + index,
        title: 'Branch opening reminder',
        body: isOpeningTime
            ? 'It is time to open $branchLabel. Please open the branch now.'
            : '$branchLabel opens at $openingLabel. Please be ready to open the branch.',
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
    if (!Platform.isAndroid) {
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
}

class PushMessagingService {
  PushMessagingService._();

  static bool _initialized = false;
  static bool _available = false;

  static bool get isAvailable => _available;

  static Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    _initialized = true;
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) {
      return;
    }

    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      await FirebaseMessaging.instance.setAutoInitEnabled(true);
      _available = true;
    } catch (_) {
      _available = false;
    }
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

  static Stream<RemoteMessage> get onMessageOpenedApp =>
      _available
          ? FirebaseMessaging.onMessageOpenedApp
          : Stream<RemoteMessage>.empty();

  static Stream<String> get onTokenRefresh =>
      _available
          ? FirebaseMessaging.instance.onTokenRefresh
          : Stream<String>.empty();

  static String get platform {
    if (Platform.isAndroid) {
      return 'android';
    }
    if (Platform.isIOS) {
      return 'ios';
    }
    if (Platform.isMacOS) {
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

  @override
  void initState() {
    super.initState();
    _splashController = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _splashController.dispose();
    super.dispose();
  }

  void _playSplashOnce(LottieComposition composition) {
    _splashController
      ..duration = composition.duration
      ..forward(from: 0).whenComplete(widget.onFinished);
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
  static const hostedBaseUrl = 'https://abhibs.in/api';
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
    final normalized = normalizedSavedValue ?? resolvedDefaultBaseUrl;

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

  static bool isValid(String value) {
    final parsed = Uri.tryParse(normalize(value));
    return parsed != null && parsed.hasScheme && parsed.host.isNotEmpty;
  }

  static Uri _normalizeLoopbackUri(Uri uri) {
    if (!Platform.isAndroid) {
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
    required this.location,
    required this.designation,
    required this.photo,
    required this.photoUrl,
    required this.rating,
    required this.status,
    required this.isNightShift,
    required this.salary,
    required this.advance,
    required this.pf,
    required this.isBranchOpeningEmployee,
    required this.branchOpeningTime,
    required this.branchOpeningReminderStartMinutes,
    required this.branchOpeningReminderIntervalMinutes,
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
  final String location;
  final String designation;
  final String photo;
  final String photoUrl;
  final int rating;
  final String status;
  final bool isNightShift;
  final int? salary;
  final int? advance;
  final int? pf;
  final bool isBranchOpeningEmployee;
  final String branchOpeningTime;
  final int branchOpeningReminderStartMinutes;
  final int branchOpeningReminderIntervalMinutes;

  bool get hasPhoto => photo.trim().isNotEmpty || photoUrl.trim().isNotEmpty;

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
      location: json['location']?.toString() ?? '',
      designation: json['designation']?.toString() ?? '',
      photo: json['photo']?.toString() ?? '',
      photoUrl: json['photoUrl']?.toString() ?? '',
      rating: parseNullableInt(json['rating']) ?? 0,
      status: json['status']?.toString() ?? 'Inactive',
      isNightShift: _parseBool(json['isNightShift']),
      salary: parseNullableInt(json['salary']),
      advance: parseNullableInt(json['advance']),
      pf: parseNullableInt(json['pf']),
      isBranchOpeningEmployee: _parseBool(json['isBranchOpeningEmployee']),
      branchOpeningTime: json['branchOpeningTime']?.toString() ?? '',
      branchOpeningReminderStartMinutes:
          parseNullableInt(json['branchOpeningReminderStartMinutes']) ?? 120,
      branchOpeningReminderIntervalMinutes:
          parseNullableInt(json['branchOpeningReminderIntervalMinutes']) ?? 15,
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
    String? location,
    String? designation,
    String? photo,
    String? photoUrl,
    int? rating,
    String? status,
    bool? isNightShift,
    int? salary,
    int? advance,
    int? pf,
    bool? isBranchOpeningEmployee,
    String? branchOpeningTime,
    int? branchOpeningReminderStartMinutes,
    int? branchOpeningReminderIntervalMinutes,
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
      location: location ?? this.location,
      designation: designation ?? this.designation,
      photo: photo ?? this.photo,
      photoUrl: photoUrl ?? this.photoUrl,
      rating: rating ?? this.rating,
      status: status ?? this.status,
      isNightShift: isNightShift ?? this.isNightShift,
      salary: salary ?? this.salary,
      advance: advance ?? this.advance,
      pf: pf ?? this.pf,
      isBranchOpeningEmployee:
          isBranchOpeningEmployee ?? this.isBranchOpeningEmployee,
      branchOpeningTime: branchOpeningTime ?? this.branchOpeningTime,
      branchOpeningReminderStartMinutes:
          branchOpeningReminderStartMinutes ??
          this.branchOpeningReminderStartMinutes,
      branchOpeningReminderIntervalMinutes:
          branchOpeningReminderIntervalMinutes ??
          this.branchOpeningReminderIntervalMinutes,
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
    required this.isNightShift,
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
  final bool isNightShift;

  bool get hasCheckedOut =>
      (checkOutDate ?? '').isNotEmpty && (checkOutTime ?? '').isNotEmpty;

  bool get hasPhoto => photoPath.isNotEmpty || photoUrl.isNotEmpty;

  bool get hasCheckOutPhoto =>
      checkOutPhotoPath.isNotEmpty || checkOutPhotoUrl.isNotEmpty;

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
      isNightShift: _parseBool(json['isNightShift']),
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
      title:
          resolvedTitle.isNotEmpty
              ? resolvedTitle
              : (fallbackTitle.isNotEmpty ? fallbackTitle : 'Attica Pagar'),
      body:
          resolvedBody.isNotEmpty
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
  });

  final int totalRecords;
  final int presentDays;
  final int completedRecords;
  final int activeRecords;

  factory AttendanceHistorySummary.fromJson(Map<String, dynamic> json) {
    int parseCount(String key) =>
        int.tryParse(json[key]?.toString() ?? '') ?? 0;

    return AttendanceHistorySummary(
      totalRecords: parseCount('totalRecords'),
      presentDays: parseCount('presentDays'),
      completedRecords: parseCount('completedRecords'),
      activeRecords: parseCount('activeRecords'),
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
      payableDays: parseDouble(json['payableDays']),
      grossPayableSalary: parseDouble(json['grossPayableSalary']),
      netPayableSalary: parseDouble(json['netPayableSalary']),
      daysElapsed: parseInt(json['daysElapsed']),
      daysInMonth: parseInt(json['daysInMonth']),
    );
  }
}

class ApiException implements Exception {
  ApiException(this.message);

  final String message;

  @override
  String toString() => message;
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
    if (!Platform.isAndroid) {
      return;
    }

    await _channel.invokeMethod<void>('openDeveloperSettings');
  }
}

class AdminNotificationBackgroundService {
  AdminNotificationBackgroundService._();

  static const Duration _periodicFrequency = Duration(minutes: 15);
  static const Duration _oneOffDelay = Duration(seconds: 20);
  static final Constraints _networkConstraints = Constraints(
    networkType: NetworkType.connected,
  );

  static Future<void> ensureScheduled() async {
    if (!Platform.isAndroid) {
      return;
    }

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
    if (!Platform.isAndroid) {
      return;
    }

    await Workmanager().registerOneOffTask(
      _adminNotificationBackgroundOneOffTaskUniqueName,
      _adminNotificationBackgroundTaskName,
      initialDelay: _oneOffDelay,
      constraints: _networkConstraints,
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }

  static Future<void> cancelAll() async {
    if (!Platform.isAndroid) {
      return;
    }

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
    }
  }
}

class EmployeeSessionStore {
  const EmployeeSessionStore();

  static const _tokenKey = 'employee_portal_token';
  static const _savedBranchIdKey = 'employee_portal_saved_branch_id';
  static const _savedEmpIdKey = 'employee_portal_saved_emp_id';
  static const _rememberCredentialsKey = 'employee_portal_remember_credentials';
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<String?> readToken() async {
    final secureToken = await _secureStorage.read(key: _tokenKey);
    if (secureToken != null && secureToken.trim().isNotEmpty) {
      return secureToken.trim();
    }

    final preferences = await SharedPreferences.getInstance();
    final legacyToken = preferences.getString(_tokenKey)?.trim() ?? '';

    if (legacyToken.isEmpty) {
      return null;
    }

    await _secureStorage.write(key: _tokenKey, value: legacyToken);
    await preferences.remove(_tokenKey);

    return legacyToken;
  }

  Future<void> writeToken(String token) async {
    await _secureStorage.write(key: _tokenKey, value: token.trim());
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_tokenKey);
  }

  Future<void> clearToken() async {
    await _secureStorage.delete(key: _tokenKey);
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_tokenKey);
  }

  Future<Map<String, String>> readSavedCredentials() async {
    final preferences = await SharedPreferences.getInstance();
    final rememberCredentials =
        preferences.getBool(_rememberCredentialsKey) ?? false;

    if (!rememberCredentials) {
      return const <String, String>{};
    }

    final secureBranchId = await _secureStorage.read(key: _savedBranchIdKey);
    final secureEmpId = await _secureStorage.read(key: _savedEmpIdKey);
    final branchId = (secureBranchId ?? '').trim();
    final empId = (secureEmpId ?? '').trim();

    if (branchId.isNotEmpty || empId.isNotEmpty) {
      return <String, String>{'branchId': branchId, 'empId': empId};
    }

    final legacyBranchId =
        preferences.getString(_savedBranchIdKey)?.trim() ?? '';
    final legacyEmpId = preferences.getString(_savedEmpIdKey)?.trim() ?? '';

    if (legacyBranchId.isNotEmpty || legacyEmpId.isNotEmpty) {
      await _secureStorage.write(key: _savedBranchIdKey, value: legacyBranchId);
      await _secureStorage.write(key: _savedEmpIdKey, value: legacyEmpId);
      await preferences.remove(_savedBranchIdKey);
      await preferences.remove(_savedEmpIdKey);

      return <String, String>{'branchId': legacyBranchId, 'empId': legacyEmpId};
    }

    return <String, String>{'branchId': '', 'empId': ''};
  }

  Future<bool> readRememberCredentials() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_rememberCredentialsKey) ?? false;
  }

  Future<void> writeSavedCredentials({
    required String branchId,
    required String empId,
    required bool rememberCredentials,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_rememberCredentialsKey, rememberCredentials);

    if (!rememberCredentials) {
      await _secureStorage.delete(key: _savedBranchIdKey);
      await _secureStorage.delete(key: _savedEmpIdKey);
      await preferences.remove(_savedBranchIdKey);
      await preferences.remove(_savedEmpIdKey);
      return;
    }

    await _secureStorage.write(key: _savedBranchIdKey, value: branchId.trim());
    await _secureStorage.write(key: _savedEmpIdKey, value: empId.trim());
    await preferences.remove(_savedBranchIdKey);
    await preferences.remove(_savedEmpIdKey);
  }
}

class EmployeeApiClient {
  const EmployeeApiClient();

  Future<AuthResponse> login({
    required String branchId,
    required String empId,
  }) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/employee/login'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'branchId': branchId, 'empId': empId}),
    );

    return _parseAuthResponse(response);
  }

  Future<void> logout(String token) async {
    await http.post(
      Uri.parse('${ApiConfig.baseUrl}/employee/logout'),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
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

  Future<AttendanceRecord?> latestAttendance(String token) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/attendance/latest'),
      headers: {'Accept': 'application/json', 'Authorization': 'Bearer $token'},
    );

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

  Future<SalarySummary> salarySummary({required String token}) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/salary/summary'),
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
    required File photo,
  }) async {
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
    request.files.add(await http.MultipartFile.fromPath('photo', photo.path));

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
    required double latitude,
    required double longitude,
    required File photo,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiConfig.baseUrl}/attendance/check-in'),
    );

    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    });
    request.fields['latitude'] = latitude.toString();
    request.fields['longitude'] = longitude.toString();
    request.files.add(await http.MultipartFile.fromPath('photo', photo.path));

    final response = await http.Response.fromStream(await request.send());

    return _parseAttendanceResponse(
      response,
      fallback: 'Unable to check in attendance right now.',
    );
  }

  Future<AttendanceRecord> checkOut({
    required String token,
    required double latitude,
    required double longitude,
    required File photo,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiConfig.baseUrl}/attendance/check-out'),
    );

    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    });
    request.fields['latitude'] = latitude.toString();
    request.fields['longitude'] = longitude.toString();
    request.files.add(await http.MultipartFile.fromPath('photo', photo.path));

    final response = await http.Response.fromStream(await request.send());

    return _parseAttendanceResponse(
      response,
      fallback: 'Unable to check out attendance right now.',
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

    throw _buildApiException(payload, fallback: fallback);
  }

  Map<String, dynamic> _decodePayload(http.Response response) {
    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }

    return <String, dynamic>{};
  }

  ApiException _buildApiException(
    Map<String, dynamic> payload, {
    required String fallback,
  }) {
    if (payload['message'] case final String message when message.isNotEmpty) {
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

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final EmployeeApiClient _apiClient = const EmployeeApiClient();
  final EmployeeSessionStore _sessionStore = const EmployeeSessionStore();

  String? _token;
  Employee? _employee;
  bool _isRestoringSession = true;
  StreamSubscription<RemoteMessage>? _pushMessageSubscription;
  StreamSubscription<RemoteMessage>? _pushMessageOpenedSubscription;
  StreamSubscription<String>? _pushTokenRefreshSubscription;
  List<EmployeePushNotification> _adminNotifications =
      const <EmployeePushNotification>[];

  int get _unreadAdminNotificationCount =>
      _adminNotifications.where((notification) => !notification.isRead).length;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializePushMessaging();
    _restoreSession();
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
  }

  Future<void> _restoreSession() async {
    final token = await _sessionStore.readToken();

    if (token == null || token.isEmpty) {
      await AdminNotificationBackgroundService.cancelAll();
      await AttendanceNotificationService.clearForLogout();
      if (!mounted) {
        return;
      }
      setState(() {
        _isRestoringSession = false;
      });
      return;
    }

    final hasInternet = await _hasInternetConnection();
    if (!hasInternet) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isRestoringSession = false;
      });
      return;
    }

    try {
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
      final stillHasInternet = await _hasInternetConnection().timeout(
        const Duration(seconds: 4),
        onTimeout: () => false,
      );
      if (stillHasInternet) {
        await _sessionStore.clearToken();
        await AdminNotificationBackgroundService.cancelAll();
        await AttendanceNotificationService.clearForLogout();
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
  }

  Future<void> _handleLogin(
    String branchId,
    String empId, {
    required bool rememberCredentials,
  }) async {
    final auth = await _apiClient.login(branchId: branchId, empId: empId);
    await _sessionStore.writeToken(auth.token);
    await _sessionStore.writeSavedCredentials(
      branchId: branchId,
      empId: empId,
      rememberCredentials: rememberCredentials,
    );
    try {
      await _syncAttendanceForNotifications(auth.token);
    } catch (_) {
      // Login should not fail if attendance sync is temporarily unavailable.
    }
    setState(() {
      _token = auth.token;
      _employee = auth.employee;
      _adminNotifications = const <EmployeePushNotification>[];
    });
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
      await AttendanceNotificationService.syncWithAttendance(attendance);
    } catch (_) {
      // Attendance notification sync must never block app navigation.
    }
  }

  Future<void> _handleLogout() async {
    final token = _token;
    try {
      if (token != null && token.isNotEmpty) {
        await _removeCurrentPushToken(token);
        await _apiClient.logout(token);
      }
    } catch (_) {
      // Clear the local session even if the backend is unreachable.
    } finally {
      await AdminNotificationBackgroundService.cancelAll();
      await _sessionStore.clearToken();
      await AttendanceNotificationService.clearForLogout();
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _token = null;
      _employee = null;
      _adminNotifications = const <EmployeePushNotification>[];
    });
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
    final notification =
        isAdminNotification
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
    if (!PushMessagingService.isAvailable) {
      return;
    }

    final deviceToken = await PushMessagingService.currentToken();
    if (deviceToken == null || deviceToken.isEmpty) {
      return;
    }

    try {
      await _apiClient.removeDeviceToken(token: token, deviceToken: deviceToken);
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
        unawaited(_syncCurrentPushToken(token));
        unawaited(_refreshAdminNotifications(token));
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _refreshAdminNotifications(String token) async {
    try {
      final notifications = await _apiClient
          .notifications(token: token)
          .timeout(const Duration(seconds: 8));
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
            onEmployeeUpdated: _handleEmployeeUpdated,
            onNotificationsViewed: _handleAdminNotificationsViewed,
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
  const _SessionBootstrapScreen();

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
                'Restoring session',
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Checking your employee access token.',
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

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLogin});

  final Future<void> Function(
    String branchId,
    String empId, {
    required bool rememberCredentials,
  })
  onLogin;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _noInternetMessage =
      'No internet connection. Check your mobile network or Wi-Fi and try again.';

  final _formKey = GlobalKey<FormState>();
  final _branchIdController = TextEditingController();
  final _empIdController = TextEditingController();
  final EmployeeSessionStore _sessionStore = const EmployeeSessionStore();

  final String _apiBaseUrl = ApiConfig.baseUrl;
  bool _isCheckingInternet = true;
  bool _hasInternet = true;
  bool _isLoading = false;
  bool _obscureText = true;
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
    super.dispose();
  }

  Future<void> _restoreSavedCredentials() async {
    final rememberCredentials = await _sessionStore.readRememberCredentials();
    final savedCredentials = await _sessionStore.readSavedCredentials();

    if (!mounted) {
      return;
    }

    _branchIdController.text = savedCredentials['branchId'] ?? '';
    _empIdController.text = savedCredentials['empId'] ?? '';
    setState(() {
      _rememberCredentials = rememberCredentials;
    });
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
        rememberCredentials: _rememberCredentials,
      );
    } on ApiException catch (error) {
      setState(() {
        _errorText = error.message;
      });
    } catch (_) {
      setState(() {
        _errorText =
            'Connection failed at $_apiBaseUrl. If you changed the endpoint, try resetting it to ${ApiConfig.resolvedDefaultBaseUrl}.';
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
                                  label: 'Password',
                                  child: TextFormField(
                                    controller: _empIdController,
                                    keyboardType: TextInputType.number,
                                    obscureText: _obscureText,
                                    onFieldSubmitted: (_) =>
                                        _isLoading ? null : _submit(),
                                    decoration: _inputDecoration(
                                      hintText: 'Enter Password',
                                      prefixIcon: Icons.lock_outline,
                                      compact: isCompact,
                                      suffixIcon: IconButton(
                                        onPressed: () {
                                          setState(() {
                                            _obscureText = !_obscureText;
                                          });
                                        },
                                        icon: Icon(
                                          _obscureText
                                              ? Icons.visibility_outlined
                                              : Icons.visibility_off_outlined,
                                        ),
                                      ),
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
  });

  final Employee employee;
  final String token;
  final EmployeeApiClient apiClient;

  @override
  State<MyAttendancePage> createState() => _MyAttendancePageState();
}

class _MyAttendancePageState extends State<MyAttendancePage> {
  static const double _allowedBranchRadiusMeters = 500;

  AttendanceRecord? _attendance;
  Position? _position;
  File? _facePhoto;
  File? _checkOutPhoto;
  bool _isLoading = true;
  bool _isCapturingFace = false;
  bool _isSubmitting = false;
  bool _isFetchingLocation = false;
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

    _fetchLocation(silent: true);
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
          (_isNightShiftAttendance && !(_attendance?.hasCheckedOut ?? true)));

  bool get _hasActiveAttendance =>
      _attendance != null &&
      (_attendance?.checkInDate == _todayDate || _isNightShiftAttendance) &&
      !(_attendance?.hasCheckedOut ?? false);

  bool get _isNightShiftAttendance =>
      _attendance != null &&
      (_attendance?.isNightShift == true || widget.employee.isNightShift);

  bool get _hasBranchCoordinates =>
      widget.employee.branchLatitude != null &&
      widget.employee.branchLongitude != null;

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

  String get _branchLabel {
    final branchName = widget.employee.branchName.trim();
    if (branchName.isNotEmpty) {
      return branchName;
    }

    final branchId = widget.employee.branchId.trim();
    return branchId.isEmpty ? 'assigned branch' : branchId;
  }

  bool get _isLocationAllowed {
    final distance = _distanceFromBranchMeters;
    return distance != null && distance <= _allowedBranchRadiusMeters;
  }

  String? get _locationValidationMessage {
    if (!_hasBranchCoordinates) {
      return 'Branch location is unavailable for $_branchLabel.';
    }

    final distance = _distanceFromBranchMeters;
    if (distance == null) {
      return 'Current location is required for attendance.';
    }

    if (distance <= _allowedBranchRadiusMeters) {
      return null;
    }

    return 'You are ${_formatDistanceMeters(distance)} away from $_branchLabel. Allowed radius is ${_formatDistanceMeters(_allowedBranchRadiusMeters)}.';
  }

  bool get _isCheckInReady =>
      _position != null &&
      _facePhoto != null &&
      _hasBranchCoordinates &&
      _isLocationAllowed &&
      !_isFetchingLocation &&
      !_isCapturingFace;

  bool get _isCheckOutReady =>
      _position != null &&
      _checkOutPhoto != null &&
      _hasBranchCoordinates &&
      _isLocationAllowed &&
      !_isFetchingLocation &&
      !_isCapturingFace;

  bool get _isCapturingForCheckOut => _hasActiveAttendance;

  File? get _currentAttendancePhoto =>
      _isCapturingForCheckOut ? _checkOutPhoto : _facePhoto;

  String get _captureTitle =>
      _isCapturingForCheckOut ? 'Check-Out Capture' : 'Face Capture';

  String get _captureSubtitle {
    if (_isCapturingForCheckOut) {
      return _checkOutPhoto != null
          ? 'Check-out photo ready for attendance check-out.'
          : 'Capture a fresh face photo before check-out.';
    }

    return _facePhoto != null
        ? 'Face photo ready for attendance check-in.'
        : 'Capture a fresh face photo before check-in.';
  }

  String get _captureButtonText {
    final currentPhoto = _currentAttendancePhoto;

    if (_isCapturingFace) {
      return 'Opening...';
    }

    if (_isCapturingForCheckOut) {
      return currentPhoto != null
          ? 'Retake Check-Out Capture'
          : 'Capture Check-Out Photo';
    }

    return currentPhoto != null ? 'Retake Capture' : 'Capture';
  }

  String get _checkInButtonText {
    if (_hasTodayAttendance) {
      return 'Checked in at ${_formatCompactTime(_attendance?.checkInTime)}';
    }
    return 'Check In';
  }

  String get _statusText {
    if (_hasActiveAttendance) {
      return _isNightShiftAttendance && _attendance!.checkInDate != _todayDate
          ? 'Night shift check-in active from ${_attendance!.checkInDate} at ${_attendance!.checkInTime}.'
          : 'Checked in today at ${_attendance!.checkInTime}.';
    }
    if (_hasTodayAttendance) {
      return 'Today attendance completed at ${_attendance!.checkOutTime ?? '-'}';
    }
    return 'Ready for today. Face capture and auto-location are required.';
  }

  String get _locationStatusText {
    if (_isFetchingLocation) {
      return 'Detecting your current location automatically.';
    }

    if (!_hasBranchCoordinates) {
      return 'Branch coordinates are unavailable for $_branchLabel.';
    }

    final distance = _distanceFromBranchMeters;
    if (distance != null) {
      if (_isLocationAllowed) {
        return 'Within branch radius. ${_formatDistanceMeters(distance)} from $_branchLabel.';
      }

      return 'Outside branch radius. ${_formatDistanceMeters(distance)} from $_branchLabel. Allowed: ${_formatDistanceMeters(_allowedBranchRadiusMeters)}.';
    }

    return 'Location will be captured automatically and matched with $_branchLabel within ${_formatDistanceMeters(_allowedBranchRadiusMeters)}.';
  }

  Color get _locationStatusColor {
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

    return _isLocationAllowed ? AppColors.success : const Color(0xFF9A1B1B);
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

  Future<void> _fetchLocation({bool silent = false}) async {
    if (mounted) {
      setState(() {
        _isFetchingLocation = true;
        _position = null;
        _fakeLocationIssue = null;
        if (!silent) {
          _errorText = null;
        }
      });
    }

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
        throw ApiException('Location permission is required for attendance.');
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
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

  Future<void> _captureFace({required bool forCheckOut}) async {
    if (_isCapturingFace) {
      return;
    }

    setState(() {
      _isCapturingFace = true;
      _errorText = null;
    });

    try {
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

      if (capturedFile == null || !mounted) {
        return;
      }

      _setAttendancePhoto(capturedFile.path, forCheckOut: forCheckOut);
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = _frontCameraErrorMessage(error);
      });
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = _frontCameraPlatformErrorMessage(error);
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

  void _setAttendancePhoto(String path, {required bool forCheckOut}) {
    if (!mounted) {
      return;
    }

    setState(() {
      if (forCheckOut) {
        _checkOutPhoto = File(path);
      } else {
        _facePhoto = File(path);
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

  Future<void> _checkIn() async {
    if (_hasTodayAttendance) {
      setState(() {
        _errorText = 'Attendance already captured for today.';
      });
      return;
    }

    await _fetchLocation(silent: true);
    if (_position == null) {
      setState(() {
        _errorText = 'Current location is required for attendance.';
      });
      return;
    }

    final locationValidationMessage = _locationValidationMessage;
    if (locationValidationMessage != null) {
      setState(() {
        _errorText = locationValidationMessage;
      });
      return;
    }

    if (_facePhoto == null) {
      setState(() {
        _errorText = 'Capture face photo before check-in.';
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
      _fakeLocationIssue = null;
    });

    try {
      final attendance = await widget.apiClient.checkIn(
        token: widget.token,
        latitude: _position!.latitude,
        longitude: _position!.longitude,
        photo: _facePhoto!,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _attendance = attendance;
        _facePhoto = null;
        _checkOutPhoto = null;
        _fakeLocationIssue = null;
      });
      await AttendanceNotificationService.markCheckInCompleted();
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Attendance checked in successfully.')),
      );
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
        _errorText = 'Unable to check in attendance.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _checkOut() async {
    if (_checkOutPhoto == null) {
      setState(() {
        _errorText = 'Capture face photo before check-out.';
      });
      return;
    }

    await _fetchLocation(silent: true);
    if (_position == null) {
      setState(() {
        _errorText = 'Current location is required for attendance.';
      });
      return;
    }

    final locationValidationMessage = _locationValidationMessage;
    if (locationValidationMessage != null) {
      setState(() {
        _errorText = locationValidationMessage;
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
      _fakeLocationIssue = null;
    });

    try {
      final attendance = await widget.apiClient.checkOut(
        token: widget.token,
        latitude: _position!.latitude,
        longitude: _position!.longitude,
        photo: _checkOutPhoto!,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _attendance = attendance;
        _checkOutPhoto = null;
        _fakeLocationIssue = null;
      });
      await AttendanceNotificationService.markCheckOutCompleted();
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Attendance checked out successfully.')),
      );
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
        _errorText = 'Unable to check out attendance.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _confirmCheckOut() async {
    final shouldCheckOut = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Check Out'),
          content: const Text('Are you sure you want to check out for today?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Confirm'),
            ),
          ],
        );
      },
    );

    if (shouldCheckOut == true) {
      await _checkOut();
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
              _fetchLocation(silent: true);
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
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
                                style: theme.textTheme.headlineMedium?.copyWith(
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
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _AttendancePanel(
                    title: 'Auto Location',
                    subtitle: _locationStatusText,
                    subtitleColor: _locationStatusColor,
                    leading: Icons.location_on_outlined,
                    trailing: _isFetchingLocation
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
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
                                      ? AppColors.success
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
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _captureTitle,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  Text(
                                    _captureSubtitle,
                                    style: theme.textTheme.bodySmall?.copyWith(
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
                              ? Image.file(
                                  _currentAttendancePhoto!,
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
                                    mainAxisAlignment: MainAxisAlignment.center,
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
                            onPressed: _isCapturingFace
                                ? null
                                : () => _captureFace(
                                    forCheckOut: _isCapturingForCheckOut,
                                  ),
                            child: Text(_captureButtonText),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed:
                          (_isSubmitting ||
                              _hasTodayAttendance ||
                              !_isCheckInReady)
                          ? null
                          : _checkIn,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        disabledBackgroundColor: AppColors.secondary.withValues(
                          alpha: 0.24,
                        ),
                        disabledForegroundColor: AppColors.secondary,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: _isSubmitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            )
                          : Text(_checkInButtonText),
                    ),
                  ),
                  if (_hasActiveAttendance) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: (_isSubmitting || !_isCheckOutReady)
                            ? null
                            : _confirmCheckOut,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: const Text('Check Out'),
                      ),
                    ),
                  ],
                ],
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

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.employee,
    required this.token,
    required this.notifications,
    required this.unreadNotificationCount,
    required this.onLogout,
    required this.onEmployeeUpdated,
    required this.onNotificationsViewed,
  });

  final Employee employee;
  final String token;
  final List<EmployeePushNotification> notifications;
  final int unreadNotificationCount;
  final Future<void> Function() onLogout;
  final ValueChanged<Employee> onEmployeeUpdated;
  final Future<void> Function() onNotificationsViewed;

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
              ),
            ),
          );
        },
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
                child: CustomScrollView(
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                                      .withValues(alpha: 0.88),
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
                        delegate: SliverChildBuilderDelegate((context, index) {
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
          if (isBirthdayToday)
            const Positioned.fill(
              child: IgnorePointer(child: _BirthdayBurstOverlay()),
            ),
        ],
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
  SalarySummary? _summary;
  bool _isLoading = true;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  Future<void> _loadSummary() async {
    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final summary = await widget.apiClient.salarySummary(token: widget.token);
      if (!mounted) {
        return;
      }
      setState(() {
        _summary = summary;
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
            onPressed: _loadSummary,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _isLoading && summary == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                              _formatMonthLabel(DateTime.now()),
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
                          'Current payable estimate for ${widget.employee.empId}',
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
                          summary?.salary ?? widget.employee.salary?.toDouble(),
                        ),
                      ),
                      _ProfileEntry(
                        label: 'Salary / Day',
                        value: _formatCurrencyValue(summary?.salaryPerDay),
                      ),
                      _ProfileEntry(
                        label: 'Advance This Month',
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
                        value: _formatCurrencyValue(summary?.netPayableSalary),
                      ),
                    ],
                  ),
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
                            '${summary?.daysElapsed ?? DateTime.now().day}/${summary?.daysInMonth ?? DateTime.now().day}',
                      ),
                    ],
                  ),
                ],
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

  Future<void> _submit() async {
    if (_formKey.currentState?.validate() != true) {
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
      body: SingleChildScrollView(
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

    if (_photo == null) {
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
        photo: _photo!,
      );
      if (!mounted) {
        return;
      }

      _siteLocationController.clear();
      _reasonController.clear();
      _approvedByController.clear();
      setState(() {
        _photo = null;
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _InsightBanner(
                title: 'Request remote work visit',
                subtitle:
                    'Submit your off-site visit with GPS, photo, and approver details for HR review.',
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
                label: 'Approved By',
                child: TextFormField(
                  controller: _approvedByController,
                  decoration: _fieldDecoration(
                    hintText: 'Manager or approver name',
                    prefixIcon: Icons.person_outline_rounded,
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Approved by is required.';
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
                title: _photo == null
                    ? 'Site photo not captured yet'
                    : 'Photo ready to upload',
                subtitle: _photo == null
                    ? 'Capture an on-site photo before submitting.'
                    : _photo!.path.split(Platform.pathSeparator).last,
                action: TextButton(
                  onPressed: _isPickingPhoto ? null : _capturePhoto,
                  child: Text(_isPickingPhoto ? 'Opening...' : 'Capture Photo'),
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
                          child: _SiteVisitRequestHistoryCard(request: request),
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
          : SingleChildScrollView(
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
                    child: DropdownButtonFormField<String>(
                      initialValue: selectedBranch?.branchId,
                      decoration: _fieldDecoration(
                        hintText: 'Select the branch you reached',
                        prefixIcon: Icons.apartment_rounded,
                      ),
                      items: _branches
                          .map(
                            (branch) => DropdownMenuItem<String>(
                              value: branch.branchId,
                              child: Text(
                                branch.label,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _isSubmitting
                          ? null
                          : (value) {
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
                        _isFetchingLocation ? 'Fetching...' : 'Use Current GPS',
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
                              child: CircularProgressIndicator(strokeWidth: 2),
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
          _RequestHistoryLine(label: 'Approver', value: request.approvedBy),
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

class _ProfilePageState extends State<ProfilePage> {
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
  bool _isUploadingPhoto = false;
  bool _isSavingProfile = false;
  String? _selectedGender;
  String? _selectedMaritalStatus;
  DateTime? _selectedDateOfBirth;

  @override
  void initState() {
    super.initState();
    _employee = widget.employee;
    _nameController = TextEditingController();
    _phoneController = TextEditingController();
    _emailController = TextEditingController();
    _addressController = TextEditingController();
    _dateOfBirthController = TextEditingController();
    _syncFormWithEmployee(_employee);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _addressController.dispose();
    _dateOfBirthController.dispose();
    super.dispose();
  }

  void _syncFormWithEmployee(Employee employee) {
    _nameController.text = employee.name;
    _phoneController.text = employee.contact;
    _emailController.text = employee.mailId;
    _addressController.text = employee.address;
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
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
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
                      onPressed: _isUploadingPhoto ? null : _pickAndUploadPhoto,
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
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final useVerticalLayout = constraints.maxWidth < 420;

                        final genderField = _LabeledField(
                          label: 'Gender',
                          child: DropdownButtonFormField<String>(
                            initialValue: _selectedGender,
                            isExpanded: true,
                            items: genderOptions
                                .map(
                                  (option) => DropdownMenuItem<String>(
                                    value: option,
                                    child: Text(
                                      option,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              setState(() {
                                _selectedGender = value;
                              });
                            },
                            decoration: _fieldDecoration(
                              hintText: 'Select Gender',
                              prefixIcon: Icons.wc_rounded,
                            ),
                          ),
                        );

                        final maritalStatusField = _LabeledField(
                          label: 'Marital Status',
                          child: DropdownButtonFormField<String>(
                            initialValue: _selectedMaritalStatus,
                            isExpanded: true,
                            items: maritalStatusOptions
                                .map(
                                  (option) => DropdownMenuItem<String>(
                                    value: option,
                                    child: Text(
                                      option,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              setState(() {
                                _selectedMaritalStatus = value;
                              });
                            },
                            decoration: _fieldDecoration(
                              hintText: 'Select Marital Status',
                              prefixIcon: Icons.favorite_border_rounded,
                            ),
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
            const _SectionTitle(title: 'Compensation'),
            const SizedBox(height: 10),
            _ProfileDetailsCard(
              entries: [
                _ProfileEntry(
                  label: 'Salary',
                  value: _formatCurrency(employee.salary),
                ),
                _ProfileEntry(
                  label: 'Advance',
                  value: _formatCurrency(employee.advance),
                ),
                _ProfileEntry(label: 'PF', value: _formatCurrency(employee.pf)),
              ],
            ),
          ],
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
    });
    await _loadHistory();
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
        );
    final records = _history?.records ?? const <AttendanceRecord>[];

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
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
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
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: AppColors.text,
                                fontWeight: FontWeight.w800,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.employee.name,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppColors.subtleText,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: _canMoveForward ? () => _moveMonth(1) : null,
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
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SummaryCard(
                    label: 'Completed',
                    value: summary.completedRecords.toString(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _SummaryCard(
                    label: 'Active',
                    value: summary.activeRecords.toString(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SummaryCard(
                    label: 'Total Records',
                    value: summary.totalRecords.toString(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Attendance Report',
              style: theme.textTheme.titleLarge?.copyWith(
                color: AppColors.text,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: records.isEmpty
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
                            'No attendance records for ${_formatMonthLabel(_selectedMonth)}.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: AppColors.secondary,
                              fontWeight: FontWeight.w600,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : _AttendanceHistoryTable(
                      records: records,
                      onViewDetails: _showRecordDetails,
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
        ResolutionPreset.medium,
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
      final normalizedFile = await _normalizeCapturedImage(File(image.path));
      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(normalizedFile);
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

  Future<File> _normalizeCapturedImage(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final decodedImage = img.decodeImage(bytes);
      if (decodedImage == null) {
        return imageFile;
      }

      final bakedImage = img.bakeOrientation(decodedImage);
      final encodedBytes = img.encodeJpg(bakedImage, quality: 92);
      await imageFile.writeAsBytes(encodedBytes, flush: true);
      return imageFile;
    } catch (_) {
      return imageFile;
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
  const _FrontCameraErrorState({required this.message});

  final String message;

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
          ],
        ),
      ),
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
  const _SummaryCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
          Text(
            value,
            style: theme.textTheme.headlineMedium?.copyWith(
              color: AppColors.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.subtleText,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
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
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          _AttendanceReportValueCell(value: serialNumber.toString(), flex: 1),
          _AttendanceReportValueCell(
            value: _formatTableDate(record.checkInDate),
            flex: 2,
          ),
          _AttendanceReportValueCell(
            value: _formatTime(record.checkInTime),
            flex: 2,
          ),
          _AttendanceReportValueCell(
            value: _formatTime(record.checkOutTime),
            flex: 2,
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
  const _AttendanceReportValueCell({required this.value, required this.flex});

  final String value;
  final int flex;

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
            color: AppColors.text,
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
    final statusColor = record.hasCheckedOut
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
                  record.hasCheckedOut ? 'Completed' : 'Active',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
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
                : const _AttendanceImagePlaceholder(
                    message: 'Attendance image not available.',
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

  return 'Rs ${amount.toStringAsFixed(2)}';
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

String _formatIsoDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    return value;
  }

  return '${parsed.day.toString().padLeft(2, '0')} ${_monthNames[parsed.month - 1].substring(0, 3)} ${parsed.year}';
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

    if (segments.first == 'storage') {
      return parsed.replace(pathSegments: ['public', ...segments]).toString();
    }

    return trimmed;
  }

  if (trimmed.startsWith('public/')) {
    return trimmed;
  }

  return trimmed.startsWith('storage/') ? 'public/$trimmed' : trimmed;
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
