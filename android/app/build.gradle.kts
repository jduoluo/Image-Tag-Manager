import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Local credentials are Git-ignored. A process environment override is optional.
val releaseSigningFile = rootProject.file("key.properties")
val releaseSigning = Properties().apply {
    if (releaseSigningFile.isFile) {
        releaseSigningFile.reader(Charsets.UTF_8).use { load(it) }
    }
}
val releaseStorePath = releaseSigning.getProperty("storeFile").orEmpty()
val releaseStorePassword = System.getenv("ITM_RELEASE_STORE_PASSWORD")?.takeIf { it.isNotEmpty() }
    ?: releaseSigning.getProperty("storePassword").orEmpty()
val releaseKeyAlias = releaseSigning.getProperty("keyAlias").orEmpty()
val releaseKeyPassword = releaseStorePassword

val validateReleaseSigningInputs = tasks.register("validateReleaseSigningInputs") {
    doLast {
        check(releaseSigningFile.isFile) {
            "Release signing requires android/key.properties. See docs/RELEASE_SIGNING.md."
        }
        check(listOf(releaseStorePath, releaseStorePassword, releaseKeyAlias, releaseKeyPassword).all { it.isNotBlank() }) {
            "Release signing requires identity configuration and a password. Fill local android/key.properties or run scripts/build_android_release.ps1."
        }
        check(rootProject.file(releaseStorePath).isFile) {
            "Release keystore was not found. Check storeFile in the local signing configuration."
        }
    }
}
// Debug remains available without credentials; every Release build must validate.
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(validateReleaseSigningInputs)
}

android {
    namespace = "com.example.image_tag_manager"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Published application identity; independent from the internal native namespace.
        applicationId = "io.github.jduoluo.imagetagmanager"
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
        externalNativeBuild { cmake { arguments += "-DANDROID_STL=c++_static" } }
    }

    externalNativeBuild {
        cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" }
    }

    signingConfigs {
        create("release") {
            if (releaseStorePath.isNotBlank()) storeFile = rootProject.file(releaseStorePath)
            storeType = "PKCS12"
            storePassword = releaseStorePassword
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
        }
    }

    buildTypes {
        release {
            // Never silently fall back to the development signing identity.
            signingConfig = signingConfigs.getByName("release")
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
