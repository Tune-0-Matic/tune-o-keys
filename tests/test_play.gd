extends SceneTree
## godot --path . -s res://tests/test_play.gd  (transport, voices; not --headless: dummy audio never frees slots)

func _initialize() -> void:
	var roll: Node = load("res://main.tscn").instantiate()
	root.add_child(roll)
	await process_frame
	assert(roll.song.notes.is_empty(), "app should open with no song")
	roll.load_midi("res://tests/demo.mid")
	roll._set_playing(true)
	roll._seek(0.0)
	for i in 5:
		await process_frame
	assert(roll.voices.size() > 0, "note starting exactly at the seek point should sound")
	roll._seek(3.0)
	assert(roll.voices.is_empty(), "seek must flush voices")
	assert(roll.song.notes[roll.next_hit].start_sec >= 3.0 and roll.song.notes[roll.next_hit - 1].start_sec < 3.0)
	roll._set_playing(false)
	var t: float = roll.time
	for i in 5:
		await process_frame
	assert(roll.time == t, "pause must freeze time")
	assert(roll.timeline.value == t and roll.time_label.text.begins_with("0:03"))
	var n: Dictionary = roll.song.notes[0]  # demo song: pedal holds C3 past its key release
	assert(n.end_sec > n.key_end)
	roll.sustain = false
	assert(roll._end(n) == n.key_end)
	# Overload: 300 simultaneous notes must all get a voice (oldest are stolen).
	roll._seek(0.0)
	for i in 300:  # 15-note chords every 20 ms (a frame); needs a real audio driver to free slots
		var id: int = roll._start_voice(roll.song.notes[i % roll.song.notes.size()])
		assert(id != AudioStreamPlaybackPolyphonic.INVALID_ID, "note %d got no voice" % i)
		if i % 15 == 14:
			await create_timer(0.02).timeout
	# Visual drawer: launch look is the default; presets change it and Default restores it.
	var d: Dictionary = roll.drawer.defaults()
	assert(roll.vis == d, "launch must use default visuals")
	for preset in roll.drawer.presets:
		roll.drawer.apply_preset(preset)
		await process_frame  # draws with this preset; script errors would surface here
	roll.drawer.apply_preset("Default")
	assert(roll.vis == d and roll.vis == roll.drawer.vis)
	assert(roll.env.glow_intensity == d.glow)
	# Live MIDI keyboard, through the real input path: note on, pedal hold, pedal release.
	print("MIDI inputs: ", OS.get_connected_midi_inputs())
	var midi := func(message: int, a: int, b: int):
		var e := InputEventMIDI.new()
		e.message = message
		if message == MIDI_MESSAGE_CONTROL_CHANGE:
			e.controller_number = a
			e.controller_value = b
		else:
			e.pitch = a
			e.velocity = b
		Input.parse_input_event(e)
	roll.sustain = true  # an earlier check switched Pedal off
	midi.call(MIDI_MESSAGE_NOTE_ON, 60, 100)
	await process_frame
	assert(roll.live_voices.has(60) and roll.live_held.has(60), "live note on should sound and light")
	midi.call(MIDI_MESSAGE_CONTROL_CHANGE, 64, 127)
	midi.call(MIDI_MESSAGE_NOTE_ON, 60, 0)  # velocity-0 note on = note off
	await process_frame
	assert(not roll.live_held.has(60) and roll.live_sustained.has(60), "pedal should hold the released key")
	var fades_before: int = roll.fading.size()
	midi.call(MIDI_MESSAGE_CONTROL_CHANGE, 64, 0)
	await process_frame
	assert(roll.live_sustained.is_empty() and roll.fading.size() > fades_before, "pedal up should damp held notes")
	midi.call(MIDI_MESSAGE_NOTE_ON, 64, 90)
	midi.call(MIDI_MESSAGE_NOTE_OFF, 64, 0)
	await process_frame
	assert(roll.live_voices.is_empty() and roll.live_held.is_empty())
	# Visual sync: demo C3 (48) is released at ~0.21 s but pedal-held to ~0.99 s.
	roll._cache_notes()  # what the Pedal switch does after changing sustain
	roll._seek(0.5)
	roll._update_notes()
	assert(roll.lit_notes.has(48), "pedal-held file note keeps its key lit")
	for k in roll.notes_mm.multimesh.visible_instance_count:
		assert(roll.note_buf[k * 16 + 3] != roll.key_x[48], "block must end at key release")
	# Velocity curve: 40*log10(v/127), so 64 -> about -12 dB; sensitivity scales it.
	assert(absf(roll._play(60, 64)[1] - (-11.9)) < 0.1)
	roll.vis.vel_curve = 0.5
	assert(absf(roll._play(60, 64)[1] - (-5.95)) < 0.1)
	roll.vis.vel_curve = 1.0
	# Release time: "font" uses the sample's own release; a slider value overrides it.
	roll.release_sec = 0.0
	roll._release(roll._play(60, 100)[0], 0.0, 2.5)
	assert(roll.fading[-1][3] == 2.5)
	# FX rack: a reverb preset loads its values onto the live effect; visual presets leave audio alone.
	roll.drawer._store("reverb_preset", 0)
	assert(is_equal_approx(roll.fx_reverb.room_size, 0.3) and roll.vis.reverb_room == 0.3)
	roll.drawer._store("reverb_on", true)
	assert(AudioServer.is_bus_effect_enabled(roll.fx_bus, 1))
	roll.drawer.apply_preset("Flat Minimal")
	assert(roll.vis.reverb_on and roll.vis.reverb_preset == 0, "visual preset must keep FX settings")
	roll.drawer._store("delay_sync", 0)
	roll.drawer._store("delay_beat", 3)  # 1/4 at 120 BPM x1 -> 500 ms
	roll.speed = 1.0
	roll.song.bpm = 120.0
	roll._apply_fx()
	assert(is_equal_approx(roll.fx_delay.feedback_delay_ms, 500.0))
	print("PLAY OK")
	quit()
