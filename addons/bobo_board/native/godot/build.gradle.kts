plugins { id("com.android.library") }
android {
    namespace = "io.github.ceratops_code.boboboard.godot"
    compileSdk = 36
    defaultConfig { minSdk = 31 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    implementation(project(":board"))
    compileOnly("org.godotengine:godot:4.7.2.stable")
}
