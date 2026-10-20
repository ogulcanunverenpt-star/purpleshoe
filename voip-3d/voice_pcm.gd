extends RefCounted

const SAMPLE_RATE := 24000


static func encode_mono_pcm16(stereo_frames: PackedVector2Array, source_rate: int) -> Dictionary:
	if source_rate <= 0:
		push_error("Voice input sample rate must be positive.")
		return {"data": PackedByteArray(), "peak": 0.0}
	if stereo_frames.is_empty():
		return {"data": PackedByteArray(), "peak": 0.0}

	var sample_count := ceili(float(stereo_frames.size() * SAMPLE_RATE) / source_rate)
	var data := PackedByteArray()
	data.resize(sample_count * 2)
	var peak := 0.0
	for output_index in range(sample_count):
		var frame_start: int = floori(float(output_index * source_rate) / SAMPLE_RATE)
		var frame_end: int = mini(stereo_frames.size(), floori(float((output_index + 1) * source_rate) / SAMPLE_RATE))
		frame_end = maxi(frame_start + 1, frame_end)
		var value := 0.0
		var group_size: int = frame_end - frame_start
		for frame_index in range(frame_start, frame_end):
			value += (stereo_frames[frame_index].x + stereo_frames[frame_index].y) * 0.5
		value /= group_size
		peak = maxf(absf(value), peak)
		data.encode_s16(output_index * 2, roundi(clampf(value, -1.0, 1.0) * 32767.0))
	return {"data": data, "peak": peak}
