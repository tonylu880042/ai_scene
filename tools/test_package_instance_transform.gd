extends SceneTree
## Package scale applies along prototype-local axes before instance rotation (R*S).
const PackageInstanceTransform = preload("res://scripts/package_instance_transform.gd")

func _initialize() -> void:
	call_deferred("_test")

func _test() -> void:
	var position := Vector3(12.5, -3.0, 9.25)
	var scale := Vector3(2.0, 1.25, 3.0)
	for yaw_deg in [0.0, 45.0, 90.0]:
		var q := Quaternion(Vector3.UP, deg_to_rad(yaw_deg))
		var xf := PackageInstanceTransform.from_package(position, q, scale)
		assert(xf.origin.distance_to(position) < 0.00001)
		assert(absf(xf.basis.x.length() - scale.x) < 0.00001)
		assert(absf(xf.basis.y.length() - scale.y) < 0.00001)
		assert(absf(xf.basis.z.length() - scale.z) < 0.00001)
		assert(absf(xf.basis.x.normalized().dot(xf.basis.z.normalized())) < 0.00001)
		assert(absf(xf.basis.x.normalized().dot(xf.basis.y.normalized())) < 0.00001)
		assert(absf(xf.basis.y.normalized().dot(xf.basis.z.normalized())) < 0.00001)
	var q := Quaternion(Vector3.UP, deg_to_rad(45.0))
	var uniform := Vector3.ONE * 2.0
	var old_uniform := Basis(q).scaled(uniform)
	var new_uniform := PackageInstanceTransform.from_package(position, q, uniform).basis
	assert(old_uniform.is_equal_approx(new_uniform))
	var quarter_turn := PackageInstanceTransform.from_package(position, Quaternion(Vector3.UP, PI / 2.0), scale)
	assert(absf(quarter_turn.basis.x.length() - 2.0) < 0.00001)
	assert(absf(quarter_turn.basis.z.length() - 3.0) < 0.00001)
	print("PACKAGE_INSTANCE_TRANSFORM_TEST_OK; local-axis scale, orthogonality, translation, uniform-scale compatibility")
	quit()
