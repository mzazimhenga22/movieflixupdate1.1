package com.example.movieflix

import android.graphics.Rect
import android.os.Bundle
import android.view.ViewTreeObserver
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.movieflix/keyboard"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Listen for layout changes to detect keyboard visibility and height
        window.decorView.rootView.viewTreeObserver
            .addOnGlobalLayoutListener(object : ViewTreeObserver.OnGlobalLayoutListener {
                private var previousKeyboardHeight = 0

                override fun onGlobalLayout() {
                    val rect = Rect()
                    window.decorView.rootView.getWindowVisibleDisplayFrame(rect)
                    val screenHeight = window.decorView.rootView.height
                    val keyboardHeight = screenHeight - rect.bottom

                    // Notify Dart only if height changed
                    if (keyboardHeight != previousKeyboardHeight) {
                        MethodChannel(
                            flutterEngine?.dartExecutor?.binaryMessenger,
                            CHANNEL
                        ).invokeMethod("keyboardHeight", keyboardHeight)
                        previousKeyboardHeight = keyboardHeight
                    }
                }
            })
    }
}
