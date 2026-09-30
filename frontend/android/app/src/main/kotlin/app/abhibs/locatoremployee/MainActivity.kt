package app.abhibs.locatoremployee

import android.content.Intent
import android.provider.Settings
import android.content.ActivityNotFoundException
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val LOCATION_INTEGRITY_CHANNEL = "app.abhibs.locatoremployee/location_integrity"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LOCATION_INTEGRITY_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openDeveloperSettings" -> {
                    openDeveloperSettings()
                    result.success(null)
                }
                "openLocationSettings" -> {
                    openLocationSettings()
                    result.success(null)
                }
                "openWirelessSettings" -> {
                    openWirelessSettings()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun openDeveloperSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun openLocationSettings() {
        val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            openGeneralSettings()
        }
    }

    private fun openWirelessSettings() {
        val intent = Intent(Settings.ACTION_WIRELESS_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            openGeneralSettings()
        }
    }

    private fun openGeneralSettings() {
        val intent = Intent(Settings.ACTION_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }
}
