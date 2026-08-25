plugins {
    id("com.android.application")

    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration

    // Flutter Gradle Plugin
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.chatbot_app"

    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // ==========================================================
    // JAVA / DESUGARING
    // ==========================================================

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17

        // REQUIRED BY flutter_local_notifications
        isCoreLibraryDesugaringEnabled = true
    }

    // ==========================================================
    // DEFAULT CONFIG
    // ==========================================================

    defaultConfig {
        applicationId = "com.example.chatbot_app"

        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion

        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Enable multidex
        multiDexEnabled = true
    }

    // ==========================================================
    // BUILD TYPES
    // ==========================================================

    buildTypes {
        release {
            // Debug signing for now
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// ==========================================================
// KOTLIN
// ==========================================================

kotlin {
    compilerOptions {
        jvmTarget =
            org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// ==========================================================
// DEPENDENCIES
// ==========================================================

dependencies {
    // REQUIRED BY flutter_local_notifications
    coreLibraryDesugaring(
        "com.android.tools:desugar_jdk_libs:2.1.4"
    )
}

// ==========================================================
// FLUTTER
// ==========================================================

flutter {
    source = "../.."
}