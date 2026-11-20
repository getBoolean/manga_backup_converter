import org.gradle.kotlin.dsl.support.serviceOf
import org.gradle.process.ExecOperations
import org.gradle.process.ExecResult

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Compatibility for irondash_engine_context 0.5.5 and super_native_extensions
// 0.9.1 (latest releases, pulled in by super_clipboard) under Gradle 9 / AGP 9.
// Registered before evaluationDependsOn so afterEvaluate hooks attach in time.
// Remove once upstream fixes both issues.
//
// 1. Gradle 9 removed Project.exec(), which their vendored cargokit script
//    still calls as `project.exec { }`. Gradle invokes a Closure stored as an
//    extra property when a missing method of that name is called, so this
//    restores `exec` on those projects only, backed by ExecOperations.
// 2. Both compile against android-31, but the androidx
//    libraries in Flutter 3.50's embedding require 33+ (checkAarMetadata).
val cargokitProjects = setOf("irondash_engine_context", "super_native_extensions")
subprojects {
    if (name in cargokitProjects) {
        val execOperations = serviceOf<ExecOperations>()
        extra["exec"] =
            object : groovy.lang.Closure<ExecResult>(this) {
                @Suppress("unused")
                fun doCall(configure: groovy.lang.Closure<*>): ExecResult =
                    execOperations.exec {
                        configure.resolveStrategy = groovy.lang.Closure.DELEGATE_FIRST
                        configure.delegate = this
                        configure.call(this)
                    }
            }
        afterEvaluate {
            withGroovyBuilder { "android" { "compileSdkVersion"(36) } }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
