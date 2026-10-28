extends SceneTree
## Frame-time benchmark: 30k-note stress file, vsync off. godot --path . -s res://tests/bench.gd
func _initialize():
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var roll = load("res://main.tscn").instantiate()
	root.add_child(roll)
	await process_frame
	var t0 := Time.get_ticks_usec()
	roll.load_midi("res://tests/stress.mid")
	print("load ms ", (Time.get_ticks_usec() - t0) / 1000.0, "  notes ", roll.song.notes.size())
	for spot in [5.0, 280.0]:
		roll._seek(spot)
		for i in 30:
			await process_frame
		var start := Time.get_ticks_usec()
		var proc := 0.0
		for i in 300:
			await process_frame
			proc += Performance.get_monitor(Performance.TIME_PROCESS)
		var ms := (Time.get_ticks_usec() - start) / 300000.0
		print("at %ds: %.2f ms/frame (%.0f fps), process %.2f ms" % [spot, ms, 1000.0 / ms, proc / 300.0 * 1000.0])
	quit()
