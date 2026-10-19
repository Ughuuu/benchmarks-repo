extends "res://framework/bench_case.gd"

## A 100x50 lattice pinned to right and lower neighbours — 5,000 bodies, ~9,950 joints — hung
## from a static anchor. Constraint-driven rather than contact-driven: the contact solver
## barely runs, and the lattice has cycles, so a solver leaning on tree-shaped island
## ordering cannot shortcut it.
##
## displacement_max guards the silent failure: if node_a/node_b do not resolve the joints do
## nothing and this quietly becomes 5,000 bodies free-falling. A hanging lattice barely moves.

const COLS := 100
const ROWS := 50
const PITCH := 24.0

var _start: Array[Vector2] = []
var _anchor: StaticBody2D


func build(root: Node) -> void:
	_anchor = fixed(root, Vector2(0, -PITCH), rect(Vector2(COLS * PITCH + 80, 16)))
	var origin := -0.5 * (COLS - 1) * PITCH
	# Bodies first: a Joint2D resolves its endpoints by path as it enters the tree.
	for row in ROWS:
		for col in COLS:
			var at := Vector2(origin + col * PITCH, row * PITCH)
			body(root, at, circle(5))
			_start.append(at)
	for row in ROWS:
		for col in COLS:
			var i := row * COLS + col
			if col + 1 < COLS:
				_pin(root, bodies[i], bodies[i + 1], _start[i] + Vector2(0.5 * PITCH, 0))
			if row + 1 < ROWS:
				_pin(root, bodies[i], bodies[i + COLS], _start[i] + Vector2(0, 0.5 * PITCH))
			if row == 0:
				# Directly above the body. The anchor origin is mid bar, so a midpoint would hang
				# the outer columns from long levers and the lattice tears itself apart.
				_pin(root, bodies[i], _anchor, _start[i] + Vector2(0, -0.5 * PITCH))


func _pin(root: Node, a: Node2D, b: Node2D, at: Vector2) -> void:
	var j := PinJoint2D.new()
	j.position = at
	root.add_child(j)
	j.node_a = j.get_path_to(a)
	j.node_b = j.get_path_to(b)


func extra_metrics() -> Dictionary:
	var worst := 0.0
	for i in bodies.size():
		var b := bodies[i] as Node2D
		if is_instance_valid(b):
			worst = maxf(worst, b.position.distance_to(_start[i]))
	return {"displacement_max": worst}
