extends AudioStreamPlayer
# Child of the Player. Plays on its footstep signal; synthesizes a thud if no stream is assigned
# (drop a real wav into `stream` to replace it).

@export var pitch_jitter := 0.12
@export var min_volume_db := -16.0
@export var max_volume_db := -5.0
@export var thump_hz := 95.0

func _ready() -> void:
	if stream == null:
		stream = _make_step()
	get_parent().connect(&"footstep", _on_step)

func _on_step(speed_ratio: float) -> void:
	pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	volume_db = lerpf(min_volume_db, max_volume_db, speed_ratio)
	play()

func _make_step() -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * 0.14)
	var data := PackedByteArray()
	data.resize(n * 2)
	var lp := 0.0
	for i in n:
		var t := float(i) / rate
		lp += (randf_range(-1.0, 1.0) - lp) * 0.25  # low-passed noise = scuff
		var s := (lp * 0.7 + sin(TAU * thump_hz * t) * 0.6) * exp(-t * 38.0)
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = data
	return w
