extends Node2D
## 88-key MIDI waterfall with audio. "Import MIDI" loads a file; the slider sets playback BPM.

const MidiParser := preload("res://midi_parser.gd")
const SoundFont := preload("res://soundfont.gd")
const VisualDrawer := preload("res://visual_drawer.gd")
const LOW := 21  # A0
const HIGH := 108  # C8
const BLACK := [1, 3, 6, 8, 10]
## C..B, red to purple with no wrap, so B -> next C is a hard break. Black-key entries are in-betweens;
## black keys themselves draw split in their neighbors' colors.
const PALETTE: Array[Color] = [
	Color("ff3030"), Color("ff6a1a"), Color("ff9f1a"), Color("ffc81a"), Color("f5e623"), Color("4cd13a"),
	Color("2cc47a"), Color("1fb5b0"), Color("2a8fe0"), Color("3d5ef0"), Color("6a3cf0"), Color("9b2fd6"),
]
const CHANNEL_COLORS: Array[Color] = [
	Color("3d8bf0"), Color("3ccf6e"), Color("ff9f1a"), Color("ff3fa4"), Color("9b5cf6"), Color("1fb5b0"), Color("f5e623"), Color("ff3030"),
]
const NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
const VOICE_BUDGET := 112  # of 128 polyphony slots
const GLOW := 1.2  # HDR boost for things that should bloom
const LEAD_IN := 2.0  # seconds before the first beat so notes fall into view

@export_file("*.mid", "*.midi") var midi_path := ""  # optional song to open at launch
@export_global_dir var soundfont_dir := "C:/Users/Gavin/Music/Tune-O-Keys/Soundfonts"
@export var pixels_per_second := 200.0
@export var keyboard_height := 120.0

var song := {notes = [], beats = [], bpm = 120.0, beats_per_bar = 4}
var speed := 1.0  # target BPM / file BPM
var time := -LEAD_IN
var next_hit := 0
var voices := []  # [note, stream id, volume_db] of held notes, oldest first
var fading := []  # [stream id, from_db, start msec] in their release fade, oldest first; they still hold a slot
var sustain := true  # follow the file's CC64 pedal; off = notes stop at key release
var note_alpha := 1.0
# Draw layers, back to front: self (backdrop, redrawn on change) > beats > notes (one instanced draw)
# > note labels > keyboard (redrawn only when lit keys change) > particles.
var beats_layer := Node2D.new()
var notes_mm := MultiMeshInstance2D.new()
var labels_layer := Node2D.new()
# Keyboard in four layers so the 88-key bed (and its labels) is drawn once, and only the few lit keys
# redraw as notes hit: white bed > lit whites > black bed (+ strike line) > lit blacks.
var white_bed := Node2D.new()
var white_lit := Node2D.new()
var black_bed := Node2D.new()
var black_lit := Node2D.new()
var note_buf := PackedFloat32Array()  # multimesh buffer: 16 floats per note tile
var label_items := []  # [rect, note index] drawn by labels_layer this frame
var label_lines := {}  # pitch*100+size -> [TextLine name, TextLine octave]
var lit_keys := PackedInt32Array()  # signature of the lit keys last drawn
var lit_notes := {}  # pitch -> sounding note index, for the keyboard
var starts := PackedFloat64Array()  # note start times, for jumping straight to on-screen notes
var max_len := 0.0  # longest note, so the search window never misses a long held note
# Per-note caches read by the per-frame loop (dictionary lookups there were the main cost).
var n_end := PackedFloat64Array()  # when each note stops sounding (and its key stops glowing), under the Pedal setting
var n_key_end := PackedFloat64Array()  # key release: the falling block shows only the key press
var n_pitch := PackedInt32Array()
var n_col := PackedFloat32Array()  # 6 per note: left r, g, b, right r, g, b
var n_dark_ink := PackedByteArray()  # 1 = label in black ink (bright fill)
var key_x := PackedFloat32Array()  # per MIDI pitch: lane left edge, width (0 = off the keyboard)
var key_w := PackedFloat32Array()
var release_sec := 0.0  # ring-out after key/pedal release; 0 = each sample's own SoundFont release
var key_rects := {}  # pitch -> Rect2
var bursts := {}  # pitch -> CPUParticles2D
var label_size := 8
var zones := []  # SoundFont.load_zones() result, or one built-in tone zone
var playback: AudioStreamPlaybackPolyphonic
var font_picker: OptionButton
var bpm_slider: HSlider
var bpm_label: Label
var playing := true
var duration := 0.0
var scrubbing := false
var play_button: Button
var timeline: HSlider
var time_label: Label
var drawer: VisualDrawer
var vis: Dictionary  # drawer.vis: live visual settings
var env: Environment
# Live MIDI keyboard: plays alongside file playback.
var midi_picker: OptionButton
var live_held := {}  # pitch -> true while the physical key is down (lights the key)
var live_voices := {}  # pitch -> [stream id, volume_db] sounding from a held key
var live_sustained := {}  # pitch -> [stream id, volume_db] key up, held by the pedal
var live_pedal := false
# FX rack: SoundFont audio -> "Piano_FX" bus (delay, reverb) -> Master (hard limiter).
var fx_bus := -1
var fx_delay := AudioEffectDelay.new()
var fx_reverb := AudioEffectReverb.new()
const DELAY_BEATS := [0.25, 0.5, 0.75, 1.0, 1.5, 2.0]  # 1/16 .. 1/2, in quarter-note beats


## Two colors per pitch: [left, right]. Naturals repeat one hue; sharps split their neighbors.
static func pitch_colors(pitch: int) -> Array[Color]:
	var s := pitch % 12
	if s in BLACK:
		return [_hue(s - 1), _hue(s + 1)]
	return [_hue(s), _hue(s)]


static func _hue(semitone: int) -> Color:
	return PALETTE[semitone]


func _ready() -> void:
	# Bloom: only colors pushed past 1.0 by _glow() (notes, lit keys, particles) cross the threshold.
	# The OpenGL fallback (old GPUs) shows HDR 2D canvases washed out, so bloom is Forward+ only.
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		get_viewport().use_hdr_2d = false
	env = Environment.new()
	env.background_mode = Environment.BG_CANVAS
	env.glow_enabled = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = 1.0
	var world := WorldEnvironment.new()
	world.environment = env
	add_child(world)
	var quad := ArrayMesh.new()  # unit quad, UV (0,0) top-left; each instance scales it to a note
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)])
	quad.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = quad
	notes_mm.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://note_tile.gdshader")
	notes_mm.material = mat
	beats_layer.draw.connect(_draw_beats)
	labels_layer.draw.connect(_draw_note_labels)
	white_bed.draw.connect(_draw_key_bed.bind(white_bed, false))
	white_lit.draw.connect(_draw_lit_keys.bind(white_lit, false))
	black_bed.draw.connect(_draw_key_bed.bind(black_bed, true))
	black_lit.draw.connect(_draw_lit_keys.bind(black_lit, true))
	for layer in [beats_layer, notes_mm, labels_layer, white_bed, white_lit, black_bed, black_lit]:
		add_child(layer)
	var poly := AudioStreamPolyphonic.new()
	poly.polyphony = 128  # engine max
	var player := AudioStreamPlayer.new()
	player.stream = poly
	player.volume_db = -6.0  # headroom: full-scale piano samples clip when sustained chords stack
	var limiter := AudioEffectHardLimiter.new()  # dense pedalled chords still sum past 0 dB; limit, don't clip
	limiter.ceiling_db = -0.5
	AudioServer.add_bus_effect(0, limiter)
	fx_bus = AudioServer.get_bus_index("Piano_FX")
	if fx_bus < 0:  # created once per run; reloading the scene reuses it
		fx_bus = AudioServer.bus_count
		AudioServer.add_bus()
		AudioServer.set_bus_name(fx_bus, "Piano_FX")
		AudioServer.set_bus_send(fx_bus, "Master")
		AudioServer.add_bus_effect(fx_bus, fx_delay, 0)
		AudioServer.add_bus_effect(fx_bus, fx_reverb, 1)
	else:
		fx_delay = AudioServer.get_bus_effect(fx_bus, 0)
		fx_reverb = AudioServer.get_bus_effect(fx_bus, 1)
	player.bus = "Piano_FX"
	add_child(player)
	player.play()
	playback = player.get_stream_playback()

	var fade := Gradient.new()  # particles fade out over their life
	fade.set_color(1, Color(1, 1, 1, 0))
	for p in range(LOW, HIGH + 1):
		var b := CPUParticles2D.new()
		b.emitting = false
		b.one_shot = true
		b.color_ramp = fade
		add_child(b)
		bursts[p] = b
	_build_ui()
	_apply_vis()
	get_viewport().size_changed.connect(_layout)
	_layout()
	if midi_path:
		load_midi(midi_path)
	else:
		_set_playing(false)
		_set_bpm(bpm_slider.value)


func _build_ui() -> void:
	var ui := CanvasLayer.new()
	add_child(ui)
	var glass := StyleBoxFlat.new()
	glass.bg_color = Color(0.05, 0.06, 0.08, 0.82)
	glass.set_corner_radius_all(10)
	glass.set_content_margin_all(8)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", glass)
	ui.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE, Control.PRESET_MODE_MINSIZE, 8)
	var rows := VBoxContainer.new()
	panel.add_child(rows)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	rows.add_child(bar)
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.mid, *.midi ; MIDI files"])
	dialog.use_native_dialog = true
	dialog.file_selected.connect(load_midi)
	ui.add_child(dialog)
	var import := Button.new()
	import.text = "Import MIDI"
	import.pressed.connect(func(): dialog.popup_centered_ratio(0.6))
	bar.add_child(import)
	font_picker = OptionButton.new()
	font_picker.custom_minimum_size = Vector2(220, 0)
	font_picker.clip_text = true  # long SoundFont names would push header buttons off screen
	font_picker.add_item("Built-in tone")
	var last: String = _load_setting("soundfont", "")
	var remembered := 0
	var piano := 0
	for path in SoundFont.find_fonts(soundfont_dir):
		font_picker.add_item(path.get_file().get_basename())
		var i := font_picker.item_count - 1
		font_picker.set_item_metadata(i, path)
		font_picker.set_item_tooltip(i, path)
		if path == last:
			remembered = i
		if piano == 0 and "piano" in path.get_file().to_lower():
			piano = i
	font_picker.item_selected.connect(_select_soundfont)
	bar.add_child(font_picker)
	# Launch font: the one picked last time, else the first with "piano" in its name, else the first.
	font_picker.select(remembered if remembered else (piano if piano else mini(1, font_picker.item_count - 1)))
	_select_soundfont(font_picker.selected)
	bpm_slider = HSlider.new()
	bpm_slider.min_value = 30
	bpm_slider.max_value = 300
	bpm_slider.step = 1
	bpm_slider.value = 120
	bpm_slider.custom_minimum_size = Vector2(240, 0)
	bpm_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bpm_slider.value_changed.connect(_set_bpm)
	bar.add_child(bpm_slider)
	var pedal := CheckButton.new()
	pedal.text = "Pedal"
	pedal.button_pressed = sustain
	pedal.toggled.connect(func(on):
		sustain = on
		_cache_notes())
	bar.add_child(pedal)
	bpm_label = Label.new()
	bar.add_child(bpm_label)
	drawer = VisualDrawer.new()
	vis = drawer.vis
	drawer.changed.connect(_apply_vis)
	drawer.visible = false
	ui.add_child(drawer)
	drawer.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	drawer.offset_left = -408
	drawer.offset_right = -8
	drawer.offset_top = 136  # below the three header rows
	drawer.offset_bottom = -keyboard_height - 8
	var visuals := Button.new()
	visuals.text = "Visual Settings"
	visuals.toggle_mode = true
	visuals.toggled.connect(func(on): drawer.visible = on)

	var transport := HBoxContainer.new()
	transport.add_theme_constant_override("separation", 10)
	rows.add_child(transport)
	play_button = Button.new()
	play_button.custom_minimum_size = Vector2(70, 0)
	play_button.pressed.connect(func():
		if not playing and time >= duration:
			_seek(-LEAD_IN)  # Play at the end restarts
		_set_playing(not playing))
	transport.add_child(play_button)
	timeline = HSlider.new()
	timeline.step = 0.01
	timeline.custom_minimum_size = Vector2(440, 0)
	timeline.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	timeline.value_changed.connect(_seek)
	timeline.drag_started.connect(func(): scrubbing = true)
	timeline.drag_ended.connect(func(_changed): scrubbing = false)
	transport.add_child(timeline)
	time_label = Label.new()
	transport.add_child(time_label)
	var alpha_label := Label.new()
	alpha_label.text = "Notes"
	transport.add_child(alpha_label)
	var alpha_slider := HSlider.new()
	alpha_slider.min_value = 0.05
	alpha_slider.max_value = 1.0
	alpha_slider.step = 0.05
	alpha_slider.value = note_alpha
	alpha_slider.custom_minimum_size = Vector2(120, 0)
	alpha_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	alpha_slider.value_changed.connect(func(v):
		note_alpha = v
		notes_mm.material.set_shader_parameter("alpha", v))
	transport.add_child(alpha_slider)
	var release_label := Label.new()
	transport.add_child(release_label)
	var release_slider := HSlider.new()
	release_slider.min_value = 0.0
	release_slider.max_value = 6.0
	release_slider.step = 0.05
	release_slider.custom_minimum_size = Vector2(140, 0)
	release_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var show_release := func(v: float):
		release_label.text = "Sustain: font" if v <= 0.0 else "Sustain %.1fs" % v
	release_slider.value_changed.connect(func(v):
		release_sec = v
		show_release.call(v))
	release_slider.value = release_sec
	show_release.call(release_sec)
	transport.add_child(release_slider)

	var midi_row := HBoxContainer.new()
	midi_row.add_theme_constant_override("separation", 10)
	rows.add_child(midi_row)
	var midi_label := Label.new()
	midi_label.text = "MIDI Input"
	midi_row.add_child(midi_label)
	midi_picker = OptionButton.new()
	midi_picker.custom_minimum_size = Vector2(260, 0)
	midi_picker.clip_text = true
	midi_row.add_child(midi_picker)
	var refresh := Button.new()
	refresh.text = "Refresh Devices"
	refresh.pressed.connect(_refresh_midi)
	midi_row.add_child(refresh)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	midi_row.add_child(spacer)
	midi_row.add_child(visuals)
	_refresh_midi()


func load_midi(path: String) -> void:
	var parsed := MidiParser.parse(FileAccess.get_file_as_bytes(path))
	if parsed.is_empty():
		push_error("Can't load MIDI file: %s" % path)
		return
	song = parsed
	song.notes.sort_custom(func(x, y): return x.start_sec < y.start_sec)
	duration = 0.0
	starts = PackedFloat64Array()
	for n in song.notes:
		duration = maxf(duration, n.end_sec)
		starts.append(n.start_sec)
	_cache_notes()
	song.beats = PackedFloat64Array(song.beats)
	timeline.max_value = duration
	_seek(-LEAD_IN)
	_set_playing(true)
	bpm_slider.set_value_no_signal(clampf(song.bpm, 30, 300))
	_set_bpm(bpm_slider.value)


## Jump to song time t: cut every sounding voice and resume triggering from the first note at/after t.
func _seek(t: float) -> void:
	for v in voices:
		playback.stop_stream(v[1])
	for f in fading:
		playback.stop_stream(f[0])
	voices.clear()
	fading.clear()
	time = t
	next_hit = starts.bsearch(t)  # first note starting at/after t


func _set_playing(on: bool) -> void:
	playing = on
	play_button.text = "Pause" if on else "Play"
	if not on:
		for v in voices:
			_release(v[1], v[2], v[3])
		voices.clear()


func _select_soundfont(index: int) -> void:
	zones = [] if index == 0 else SoundFont.load_zones(font_picker.get_item_metadata(index))
	if index > 0 and zones:
		_save_setting("soundfont", font_picker.get_item_metadata(index))
	if zones.is_empty():
		font_picker.select(0)
		zones = [{lo = 0, hi = 127, vlo = 0, vhi = 127, root = 60, cents = 0, release = 0.12, stream = _synth_tone()}]


const SETTINGS := "user://settings.cfg"


static func _load_setting(key: String, fallback: Variant) -> Variant:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)  # missing file on first launch -> fallback
	return cfg.get_value("app", key, fallback)


static func _save_setting(key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("app", key, value)
	cfg.save(SETTINGS)


func _set_bpm(target: float) -> void:
	speed = target / song.bpm
	if vis:
		_apply_fx()  # tempo-synced delay follows the playback BPM
	bpm_label.text = "%d BPM  (file %d, x%.2f)" % [target, roundi(song.bpm), speed]


func _layout() -> void:
	var size := get_viewport_rect().size
	var ww := size.x / 52.0  # 52 white keys in 88
	var top := size.y - keyboard_height
	label_size = maxi(6, int(ww * 0.42))
	var wi := 0
	key_x.resize(128)
	key_w.resize(128)
	for p in range(LOW, HIGH + 1):
		if p % 12 in BLACK:
			key_rects[p] = Rect2(wi * ww - ww * 0.3, top, ww * 0.6, keyboard_height * 0.62)
		else:
			key_rects[p] = Rect2(wi * ww, top, ww, keyboard_height)
			wi += 1
		bursts[p].position = Vector2(key_rects[p].get_center().x, top)
		key_x[p] = key_rects[p].position.x + 1
		key_w[p] = key_rects[p].size.x - 2
	label_lines.clear()
	queue_redraw()
	for layer in [white_bed, white_lit, black_bed, black_lit]:
		layer.queue_redraw()


func _process(delta: float) -> void:
	if playing:
		time += delta * speed
		if time > duration + 1.0:
			_set_playing(false)
	if not scrubbing:
		timeline.set_value_no_signal(maxf(time, 0.0))
	time_label.text = "%s / %s" % [_clock(time), _clock(duration)]
	while next_hit < song.notes.size() and song.notes[next_hit].start_sec <= time:
		var n: Dictionary = song.notes[next_hit]
		next_hit += 1
		if not bursts.has(n.pitch):
			continue
		if vis.particles and vis.particle_amount > 0:
			bursts[n.pitch].color = _glow(_note_colors(n)[0])
			bursts[n.pitch].restart()
		_start_voice(n)
	for i in range(voices.size() - 1, -1, -1):
		if _end(voices[i][0]) <= time:
			_release(voices[i][1], voices[i][2], voices[i][3])
			voices.remove_at(i)
	# Damper fades: one loop instead of a tween per note.
	var now := Time.get_ticks_msec()
	for i in range(fading.size() - 1, -1, -1):
		var f: Array = fading[i]
		var k: float = (now - f[2]) / (f[3] * 1000.0)
		if k >= 1.0:
			playback.stop_stream(f[0])
			fading.remove_at(i)
		else:
			playback.set_stream_volume(f[0], lerpf(f[1], -60.0, k))
	_update_notes()
	beats_layer.queue_redraw()


## Play note n. Past VOICE_BUDGET, cut the oldest fading voice (else oldest held): a stopped slot only
## frees on the audio thread's next mix, so the spare slots above the budget absorb same-frame chords.
func _start_voice(n: Dictionary) -> int:
	var v := _play(n.pitch, n.velocity)
	voices.append([n, v[0], v[1], v[2]])
	return v[0]


## Sound one pitch through the SoundFont; returns [stream id, volume_db, font release s]. Shared by file and live notes.
## Velocity follows the MIDI/SoundFont curve 40*log10(v/127) dB (64 -> -12 dB); Velocity Sensitivity scales it.
func _play(pitch: int, velocity: int) -> Array:
	while fading.size() + voices.size() + live_voices.size() + live_sustained.size() >= VOICE_BUDGET and (fading or voices):
		playback.stop_stream(fading.pop_front()[0] if fading else voices.pop_front()[1])
	var db: float = 2.0 * linear_to_db(velocity / 127.0) * vis.vel_curve
	var z := SoundFont.pick(zones, pitch, velocity)
	return [playback.play_stream(z.stream, 0.0, db, pow(2.0, ((pitch - z.root) * 100 + z.cents) / 1200.0)), db, z.get("release", 0.12)]


## Reopen OS MIDI inputs and list them. Godot opens every input at once; the picker only filters.
func _refresh_midi() -> void:
	OS.close_midi_inputs()
	OS.open_midi_inputs()
	var devices := OS.get_connected_midi_inputs()
	midi_picker.clear()
	midi_picker.add_item("All MIDI inputs" if devices else "No MIDI devices found")
	for d in devices:
		midi_picker.add_item(d)


func _input(event: InputEvent) -> void:
	var m := event as InputEventMIDI
	if m == null or (midi_picker.selected > 0 and m.device != midi_picker.selected - 1):
		return
	match m.message:
		MIDI_MESSAGE_NOTE_ON:
			if m.velocity > 0:
				_live_on(m.pitch, m.velocity)
			else:
				_live_off(m.pitch)  # many keyboards send note-on velocity 0 as note-off
		MIDI_MESSAGE_NOTE_OFF:
			_live_off(m.pitch)
		MIDI_MESSAGE_CONTROL_CHANGE:
			if m.controller_number == 64:
				_live_pedal(m.controller_value >= 64)


func _live_on(pitch: int, velocity: int) -> void:
	_live_cut(pitch)  # re-strike: damp the previous sound of this key first
	live_voices[pitch] = _play(pitch, velocity)
	live_held[pitch] = true
	if bursts.has(pitch) and vis.particles and vis.particle_amount > 0:
		bursts[pitch].color = _glow(pitch_colors(pitch)[0])
		bursts[pitch].restart()
	_redraw_lit()


func _live_off(pitch: int) -> void:
	live_held.erase(pitch)
	if live_voices.has(pitch):
		if live_pedal and sustain:
			live_sustained[pitch] = live_voices[pitch]
		else:
			_release(live_voices[pitch][0], live_voices[pitch][1], live_voices[pitch][2])
		live_voices.erase(pitch)
	_redraw_lit()


func _live_pedal(down: bool) -> void:
	live_pedal = down
	if not down:
		for v in live_sustained.values():
			_release(v[0], v[1], v[2])
		live_sustained.clear()


func _live_cut(pitch: int) -> void:
	for held in [live_voices, live_sustained]:
		if held.has(pitch):
			_release(held[pitch][0], held[pitch][1], held[pitch][2])
			held.erase(pitch)


func _redraw_lit() -> void:
	white_lit.queue_redraw()
	black_lit.queue_redraw()


## When note n stops sounding: pedal release if Sustain is on, else key release.
func _end(n: Dictionary) -> float:
	return n.end_sec if sustain else n.key_end


static func _clock(sec: float) -> String:
	var s := maxi(0, int(sec))
	return "%d:%02d" % [s / 60, s % 60]


## Damper: exponential gain drop (linear in dB) over the font's release time, or the Sustain slider's when
## it's above "font". Can't outlast the sample's own recorded tail.
func _release(id: int, from_db: float, font_release: float) -> void:
	fading.append([id, from_db, Time.get_ticks_msec(), font_release if release_sec <= 0.0 else release_sec])


## Collect on-screen notes into the instanced note buffer, note labels and the lit-key set.
func _update_notes() -> void:
	var top := get_viewport_rect().size.y - keyboard_height
	var active := {}  # pitch -> sounding note index
	var whites := PackedInt32Array()  # black-key notes go last so neighbors don't cover them
	var blacks := PackedInt32Array()
	var horizon := time + top / pixels_per_second
	var count := starts.size()
	var i := starts.bsearch(time - max_len)  # no note starting earlier can still be on screen
	while i < count and starts[i] <= horizon:
		var p := n_pitch[i]
		if n_end[i] >= time and key_w[p] > 0.0:
			if starts[i] <= time:
				active[p] = i  # key glows while the note sounds, pedal hold included
			if n_key_end[i] >= time:  # block shows only the key press
				if p % 12 in BLACK:
					blacks.append(i)
				else:
					whites.append(i)
		i += 1
	whites.append_array(blacks)
	var shown := whites.size()
	var mm := notes_mm.multimesh
	if shown > mm.instance_count:  # grow capacity in steps; resizing every frame is slow
		mm.instance_count = shown + 256
		note_buf.resize(mm.instance_count * 16)
	label_items.clear()
	var label_min: float = label_size * vis.label_scale * 2.4
	for k in shown:
		var j := whites[k]
		var p := n_pitch[j]
		var y0: float = top - (n_key_end[j] - time) * pixels_per_second
		var h: float = minf(top, top - (starts[j] - time) * pixels_per_second) - y0
		var o := k * 16
		# Transform2D (scale to the tile, move to its corner), then color, then custom data.
		note_buf[o] = key_w[p]
		note_buf[o + 3] = key_x[p]
		note_buf[o + 5] = h
		note_buf[o + 7] = y0
		note_buf[o + 8] = n_col[j * 6]
		note_buf[o + 9] = n_col[j * 6 + 1]
		note_buf[o + 10] = n_col[j * 6 + 2]
		note_buf[o + 11] = 1.0
		note_buf[o + 12] = n_col[j * 6 + 3]
		note_buf[o + 13] = n_col[j * 6 + 4]
		note_buf[o + 14] = n_col[j * 6 + 5]
		note_buf[o + 15] = 1.0 if p % 12 in BLACK else 0.0
		if vis.labels and h >= label_min:
			label_items.append([Rect2(key_x[p], y0, key_w[p], h), j])
	mm.buffer = note_buf
	mm.visible_instance_count = shown
	labels_layer.queue_redraw()

	# Keyboard only redraws when the set of lit keys (or which note lights them) changes.
	var lit := PackedInt32Array(active.values())
	if lit != lit_keys:
		lit_keys = lit
		lit_notes = active
		white_lit.queue_redraw()
		black_lit.queue_redraw()


func _draw() -> void:
	var size := get_viewport_rect().size
	_draw_backdrop(size, size.y - keyboard_height)


func _draw_beats() -> void:
	if not vis.beat_lines:
		return
	var size := get_viewport_rect().size
	var top := size.y - keyboard_height
	for i in range(maxi(0, song.beats.bsearch(time) - 1), song.beats.size()):  # beat lines; bar lines brighter
		var y: float = top - (song.beats[i] - time) * pixels_per_second
		if y > top:
			continue
		if y < 0.0:
			break
		var bar: bool = i % song.beats_per_bar == 0
		beats_layer.draw_line(Vector2(0, y), Vector2(size.x, y), Color(1, 1, 1, vis.beat_alpha * (1.0 if bar else 0.5)), 3.0 if bar else 1.5)


func _draw_note_labels() -> void:
	var font_size := int(label_size * vis.label_scale)
	var dark := Color(0, 0, 0, note_alpha)
	var light := Color(1, 1, 1, note_alpha)
	var neon: bool = vis.note_style == 2
	for item in label_items:
		var j: int = item[1]
		_draw_label(labels_layer, item[0], n_pitch[j], dark if n_dark_ink[j] and not neon else light, font_size)


func _draw_backdrop(size: Vector2, top: float) -> void:
	var seams := [0.0]
	for p in range(24, HIGH + 1, 12):  # left edge of C1..C8
		seams.append(key_rects[p].position.x)
	seams.append(size.x)
	match vis.backdrop:
		0:  # one solid band per octave, alternating; contrast 0.5 = #22262e / #2e333d
			var odd := Color("22262e").lerp(Color("2e333d"), vis.octave_contrast * 2.0)
			for i in seams.size() - 1:
				draw_rect(Rect2(seams[i], 0, seams[i + 1] - seams[i], top), odd if i % 2 else Color("22262e"))
		1:  # a lane per key in its pitch color; black-key lanes split, drawn over the whites
			for black in [false, true]:
				for p in key_rects:
					if (p % 12 in BLACK) == black:
						var r: Rect2 = key_rects[p]
						var c := pitch_colors(p)
						var half := r.size.x / 2.0
						draw_rect(Rect2(r.position.x, 0, half, top), c[0].darkened(0.35))
						draw_rect(Rect2(r.position.x + half, 0, half, top), c[1].darkened(0.35))
		2:
			draw_rect(Rect2(0, 0, size.x, top), Color(0.02, 0.02, 0.03))
		3:
			draw_rect(Rect2(0, 0, size.x, top), vis.backdrop_color)
	if vis.seam_width > 0.0:
		for x in seams.slice(1, -1):
			draw_line(Vector2(x, 0), Vector2(x, top), Color.BLACK, vis.seam_width)
	var mid_c: Rect2 = key_rects[60]  # home anchor
	draw_rect(Rect2(mid_c.position.x + 4, 0, mid_c.size.x - 5, top), Color("ffc531"), false, 3.0)  # gold


## Fill colors [left, right] for a note under the current scheme; only chromatic splits black keys.
func _note_colors(n: Dictionary) -> Array[Color]:
	match vis.note_scheme:
		1:
			var c := CHANNEL_COLORS[n.get("channel", 0) % CHANNEL_COLORS.size()]
			return [c, c]
		2:
			return [vis.note_color, vis.note_color]
		3:
			var c := Color("2a6bff").lerp(Color("ff3fa4"), n.velocity / 127.0)
			return [c, c]
	return pitch_colors(n.pitch)


func _draw_key_bed(cv: CanvasItem, black: bool) -> void:
	var style: int = vis.key_style
	for p in key_rects:
		if (p % 12 in BLACK) != black:
			continue
		var r: Rect2 = key_rects[p]
		match style:
			0:
				cv.draw_rect(r, Color(0.08, 0.08, 0.1) if black else Color.WHITE)
				cv.draw_rect(r, Color.BLACK, false, 1.0)
			1:  # flat: soft greys, hairline gaps
				cv.draw_rect(r.grow(-0.5), Color(0.28, 0.28, 0.32) if black else Color(0.9, 0.9, 0.92))
			2:  # glass: see-through with a light rim
				cv.draw_rect(r, Color(0, 0, 0, 0.55) if black else Color(1, 1, 1, 0.18))
				cv.draw_rect(r, Color(1, 1, 1, 0.35), false, 1.0)
			3:  # LED: every key shows its pitch color dimly
				var dim := pitch_colors(p)
				_draw_split(cv, r, [dim[0].darkened(0.6), dim[1].darkened(0.6)], Color.BLACK, 1.0)
		if _key_named(p):
			_draw_label(cv, r, p, Color.WHITE if black or style >= 2 else Color(0.1, 0.1, 0.1), label_size)
	if black and vis.strike:
		var size := get_viewport_rect().size
		var y: float = size.y - keyboard_height - vis.strike_width / 2.0
		cv.draw_line(Vector2(0, y), Vector2(size.x, y), vis.strike_color, vis.strike_width)


func _draw_lit_keys(cv: CanvasItem, black: bool) -> void:
	if vis.key_tint <= 0.0:
		return
	var lit := lit_notes.duplicate()
	for p in live_held:  # live keys glow only while physically held (not while the pedal holds the sound); a falling note on the same key wins
		if not lit.has(p) and key_rects.has(p):
			lit[p] = -1
	for p in lit:
		if (p % 12 in BLACK) != black:
			continue
		var r: Rect2 = key_rects[p]
		var c := pitch_colors(p) if lit[p] < 0 else _note_colors(song.notes[lit[p]])
		_draw_split(cv, r, [_glow(Color(c[0], vis.key_tint)), _glow(Color(c[1], vis.key_tint))], Color(0, 0, 0, 0.6))
		if _key_named(p):
			var light_ink: bool = (black or vis.key_style >= 2) and vis.key_tint < 0.5
			_draw_label(cv, r, p, Color.WHITE if light_ink else Color(0.1, 0.1, 0.1), label_size)


func _key_named(p: int) -> bool:
	return vis.key_names == 0 or (vis.key_names == 1 and p % 12 == 0)


## Push node-level settings (glow, note shader, particles) after a drawer change, and redraw every layer.
func _apply_vis() -> void:
	env.glow_enabled = vis.glow > 0.0  # skip the bloom passes entirely when it's off
	env.glow_intensity = vis.glow
	var mat: ShaderMaterial = notes_mm.material
	mat.set_shader_parameter("radius", vis.corner)
	mat.set_shader_parameter("border", vis.border)
	mat.set_shader_parameter("border_white", vis.border_color)
	mat.set_shader_parameter("alpha", note_alpha)
	mat.set_shader_parameter("glow", GLOW)
	mat.set_shader_parameter("style", vis.note_style)
	mat.set_shader_parameter("linear", get_viewport().use_hdr_2d)
	for b in bursts.values():
		b.amount = maxi(1, vis.particle_amount)
		b.lifetime = vis.particle_life
		b.direction = Vector2.UP
		match vis.particle_type:
			0:  # sparks
				b.explosiveness = 1.0
				b.spread = 50.0
				b.initial_velocity_min = 80.0
				b.initial_velocity_max = 180.0
				b.gravity = Vector2(0, 400)
				b.scale_amount_min = 2.0
				b.scale_amount_max = 4.0
			1:  # rising flame/smoke
				b.explosiveness = 0.5
				b.spread = 15.0
				b.initial_velocity_min = 30.0
				b.initial_velocity_max = 70.0
				b.gravity = Vector2(0, -60)
				b.scale_amount_min = 3.0
				b.scale_amount_max = 7.0
			2:  # explosion burst
				b.explosiveness = 1.0
				b.spread = 180.0
				b.initial_velocity_min = 150.0
				b.initial_velocity_max = 320.0
				b.gravity = Vector2(0, 200)
				b.scale_amount_min = 2.0
				b.scale_amount_max = 5.0
	label_lines.clear()
	_cache_notes()
	_apply_fx()
	queue_redraw()
	for layer in [white_bed, white_lit, black_bed, black_lit]:
		layer.queue_redraw()


## Push FX rack settings onto the bus effects. The effects read these properties every mix, so changes
## are live; the bus is never rebuilt.
func _apply_fx() -> void:
	AudioServer.set_bus_effect_enabled(fx_bus, 0, vis.delay_on)
	AudioServer.set_bus_effect_enabled(fx_bus, 1, vis.reverb_on)
	var ms: float = vis.delay_ms
	if vis.delay_sync == 0:
		ms = 60000.0 / (song.bpm * speed) * DELAY_BEATS[vis.delay_beat]
	ms = clampf(ms, 10.0, 2000.0)  # slider range; very slow tempo-synced halves would run longer
	# Godot's feedback line also echoes the dry signal (first echo gets + Feedback x Dry), so tap 1 adds
	# only the rest: first echo = Wet, each repeat = previous x Feedback (darkened by Tone). Measured with
	# a click through the bus. Wet below Feedback x Dry can't be reached, so feedback is capped at Wet/Dry.
	var dry: float = vis.delay_dry
	var wet: float = vis.delay_wet
	var fb: float = vis.delay_feedback if dry <= 0.0 else minf(vis.delay_feedback, wet / dry)
	var tap: float = wet - fb * dry
	fx_delay.dry = dry
	fx_delay.tap1_active = tap > 0.001
	fx_delay.tap1_delay_ms = ms
	fx_delay.tap1_level_db = linear_to_db(maxf(tap, 0.0001))
	fx_delay.tap1_pan = 0.0
	fx_delay.tap2_active = false
	fx_delay.feedback_active = fb > 0.0
	fx_delay.feedback_delay_ms = ms
	fx_delay.feedback_level_db = linear_to_db(maxf(fb, 0.0001))
	fx_delay.feedback_lowpass = vis.delay_tone
	fx_reverb.room_size = vis.reverb_room
	fx_reverb.damping = vis.reverb_damping
	fx_reverb.spread = vis.reverb_spread
	fx_reverb.dry = vis.reverb_dry
	fx_reverb.wet = vis.reverb_wet
	fx_reverb.predelay_msec = vis.reverb_predelay
	fx_reverb.hipass = 0.0


## Rebuild per-note caches: on load, Pedal toggle and color-scheme changes.
func _cache_notes() -> void:
	var count: int = song.notes.size()
	n_end.resize(count)
	n_key_end.resize(count)
	n_pitch.resize(count)
	n_col.resize(count * 6)
	n_dark_ink.resize(count)
	max_len = 0.0
	for i in count:
		var n: Dictionary = song.notes[i]
		n_end[i] = _end(n)
		n_key_end[i] = n.key_end
		n_pitch[i] = n.pitch
		max_len = maxf(max_len, n_end[i] - n.start_sec)
		var c := _note_colors(n)
		for k in 3:
			n_col[i * 6 + k] = c[0][k]
			n_col[i * 6 + 3 + k] = c[1][k]
		n_dark_ink[i] = 1 if (c[0].get_luminance() + c[1].get_luminance()) / 2.0 > 0.5 else 0
	lit_keys = PackedInt32Array()  # force a keyboard redraw with the new colors


## Note name over octave at the bottom of r: "F#4" on one line is wider than a black key.
## Shaped text is cached per pitch and size; shaping every frame was a large share of draw time.
func _draw_label(cv: CanvasItem, r: Rect2, pitch: int, ink: Color, font_size: int) -> void:
	var key := pitch * 100 + font_size
	if not label_lines.has(key):
		var lines := []
		for text in [NAMES[pitch % 12], str(floori(pitch / 12.0) - 1)]:
			var line := TextLine.new()
			line.add_string(text, ThemeDB.fallback_font, font_size)
			lines.append(line)
		label_lines[key] = lines
	var rows: Array = label_lines[key]
	for k in 2:
		var line: TextLine = rows[k]
		var baseline := r.end.y - font_size * (1.4 if k == 0 else 0.4)
		line.draw(cv.get_canvas_item(), Vector2(r.position.x + (r.size.x - line.get_line_width()) / 2.0, baseline - line.get_line_ascent()), ink)


## Push a color past 1.0 so the HDR glow picks it up.
static func _glow(c: Color) -> Color:
	return Color(c.r * GLOW, c.g * GLOW, c.b * GLOW, c.a)


func _draw_split(cv: CanvasItem, r: Rect2, c: Array[Color], edge := Color(0, 0, 0, 0.6), width := 1.0) -> void:
	var half := Vector2(r.size.x / 2.0, r.size.y)
	cv.draw_rect(Rect2(r.position, half), c[0])
	cv.draw_rect(Rect2(r.position + Vector2(half.x, 0), half), c[1])
	cv.draw_rect(r, edge, false, width)  # split colors match neighbors; edge keeps shapes apart


## Fallback when no SoundFont loads: one synthesized C4 tone stretched over all keys.
static func _synth_tone() -> AudioStreamWAV:
	var rate := 44100
	var count := rate * 2
	var data := PackedByteArray()
	data.resize(count * 2)
	for i in count:
		var t := i / float(rate)
		var s := sin(TAU * 261.63 * t) + 0.5 * sin(TAU * 523.25 * t) + 0.25 * sin(TAU * 784.88 * t)
		data.encode_s16(i * 2, int(s * 0.5 * exp(-3.0 * t) * minf(1.0, t * 500.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.data = data
	return wav
