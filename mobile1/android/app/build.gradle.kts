plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing — credentials live in android/keystore.properties (gitignored).
// File format:
//   storeFile=app/upload-keystore.jks
//   storePassword=...
//   keyAlias=upload
//   keyPassword=...
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps: Map<String, String> =
    if (keystorePropsFile.isFile) {
        keystorePropsFile.readLines().mapNotNull { line ->
            val idx = line.indexOf('=')
            if (idx > 0) {
                val key = line.substring(0, idx).trim()
                val value = line.substring(idx + 1).trim()
                if (key.isNotEmpty() && value.isNotEmpty()) key to value else null
            } else {
                null
            }
        }.toMap()
    } else {
        emptyMap()
    }

android {
    namespace = "com.addisfurnish.addisfurnish"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.addisfurnish.addisfurnish"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (keystoreProps.isNotEmpty()) {
        signingConfigs {
            create("release") {
                this.storeFile = rootProject.file(keystoreProps["storeFile"]!!)
                storePassword = keystoreProps["storePassword"]!!
                keyAlias = keystoreProps["keyAlias"]!!
                keyPassword = keystoreProps["keyPassword"]!!
            }
        }
    }

    buildTypes {
        release {
            // Signed with your own upload keystore (android/keystore.properties).
            // Falls back to debug signing only when the properties file is
            // absent (fresh clones without the keystore).
            signingConfig = if (keystorePropsFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
