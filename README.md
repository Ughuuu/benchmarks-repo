# Godot physics engine benchmarks

Compares Godot physics extensions on the same scenes, in the same engine build, measured the
same way.

| track | engines |
|---|---|
| **2D** | [Rapier](https://github.com/appsinacup/godot-rapier-physics) · [Box2D](https://github.com/erincatto/godot-box2d) |
| **3D** | [Rapier](https://github.com/appsinacup/godot-rapier-physics) · Jolt (in Godot 4.4+) · [Box3D](https://github.com/bearlikelion/godot-box3d) |

**Results: [2D](docs/REPORT-2D.md) · [3D](docs/REPORT-3D.md) · [both](docs/REPORT.md)**

## Run it

Addons are committed, so a clone is all you need. Every case measures 5 seconds.

```bash
./run_bench.sh                              # both tracks, writes docs/REPORT.md
./run_bench.sh --dim 2d --cases pyramid
./run_bench.sh --dim 3d --repeats 3         # average out noise
./capture_shots.sh                          # screenshots at an identical tick
python3 make_pdf.py                         # PDF + self-contained HTML
```

`--with-godot` adds Godot's built-in server as a reference column.

Results accumulate in `results/` and are never cleared, so a crashed or skipped combination
can be filled in afterwards and the report picks it up:

```bash
./run_bench.sh                              # whatever survives
./run_bench.sh --dim 3d --cases joint_grid  # re-run just the one that died
python3 make_report.py                      # merges everything present
```

Delete `results/` by hand when a case changes, or the old numbers linger.

Each run writes JSON to `results/`: `step_ms` (min/mean/p50/p95/p99/max), `cpu`
(`cores_used`, `peak_rss_mb`), `body_count`, and a determinism `fingerprint`.

## Watch a case

```bash
./record_helper.sh 2d Rapier2D pyramid      # one case, windowed at 1920x1080
./record_helper.sh 2d Rapier2D all          # every case back to back, 5s each
RES=3840x2160 SECS=8 ./record_helper.sh 3d "Jolt Physics" all
```

Engine names must match what the extension registers, and they differ between addons:

| track | names |
|---|---|
| 2D | `Rapier2D`, `Box2D`, `GodotPhysics2D` |
| 3D | `Rapier3D`, `Jolt Physics`, `Box3D Physics`, `GodotPhysics3D` |

Note the trailing ` Physics` in 3D. A wrong name makes Godot fall back to its own server
silently, so `record_helper.sh` validates it and refuses to launch.

Or open `bench2d/` / `bench3d/` in Godot and press play. In the viewer: `esc` menu,
`space` pause, `r` restart, `d` toggle shape drawing.

## Building Rapier from source

The plugin repo is expected alongside this one at `~/Documents/godot-rapier-2d`.

```bash
cd ~/Documents/godot-rapier-2d
./scripts/build-rel-2d.sh                   # or build-rel-3d.sh
```

That writes into the plugin repo's own `bin2d/`, so copy it here before measuring — otherwise
you benchmark the committed build:

```bash
rsync -a ~/Documents/godot-rapier-2d/bin2d/addons/godot-rapier2d/ bench2d/addons/godot-rapier2d/
```

Use a release build for any number you quote; debug builds are several times slower.

## Prebuilt addons

| addon | where |
|---|---|
| Rapier | [releases](https://github.com/appsinacup/godot-rapier-physics/releases) |
| Box2D | build from [source](https://github.com/erincatto/godot-box2d) |
| Box3D | [releases](https://github.com/bearlikelion/godot-box3d/releases) |
| Jolt | ships with Godot 4.4+ |

Only macOS arm64 is committed. For other platforms drop the libraries into
`bench{2,3}d/addons/*/bin/` and extend the `.gdextension` files.

## Cases

| case | bodies | measures |
|---|---:|---|
| `pyramid` | 10,000 / 3,795 | solver throughput, box-box |
| `mixed_pile` | 5,000 | narrow phase: circle, capsule, convex |
| `joint_grid` | 5,000 / ~9,950 joints | constraints |
| `smash` | 5,001 | high-energy impact |
| `query_storm` | 2,000 + ~900 queries/tick | acceleration structure |
| `drop` | 8,000 | falling, colliding, settling pile |

`BENCH_DROP_COUNT` and `BENCH_DROP_COLS` override the drop scene.

## Layout

```
bench2d/  bench3d/    Godot projects: cases/, framework/, addons/
run_bench.sh          sweep driver
record_helper.sh      windowed playback for screen recording
capture_shots.sh      screenshots at a fixed tick
make_report.py        results/ -> docs/REPORT.md + charts
make_pdf.py           REPORT.md -> PDF + HTML
```
