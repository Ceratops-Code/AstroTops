plugins { id("com.android.library") version "9.5.0" apply false }
layout.buildDirectory.set(layout.projectDirectory.dir(".gradle/build/root"))
subprojects {
    layout.buildDirectory.set(rootProject.layout.projectDirectory.dir(".gradle/build/" + project.name))
}
