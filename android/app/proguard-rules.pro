# Flutter specific rules.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Rules for flutter_v2ray to prevent it from being removed
-keep class com.github.blueboytm.flutter_v2ray.** { *; }
-keep class go.** { *; }
-keep class libv2ray.** { *; }
-keep class v2ray.** { *; }