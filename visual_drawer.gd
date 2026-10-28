extends PanelContainer
## Right-side settings drawer, two tabs: Visuals (presets + look) and FX Rack (delay, reverb, touch).
## All controls write one shared settings dict.
## The piano roll reads `vis` every frame and listens to `changed` for node-level settings.

signal changed

const BACKDROPS := ["Solid Octave Bands", "Full Pitch Spectrum Lanes", "Pitch Black", "Custom Color"]
const SCHEMES := ["12-Semitone Chromatic", "Track/Channel Mapped", "Single Custom Color", "Velocity Heatmap"]
const NOTE_STYLES := ["Solid Color", "Glass Tile (Inner Highlight)", "Neon Glow"]
const PARTICLE_TYPES := ["Sparks", "Rising Flame/Smoke", "Explosion Burst"]
const KEY_STYLES := ["Classic B&W", "Flat Minimalist", "Glass/Transparent", "Full LED Light"]
const KEY_NAMES := ["All Keys", "C-Keys Only", "None"]
const DELAY_SYNC := ["Tempo Sync (Beats)", "Free (ms)"]
const DELAY_BEATS := ["1/16", "1/8", "1/8 Dotted", "1/4", "1/4 Dotted", "1/2"]
const REVERB_PRESETS := ["Small Room", "Studio Stage", "Concert Hall", "Deep Cathedral", "Shimmer Ambient"]
## Settings each reverb preset loads (the sliders stay free to tweak afterwards).
const REVERB_VALUES := [
	{reverb_room = 0.3, reverb_damping = 0.6, reverb_spread = 0.6, reverb_wet = 0.2, reverb_predelay = 10.0},
	{reverb_room = 0.5, reverb_damping = 0.5, reverb_spread = 0.8, reverb_wet = 0.25, reverb_predelay = 20.0},
	{reverb_room = 0.8, reverb_damping = 0.4, reverb_spread = 1.0, reverb_wet = 0.3, reverb_predelay = 40.0},
	{reverb_room = 0.95, reverb_damping = 0.3, reverb_spread = 1.0, reverb_wet = 0.4, reverb_predelay = 60.0},
	{reverb_room = 0.98, reverb_damping = 0.05, reverb_spread = 1.0, reverb_wet = 0.5, reverb_predelay = 80.0},
]
## Audio keys survive visual presets.
const AUDIO_KEYS := [
	"vel_curve", "delay_on", "delay_sync", "delay_beat", "delay_ms", "delay_feedback", "delay_tone", "delay_dry",
	"delay_wet", "reverb_on", "reverb_preset", "reverb_room", "reverb_damping", "reverb_spread", "reverb_dry",
	"reverb_wet", "reverb_predelay",
]

## Overrides on top of defaults(); "Default" is the launch look.
var presets := {
	"Default": {},
	"Dark Particles": {
		backdrop = 2, glow = 1.6, note_scheme = 3, note_style = 1,
		particle_type = 2, particle_amount = 80, particle_life = 1.2,
	},
	"Flat Minimal": {
		backdrop = 2, note_scheme = 1, note_style = 0, corner = 2.0, border = 0.0,
		glow = 0.0, particles = false, key_style = 1, key_names = 1, beat_alpha = 0.3,
	},
	"Rainbow Lanes": {
		backdrop = 1, note_style = 0, corner = 2.0, border = 2.0, border_color = Color.WHITE, glow = 0.3,
	},
}
var vis := defaults()
var _setters := {}  # key -> Callable(value) that updates its control without emitting


static func defaults() -> Dictionary:
	return {
		backdrop = 0, backdrop_color = Color("22262e"), octave_contrast = 0.5, seam_width = 6.0,
		beat_lines = true, beat_alpha = 0.8,
		note_scheme = 0, note_color = Color("3d8bf0"), corner = 3.0, border = 2.0, border_color = Color.WHITE,
		labels = true, label_scale = 1.0, note_style = 1,
		glow = 0.5, strike = true, strike_color = Color.WHITE, strike_width = 2.0,
		particles = true, particle_type = 0, particle_amount = 16, particle_life = 0.5,
		key_style = 0, key_tint = 1.0, key_names = 0,
		vel_curve = 1.0,
		delay_on = false, delay_sync = 0, delay_beat = 3, delay_ms = 250.0, delay_feedback = 0.35,
		delay_tone = 6000.0, delay_dry = 1.0, delay_wet = 0.35,
		reverb_on = false, reverb_preset = 2, reverb_room = 0.8, reverb_damping = 0.4, reverb_spread = 1.0,
		reverb_dry = 1.0, reverb_wet = 0.3, reverb_predelay = 40.0,
	}


func apply_preset(preset: String) -> void:
	var audio := {}  # audio settings aren't part of a look; visual presets leave them alone
	for k in AUDIO_KEYS:
		audio[k] = vis[k]
	vis.clear()  # keep the same dict: the piano roll holds a reference
	vis.merge(defaults())
	vis.merge(audio, true)
	vis.merge(presets[preset], true)
	for k in _setters:
		_setters[k].call(vis[k])
	changed.emit()


func _ready() -> void:
	var glass := StyleBoxFlat.new()
	glass.bg_color = Color(0.05, 0.06, 0.08, 0.9)
	glass.set_corner_radius_all(10)
	glass.set_content_margin_all(10)
	add_theme_stylebox_override("panel", glass)
	var tabs := TabContainer.new()
	add_child(tabs)
	var box := _page(tabs, "Visuals")

	_title(box, "Presets")
	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	for p in presets:
		var b := Button.new()
		b.text = p
		b.clip_text = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(apply_preset.bind(p))
		grid.add_child(b)

	_title(box, "Background & Grid")
	_option(box, "backdrop", "Backdrop", BACKDROPS)
	_color(box, "backdrop_color", "Custom Color")
	_slider(box, "octave_contrast", "Octave Contrast", 0.0, 1.0, 0.05)
	_slider(box, "seam_width", "C-Seam Width", 0.0, 10.0, 0.5)
	_check(box, "beat_lines", "Beat Lines")
	_slider(box, "beat_alpha", "Beat Opacity", 0.0, 1.0, 0.05)

	_title(box, "Note Blocks")
	_option(box, "note_scheme", "Color Scheme", SCHEMES)
	_color(box, "note_color", "Single Color")
	_option(box, "note_style", "Note Style", NOTE_STYLES)
	_slider(box, "corner", "Corner Radius", 0.0, 16.0, 1.0)
	_slider(box, "border", "Border", 0.0, 5.0, 0.5)
	_color(box, "border_color", "Border Color")
	_check(box, "labels", "Note Labels")
	_slider(box, "label_scale", "Label Size", 0.5, 2.0, 0.1)

	_title(box, "Glow & Particles")
	_slider(box, "glow", "Glow Strength", 0.0, 3.0, 0.05)
	_check(box, "strike", "Strike Line")
	_color(box, "strike_color", "Strike Color")
	_slider(box, "strike_width", "Strike Width", 1.0, 8.0, 0.5)
	_check(box, "particles", "Particles")
	_option(box, "particle_type", "Particle Type", PARTICLE_TYPES)
	_slider(box, "particle_amount", "Amount", 0.0, 300.0, 1.0)
	_slider(box, "particle_life", "Lifetime", 0.1, 2.0, 0.05)

	_title(box, "Keyboard")
	_option(box, "key_style", "Key Bed", KEY_STYLES)
	_slider(box, "key_tint", "Press Tint", 0.0, 1.0, 0.05)
	_option(box, "key_names", "Key Names", KEY_NAMES)

	var fx := _page(tabs, "FX Rack")
	_title(fx, "Delay")
	_check(fx, "delay_on", "Enable")
	_option(fx, "delay_sync", "Sync Mode", DELAY_SYNC)
	_option(fx, "delay_beat", "Time (beats)", DELAY_BEATS)
	_slider(fx, "delay_ms", "Time (ms)", 10.0, 2000.0, 10.0)
	_slider(fx, "delay_feedback", "Feedback", 0.0, 0.95, 0.01)
	_slider(fx, "delay_tone", "Tone (Hz)", 1000.0, 16000.0, 100.0)
	_slider(fx, "delay_dry", "Dry", 0.0, 1.0, 0.05)
	_slider(fx, "delay_wet", "Wet", 0.0, 1.0, 0.05)

	_title(fx, "Reverb")
	_check(fx, "reverb_on", "Enable")
	_option(fx, "reverb_preset", "Preset", REVERB_PRESETS)
	_slider(fx, "reverb_room", "Room Size", 0.1, 0.98, 0.01)
	_slider(fx, "reverb_damping", "Damping", 0.0, 1.0, 0.05)
	_slider(fx, "reverb_spread", "Stereo Spread", 0.0, 1.0, 0.05)
	_slider(fx, "reverb_dry", "Dry", 0.0, 1.0, 0.05)
	_slider(fx, "reverb_wet", "Wet", 0.0, 1.0, 0.05)

	_title(fx, "Touch")
	_slider(fx, "vel_curve", "Velocity Sensitivity", 0.5, 2.0, 0.05)


## One scrollable tab page.
func _page(tabs: TabContainer, title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER  # keep the drawer its anchored width
	tabs.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	return box


func _title(box: VBoxContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color("ffc531"))
	box.add_child(l)


func _row(box: VBoxContainer, text: String, control: Control) -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(120, 0)
	row.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(control)
	box.add_child(row)


func _store(key: String, value: Variant) -> void:
	vis[key] = value
	if key == "reverb_preset":  # a preset loads its values into the reverb sliders
		vis.merge(REVERB_VALUES[value], true)
		for k in REVERB_VALUES[value]:
			if _setters.has(k):
				_setters[k].call(vis[k])
	changed.emit()


func _slider(box: VBoxContainer, key: String, text: String, lo: float, hi: float, step: float) -> void:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = vis[key]
	var readout := Label.new()
	readout.custom_minimum_size = Vector2(44, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var show := func(v: float): readout.text = str(int(v)) if step >= 1.0 else "%.2f" % v
	show.call(s.value)
	s.value_changed.connect(func(v):
		show.call(v)
		_store(key, int(v) if vis[key] is int else v))
	_setters[key] = func(v):
		s.set_value_no_signal(v)
		show.call(v)
	_row(box, text, s)
	s.get_parent().add_child(readout)


func _check(box: VBoxContainer, key: String, text: String) -> void:
	var c := Button.new()  # an On/Off button: unticked checkboxes and off switches vanish on the dark panel
	c.toggle_mode = true
	c.button_pressed = vis[key]
	c.text = "On" if vis[key] else "Off"
	c.toggled.connect(func(on):
		c.text = "On" if on else "Off"
		_store(key, on))
	_setters[key] = func(on):
		c.set_pressed_no_signal(on)
		c.text = "On" if on else "Off"
	_row(box, text, c)


func _option(box: VBoxContainer, key: String, text: String, items: Array) -> void:
	var o := OptionButton.new()
	o.clip_text = true  # long names would push the drawer off screen
	for item in items:
		o.add_item(item)
	o.select(vis[key])
	o.item_selected.connect(func(i): _store(key, i))
	_setters[key] = o.select
	_row(box, text, o)


func _color(box: VBoxContainer, key: String, text: String) -> void:
	var c := ColorPickerButton.new()
	c.color = vis[key]
	c.custom_minimum_size = Vector2(0, 24)
	c.color_changed.connect(func(col): _store(key, col))
	_setters[key] = func(col): c.color = col
	_row(box, text, c)
