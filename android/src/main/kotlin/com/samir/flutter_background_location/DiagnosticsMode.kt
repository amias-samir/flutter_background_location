package com.samir.flutter_background_location

import android.content.Context

/**
 * The route detail the host app records (`recordingDetail`, capability
 * `recording_detail_mode`): `full` keeps native diagnostics, `clean` keeps
 * none. Capture is the same in both.
 *
 * Dart sends the detail with `initialize`. It is kept in preferences, so a
 * service restart or boot restore that runs before Dart uses it too. Until
 * Dart has sent one, the detail is clean.
 *
 * In clean detail the step counter keeps no diagnostics ring, and platform
 * error text is left out of status and failure messages: only the package's
 * fixed sentence remains.
 */
internal object DiagnosticsMode {
    const val FULL = "full"
    const val CLEAN = "clean"

    @Volatile
    var full: Boolean = false
        private set

    @Volatile
    private var loaded = false

    /** Loads the kept detail once per process. */
    fun load(context: Context) {
        if (loaded) return
        synchronized(this) {
            if (loaded) return
            full = preferences(context).getString(KEY_RECORDING_DETAIL, CLEAN) == FULL
            loaded = true
        }
    }

    /**
     * Applies and keeps [detail] when it is `full` or `clean`; any other
     * value, or none, keeps the current detail. Switching to clean clears
     * the step counter's diagnostics.
     */
    fun apply(context: Context, detail: Any?) {
        val value = parse(detail) ?: return
        synchronized(this) {
            full = value == FULL
            loaded = true
        }
        preferences(context).edit().putString(KEY_RECORDING_DETAIL, value).apply()
        if (value == CLEAN) StepCounter.clearDiagnostics()
    }

    /** [message] with [error]'s platform text appended in full detail only. */
    fun detail(message: String, error: Throwable?): String = detail(message, error, full)

    /** `full` or `clean`, or null for anything else. */
    fun parse(detail: Any?): String? = (detail as? String)?.takeIf { it == FULL || it == CLEAN }

    /**
     * [message]; when [full] and [error] has text, the message without its
     * final full stop, `: ` and that text.
     */
    fun detail(message: String, error: Throwable?, full: Boolean): String {
        val text = error?.message?.takeIf { it.isNotBlank() }
        return if (full && text != null) "${message.removeSuffix(".")}: $text" else message
    }

    private fun preferences(context: Context) =
        context.applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    private const val PREFERENCES_NAME = "flutter_background_location_diagnostics"
    private const val KEY_RECORDING_DETAIL = "recording_detail"
}
