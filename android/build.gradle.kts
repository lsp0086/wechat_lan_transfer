import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        google()
        mavenCentral()
    }
}

// 为所有子项目的 buildscript 注入阿里云镜像，避免插件内部硬编码的仓库下载失败
subprojects {
    buildscript {
        repositories {
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            maven { url = uri("https://maven.aliyun.com/repository/public") }
            maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
            google()
            mavenCentral()
            gradlePluginPortal()
        }
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
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// JVM 目标统一：钉版插件（receive_sharing_intent 1.8.1 等）只默认 Java 1.8
// 且不设 Kotlin 目标，KGP 2.2 下 Kotlin 默认取 Gradle JVM（21），与 Java 目标
// 不一致会触发 KGP 校验直接构建失败（Inconsistent JVM Target Compatibility）。
// 在 afterEvaluate 后覆盖为 Java/Kotlin 17，与 app 模块（17/17）一致。
subprojects {
    // :app 会被上面的 evaluationDependsOn 提前评估完：此时 compileOptions 已
    // finalize（不可再写），且 app 自身就是 17/17 无需处理，直接跳过；
    // 其余插件子项目在评估完成后收敛。
    if (state.executed) return@subprojects
    afterEvaluate {
        val androidExt = extensions.findByName("android")
        if (androidExt is com.android.build.gradle.LibraryExtension) {
            androidExt.compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        } else if (androidExt is com.android.build.api.dsl.ApplicationExtension) {
            androidExt.compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        }
        tasks.withType<KotlinCompile>().configureEach {
            compilerOptions.jvmTarget.set(JvmTarget.JVM_17)
        }
    }
}
