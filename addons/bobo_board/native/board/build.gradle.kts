plugins { id("com.android.library") }
android {
    namespace = "io.github.ceratops_code.boboboard"
    compileSdk = 36
    defaultConfig { minSdk = 31 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets.getByName("test").resources.srcDir("src/main/assets")
}
dependencies {
    implementation("no.nordicsemi.android:ble:2.11.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20260814")
}
