# ML Kit discovers registrars by class name in the Android manifest and
# instantiates them reflectively through their no-argument constructors.
-keep class com.google.mlkit.** implements com.google.firebase.components.ComponentRegistrar {
    public <init>();
}
