pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositoriesMode = RepositoriesMode.FAIL_ON_PROJECT_REPOS
    repositories {
        mavenCentral()
        google {
            content { includeGroup("com.android.tools.build") ; includeGroup("com.android.tools") }
        }
        maven("https://jitpack.io") {
            content { includeGroup("com.github.mihonapp") }
        }
    }
}

rootProject.name = "tachi-source-runner"
