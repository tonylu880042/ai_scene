extends Path3D

@export var radius := 185.0
@export var wobble := 12.0   # bay-like wiggle amplitude (m)
@export var hill := 0.4      # elevation swing (m)
@export var points := 48

func _ready() -> void:
	var pts: Array[Vector3] = []
	for i in points:
		var a := TAU * i / points
		var r := radius + wobble * sin(3.0 * a) + wobble * 0.5 * sin(5.0 * a + 1.0)
		pts.append(Vector3(cos(a) * r, hill * sin(2.0 * a), sin(a) * r))
	var c := Curve3D.new()
	for i in points + 1:  # +1 repeats the first point to close the loop
		var h := (pts[(i + 1) % points] - pts[(i - 1 + points) % points]) / 6.0  # Catmull-Rom handles
		c.add_point(pts[i % points], -h, h)
	curve = c
