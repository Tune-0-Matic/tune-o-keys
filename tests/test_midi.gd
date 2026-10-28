extends SceneTree
## godot --headless --path . -s res://tests/test_midi.gd

func _init() -> void:
	var track := PackedByteArray([
		0x00, 0xFF, 0x58, 0x04, 3, 2, 24, 8,        # 3/4
		0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,  # 120 bpm
		0x00, 0x90, 60, 100,                        # C4 on @0
		0x81, 0x70, 0xB0, 64, 127,                  # pedal down @240
		0x81, 0x70, 0x80, 60, 0,                    # C4 off @480 (sustained)
		0x83, 0x60, 0xB0, 64, 0,                    # pedal up @960 -> C4 ends 1.0s
		0x00, 0xFF, 0x51, 0x03, 0x03, 0xD0, 0x90,   # 240 bpm @960
		0x00, 0x90, 61, 50,                         # C#4 on @960
		0x83, 0x60, 61, 0,                          # running status, vel 0 off @1440
		0x00, 0xFF, 0x2F, 0x00,
	])
	var data := PackedByteArray([0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0])
	data.append_array([0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, track.size()])
	data.append_array(track)

	var parser := preload("res://midi_parser.gd")
	var song: Dictionary = parser.parse(data)
	var notes: Array = song.notes
	assert(notes.size() == 2)
	assert(notes[0].pitch == 60 and notes[0].velocity == 100 and is_equal_approx(notes[0].start_sec, 0.0))
	assert(is_equal_approx(notes[0].end_sec, 1.0), "sustain should hold C4 to pedal up")
	assert(is_equal_approx(notes[0].key_end, 0.5) and is_equal_approx(notes[1].key_end, 1.25))
	assert(notes[1].pitch == 61 and notes[1].velocity == 50 and is_equal_approx(notes[1].start_sec, 1.0))
	assert(is_equal_approx(notes[1].end_sec, 1.25), "tempo change should apply")
	assert(is_equal_approx(song.bpm, 120.0) and song.beats_per_bar == 3)
	assert(song.beats == [0.0, 0.5, 1.0, 1.25], str(song.beats))
	assert(parser.parse(PackedByteArray()).is_empty())

	var roll := preload("res://piano_roll.gd")
	var cs: Array[Color] = roll.pitch_colors(61)
	assert(cs[0] == roll.pitch_colors(60)[0] and cs[1] == roll.pitch_colors(62)[0])
	assert(roll.pitch_colors(64)[0] == roll.pitch_colors(64)[1])
	# Every SoundFont in the user's folder (subfolders included; only on the dev machine).
	var sf := preload("res://soundfont.gd")
	for path in sf.find_fonts("C:/Users/Gavin/Music/Tune-O-Keys/Soundfonts"):
		var zones: Array = sf.load_zones(path)
		assert(zones.size() > 0, "no samples in " + path)
		for pitch in [21, 60, 108]:  # every key gets a sample; outside a font's range, the nearest one
			var z: Dictionary = sf.pick(zones, pitch, 100)
			assert(z.stream.data.size() > 0 and z.root >= 0 and z.root <= 127)
		if "UprightPianoKW" in path:  # has two velocity layers: soft and hard hits use different samples
			assert(sf.pick(zones, 60, 20) != sf.pick(zones, 60, 127))
		if "TenorSaxophone" in path:  # sax ends well below C8: the top key borrows the highest zone
			var top_zone := 0
			for z in zones:
				top_zone = maxi(top_zone, z.hi)
			assert(sf.pick(zones, 108, 100).hi == top_zone)
		print("font ok: ", path.get_file())
	assert(sf.load_zones("res://tests/demo.mid").is_empty())
	print("OK")
	quit()


