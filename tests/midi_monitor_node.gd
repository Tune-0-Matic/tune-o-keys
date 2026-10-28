extends Node
## Logs MIDI input for tests/midi_monitor.gd.
var count := 0

func _input(event: InputEvent) -> void:
	var m := event as InputEventMIDI
	if m == null:
		return
	count += 1
	print("%6d ms  dev %d  msg %d  ch %d  pitch %d  vel %d  cc %d = %d" % [Time.get_ticks_msec(), m.device, m.message, m.channel, m.pitch, m.velocity, m.controller_number, m.controller_value])
	if count >= 80:
		get_tree().quit()
