plugins {
    kotlin("jvm") version "2.1.0"
    application
}

repositories {
    mavenCentral()
}

dependencies {
    // The uniffi Kotlin bindings talk to the cdylib through JNA.
    implementation("net.java.dev.jna:jna:5.14.0")
    // Every exported method is `suspend`, so the host needs coroutines.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
}

kotlin {
    // `uniffi-bindgen` writes here; the directory is generated, never committed.
    sourceSets["main"].kotlin.srcDir("build/generated/uniffi")
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_21
    targetCompatibility = JavaVersion.VERSION_21
}

application {
    mainClass.set("MainKt")
    // Point JNA at the directory holding rhttp_uniffi.dll / librhttp_uniffi.so.
    providers.gradleProperty("nativeDir").orNull?.let { directory ->
        applicationDefaultJvmArgs = listOf("-Djna.library.path=$directory")
    }
}
