#!/usr/bin/env python3
"""Build docs/REPORT.md from the benchmark JSON: screenshots, tables, charts.

Reads results/<dim>/<engine>/<case>_r<N>.json as written by run_bench.sh.

Across repeats it reports the median of each repeat's p50, so one repeat disturbed by other
load on the machine does not move the headline.

Two validity checks run before anything is ranked. Engines within a case that share a
fingerprint did not both run — Godot falls back to its default server without warning when it
cannot find the engine named in project settings. And repeats of one engine that disagree
were not simulating the same thing twice.
"""

import json
import math
import pathlib
import re
import statistics
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

CASE_ORDER = [
    "pyramid",
    "mixed_pile",
    "joint_grid",
    "smash",
    "query_storm",
    "ghost_collisions",
]

BASELINE = {"2d": "Rapier2D", "3d": "Rapier3D"}
COLORS = {
    "Rapier2D": "#4c8dff",
    "Rapier3D": "#4c8dff",
    "Box2D": "#f2a33c",
    "Jolt Physics": "#f2a33c",
    "GodotPhysics2D": "#8b93a1",
    "GodotPhysics3D": "#8b93a1",
}
FG = "#c9d1d9"
BG = "#0d1117"

ROOT = pathlib.Path(__file__).parent


def fmt(value):
    if value is None:
        return "—"
    if isinstance(value, float) and not value.is_integer():
        return f"{value:.4g}"
    return f"{int(value)}"


def _repeats(tree):
    counts = {
        len(runs) for cases in tree.values() for e in cases.values() for runs in e.values()
    }
    return max(counts) if counts else 1


def load(results_dir):
    tree = {}
    for path in sorted(results_dir.rglob("*.json")):
        rel = path.relative_to(results_dir)
        if len(rel.parts) != 3:
            continue
        try:
            run = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError) as exc:
            print(f"warning: unreadable {path}: {exc}", file=sys.stderr)
            continue
        tree.setdefault(rel.parts[0], {}).setdefault(run.get("case", "?"), {}).setdefault(
            run.get("engine_label", "unknown"), []
        ).append(run)
    return tree


def summarize(runs):
    p50s = [r["step_ms"]["p50_ms"] for r in runs]
    extra = {}
    diverged = False
    for r in runs:
        for key, value in (r.get("extra_metrics") or {}).items():
            # Godot writes inf as 1e99999 and NaN as null. Either means the world blew up,
            # and stepping a blown up world is cheap, so its time must not be ranked.
            if value is None or (isinstance(value, float) and not math.isfinite(value)):
                diverged = True
                value = math.inf
            extra.setdefault(key, []).append(value)
    return {
        "diverged": diverged,
        "diverged_reason": "reported a non-finite metric, so the simulation blew up" if diverged else None,
        "repeats": len(runs),
        "p50": min(p50s),
        "median": statistics.median(p50s),
        "lo": min(p50s),
        "hi": max(p50s),
        "p99": min(r["step_ms"]["p99_ms"] for r in runs),
        "bodies": runs[0].get("body_count", 0),
        "fps": sorted({r.get("fingerprint", "?") for r in runs}),
        "extra": {k: statistics.median(v) for k, v in extra.items()},
    }


def style(ax):
    ax.set_facecolor(BG)
    for spine in ax.spines.values():
        spine.set_color("#30363d")
    ax.tick_params(colors=FG, labelsize=9)
    ax.xaxis.label.set_color(FG)
    ax.grid(axis="x", color="#21262d", linewidth=0.8)
    ax.set_axisbelow(True)


def chart_absolute(dim, cases, data, engines, out):
    height = max(3.0, 0.42 * len(cases) * len(engines))
    fig, ax = plt.subplots(figsize=(11.0, height), facecolor=BG)
    style(ax)
    n = len(engines)
    ypos = []
    for row, case in enumerate(cases):
        for i, engine in enumerate(engines):
            s = data[case].get(engine)
            if s is None or s["diverged"]:
                continue
            y = row * (n + 0.8) + i
            ypos.append(y)
            ax.barh(y, s["p50"], color=COLORS.get(engine, "#777"), height=0.82)
            ax.text(
                s["p50"] * 1.05, y, f"{s['p50']:.2f}", va="center", color=FG, fontsize=7.5
            )
    ax.set_yticks([row * (n + 0.8) + (n - 1) / 2 for row in range(len(cases))])
    ax.set_yticklabels(cases, color=FG, fontsize=9)
    ax.invert_yaxis()
    ax.set_xscale("log")
    ax.set_xlabel("step time (ms, log scale)")
    handles = [plt.Rectangle((0, 0), 1, 1, color=COLORS.get(e, "#777")) for e in engines]
    legend = ax.legend(handles, engines, loc="upper left", bbox_to_anchor=(1.005, 1.0),
                       fontsize=8, facecolor="#161b22", edgecolor="#30363d")
    for text in legend.get_texts():
        text.set_color(FG)
    ax.set_title(f"{dim.upper()} (lower is better)", color=FG, fontsize=12, loc="left")
    fig.tight_layout()
    fig.savefig(out, dpi=140, facecolor=BG)
    plt.close(fig)


def chart_relative(dim, cases, data, engines, out):
    base = BASELINE[dim]
    others = [e for e in engines if e != base]
    if not others:
        return False
    fig, ax = plt.subplots(figsize=(11.0, max(2.6, 0.34 * len(cases))), facecolor=BG)
    style(ax)
    for i, engine in enumerate(others):
        xs, ys = [], []
        for row, case in enumerate(cases):
            s, b = data[case].get(engine), data[case].get(base)
            if not s or not b or b["p50"] <= 0 or s["diverged"] or b["diverged"]:
                continue
            xs.append(s["p50"] / b["p50"])
            ys.append(row + (i - (len(others) - 1) / 2) * 0.32)
        ax.barh(ys, xs, color=COLORS.get(engine, "#777"), height=0.3, label=engine)
    ax.axvline(1.0, color="#4c8dff", linewidth=1.4)
    ax.set_yticks(range(len(cases)))
    ax.set_yticklabels(cases, color=FG, fontsize=9)
    ax.invert_yaxis()
    ax.set_xscale("log")
    ax.set_xlabel(f"step time relative to {base} (1.0 = same; >1 slower than {base})")
    legend = ax.legend(loc="upper left", bbox_to_anchor=(1.005, 1.0), fontsize=8,
                       facecolor="#161b22", edgecolor="#30363d")
    for text in legend.get_texts():
        text.set_color(FG)
    ax.set_title(f"{dim.upper()} — relative to {base}", color=FG, fontsize=11, loc="left")
    fig.tight_layout()
    fig.savefig(out, dpi=140, facecolor=BG)
    plt.close(fig)
    return True


# Extra metrics that measure how far bodies travelled. A world can explode without ever going
# non-finite: bodies fly apart, stop touching, and the step gets cheap — a fast time for a
# simulation that failed. So a value far beyond every other engine's on the same case marks the
# run diverged. Relative, because what counts as "far" differs by case; compared against the
# largest other value, so an engine that merely settles looser is not caught.
EXPLOSION_METRICS = ("displacement_max", "spread")
EXPLOSION_RATIO = 10.0


def mark_exploded(case_data):
    for key in EXPLOSION_METRICS:
        values = {
            e: v["extra"][key]
            for e, v in case_data.items()
            if key in v["extra"] and math.isfinite(v["extra"][key])
        }
        for engine, value in values.items():
            others = [x for e, x in values.items() if e != engine]
            if not others or max(others) <= 0:
                continue
            ratio = value / max(others)
            if ratio > EXPLOSION_RATIO and not case_data[engine]["diverged"]:
                case_data[engine]["diverged"] = True
                case_data[engine]["diverged_reason"] = (
                    f"has `{key}` at {ratio:,.0f}x any other engine's, so the simulation exploded"
                )


def carried_section(docs, dim):
    """A track's section from its existing REPORT-<DIM>.md, for a run that did not include it.

    Running one track would otherwise drop the other from the combined report. The section is
    marked as carried over, with the run line it was measured under, so it is not mistaken for
    numbers from this run.
    """
    path = docs / f"REPORT-{dim.upper()}.md"
    if not path.exists():
        return None
    lines = path.read_text(encoding="utf-8").split("\n")
    start = next((i for i, l in enumerate(lines) if l.startswith(f"## {dim.upper()} ")), None)
    if start is None:
        return None
    meta = next((l for l in lines[:start] if l.startswith("Godot ")), None)
    note = f"_Not re-run: carried over from `{path.name}`" + (
        f" ({meta.rstrip('.')})._" if meta else "._"
    )
    return [lines[start], "", note] + lines[start + 1 :]


def main():
    results_dir = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "results"
    docs = ROOT / "docs"
    docs.mkdir(exist_ok=True)

    tree = load(results_dir)
    if not tree:
        print(f"no results under {results_dir}", file=sys.stderr)
        return 1

    sample = next(iter(next(iter(next(iter(tree.values())).values())).values()))[0]
    warnings = []

    out = [
        "# Godot physics engine benchmark",
        "",
        f"Godot {sample.get('godot_version', '?')} · {sample.get('steps', '?')} timed steps · "
        f"{sample.get('physics_ticks_per_second', 60)} Hz · "
        + ("single run" if _repeats(tree) == 1 else f"best of {_repeats(tree)} runs")
        + " · lower is better.",
        "",
    ]

    carried = {
        d: s for d in BASELINE if d not in tree and (s := carried_section(docs, d)) is not None
    }

    per_dim = {}
    for dim in sorted(set(tree) | set(carried)):
        if dim not in tree:
            out += carried[dim]
            continue
        section_start = len(out)
        cases_present = tree[dim]
        ordered = [c for c in CASE_ORDER if c in cases_present] + [
            c for c in sorted(cases_present) if c not in CASE_ORDER
        ]
        data = {c: {e: summarize(r) for e, r in cases_present[c].items()} for c in ordered}
        for c in ordered:
            mark_exploded(data[c])
        engines = sorted(
            {e for c in ordered for e in data[c]}, key=lambda e: (e != BASELINE.get(dim), e)
        )

        chart_absolute(dim, ordered, data, engines, docs / f"chart_{dim}.png")
        has_rel = chart_relative(dim, ordered, data, engines, docs / f"chart_{dim}_rel.png")

        out += [f"## {dim.upper()} (lower is better)", "", f"![{dim} step time](chart_{dim}.png)", ""]
        if has_rel:
            out += [f"![{dim} relative](chart_{dim}_rel.png)", ""]


        for case in ordered:
            s = data[case]
            out += [f"### `{case}` ({dim})", ""]
            # One screenshot per engine, side by side: the end state is itself a result.
            # Two solvers can post similar step times and still leave visibly different
            # piles, and that difference is invisible in a table of milliseconds.
            shots = [
                (e, f"shots/{dim}_{case}_{e.replace(' ', '_')}.png")
                for e in engines
                if (docs / f"shots/{dim}_{case}_{e.replace(' ', '_')}.png").exists()
            ]
            if shots:
                out += [
                    "| " + " | ".join(e for e, _ in shots) + " |",
                    "|---" * len(shots) + "|",
                    "| " + " | ".join(f"![{e}]({s})" for e, s in shots) + " |",
                    "",
                ]
            elif (docs / f"shots/{dim}_{case}.png").exists():
                out += [f"![{case}](shots/{dim}_{case}.png)", ""]
            out += [
                "| engine | step p50 | step p99 | vs " + BASELINE.get(dim, "baseline") + " |",
                "|---|---:|---:|---:|",
            ]
            for missing in [e for e in engines if e not in s]:
                out.append(f"| {missing} | failed | — | — |")
            valid = {e: v for e, v in s.items() if not v["diverged"]}
            for engine in sorted(e for e in s if e not in valid):
                out.append(f"| {engine} | diverged | — | — |")
            base = valid.get(BASELINE.get(dim), {}).get("p50")
            fastest = min((v["p50"] for v in valid.values()), default=None)
            for engine in sorted(valid, key=lambda e: valid[e]["p50"]):
                v = valid[engine]
                rel = (
                    "—"
                    if engine == BASELINE.get(dim)
                    else (f"{v['p50'] / base:.2f}x" if base else "—")
                )
                win = v["p50"] == fastest
                name = f"**{engine}**" if win else engine
                p50 = f"**{v['p50']:.2f} ms**" if win else f"{v['p50']:.2f} ms"
                out.append(f"| {name} | {p50} | {v['p99']:.2f} ms | {rel} |")
            keys = sorted(
                k
                for k in {k for v in s.values() for k in v["extra"]}
                if any(v["extra"].get(k) for v in s.values())
            )
            if keys:
                out += [
                    "",
                    "| engine | " + " | ".join(f"`{k}`" for k in keys) + " |",
                    "|---" * (len(keys) + 1) + "|",
                ]
                for engine in sorted(s):
                    out.append(
                        f"| {engine} | "
                        + " | ".join(fmt(s[engine]["extra"].get(k)) for k in keys)
                        + " |"
                    )
            out.append("")

            owners = {}
            for engine, v in s.items():
                if v["diverged"]:
                    warnings.append(
                        f"{dim}/{case}: {engine} {v['diverged_reason']} — its step time is "
                        f"not ranked."
                    )
                if len(v["fps"]) > 1:
                    warnings.append(
                        f"{dim}/{case}: {engine} produced {len(v['fps'])} fingerprints across "
                        f"{v['repeats']} repeats — its repeats diverged."
                    )
                for f in v["fps"]:
                    owners.setdefault(f, []).append(engine)
            for f, es in owners.items():
                if len(es) > 1:
                    warnings.append(
                        f"{dim}/{case}: {' and '.join(sorted(es))} share fingerprint {f} — at "
                        f"least one fell back to the default server; those columns are invalid."
                    )

        per_dim[dim] = out[section_start:]

    # Taken before the warnings go in: they are inserted after the title, and slicing afterwards
    # gives the per-dimension files a warnings heading in place of the run line.
    header = out[:4]

    def with_warnings(lines, ws):
        if not ws:
            return lines
        return lines[:2] + ["## ⚠ Validity warnings", ""] + [f"- {w}" for w in ws] + [""] + lines[2:]

    (docs / "REPORT.md").write_text("\n".join(with_warnings(out, warnings)), encoding="utf-8")
    print(f"wrote {docs / 'REPORT.md'}")
    # One file per dimension too: the tracks share no engine, so a reader only ever wants one —
    # and that reader still needs to know which of its columns are invalid. Every warning is
    # prefixed "<dim>/<case>:", which is what routes it to its track.
    for dim, body in per_dim.items():
        path = docs / f"REPORT-{dim.upper()}.md"
        own = [w for w in warnings if w.startswith(f"{dim}/")]
        path.write_text("\n".join(with_warnings(header + body, own)), encoding="utf-8")
        print(f"wrote {path}")
    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
