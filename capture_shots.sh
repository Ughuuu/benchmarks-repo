#!/usr/bin/env bash
#
# One screenshot per (engine, case), so the report can put the engines side by side and show
# how the same scene ends up under each solver. A pile that sags, a stack that leans or a
# lattice that stretches is a real difference that a millisecond figure does not convey.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
VISUAL_CASES="pyramid mixed_pile joint_grid smash query_storm"
RES="${RES:-1000x640}"
CAP="${CAP:-180}"
# Every engine is captured at the same simulated tick. Stopping on "settled" or on a wall
# clock is frame-rate dependent, so a fast-rendering engine gets photographed later in the
# simulation than a slow one and the two images cannot be compared at all.
SHOT_TICK="${SHOT_TICK:-400}"

shoot_engine() {
    local project=$1 dim=$2 engine=$3
    local slug="${engine// /_}"
    printf '[physics]\n\n%s/physics_engine="%s"\n' "$dim" "$engine" > "$project/override.cfg"
    for case_name in $VISUAL_CASES; do
        [[ -f "$project/cases/$case_name.gd" ]] || continue
        local f="docs/shots/${dim}_${case_name}_${slug}.png"
        # A stale image from an earlier run would otherwise pass for a fresh one.
        rm -f "$f"
        # Godot backgrounded directly, not in a subshell: with ( ... ) & the recorded pid is
        # the subshell's, and killing that on timeout orphans Godot to run forever.
        "$GODOT" --path "$project" --resolution "$RES" -- \
            --case="$case_name" --shot="$PWD/$f" --shot-tick="$SHOT_TICK" --shot-exact \
            >"/tmp/shot_${dim}_${case_name}_${slug}.log" 2>&1 &
        local p=$! n=0
        while kill -0 $p 2>/dev/null && [ $n -lt "$CAP" ]; do sleep 1; n=$((n+1)); done
        kill -9 $p 2>/dev/null
        if [[ -f "$f" ]]; then echo "  ok   ${dim}/${case_name}/${engine} (${n}s)"
        else echo "  FAIL ${dim}/${case_name}/${engine} (${n}s)"; fi
    done
    rm -f "$project/override.cfg"
}

mkdir -p docs/shots
echo "=== 2D ==="
shoot_engine bench2d 2d "Box2D"
shoot_engine bench2d 2d "Rapier2D"
shoot_engine bench2d 2d "GodotPhysics2D"
echo "=== 3D ==="
shoot_engine bench3d 3d "Jolt Physics"
shoot_engine bench3d 3d "Rapier3D"
echo "shots: $(ls docs/shots | wc -l)"
