plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

group = "com.unity_kit"
version = "0.9.1"

android {
    namespace = "com.unity_kit"
    compileSdk = 34

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("org.jetbrains.kotlin:kotlin-stdlib")
    implementation("androidx.lifecycle:lifecycle-common:2.7.0")
    implementation("androidx.lifecycle:lifecycle-process:2.7.0")
    implementation("androidx.annotation:annotation:1.7.1")
    compileOnly(group = "", name = "unity-classes", ext = "jar") // provided by Unity at runtime via flatDir

    val lifecycleProject = rootProject.findProject(":flutter_plugin_android_lifecycle")
    if (lifecycleProject != null) {
        compileOnly(lifecycleProject)
    }
}
