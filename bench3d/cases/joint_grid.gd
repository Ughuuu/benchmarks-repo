extends "res://framework/bench_case.gd"

## A 100x50 lattice pinned to right and lower neighbours — 5,000 bodies, ~9,950 joints — hung
## from a static anchor. Constraint-driven rather than contact-driven, and the lattice has
## cycles, so a solver leaning on tree-shaped island ordering cannot shortcut it.
##
## displacement_max guards the silent failure: if node_a/node_b do not resolve the joints do
## nothing and this becomes 5,000 bodies free-falling. A hanging lattice barely moves.

const COLS := 100
const ROWS := 50
const PITCH := 1.2

var _start: Array[Vector3] = []
var _anchor: StaticBody3D


func build(root: Node) -> void:
	_anchor = fixed3(root, Vector3(0, ROWS * PITCH + PITCH, 0), box3(Vector3(COLS * PITCH + 4, 0.5, 1)))
	var origin := -0.5 * (COLS - 1) * PITCH
	# Bodies first: a Joint3D resolves its endpoints by path as it enters the tree.
	for row in ROWS:
		for col in COLS:
			var at := Vector3(origin + col * PITCH, (ROWS - row) * PITCH, 0)
			body3(root, at, sphere3(0.25))
			_start.append(at)
	for row in ROWS:
		for col in COLS:
			var i := row * COLS + col
			if col + 1 < COLS:
				_pin(root, bodies[i], bodies[i + 1], _start[i] + Vector3(0.5 * PITCH, 0, 0))
			if row + 1 < ROWS:
				_pin(root, bodies[i], bodies[i + COLS], _start[i] + Vector3(0, -0.5 * PITCH, 0))
			if row == 0:
				# Directly above the body. The anchor origin is mid bar, so a midpoint would hang
				# the outer columns from long levers and the lattice tears itself apart.
				_pin(root, bodies[i], _anchor, _start[i] + Vector3(0, 0.5 * PITCH, 0))


func _pin(root: Node, a: Node3D, b: Node3D, at: Vector3) -> void:
	var j := PinJoint3D.new()
	j.position = at
	root.add_child(j)
	j.node_a = j.get_path_to(a)
	j.node_b = j.get_path_to(b)


func extra_metrics() -> Dictionary:
	var worst := 0.0
	for i in bodies.size():
		worst = maxf(worst, (bodies[i] as Node3D).position.distance_to(_start[i]))
	return {"displacement_max": worst}
