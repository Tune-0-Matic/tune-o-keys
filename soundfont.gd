extends RefCounted
## Minimal SF2 reader: the first preset's sample zones as {lo, hi, vlo, vhi, root, cents, release, stream}
## (key range, velocity range, root key, tuning, release seconds, AudioStreamWAV).
## shortcut: ignores envelopes, filters, modulators, attenuation, sample offsets and preset-level ranges;
## fine for a piano, add them if a multi-instrument font sounds wrong.

const TABLES := ["phdr", "pbag", "pgen", "inst", "ibag", "igen", "shdr"]


static func load_zones(path: String) -> Array:
	# Streamed from disk: only the preset tables are read whole, samples are read one at a time,
	# so a 1 GB+ font never sits in memory twice.
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 12 or f.get_buffer(4).get_string_from_ascii() != "RIFF":
		push_error("Not a SoundFont: %s" % path)
		return []
	f.get_32()
	if f.get_buffer(4).get_string_from_ascii() != "sfbk":
		push_error("Not a SoundFont: %s" % path)
		return []
	var c := {}  # chunk id -> [offset, size]
	_walk(f, 12, f.get_length(), c)
	for id in TABLES + ["smpl"]:
		if not c.has(id):
			push_error("SoundFont missing %s chunk: %s" % [id, path])
			return []
	var base: int = c.phdr[0]
	var stop := 0
	for id in TABLES:
		base = mini(base, c[id][0])
		stop = maxi(stop, c[id][0] + c[id][1])
	f.seek(base)
	var data := f.get_buffer(stop - base)  # the pdta tables; offsets below are relative to this
	for id in TABLES:
		c[id][0] -= base

	# Preset with the lowest bank/program number (normally 000:000).
	var best := 0
	for i in c.phdr[1] / 38 - 1:  # last record is the EOP terminator
		var o: int = c.phdr[0] + i * 38
		var b: int = c.phdr[0] + best * 38
		if data.decode_u16(o + 22) * 128 + data.decode_u16(o + 20) < data.decode_u16(b + 22) * 128 + data.decode_u16(b + 20):
			best = i
	var instruments := []
	var p: int = c.phdr[0] + best * 38
	for bag in range(data.decode_u16(p + 24), data.decode_u16(p + 38 + 24)):
		for g in range(data.decode_u16(c.pbag[0] + bag * 4), data.decode_u16(c.pbag[0] + bag * 4 + 4)):
			var go: int = c.pgen[0] + g * 4
			if data.decode_u16(go) == 41 and not data.decode_u16(go + 2) in instruments:  # instrument, once
				instruments.append(data.decode_u16(go + 2))

	var zones := []
	var streams := {}  # sample index -> AudioStreamWAV
	for inst in instruments:
		var io: int = c.inst[0] + inst * 22
		var first := data.decode_u16(io + 20)
		var global := {}
		for bag in range(first, data.decode_u16(io + 22 + 20)):
			var gens := global.duplicate()
			for g in range(data.decode_u16(c.ibag[0] + bag * 4), data.decode_u16(c.ibag[0] + bag * 4 + 4)):
				var go: int = c.igen[0] + g * 4
				gens[data.decode_u16(go)] = data.decode_u16(go + 2)
			if not gens.has(53):  # no sampleID: global zone, defaults for the rest
				if bag == first:
					global = gens
				continue
			var s: int = gens[53]
			var sh: int = c.shdr[0] + s * 46
			var kind := data.decode_u16(sh + 44)
			if kind == 2 or kind & 0x8000:  # right half of a stereo pair (left is enough), or ROM sample
				continue
			if not streams.has(s):
				var start := data.decode_u32(sh + 20)
				var end := mini(data.decode_u32(sh + 24), c.smpl[1] / 2)
				if end <= start:
					continue
				var wav := AudioStreamWAV.new()
				wav.format = AudioStreamWAV.FORMAT_16_BITS
				wav.mix_rate = data.decode_u32(sh + 36)
				# shortcut: loops ignored so samples ring out through their recorded tail (no volume
				# envelope to decay a loop); fonts with very short samples would need loop + envelope
				f.seek(c.smpl[0] + start * 2)
				wav.data = f.get_buffer((end - start) * 2)
				streams[s] = wav
			var key: int = gens.get(43, 0x7F00)
			var vel: int = gens.get(44, 0x7F00)
			var root := _s16(gens.get(58, 0xFFFF))
			zones.append({
				lo = key & 0xFF, hi = key >> 8, vlo = vel & 0xFF, vhi = vel >> 8,
				root = root if root >= 0 else data[sh + 40],
				cents = _s16(gens.get(51, 0)) * 100 + _s16(gens.get(52, 0)) + data.decode_s8(sh + 41),
				# releaseVolEnv (timecents): the font's own damper time. Unset -> 0.12 s; clamped so it
				# neither clicks nor rings forever (some GM fonts set 100 s).
				release = clampf(pow(2.0, _s16(gens[38]) / 1200.0), 0.03, 10.0) if gens.has(38) else 0.12,
				stream = streams[s],
			})
	if zones.is_empty():
		push_error("SoundFont has no usable samples: %s" % path)
	return zones


## Every .sf2 under dir, subfolders included, sorted by path.
static func find_fonts(dir: String) -> PackedStringArray:
	var found := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() == "sf2":
			found.append(dir.path_join(f))
	for sub in DirAccess.get_directories_at(dir):
		found.append_array(find_fonts(dir.path_join(sub)))
	found.sort()
	return found


## Zone for this key and velocity; falls back to any zone covering the key, then (for keys outside the
## font's range, e.g. a sax or organ) the nearest zone, so the sample is stretched as little as possible.
static func pick(zones: Array, pitch: int, velocity: int) -> Dictionary:
	var by_key := {}
	var nearest: Dictionary = zones[0]
	var gap := 1 << 30
	for z in zones:
		if pitch >= z.lo and pitch <= z.hi:
			if velocity >= z.vlo and velocity <= z.vhi:
				return z
			if by_key.is_empty():
				by_key = z
		elif by_key.is_empty():
			var d: int = maxi(z.lo - pitch, pitch - z.hi)
			if d < gap:
				gap = d
				nearest = z
	return nearest if by_key.is_empty() else by_key


## Every chunk of file f between from and to (descending into LISTs) -> out[id] = [offset, size].
static func _walk(f: FileAccess, from: int, to: int, out: Dictionary) -> void:
	var pos := from
	while pos + 8 <= to:
		f.seek(pos)
		var id := f.get_buffer(4).get_string_from_ascii()
		var size := f.get_32()
		if id == "LIST":
			_walk(f, pos + 12, pos + 8 + size, out)
		else:
			out[id] = [pos + 8, size]
		pos += 8 + size + (size & 1)


static func _s16(v: int) -> int:
	return v - 0x10000 if v >= 0x8000 else v
