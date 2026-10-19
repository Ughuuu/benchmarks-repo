extends Control

## Pick a physics engine and a case, then watch it run.
##
## The engine list comes from the `physics_engine` setting's property hint — the servers that
## actually registered — so an extension that failed to load is absent rather than silently
## falling back. Switching engine needs a restart: Godot reads the setting once at startup.

const Visualize := preload("res://framework/visualize.gd")

var _dim := "2d"
var _active_engine := ""
var _engine_picker: OptionButton
var _case_picker: OptionButton
var _debug_toggle: CheckBox
var _status: Label


func _ready() -> void:
	_dim = str(ProjectSettings.get_setting("application/config/bench_dim", "2d"))
	_active_engine = str(
		ProjectSettings.get_setting("physics/%s/physics_engine" % _dim, "DEFAULT")
	)

	# `-- --case=pyramid` jumps straight into the viewer, skipping the menu. Handy for
	# looking at one case quickly, and it is how the scene screenshots are produced.
	var args := _user_args()
	# `--play-all` runs every case back to back, so a screen recording captures the whole
	# suite in one take instead of relaunching per case.
	if args.has("play-all"):
		_play_all(
			args.get("debug-draw", "true") != "false",
			int(args.get("record-ticks", "0")),
			float(args.get("record-seconds", "5"))
		)
		return
	if args.has("case"):
		_open_viewer(
			args["case"],
			args.get("debug-draw", "true") != "false",
			args.get("shot", ""),
			int(args.get("shot-tick", "90")),
			args.has("shot-exact"),
			int(args.get("record-ticks", "0"))
		)
		return

	_build_ui()


func _play_all(debug_draw: bool, ticks: int, seconds: float) -> void:
	var names: Array[String] = []
	for f in DirAccess.get_files_at("res://cases"):
		if f.ends_with(".gd"):
			names.append(f.get_basename())
	names.sort()
	for name in names:
		var viewer: Node = load("res://framework/viewer.gd").new()
		viewer.case_name = name
		viewer.debug_draw = debug_draw
		viewer.max_ticks = ticks
		viewer.max_seconds = seconds
		add_child(viewer)
		await viewer.case_finished
		viewer.queue_free()
		await get_tree().process_frame
	get_tree().quit()


func _user_args() -> Dictionary:
	var parsed: Dictionary = {}
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--"):
			continue
		var body := arg.substr(2)
		var eq := body.find("=")
		if eq == -1:
			parsed[body] = "true"
		else:
			parsed[body.left(eq)] = body.substr(eq + 1)
	return parsed


func _open_viewer(
	name: String, debug_draw: bool, shot := "", shot_tick := 90, exact := false,
	record_ticks := 0
) -> void:
	var viewer: Node = load("res://framework/viewer.gd").new()
	viewer.case_name = name
	viewer.debug_draw = debug_draw
	# Recording wants a clip of an exact length: run to this tick and never settle-quit early,
	# so every engine's clip has the same frame count and the panes stay in sync.
	if record_ticks > 0:
		viewer.max_ticks = record_ticks
		viewer.shot_tick = record_ticks
		viewer.shot_exact = true
	viewer.shot_path = shot
	viewer.shot_tick = shot_tick
	viewer.shot_exact = exact
	# Physics stops at the tick limit, so a later shot tick would never arrive.
	if shot != "":
		viewer.max_ticks = maxi(viewer.max_ticks, shot_tick)
	# Deferred because this can be reached from _ready, and the tree refuses an add_child
	# while it is still setting up the current scene's children.
	_swap_scene.call_deferred(viewer)


func _swap_scene(viewer: Node) -> void:
	var previous := get_tree().current_scene
	get_tree().root.add_child(viewer)
	get_tree().current_scene = viewer
	if previous != null:
		previous.queue_free()


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var title := Label.new()
	title.text = "Godot Rapier — %s physics benchmarks" % _dim.to_upper()
	title.add_theme_font_size_override("font_size", 24)
	column.add_child(title)

	var active := Label.new()
	active.text = "Currently running: %s" % _active_engine
	column.add_child(active)

	column.add_child(HSeparator.new())

	_engine_picker = OptionButton.new()
	for engine in _registered_engines():
		_engine_picker.add_item(engine)
		if engine == _active_engine:
			_engine_picker.select(_engine_picker.item_count - 1)
	column.add_child(_labelled("Physics engine", _engine_picker))

	_case_picker = OptionButton.new()
	for case_name in _available_cases():
		_case_picker.add_item(case_name)
	column.add_child(_labelled("Case", _case_picker))

	_debug_toggle = CheckBox.new()
	_debug_toggle.button_pressed = true
	_debug_toggle.text = "Draw collision shapes (costs frame time — toggle with D in the viewer)"
	column.add_child(_debug_toggle)

	column.add_child(HSeparator.new())

	var run := Button.new()
	run.text = "Run case"
	run.pressed.connect(_on_run)
	column.add_child(run)

	var apply := Button.new()
	apply.text = "Apply engine and restart"
	apply.pressed.connect(_on_apply_engine)
	column.add_child(apply)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(560, 0)
	_status.text = (
		"Timings shown in the viewer are for eyeballing behaviour only — the window renders "
		+ "and runs unbounded. Use ./run_bench.sh for numbers."
	)
	column.add_child(_status)


func _labelled(text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(120, 0)
	row.add_child(label)
	control.custom_minimum_size = Vector2(260, 0)
	row.add_child(control)
	return row


## The servers that actually registered, straight from the setting's enum hint. DEFAULT is
## excluded because it is an alias — selecting it would tell you nothing about what ran.
func _registered_engines() -> Array[String]:
	var found: Array[String] = []
	for property in ProjectSettings.get_property_list():
		if String(property.name) != "physics/%s/physics_engine" % _dim:
			continue
		for entry in String(property.hint_string).split(","):
			var name := entry.strip_edges()
			if name != "" and name != "DEFAULT" and name != "Dummy":
				found.append(name)
	return found


func _available_cases() -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open("res://cases")
	if dir == null:
		return found
	for file_name in dir.get_files():
		# Exported builds see .remap; the editor sees .gd.
		var trimmed := file_name.trim_suffix(".remap")
		if trimmed.ends_with(".gd"):
			found.append(trimmed.trim_suffix(".gd"))
	found.sort()
	return found


func _on_run() -> void:
	if _case_picker.item_count == 0:
		_status.text = "No cases found under res://cases."
		return
	var chosen := _engine_picker.get_item_text(_engine_picker.selected)
	if chosen != _active_engine:
		_status.text = (
			"'%s' is selected but '%s' is running. Press 'Apply engine and restart' first, "
			% [chosen, _active_engine]
			+ "otherwise you would be watching the wrong engine."
		)
		return

	_open_viewer(
		_case_picker.get_item_text(_case_picker.selected), _debug_toggle.button_pressed
	)


func _on_apply_engine() -> void:
	var chosen := _engine_picker.get_item_text(_engine_picker.selected)
	var path := ProjectSettings.globalize_path("res://override.cfg")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_status.text = "Could not write %s (%s)." % [path, FileAccess.get_open_error()]
		return
	# Same mechanism run_bench.sh uses, so the viewer and the sweep select engines the one way.
	file.store_string('[physics]\n\n%s/physics_engine="%s"\n' % [_dim, chosen])
	file.close()

	_status.text = "Wrote override.cfg for %s. Restarting…" % chosen
	OS.set_restart_on_exit(true)
	await get_tree().create_timer(0.4).timeout
	get_tree().quit()
