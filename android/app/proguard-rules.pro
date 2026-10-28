# Flutter/Dart/sing-box ProGuard rules
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.view.** { *; }
-keep class com.izz.tunneling.injector.** { *; }
-dontwarn io.flutter.**
-dontwarn kotlin.**

# Keep AndroidX
-keep class androidx.** { *; }
-dontwarn androidx.**

# Keep hev-socks5-tunnel
-keep class hev.htproxy.** { *; }

# Keep JSch (HTTP Custom SSH Engine)
-keep class com.jcraft.jsch.** { *; }
-dontwarn com.jcraft.jsch.**

# Keep Kotlin metadata
-keepclassmembers class * {
    @kotlin.Metadata *;
}
