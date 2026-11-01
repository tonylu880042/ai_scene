extends RefCounted
## Converts package instance transforms: scale is expressed on prototype-local axes.
static func from_package(position: Vector3, rotation: Quaternion, scale: Vector3) -> Transform3D:
	return Transform3D(Basis(rotation).scaled_local(scale), position)
