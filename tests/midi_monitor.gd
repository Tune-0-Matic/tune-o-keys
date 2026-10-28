extends SceneTree
## Prints every MIDI message for 60 s (or 60 messages). Close the app first: Windows lets one program hold a device.
## godot --path . -s res://tests/midi_monitor.gd
var count := 0
var t0 := 0

func _initialize():
	OS.open_midi_inputs()
	print("inputs: ", OS.get_connected_midi_inputs())
	t0 = Time.get_ticks_msec()
	root.set_process_input(true)
	var n := Node.new()
	n.set_script(preload("res://tests/midi_monitor_node.gd"))
	root.add_child(n)
	await create_timer(60.0).timeout
	print("done")
	quit()
