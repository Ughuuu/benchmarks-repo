#!/usr/bin/env bash
#
# Cross-engine physics benchmark driver.
#
#   2D track: Rapier2D vs Box2D (godot-box2d) vs GodotPhysics2D
#   3D track: Rapier3D vs Jolt Physics vs GodotPhysics3D
#
# Every (engine, case, repeat) is a separate Godot process. That is the point: it keeps a
# warm allocator or a grown physics island from one run out of the next, and it means a
# crash costs one data point instead of the whole sweep.
#
# The engine is selected by writing `override.cfg` before each launch, because Godot reads
# `physics/{2d,3d}/physics_engine` once at startup and exposes no CLI flag for it.
#
# Usage:
#   ./run_bench.sh [--dim 2d|3d|both] [--repeats N] [--steps N] [--warmup N]
#                  [--cases "pyramid mixed_pile"] [--out DIR] [--godot PATH]

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
DIM="both"
REPEATS=1
STEPS=300
WARMUP=60
CASES="pyramid mixed_pile joint_grid smash query_storm drop"
OUT="$HERE/results"
# Per-run wall-clock ceiling. An engine can be pathologically slow on a case rather than
# merely slower — Godot Physics 2D CCD is minutes-per-step at high bullet counts — and
# without a ceiling one such combination stalls the whole sweep. A run that trips this is
# recorded as TIMEOUT, which is itself a result.
TIMEOUT_S=60

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dim) DIM="$2"; shift 2 ;;
        --repeats) REPEATS="$2"; shift 2 ;;
        --steps) STEPS="$2"; shift 2 ;;
        --warmup) WARMUP="$2"; shift 2 ;;
        --cases) CASES="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --timeout) TIMEOUT_S="$2"; shift 2 ;;
        --with-godot) WITH_GODOT=1; shift ;;
        --godot) GODOT="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -x "$GODOT" ]]; then
    echo "error: godot not executable at $GODOT (override with --godot or \$GODOT)" >&2
    exit 1
fi

mkdir -p "$OUT"

# Git Bash on Windows has no `time -l`, `sysctl` or `uptime`. Runs there skip the cpu and
# load figures rather than fail.
WINDOWS=0
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) WINDOWS=1 ;;
esac

# Engine lists are the names each server registers with PhysicsServer{2,3}DManager, not
# display names. `DEFAULT` is deliberately not used: it is an alias whose target depends on
# project settings, and a run labelled DEFAULT tells you nothing about what actually ran.
ENGINES_2D=("Box2D" "Rapier2D")
ENGINES_3D=("Jolt Physics" "Box3D Physics" "Rapier3D")
# Godot's built-in server is an order of magnitude slower at these body counts and dominates
# the sweep's wall time; --with-godot puts it back as a reference column.
if [[ "${WITH_GODOT:-0}" == "1" ]]; then
    ENGINES_2D+=("GodotPhysics2D")
    ENGINES_3D+=("GodotPhysics3D")
fi


# Godot silently falls back to the default server when `physics_engine` names something it
# cannot find — no error, no warning, and the run looks like a legitimate result. The
# registered engines show up in the setting's property hint, so check there before spending
# minutes measuring a fallback.
preflight() {
    local project="$1" dim="$2"; shift 2
    local -a wanted=("$@")

    cat > "$project/_preflight.gd" <<'EOF'
extends Node
func _ready() -> void:
	for p in ProjectSettings.get_property_list():
		if String(p.name).ends_with("physics_engine"):
			print("HINT|", p.name, "|", p.hint_string)
	get_tree().quit()
EOF
    cat > "$project/_preflight.tscn" <<'EOF'
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://_preflight.gd" id="1"]
[node name="P" type="Node"]
script = ExtResource("1")
EOF

    local hint
    hint="$("$GODOT" --headless --path "$project" _preflight.tscn 2>/dev/null \
            | grep "^HINT|physics/$dim/physics_engine|" | head -1 | cut -d'|' -f3)"
    rm -f "$project/_preflight.gd" "$project/_preflight.tscn" "$project/_preflight.gd.uid"

    if [[ -z "$hint" ]]; then
        echo "error: could not read the $dim physics_engine hint from $project" >&2
        return 1
    fi
    echo "  registered $dim engines: $hint"

    local missing=0 engine
    for engine in "${wanted[@]}"; do
        if [[ ",$hint," != *",$engine,"* ]]; then
            echo "  error: '$engine' is not registered — its extension did not load." >&2
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        echo "  hint: run '$GODOT --headless --import --path $project' first (twice on a" >&2
        echo "        fresh project; the first pass builds .godot/extension_list.cfg)." >&2
        return 1
    fi
    return 0
}


# macOS ships no timeout(1), so run the child in the background and poll it.
# Kills the whole process group, not just the job: the timed command is wrapped in
# `/usr/bin/time`, so `$!` is the wrapper and killing it alone leaves godot orphaned —
# an escaped run burns cores for the rest of the sweep and corrupts every later result.
run_with_timeout() {
    local limit="$1"; shift
    set -m
    "$@" &
    local pid=$!
    set +m
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if (( waited >= limit )); then
            kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
            sleep 1
            kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1
        (( waited++ ))
    done
    wait "$pid"
}


run_track() {
    local dim="$1"; shift
    local -a engines=("$@")
    local project="$HERE/bench$dim"

    if [[ ! -d "$project" ]]; then
        echo "skipping ${dim}: no project at $project"
        return 0
    fi

    echo "=== ${dim} track ==="

    # A never-opened project has no .godot/extension_list.cfg, so no GDExtension loads and
    # every engine silently resolves to the built-in one. The first import on a fresh
    # project can abort after writing that file, so import until it exits clean, twice at
    # most.
    if [[ ! -f "$project/.godot/extension_list.cfg" ]]; then
        echo "  importing $project ..."
        "$GODOT" --headless --import --path "$project" >/dev/null 2>&1
        "$GODOT" --headless --import --path "$project" >/dev/null 2>&1
    fi

    preflight "$project" "$dim" "${engines[@]}" || return 1

    # Case-outer, engine-inner: every case finishes across all engines before the next one
    # starts, so an interrupted sweep still yields complete, comparable results for the cases
    # it got through. The other order leaves you with one engine and nothing to compare it to.
    local engine case_name repeat slug out_file
    for case_name in $CASES; do
        if [[ ! -f "$project/cases/$case_name.gd" ]]; then
            echo "  skip $case_name (no such case)"
            continue
        fi
        for engine in "${engines[@]}"; do
            slug="${engine// /_}"
            mkdir -p "$OUT/$dim/$slug"
            for ((repeat = 1; repeat <= REPEATS; repeat++)); do
                out_file="$OUT/$dim/$slug/${case_name}_r${repeat}.json"
                printf '[physics]\n\n%s/physics_engine="%s"\n' "$dim" "$engine" \
                    > "$project/override.cfg"
                # `time -l` reports the process's own cpu seconds and peak resident memory.
                # cpu divided by wall time is the average number of cores the engine kept busy:
                # step time alone hides an engine that wins by burning more of the machine.
                local cpu_file="$OUT/$dim/$slug/${case_name}_r${repeat}.cpu"
                local -a timer=(/usr/bin/time -l)
                [[ $WINDOWS -eq 1 ]] && timer=()
                run_with_timeout "$TIMEOUT_S" \
                    "${timer[@]}" \
                    "$GODOT" --headless --fixed-fps 60 --path "$project" bench.tscn -- \
                    --case="$case_name" --steps="$STEPS" --warmup="$WARMUP" \
                    --out="$out_file" --engine-label="$engine" \
                    > "$OUT/$dim/$slug/${case_name}_r${repeat}.log" 2>"$cpu_file"
                local rc=$?
                if [[ -f "$out_file" ]]; then
                    python3 - "$out_file" "$cpu_file" <<'CPUPY'
import json, re, sys
out, cpu = sys.argv[1], sys.argv[2]
text = open(cpu, errors="ignore").read()
# `time -l` puts timings on one line: "  1.23 real   2.34 user   0.12 sys"
vals = {k: float(v) for v, k in re.findall(r"([\d.]+)\s+(real|user|sys)\b", text)}
rss = re.search(r"(\d+)\s+maximum resident set size", text)
if {"real", "user", "sys"} <= vals.keys() and vals["real"] > 0:
    d = json.load(open(out))
    d["cpu"] = {
        "wall_s": vals["real"],
        "user_s": vals["user"],
        "sys_s": vals["sys"],
        "cores_used": round((vals["user"] + vals["sys"]) / vals["real"], 3),
    }
    if rss:
        d["cpu"]["peak_rss_mb"] = round(int(rss.group(1)) / (1024 * 1024), 1)
    json.dump(d, open(out, "w"), indent=1)
CPUPY
                fi
                if [[ $rc -eq 124 ]]; then
                    printf '  %-16s %-14s r%d  TIMEOUT (>%ss)\n' \
                        "$engine" "$case_name" "$repeat" "$TIMEOUT_S"
                elif [[ -f "$out_file" ]]; then
                    printf '  %-16s %-14s r%d  %s\n' "$engine" "$case_name" "$repeat" \
                        "$(python3 "$HERE/_summarize.py" "$out_file")"
                else
                    printf '  %-16s %-14s r%d  FAILED (see .log)\n' "$engine" "$case_name" "$repeat"
                fi
            done
        done
    done
    rm -f "$project/override.cfg"
}


echo "godot:   $GODOT"
echo "steps:   $STEPS (warmup $WARMUP), repeats: $REPEATS"
echo "output:  $OUT"
echo

# Load average is recorded because these are CPU-time measurements: a busy machine inflates
# every number, and a report that does not say so invites comparison against results taken
# on a quiet one.
mkdir -p "$OUT"
if [[ $WINDOWS -eq 1 ]]; then
    printf '{"load_before": "n/a", "cpus": %s}\n' "$(nproc)" > "$OUT/environment.json"
else
    printf '{"load_before": "%s", "cpus": %s}\n' \
        "$(uptime | sed 's/.*averages*: *//')" "$(sysctl -n hw.ncpu)" > "$OUT/environment.json"
fi

status=0
if [[ "$DIM" == "2d" || "$DIM" == "both" ]]; then
    run_track 2d "${ENGINES_2D[@]}" || status=1
fi
if [[ "$DIM" == "3d" || "$DIM" == "both" ]]; then
    run_track 3d "${ENGINES_3D[@]}" || status=1
fi

echo
echo "writing report ..."
python3 "$HERE/make_report.py" "$OUT" || status=1
exit $status
