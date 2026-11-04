plugins { id("com.android.library") version "9.5.0" apply false }
layout.buildDirectory.set(layout.projectDirectory.dir(".build/root"))
subprojects {
    layout.buildDirectory.set(rootProject.layout.projectDirectory.dir(".build/" + project.name))
}
