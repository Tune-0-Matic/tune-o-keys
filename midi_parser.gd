extends RefCounted
## Standard MIDI File -> {notes, beats, bpm, beats_per_bar}, or {} if the file isn't MIDI.
## notes: Array of {pitch, start_sec, end_sec, key_end, velocity, channel}; end_sec includes pedal hold, key_end doesn't. beats: start time of every beat in seconds.
## CC64 sustain is folded in: a note released while the pedal is down ends at pedal release.

static func parse(data: PackedByteArray) -> Dictionary:
	var spb := StreamPeerBuffer.new()
	spb.data_array = data
	spb.big_endian = true
	if data.size() < 14 or spb.get_data(4)[1].get_string_from_ascii() != "MThd":
		push_error("Not a MIDI file")
		return {}
	var header_end := 8 + spb.get_u32()
	spb.get_u16()  # format: 0/1/2 all read the same way here
	var track_count := spb.get_u16()
	var division := spb.get_u16()
	if division & 0x8000:
		push_error("SMPTE time division not supported")
		return {}
	spb.seek(header_end)

	var events := []  # [tick, seq, channel, kind, a, b]
	var tempos := []  # [tick, microseconds per quarter]
	var beats_per_bar := 0
	for track in track_count:
		if spb.get_available_bytes() < 8:
			break
		var id: String = spb.get_data(4)[1].get_string_from_ascii()
		var end := spb.get_u32() + spb.get_position()
		if id != "MTrk":
			spb.seek(end)
			continue
		var tick := 0
		var status := 0
		while spb.get_position() < end:
			tick += _vlq(spb)
			var byte := spb.get_u8()
			if byte >= 0x80:
				status = byte
			else:
				spb.seek(spb.get_position() - 1)  # running status: byte was data
			if status == 0xFF:
				var type := spb.get_u8()
				var length := _vlq(spb)
				var next := spb.get_position() + length
				if type == 0x51:
					tempos.append([tick, (spb.get_u8() << 16) | (spb.get_u8() << 8) | spb.get_u8()])
				elif type == 0x58 and beats_per_bar == 0:
					beats_per_bar = spb.get_u8()  # shortcut: first time signature only, ignores meter changes
				spb.seek(next)
			elif status == 0xF0 or status == 0xF7:
				spb.seek(spb.get_position() + _vlq(spb))
			else:
				var kind := status & 0xF0
				var a := spb.get_u8()
				var b := 0 if kind == 0xC0 or kind == 0xD0 else spb.get_u8()
				if kind == 0x80 or kind == 0x90 or kind == 0xB0:
					events.append([tick, events.size(), status & 0x0F, kind, a, b])
		spb.seek(end)

	tempos.sort_custom(func(x, y): return x[0] < y[0])
	events.sort_custom(func(x, y): return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]))
	var times := _secs(events.map(func(e): return e[0]), tempos, division)
	var last_tick: int = events[-1][0] if events else 0

	var notes := []
	var held := {}  # channel*128+pitch -> note, key still down
	var sustained := {}  # channel*128+pitch -> note, key up but pedal down
	var pedal := []
	pedal.resize(16)
	pedal.fill(false)
	var t := 0.0
	for i in events.size():
		var e: Array = events[i]
		t = times[i]
		var ch: int = e[2]
		var kind: int = e[3]
		var k: int = ch * 128 + e[4]
		if kind == 0x90 and e[5] > 0:
			_close(held, k, t)  # re-strike cuts the previous copy of this key
			_close(sustained, k, t)
			var n := {pitch = e[4], start_sec = t, end_sec = -1.0, key_end = -1.0, velocity = e[5], channel = ch}
			notes.append(n)
			held[k] = n
		elif kind == 0x80 or kind == 0x90:
			if held.has(k):
				held[k].key_end = t
				if pedal[ch]:
					sustained[k] = held[k]
					held.erase(k)
				else:
					_close(held, k, t)
		elif e[4] == 64:  # CC64
			pedal[ch] = e[5] >= 64
			if not pedal[ch]:
				for sk in sustained.keys():
					if sk / 128 == ch:
						_close(sustained, sk, t)
	for n in notes:  # notes never released end with the file
		if n.end_sec < 0.0:
			n.end_sec = t
		if n.key_end < 0.0:
			n.key_end = t
	return {
		notes = notes,
		beats = _secs(range(0, last_tick + 1, division), tempos, division),
		bpm = 60e6 / tempos[0][1] if tempos else 120.0,
		beats_per_bar = maxi(beats_per_bar, 1) if beats_per_bar else 4,
	}


## Ticks (sorted ascending) -> seconds, walking the tempo map once.
static func _secs(ticks: Array, tempos: Array, division: int) -> Array:
	var out := []
	var ti := 0
	var seg_tick := 0
	var seg_sec := 0.0
	var uspq := 500000.0
	for tick in ticks:
		while ti < tempos.size() and tempos[ti][0] <= tick:
			seg_sec += (tempos[ti][0] - seg_tick) * uspq / 1e6 / division
			seg_tick = tempos[ti][0]
			uspq = tempos[ti][1]
			ti += 1
		out.append(seg_sec + (tick - seg_tick) * uspq / 1e6 / division)
	return out


static func _close(map: Dictionary, k: int, t: float) -> void:
	if map.has(k):
		map[k].end_sec = t
		if map[k].key_end < 0.0:  # re-strike while key still down
			map[k].key_end = t
		map.erase(k)


static func _vlq(spb: StreamPeerBuffer) -> int:
	var v := 0
	while true:
		var b := spb.get_u8()
		v = (v << 7) | (b & 0x7F)
		if b < 0x80:
			return v
	return v
