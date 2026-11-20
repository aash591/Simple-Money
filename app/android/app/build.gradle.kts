import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The upload key used to sign Play Store release builds. Signing material is
// kept with the repository's other gitignored secrets, never in app/android.
val signingSecretsDirectory = rootProject.projectDir.resolve("../../secrets/android").canonicalFile
val keystorePropertiesFile = signingSecretsDirectory.resolve("key.properties")
val keystoreProperties = Properties()
val hasKeystoreProperties = keystorePropertiesFile.exists()
if (hasKeystoreProperties) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

// Flutter hands --dart-define(-from-file) values to Gradle base64-encoded, so
// secrets/.env reaches the manifest as well as the Dart code.
val dartDefines: Map<String, String> = (project.findProperty("dart-defines") as String?)
    ?.split(",")
    ?.mapNotNull {
        val pair = String(Base64.getDecoder().decode(it)).split("=", limit = 2)
        if (pair.size == 2) pair[0] to pair[1] else null
    }
    ?.toMap()
    .orEmpty()
val improvementToken = dartDefines["TELEGRAM_BOT_TOKEN"].orEmpty()
val improvementChat = dartDefines["TELEGRAM_CHAT_ID"].orEmpty().ifEmpty { "-1004422446586" }
require(improvementToken.isEmpty() || improvementToken.matches(Regex("[0-9]+:[A-Za-z0-9_-]+")))
require(improvementChat.matches(Regex("-?[0-9]+")))
val admobAppId = dartDefines["ADMOB_APP_ID"].orEmpty()
    .ifEmpty { "ca-app-pub-3940256099942544~3347511713" }

android {
    buildFeatures { buildConfig = true }
    namespace = "com.aash591.SimpleMoney"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications schedules with java.time on old Androids.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        buildConfigField("String", "IMPROVEMENT_TOKEN", "\"$improvementToken\"")
        buildConfigField("String", "IMPROVEMENT_CHAT", "\"$improvementChat\"")
        applicationId = "com.aash591.SimpleMoney"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["admobAppId"] = admobAppId
    }

    signingConfigs {
        if (hasKeystoreProperties) {
            create("release") {
                storeFile = signingSecretsDirectory.resolve(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    // Every build type uses the same package name (com.aash591.SimpleMoney)
    // and, when the upload key is present, the same signing key. Google
    // sign-in (Drive sync) identifies the app by exactly that pair, so debug,
    // profile and release builds can all sign in with the one Android OAuth
    // client. A checkout without secrets/android/key.properties falls back to
    // the debug key, so `flutter run` keeps working (Google sign-in then needs
    // that machine's debug SHA-1 registered).
    //
    // The profile build seeds a sample ledger on a fresh install only; on a
    // phone that already has the app it keeps that phone's data.
    val sharedSigning =
        if (hasKeystoreProperties) {
            signingConfigs.getByName("release")
        } else {
            signingConfigs.getByName("debug")
        }
    buildTypes {
        getByName("debug") { signingConfig = sharedSigning }
        getByName("profile") { signingConfig = sharedSigning }
        release { signingConfig = sharedSigning }
    }

    packaging {
        jniLibs {
            // Store native libraries (Flutter engine, Dart AOT code, ML Kit,
            // SQLite) compressed so the APK is roughly half the size. Android
            // extracts them once at install time instead of mapping them
            // straight from the APK.
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    implementation("net.lingala.zip4j:zip4j:2.11.6")
    // Reads the text of UPI statement PDFs (Google Pay, PhonePe, Paytm).
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// Android Studio can run `exportReleaseApks` to generate a universal APK plus one
// APK per supported ABI. Files are copied outside the Flutter build directory so
// they remain easy to find after subsequent builds.
val flutterSdkPath = Properties().run {
    rootProject.file("local.properties").inputStream().use(::load)
    getProperty("flutter.sdk")
        ?: error("flutter.sdk is missing from android/local.properties")
}
val flutterExecutable = file(
    if (System.getProperty("os.name").startsWith("Windows", ignoreCase = true)) {
        "$flutterSdkPath/bin/flutter.bat"
    } else {
        "$flutterSdkPath/bin/flutter"
    },
)
val flutterProjectDir = rootProject.projectDir.parentFile
val flutterApkDir = flutterProjectDir.resolve("build/app/outputs/flutter-apk")
val apkOutDir = flutterProjectDir.parentFile.resolve("apkOut")
// Dart symbols are written here instead of into libapp.so. Keep them to
// symbolize release crash stack traces with `flutter symbolize`.
val splitDebugInfo = "--split-debug-info=build/app/outputs/symbols"
// These nested Flutter builds don't see secrets/.env on their own: Flutter reads it
// only through --dart-define-from-file (AdMob and Play IDs, the AI relay address).
val dartDefineFile = flutterProjectDir.parentFile.resolve("secrets/.env")
val dartDefineArgs =
    if (dartDefineFile.exists()) {
        listOf("--dart-define-from-file=${dartDefineFile.absolutePath}")
    } else {
        logger.warn("secrets/.env not found: exporting with default settings (test AdMob IDs, no AI relay).")
        emptyList()
    }

val nestedGradleJavaOptions =
    listOfNotNull(
        System.getenv("JAVA_OPTS")?.takeIf(String::isNotBlank),
        "--enable-native-access=ALL-UNNAMED",
    ).joinToString(" ")

val prepareUniversalReleaseIntermediates =
    tasks.register<Delete>("prepareUniversalReleaseIntermediates") {
        delete(flutterProjectDir.resolve("build/app/intermediates/flutter/release"))
    }

val buildUniversalReleaseApk = tasks.register<Exec>("buildUniversalReleaseApk") {
    group = "distribution"
    description = "Builds the universal release APK."
    dependsOn(prepareUniversalReleaseIntermediates)
    workingDir = flutterProjectDir
    environment("JAVA_OPTS", nestedGradleJavaOptions)
    commandLine(
        listOf(flutterExecutable.absolutePath, "build", "apk", "--release", splitDebugInfo) + dartDefineArgs,
    )
}

// A second Flutter release build can fail on Windows when it tries to copy
// assets over the universal build's existing intermediate asset directory.
// Remove only those intermediates; the completed universal APK is preserved.
val resetFlutterReleaseIntermediates =
    tasks.register<Delete>("resetFlutterReleaseIntermediates") {
        dependsOn(buildUniversalReleaseApk)
        delete(flutterProjectDir.resolve("build/app/intermediates/flutter/release"))
    }

val buildSplitReleaseApks = tasks.register<Exec>("buildSplitReleaseApks") {
    group = "distribution"
    description = "Builds release APKs for armeabi-v7a, arm64-v8a, and x86_64."
    dependsOn(resetFlutterReleaseIntermediates)
    workingDir = flutterProjectDir
    environment("JAVA_OPTS", nestedGradleJavaOptions)
    commandLine(
        listOf(
            flutterExecutable.absolutePath, "build", "apk", "--release", "--split-per-abi", splitDebugInfo,
        ) + dartDefineArgs,
    )
}

tasks.register<Copy>("exportReleaseApks") {
    group = "distribution"
    description = "Exports universal and ABI-specific release APKs to /apkOut."
    dependsOn(buildUniversalReleaseApk, buildSplitReleaseApks)
    from(flutterApkDir) {
        include("app-release.apk", "app-*-release.apk")
        rename { fileName ->
            if (fileName == "app-release.apk") {
                "simple-money-release-universal.apk"
            } else {
                val abi = fileName.removePrefix("app-").removeSuffix("-release.apk")
                "simple-money-release-$abi.apk"
            }
        }
    }
    into(apkOutDir)
}

val prepareArm64ReleaseIntermediates =
    tasks.register<Delete>("prepareArm64ReleaseIntermediates") {
        delete(flutterProjectDir.resolve("build/app/intermediates/flutter/release"))
    }

val buildArm64ReleaseApk = tasks.register<Exec>("buildArm64ReleaseApk") {
    group = "distribution"
    description = "Builds only the arm64-v8a release APK."
    dependsOn(prepareArm64ReleaseIntermediates)
    workingDir = flutterProjectDir
    environment("JAVA_OPTS", nestedGradleJavaOptions)
    commandLine(
        listOf(
            flutterExecutable.absolutePath, "build", "apk", "--release",
            "--target-platform=android-arm64", "--split-per-abi", splitDebugInfo,
        ) + dartDefineArgs,
    )
}

tasks.register<Copy>("exportArm64ReleaseApk") {
    group = "distribution"
    description = "Exports only the arm64-v8a release APK to /apkOut."
    dependsOn(buildArm64ReleaseApk)
    from(flutterApkDir) {
        include("app-arm64-v8a-release.apk")
        rename { "simple-money-release-arm64-v8a.apk" }
    }
    into(apkOutDir)
}
