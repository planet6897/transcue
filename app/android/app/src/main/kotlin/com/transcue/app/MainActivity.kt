package com.transcue.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File

/// 동영상 읽기 권한 요청 (기기의 동영상을 실제 경로로 열기 위해).
/// 외부 플러그인(permission_handler)은 빌드 도구 버전과 충돌해서 직접 구현.
class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null

    private val videoPermission: String
        get() = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_VIDEO
        else Manifest.permission.READ_EXTERNAL_STORAGE

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        WhisperBridge(flutterEngine.dartExecutor.binaryMessenger)
        // TV(리모컨으로만 조작)인지: 앱이 메뉴에 포커스를 주고 방향키로 움직이게 한다
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "transcue/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTv" -> result.success(
                        packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK),
                    )
                    "textInput" -> showTextInput(
                        call.argument<String>("text") ?: "",
                        call.argument<String>("hint") ?: "",
                        call.argument<Boolean>("english") ?: false,
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
        // 자동 업데이트: 받은 APK의 설치 화면, 배포 페이지 열기
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "transcue/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "install" -> result.success(installApk(File(call.argument<String>("path")!!)))
                    "openUrl" -> {
                        startActivity(
                            Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url")))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // 화면 위/아래로 밀어 소리 조절: 기기 미디어 음량 (볼륨 버튼과 같은 값, 0~1)
        val audio = getSystemService(AUDIO_SERVICE) as AudioManager
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "transcue/volume")
            .setMethodCallHandler { call, result ->
                val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                when (call.method) {
                    "get" -> result.success(
                        audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max,
                    )
                    "set" -> {
                        val v = (call.arguments as Number).toDouble().coerceIn(0.0, 1.0)
                        audio.setStreamVolume(
                            AudioManager.STREAM_MUSIC, Math.round(v * max).toInt(), 0,
                        )
                        result.success(
                            audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max,
                        )
                    }
                    else -> result.notImplemented()
                }
            }
        // 화면 왼쪽을 위/아래로 밀어 밝기 조절: 이 앱 창의 밝기만 바꾼다 (0~1, 권한 불필요).
        // reset 하면 기기 설정 밝기로 돌아간다
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "transcue/brightness")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "get" -> {
                        val own = window.attributes.screenBrightness
                        result.success(
                            if (own >= 0f) own.toDouble()
                            else Settings.System.getInt(
                                contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128,
                            ).coerceIn(0, 255) / 255.0,
                        )
                    }
                    "set" -> {
                        val v = (call.arguments as Number).toFloat().coerceIn(0.01f, 1f)
                        window.attributes = window.attributes.apply { screenBrightness = v }
                        result.success(v.toDouble())
                    }
                    "reset" -> {
                        window.attributes = window.attributes.apply {
                            screenBrightness =
                                android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "transcue/permission")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestVideo" -> {
                        if (checkSelfPermission(videoPermission) == PackageManager.PERMISSION_GRANTED) {
                            result.success(true)
                        } else {
                            pending?.success(false)
                            pending = result
                            requestPermissions(arrayOf(videoPermission), REQUEST)
                        }
                    }
                    "openSettings" -> {
                        startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.fromParts("package", packageName, null)),
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// TV: 기본(Android) 입력창. Flutter 입력란에서는 리모컨 방향키가 앱으로 가서 화면 키보드
    /// (Gboard)를 조작할 수 없다(실측). 기본 입력란에서는 키보드가 방향키를 받는다.
    /// 입력한 글(검색 키·확인) 또는 취소하면 null.
    private fun showTextInput(
        text: String,
        hint: String,
        english: Boolean,
        result: MethodChannel.Result,
    ) {
        var done = false
        fun finish(value: String?) {
            if (done) return
            done = true
            result.success(value)
        }
        val field = android.widget.EditText(this).apply {
            setText(text)
            setSelection(text.length)
            this.hint = hint
            isSingleLine = true
            imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH
            // 영어 검색: 키보드를 영어 배열로 (한글 배열이면 자모가 들어간다)
            if (english && Build.VERSION.SDK_INT >= 24) {
                imeHintLocales = android.os.LocaleList(java.util.Locale.ENGLISH)
            }
        }
        val dialog = android.app.AlertDialog.Builder(this)
            .setView(
                android.widget.FrameLayout(this).apply {
                    val pad = (24 * resources.displayMetrics.density).toInt()
                    setPadding(pad, pad, pad, 0)
                    addView(field)
                },
            )
            .setPositiveButton(android.R.string.ok) { _, _ -> finish(field.text.toString()) }
            .setNegativeButton(android.R.string.cancel) { _, _ -> finish(null) }
            .setOnDismissListener { finish(null) }
            .create()
        field.setOnEditorActionListener { _, _, _ ->
            finish(field.text.toString())
            dialog.dismiss()
            true
        }
        dialog.window?.setSoftInputMode(
            android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE,
        )
        dialog.show()
        field.requestFocus()
    }

    override fun onRequestPermissionsResult(code: Int, perms: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(code, perms, grants)
        if (code != REQUEST) return
        pending?.success(grants.isNotEmpty() && grants[0] == PackageManager.PERMISSION_GRANTED)
        pending = null
    }

    companion object {
        private const val REQUEST = 7001
    }

    /// 설치 화면을 열면 "started". 처음이라 '이 앱의 설치 허용'이 꺼져 있으면 그 설정 화면을 열고
    /// "needPermission" (허용한 뒤 다시 누르게 한다).
    private fun installApk(apk: File): String {
        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            return "needPermission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
        startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return "started"
    }
}
