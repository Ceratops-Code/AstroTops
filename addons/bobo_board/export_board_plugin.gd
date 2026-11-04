@tool
extends EditorPlugin

var board_export: EditorExportPlugin


func _enter_tree() -> void:
    board_export = BoardAndroidExport.new()
    add_export_plugin(board_export)


func _exit_tree() -> void:
    remove_export_plugin(board_export)
    board_export = null


class BoardAndroidExport extends EditorExportPlugin:
    func _supports_platform(platform: EditorExportPlatform) -> bool:
        return platform is EditorExportPlatformAndroid

    func _get_name() -> String:
        return "BoboBoard"

    func _get_android_libraries(_platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
        var variant := "debug" if debug else "release"
        return PackedStringArray([
            "bobo_board/.artifacts/board-%s.aar" % variant,
            "bobo_board/.artifacts/godot-%s.aar" % variant,
        ])

    func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
        return PackedStringArray(["no.nordicsemi.android:ble:2.11.0"])
