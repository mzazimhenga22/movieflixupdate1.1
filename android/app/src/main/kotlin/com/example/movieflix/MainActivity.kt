package com.example.movieflix

import android.graphics.Rect
import android.os.Bundle
import android.view.ViewTreeObserver
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.movieflix/keyboard"
    private lateinit var methodChannel: MethodChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize MethodChannel with non-null binaryMessenger
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        // Set up keyboard height listener
        window.decorView.rootView.viewTreeObserver
            .addOnGlobalLayoutListener(object : ViewTreeObserver.OnGlobalLayoutListener {
                private var previousKeyboardHeight = 0

                override fun onGlobalLayout() {
                    val rect = Rect()
                    window.decorView.rootView.getWindowVisibleDisplayFrame(rect)
                    val screenHeight = window.decorView.rootView.height
                    val keyboardHeight = screenHeight - rect.bottom

                    if (keyboardHeight != previousKeyboardHeight) {
                        methodChannel.invokeMethod("keyboardHeight", keyboardHeight)
                        previousKeyboardHeight = keyboardHeight
                    }
                }
            })
    }
}
