package com.aash591.drive_authorization

import android.accounts.Account
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.util.AtomicFile
import android.util.Log
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.util.UUID

/** Uses application Context in workers; consent UI is never launched in background. */
class DriveAuthorizationPlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var binding: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "simple_money/drive_authorization")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "installationId") {
            // Android device transfer can copy the ledger. This ID is deliberately
            // excluded from OS backups, so the copy gets an independent mirror.
            try {
                val id = synchronized(DriveAuthorizationPlugin::class.java) {
                    val file = AtomicFile(File(context.noBackupFilesDir, "drive-mirror-installation"))
                    val existing = try { String(file.readFully(), Charsets.UTF_8).trim() }
                        catch (_: java.io.FileNotFoundException) { "" }
                    if (existing.isNotEmpty()) existing else {
                        val id = UUID.randomUUID().toString()
                        val output = file.startWrite()
                        try {
                            output.write(id.toByteArray(Charsets.UTF_8))
                            file.finishWrite(output)
                        } catch (error: Exception) {
                            file.failWrite(output)
                            throw error
                        }
                        id
                    }
                }
                result.success(id)
            } catch (_: Exception) {
                result.error("installation_unavailable", "Could not identify this device for sync.", null)
            }
            return
        }
        if (call.method != "authorize") { result.notImplemented(); return }
        if (pending != null) { result.error("busy", "Authorization is already open.", null); return }
        val interactive = call.argument<Boolean>("interactive") == true
        val email = call.argument<String>("email")
        if (!interactive && email == null) {
            result.error("authorization_required", "Connect a Google account.", null); return
        }
        pending = result
        val request = AuthorizationRequest.builder().setRequestedScopes(listOf(
            Scope("https://www.googleapis.com/auth/drive.appdata"),
            Scope("https://www.googleapis.com/auth/userinfo.email"),
            Scope("https://www.googleapis.com/auth/userinfo.profile"),
            Scope("openid")
        ))
        if (email != null) request.setAccount(Account(email, "com.google"))
        Identity.getAuthorizationClient(context).authorize(request.build())
            .addOnSuccessListener { authorization ->
                if (!authorization.hasResolution()) finish(authorization)
                else {
                    val activity = binding?.activity
                    if (!interactive || activity == null) {
                        fail("authorization_required", "Reconnect your Google account to resume sync.")
                    } else {
                        try {
                            activity.startIntentSenderForResult(
                                authorization.pendingIntent!!.intentSender, REQUEST_CODE,
                                null, 0, 0, 0
                            )
                        } catch (_: Exception) {
                            fail("authorization_failed", "Could not open Google authorization.")
                        }
                    }
                }
            }
            .addOnFailureListener { error ->
                failAuthorization(error)
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        // Error results can contain Google's status even when Android reports
        // RESULT_CANCELED. Parse them before deciding the user dismissed the UI.
        if (data == null && resultCode == Activity.RESULT_CANCELED) {
            fail("canceled", "Connection canceled.")
        } else try {
            finish(Identity.getAuthorizationClient(context).getAuthorizationResultFromIntent(data))
        } catch (error: Exception) {
            failAuthorization(error)
        }
        return true
    }

    private fun finish(result: AuthorizationResult) {
        val token = result.accessToken
        if (token.isNullOrEmpty()) fail("authorization_required", "Google Drive access is required.")
        else { pending?.success(token); pending = null }
    }
    private fun failAuthorization(error: Exception) {
        val status = (error as? ApiException)?.statusCode
        if (status == CommonStatusCodes.CANCELED) {
            fail("canceled", "Connection canceled.")
            return
        }
        // Log only the status, never account data, intents or access tokens.
        Log.w("DriveAuthorization", "Google authorization failed (status=$status)")
        val message = when (status) {
            CommonStatusCodes.DEVELOPER_ERROR ->
                "Google sign-in is not configured for this app build. Check its Android OAuth package name and signing certificate."
            CommonStatusCodes.NETWORK_ERROR ->
                "Google sign-in could not connect. Check your internet connection and try again."
            else -> "Google sign-in could not be completed. Please try again."
        }
        fail("authorization_failed", if (status == null) message else "$message (Google error $status)")
    }
    private fun fail(code: String, message: String) {
        pending?.error(code, message, null); pending = null
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding; binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivityForConfigChanges() {
        binding?.removeActivityResultListener(this); binding = null
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        fail("canceled", "Connection canceled.")
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        fail("canceled", "Connection canceled.")
    }
    companion object { private const val REQUEST_CODE = 5931 }
}
