package com.asad.vpn

import android.app.Application
import go.Seq
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import java.io.File
import java.util.Locale

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Seq.setContext(this)
        Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))

        val baseDir = filesDir.also { it.mkdirs() }
        val workingDir = getExternalFilesDir(null)?.also { it.mkdirs() } ?: filesDir
        val tempDir = cacheDir.also { it.mkdirs() }

        Libbox.setup(
            SetupOptions().also {
                it.basePath = baseDir.path
                it.workingPath = workingDir.path
                it.tempPath = tempDir.path
                it.fixAndroidStack = false
            }
        )
        Libbox.redirectStderr(File(workingDir, "stderr.log").path)
    }
}