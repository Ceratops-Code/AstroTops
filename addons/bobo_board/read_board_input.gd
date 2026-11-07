class_name BoboBoardInput
extends Node
## Reusable Godot facade. Coordinates use Godot's screen axes. A caller can inject
## another backend with the same signal and methods before adding this node.

signal board_state_changed
signal board_input_lost

var backend: Object
var status := "unsupported"
var message := "BoBo connection is available on Android"
var movement := Vector2.ZERO
var battery := -1
var requested := false
var calibration_source := "Imported default"
var calibration: Dictionary = {}
var _last_packet_ms := -1
var _last_sequence := -1
var _local_failure := ""
# A displayed error can outlive the asynchronous radio release behind it.
var _release_pending := false


func _ready() -> void:
    if backend == null and Engine.has_singleton("BoboBoard"):
        backend = Engine.get_singleton("BoboBoard")
    if backend != null:
        backend.connect("board_state_changed", _receive_board_state)
        status = "disconnected"
        message = "BoBo disconnected"


func is_supported() -> bool:
    return backend != null


func is_ready() -> bool:
    return status == "ready" and has_live_packets()


func has_live_packets() -> bool:
    return requested and _last_packet_ms >= 0 and Time.get_ticks_msec() - _last_packet_ms <= 1000


func begin_calibration() -> void:
    if backend != null and is_ready():
        backend.call("beginBoardCalibration")


func select_calibration_pose(pose: String) -> void:
    if backend != null and pose in ["CENTER", "LEFT", "RIGHT", "UP", "DOWN"]:
        backend.call("selectBoardCalibrationPose", pose)


func capture_calibration_pose() -> void:
    if backend != null and calibration.get("active", false) and has_live_packets():
        backend.call("captureBoardCalibrationPose")


func cancel_calibration() -> void:
    if backend != null:
        backend.call("cancelBoardCalibration")


func save_calibration() -> void:
    if backend != null and calibration.get("can_save", false) and has_live_packets():
        backend.call("saveBoardCalibration")


func save_center() -> void:
    if backend != null and calibration.get("can_save_center", false) and has_live_packets():
        backend.call("saveBoardCenter")


func set_sensitivity_percent(control: String, percent: int) -> void:
    if backend != null and calibration.get("active", false) and has_live_packets():
        backend.call("setBoardSensitivityPercent", control, percent)


func save_sensitivity() -> void:
    if backend != null and calibration.get("can_save_sensitivity", false) and has_live_packets():
        backend.call("saveBoardSensitivity")


func restore_imported_default() -> void:
    if backend != null and has_live_packets():
        backend.call("restoreImportedBoardCalibration")


func can_connect_board() -> bool:
    return backend != null and not requested and not _release_pending


func connect_board() -> void:
    if not can_connect_board():
        return
    requested = true
    _local_failure = ""
    _last_sequence = -1
    status = "connecting"
    message = "Connecting to BoBo"
    movement = Vector2.ZERO
    board_state_changed.emit()
    backend.call("connectToBoBoBoard")


func disconnect_board() -> void:
    if not requested and status in ["disconnected", "releasing", "unsupported"]:
        return
    var was_ready := is_ready()
    _local_failure = ""
    requested = false
    movement = Vector2.ZERO
    _last_packet_ms = -1
    if was_ready:
        board_input_lost.emit()
    if backend != null:
        _release_pending = true
        status = "releasing"
        message = "Releasing BoBo"
        board_state_changed.emit()
        backend.call("disconnectFromBoBoBoard")


func _receive_board_state(payload: String) -> void:
    var parsed: Variant = JSON.parse_string(payload)
    if not parsed is Dictionary:
        return
    var was_ready := is_ready()
    var next_status := str(parsed.get("status", "error"))
    if next_status == "releasing":
        _release_pending = true
    elif next_status in ["disconnected", "error"]:
        _release_pending = false
    if not _local_failure.is_empty() and next_status in ["releasing", "disconnected"]:
        status = "error"
        message = _local_failure
        board_state_changed.emit()
        return
    var must_release := false
    # Late packets after Disconnect never restore movement or readiness.
    if not requested and next_status in ["ready", "waiting", "connecting", "scanning", "calibrating"]:
        return
    status = next_status
    message = str(parsed.get("message", "BoBo status unavailable"))
    battery = int(parsed.get("battery", -1))
    calibration_source = str(parsed.get("calibration_source", calibration_source))
    var calibration_state: Variant = parsed.get("calibration", {})
    if calibration_state is Dictionary:
        calibration = calibration_state
    movement = Vector2.ZERO
    if requested and status in ["ready", "calibrating"] and parsed.get("fresh", false) == true:
        var x := float(parsed.get("x", 0.0))
        var y := float(parsed.get("y", 0.0))
        if is_finite(x) and is_finite(y) and absf(x) <= 1.001 and absf(y) <= 1.001:
            movement = Vector2(x, y).limit_length(1.0) if status == "ready" else Vector2.ZERO
            var sequence := int(parsed.get("sequence", -1))
            if sequence > _last_sequence:
                _last_sequence = sequence
                _last_packet_ms = Time.get_ticks_msec()
        else:
            status = "error"
            message = "BoBo returned invalid movement"
            _local_failure = message
            must_release = true
            _release_pending = true
            _last_packet_ms = -1
    else:
        _last_packet_ms = -1
    if status in ["error", "disconnected"]:
        requested = false
    if was_ready and not is_ready():
        board_input_lost.emit()
    board_state_changed.emit()
    if must_release and backend != null:
        backend.call("disconnectFromBoBoBoard")


func _process(_delta: float) -> void:
    if status in ["ready", "calibrating"] and not has_live_packets():
        movement = Vector2.ZERO
        status = "error"
        message = "BoBo tilt stopped. Tap Connect to reconnect."
        _local_failure = message
        requested = false
        _release_pending = true
        board_input_lost.emit()
        board_state_changed.emit()
        if backend != null:
            backend.call("disconnectFromBoBoBoard")


func _exit_tree() -> void:
    if backend != null:
        backend.call("disconnectFromBoBoBoard")
        if backend.is_connected("board_state_changed", _receive_board_state):
            backend.disconnect("board_state_changed", _receive_board_state)


func create_sidebar() -> BoardSidebar:
    return BoardSidebar.new(self)


func create_calibration_panel() -> BoardCalibrationPanel:
    return BoardCalibrationPanel.new(self)


static func make_action_button(text: String, color: Color) -> Button:
    var button := Button.new()
    button.text = text
    button.custom_minimum_size = Vector2(0, 46)
    button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    button.add_theme_font_size_override("font_size", 18)
    for state_name in ["normal", "hover", "pressed", "disabled", "focus"]:
        var box := StyleBoxFlat.new()
        box.bg_color = Color(0.025, 0.035, 0.12, 0.98)
        box.border_color = Color(color, 0.30) if state_name == "disabled" else color
        if state_name in ["hover", "focus"]:
            box.bg_color = Color(0.06, 0.09, 0.18, 1.0)
            box.border_color = color.lightened(0.25)
        box.set_border_width_all(2)
        box.set_corner_radius_all(8)
        box.corner_detail = 1
        button.add_theme_stylebox_override(state_name, box)
    button.add_theme_color_override("font_color", Color.WHITE)
    button.add_theme_color_override("font_disabled_color", Color(0.65, 0.69, 0.78, 0.55))
    return button


static func make_panel_margin(panel: PanelContainer, padding: int) -> VBoxContainer:
    var style := StyleBoxFlat.new()
    style.bg_color = Color(0.015, 0.025, 0.09, 0.98)
    style.border_color = Color("324568")
    style.set_border_width_all(1)
    style.set_corner_radius_all(8)
    panel.add_theme_stylebox_override("panel", style)
    var margin := MarginContainer.new()
    for edge in ["left", "right", "top", "bottom"]:
        margin.add_theme_constant_override("margin_" + edge, padding)
    panel.add_child(margin)
    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 12)
    margin.add_child(column)
    return column


class BoardSidebar extends Control:
    signal test_requested
    signal calibration_requested
    signal expanded_changed(value: bool)
    signal connection_selected(active: bool)
    var board: BoboBoardInput
    var expanded := false
    var toggle_button: Button
    var panel: PanelContainer
    var status_label: Label
    var profile_label: Label
    var connect_button: Button
    var test_button: Button
    var calibrate_button: Button
    var disconnect_button: Button

    func _init(source: BoboBoardInput) -> void:
        board = source

    func _ready() -> void:
        mouse_filter = Control.MOUSE_FILTER_IGNORE
        size = Vector2(300, 720)
        toggle_button = BoboBoardInput.make_action_button("BOBO BOARD  >", Color("41f4c6"))
        toggle_button.position = Vector2(24, 18)
        toggle_button.size = Vector2(260, 48)
        toggle_button.pressed.connect(func() -> void: set_expanded(not expanded))
        add_child(toggle_button)
        panel = PanelContainer.new()
        panel.position = Vector2(14, 184)
        panel.custom_minimum_size = Vector2(282, 0)
        panel.size = Vector2(282, 0)
        add_child(panel)
        var column := BoboBoardInput.make_panel_margin(panel, 12)
        var title := Label.new()
        title.text = "BOBO BOARD"
        title.add_theme_font_size_override("font_size", 23)
        title.add_theme_color_override("font_color", Color("41f4c6"))
        column.add_child(title)
        status_label = Label.new()
        status_label.custom_minimum_size = Vector2(250, 64)
        status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        status_label.max_lines_visible = 4
        status_label.add_theme_font_size_override("font_size", 16)
        column.add_child(status_label)
        connect_button = BoboBoardInput.make_action_button("CONNECT TO BOBO", Color("41f4c6"))
        connect_button.pressed.connect(func() -> void:
            connection_selected.emit(true)
            board.connect_board())
        column.add_child(connect_button)
        test_button = BoboBoardInput.make_action_button("TEST BOARD", Color("46a8ff"))
        test_button.pressed.connect(func() -> void: test_requested.emit())
        column.add_child(test_button)
        calibrate_button = BoboBoardInput.make_action_button("BOARD SETTINGS", Color("a879ff"))
        calibrate_button.pressed.connect(func() -> void: calibration_requested.emit())
        column.add_child(calibrate_button)
        disconnect_button = BoboBoardInput.make_action_button("DISCONNECT BOBO", Color("ffc857"))
        disconnect_button.pressed.connect(func() -> void:
            connection_selected.emit(false)
            board.disconnect_board())
        column.add_child(disconnect_button)
        var caption := Label.new()
        caption.text = "CALIBRATION"
        caption.add_theme_font_size_override("font_size", 13)
        caption.add_theme_color_override("font_color", Color("8494b4"))
        column.add_child(caption)
        profile_label = Label.new()
        profile_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        profile_label.add_theme_font_size_override("font_size", 16)
        column.add_child(profile_label)
        board.board_state_changed.connect(_refresh)
        _refresh()
        _show_expanded_state()

    func set_expanded(value: bool) -> void:
        if expanded == value:
            return
        expanded = value
        _show_expanded_state()
        expanded_changed.emit(value)

    func _show_expanded_state() -> void:
        if panel != null:
            panel.visible = expanded
            toggle_button.text = "<  BOBO BOARD" if expanded else "BOBO BOARD  >"

    func _refresh() -> void:
        if status_label == null:
            return
        status_label.text = board.message
        if board.is_ready():
            status_label.text += "\nX %+.2f   Y %+.2f" % [board.movement.x, board.movement.y]
            if board.battery >= 0:
                status_label.text += "   %d%%" % board.battery
        profile_label.text = board.calibration_source
        connect_button.disabled = not board.can_connect_board()
        test_button.disabled = not board.is_supported()
        calibrate_button.disabled = not board.is_ready()
        disconnect_button.disabled = not board.is_supported() or board.status in ["disconnected", "releasing"]


class BoardCalibrationPanel extends PanelContainer:
    signal closed
    const POSES := ["CENTER", "LEFT", "RIGHT", "UP", "DOWN"]
    const NAMES := ["Center", "Left", "Right", "Forward", "Backward"]
    const INSTRUCTIONS := [
        "Keep the board level and centered.",
        "Tilt the board to the left.",
        "Tilt the board to the right.",
        "Tilt the board forward, away from you.",
        "Tilt the board backward, toward you.",
    ]
    var board: BoboBoardInput
    var pose_label: Label
    var instruction_label: Label
    var status_label: Label
    var progress: ProgressBar
    var pose_buttons: Array[Button] = []
    var capture_button: Button
    var save_button: Button
    var cancel_button: Button
    var restore_button: Button
    var sensitivity_column: VBoxContainer
    var sensitivity_sliders: Dictionary = {}
    var sensitivity_labels: Dictionary = {}
    var sensitivity_save_button: Button
    var preview_label: Label
    var preview: BoardTiltPreview
    var _awaiting_completion := false

    func _init(source: BoboBoardInput) -> void:
        board = source

    func _ready() -> void:
        position = Vector2(68, 16)
        custom_minimum_size = Vector2(1144, 0)
        size = Vector2(1144, 0)
        var column := BoboBoardInput.make_panel_margin(self, 16)
        var title := Label.new()
        title.text = "BOBO CALIBRATION & SENSITIVITY"
        title.add_theme_font_size_override("font_size", 28)
        title.add_theme_color_override("font_color", Color("41f4c6"))
        column.add_child(title)
        var explanation := Label.new()
        explanation.text = "If the board drifts at rest, hold it level, capture Center and choose Save Center."
        explanation.add_theme_font_size_override("font_size", 17)
        column.add_child(explanation)
        var body := HBoxContainer.new()
        body.add_theme_constant_override("separation", 24)
        column.add_child(body)
        var poses_column := VBoxContainer.new()
        poses_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        poses_column.add_theme_constant_override("separation", 12)
        body.add_child(poses_column)
        sensitivity_column = VBoxContainer.new()
        sensitivity_column.custom_minimum_size.x = 330
        sensitivity_column.add_theme_constant_override("separation", 6)
        body.add_child(sensitivity_column)
        var sensitivity_title := Label.new()
        sensitivity_title.text = "SENSITIVITY"
        sensitivity_title.add_theme_font_size_override("font_size", 21)
        sensitivity_title.add_theme_color_override("font_color", Color("a879ff"))
        sensitivity_column.add_child(sensitivity_title)
        var poses_row := HBoxContainer.new()
        poses_row.add_theme_constant_override("separation", 8)
        poses_column.add_child(poses_row)
        for index in range(POSES.size()):
            var button := BoboBoardInput.make_action_button(NAMES[index], Color("46a8ff"))
            button.add_theme_font_size_override("font_size", 14)
            button.pressed.connect(board.select_calibration_pose.bind(POSES[index]))
            poses_row.add_child(button)
            pose_buttons.append(button)
        pose_label = Label.new()
        pose_label.add_theme_font_size_override("font_size", 25)
        poses_column.add_child(pose_label)
        instruction_label = Label.new()
        instruction_label.custom_minimum_size = Vector2(0, 48)
        instruction_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        instruction_label.add_theme_font_size_override("font_size", 19)
        poses_column.add_child(instruction_label)
        status_label = Label.new()
        status_label.custom_minimum_size = Vector2(0, 68)
        status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        status_label.max_lines_visible = 4
        status_label.add_theme_font_size_override("font_size", 17)
        poses_column.add_child(status_label)
        progress = ProgressBar.new()
        progress.max_value = 3000
        progress.show_percentage = false
        progress.custom_minimum_size.y = 18
        poses_column.add_child(progress)
        var capture_row := HBoxContainer.new()
        capture_row.add_theme_constant_override("separation", 12)
        poses_column.add_child(capture_row)
        capture_button = BoboBoardInput.make_action_button("CAPTURE CENTER", Color("41f4c6"))
        capture_button.pressed.connect(_capture)
        capture_row.add_child(capture_button)
        save_button = BoboBoardInput.make_action_button("SAVE CALIBRATION", Color("46a8ff"))
        save_button.pressed.connect(_save)
        capture_row.add_child(save_button)
        # Controls and bounds come from the native module, shared with other hosts.
        _add_sensitivity_controls()
        var hint := Label.new()
        hint.text = "Higher sensitivity needs less tilt.\nDead zone keeps small center movements still."
        hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        hint.add_theme_font_size_override("font_size", 15)
        sensitivity_column.add_child(hint)
        var preview_row := HBoxContainer.new()
        preview_row.add_theme_constant_override("separation", 12)
        sensitivity_column.add_child(preview_row)
        preview = BoardTiltPreview.new()
        preview.custom_minimum_size = Vector2(64, 64)
        preview_row.add_child(preview)
        preview_label = Label.new()
        preview_label.add_theme_font_size_override("font_size", 16)
        preview_row.add_child(preview_label)
        sensitivity_save_button = BoboBoardInput.make_action_button("SAVE SENSITIVITY", Color("a879ff"))
        sensitivity_save_button.pressed.connect(board.save_sensitivity)
        sensitivity_column.add_child(sensitivity_save_button)
        var bottom := HBoxContainer.new()
        bottom.add_theme_constant_override("separation", 12)
        column.add_child(bottom)
        cancel_button = BoboBoardInput.make_action_button("CANCEL", Color("8291b9"))
        cancel_button.pressed.connect(close_panel)
        bottom.add_child(cancel_button)
        restore_button = BoboBoardInput.make_action_button("RESTORE IMPORTED DEFAULT", Color("ffc857"))
        restore_button.add_theme_font_size_override("font_size", 16)
        restore_button.pressed.connect(_restore)
        bottom.add_child(restore_button)
        board.board_state_changed.connect(_refresh)
        _refresh()

    func _add_sensitivity_controls() -> void:
        for control: Dictionary in board.calibration.get("sensitivity_controls", []):
            var control_id := str(control["id"])
            if sensitivity_sliders.has(control_id):
                continue
            var control_index := 1 + sensitivity_sliders.size() * 2
            var label := Label.new()
            label.add_theme_font_size_override("font_size", 16)
            sensitivity_column.add_child(label)
            sensitivity_column.move_child(label, control_index)
            sensitivity_labels[control_id] = label
            var slider := HSlider.new()
            slider.min_value = int(control["minimum"])
            slider.max_value = int(control["maximum"])
            slider.step = 1
            slider.custom_minimum_size = Vector2(330, 20)
            slider.value_changed.connect(func(value: float) -> void: board.set_sensitivity_percent(control_id, roundi(value)))
            sensitivity_column.add_child(slider)
            sensitivity_column.move_child(slider, control_index + 1)
            sensitivity_sliders[control_id] = slider

    func close_panel() -> void:
        _awaiting_completion = false
        board.cancel_calibration()
        closed.emit()

    func _capture() -> void:
        if board.calibration.get("active", false):
            board.capture_calibration_pose()
        else:
            board.begin_calibration()

    func _save() -> void:
        _awaiting_completion = true
        if board.calibration.get("can_save_center", false):
            board.save_center()
        else:
            board.save_calibration()

    func _restore() -> void:
        _awaiting_completion = true
        board.restore_imported_default()

    func _refresh() -> void:
        if pose_label == null:
            return
        var state: Dictionary = board.calibration
        _add_sensitivity_controls()
        var active: bool = state.get("active", false)
        var capturing: bool = state.get("capturing", false)
        var index: int = maxi(0, POSES.find(str(state.get("pose", "CENTER"))))
        var captured: Array = state.get("captured", [])
        pose_label.text = "%d / 5  —  %s" % [index + 1, NAMES[index]]
        instruction_label.text = INSTRUCTIONS[index] + " Hold steady for three seconds after pressing Capture."
        var event := str(state.get("event", ""))
        status_label.text = str(state.get("message", "")) if active or event.ends_with("failed") else board.message
        for pose_index in range(POSES.size()):
            var done: bool = POSES[pose_index] in captured
            pose_buttons[pose_index].text = NAMES[pose_index] + (" done" if done else "")
            pose_buttons[pose_index].disabled = not active or capturing
            pose_buttons[pose_index].modulate = Color("76ed55") if done else (Color("ffc857") if pose_index == index else Color.WHITE)
        var live: bool = board.has_live_packets()
        for control: Dictionary in state.get("sensitivity_controls", []):
            var control_id := str(control["id"])
            if sensitivity_sliders.has(control_id):
                var slider: HSlider = sensitivity_sliders[control_id]
                slider.set_value_no_signal(float(control["percent"]))
                slider.editable = active and live and not capturing
                sensitivity_labels[control_id].text = "%s  %d%%" % [control["label"], control["percent"]]
        sensitivity_save_button.disabled = not active or capturing or not live or not state.get("can_save_sensitivity", false)
        preview.tilt = Vector2(float(state.get("preview_x", 0.0)), float(state.get("preview_y", 0.0))) if live else Vector2.ZERO
        preview.queue_redraw()
        preview_label.text = "LIVE PREVIEW\nX %+.2f   Y %+.2f" % [preview.tilt.x, preview.tilt.y] if live else "PREVIEW\nWaiting for live tilt"
        capture_button.disabled = capturing or not live
        capture_button.text = ("HOLD STILL  %.1fs" % (float(state.get("remaining_ms", 0)) / 1000.0)) if capturing else ("CAPTURE " + NAMES[index].to_upper() if active else "START CALIBRATION")
        var can_save_center: bool = state.get("can_save_center", false)
        save_button.text = "SAVE CENTER" if can_save_center else "SAVE CALIBRATION"
        save_button.disabled = not active or capturing or not live or not (can_save_center or state.get("can_save", false))
        restore_button.disabled = not live or capturing
        progress.value = 3000 - int(state.get("remaining_ms", 3000)) if capturing else 0
        if _awaiting_completion and event in ["save_failed", "restore_failed"]:
            _awaiting_completion = false
        if _awaiting_completion and not active and event in ["saved", "center_saved", "restored"]:
            _awaiting_completion = false
            closed.emit()


class BoardTiltPreview extends Control:
    var tilt := Vector2.ZERO

    func _draw() -> void:
        var center := size * 0.5
        var radius := minf(size.x, size.y) * 0.5 - 4.0
        draw_circle(center, radius, Color("14233e"))
        draw_arc(center, radius, 0, TAU, 48, Color("62799c"), 1.0, true)
        draw_line(center - Vector2(radius, 0), center + Vector2(radius, 0), Color("324568"))
        draw_line(center - Vector2(0, radius), center + Vector2(0, radius), Color("324568"))
        draw_circle(center + tilt.limit_length(1.0) * (radius - 5.0), 5.0, Color("41f4c6"))
