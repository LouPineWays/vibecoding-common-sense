#!/usr/bin/env python3
"""
Collect per-request token evidence from a Claude Code session transcript.

Why this exists as a script rather than "read the transcript and eyeball it":
three properties of the transcript format will silently corrupt the numbers if
you count by hand, and none of them announce themselves.

  1. STREAMED ENTRIES REPEAT USAGE. One API response is written to the
     transcript as several lines (one per content block), each carrying the
     SAME `message.usage` object. Summing usage across `type == "assistant"`
     lines double-counts by however many blocks the response happened to have.
     Measured on a real 9-request session: 2.31x over-count. Dedupe on
     `message.id`.

  2. CACHE READS ARE MOST OF THE VOLUME AND ARE NOT PRICED LIKE INPUT.
     `cache_read_input_tokens` is ~10x cheaper per token than fresh input, and
     `cache_creation_input_tokens` is 1.25x (5-minute TTL) or 2x (1-hour) MORE
     expensive. A raw token total mixes three prices into one meaningless
     number, and because cache reads dominate, that number is dominated by its
     cheapest component.

  3. SUBAGENTS AND SPILLED TOOL OUTPUT LIVE ELSEWHERE. Subagent transcripts are
     written to `<session>/subagents/`, and tool output too large for context is
     spilled to `<session>/tool-results/` with only a preview inlined. Reading
     only the main .jsonl misses the former entirely; measuring the spill files
     double-counts the latter, because only the preview ever reached context.

Output is aggregate numbers and structural labels only -- turn indices, model
IDs, tool names, token counts, byte counts. It never prints message text, tool
arguments, tool results, or file contents. That is deliberate and load-bearing:
transcripts are unencrypted on disk and contain whatever passed through a tool,
including any secret a command happened to print.

Usage:
    collect-token-evidence.py                    # most recent session, this cwd
    collect-token-evidence.py --session <uuid>   # a specific session
    collect-token-evidence.py --list             # list sessions for this cwd
    collect-token-evidence.py --all --days 7     # every session in the last 7 days
    collect-token-evidence.py --json             # machine-readable

Stdlib only. No dependencies.
"""

import argparse
import json
import os
import sys
from collections import Counter, OrderedDict, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

# --- Cost weights -------------------------------------------------------------
#
# Everything is expressed in "weighted input-token equivalents" (wu): one unit is
# one fresh input token on the model in question. Reported in units, not dollars,
# for three reasons, in order of how much they matter:
#
#   - On a subscription plan (Pro/Max/Team) dollars are not what you spend. Usage
#     comes out of a plan allowance, and Claude Code's own docs say the session
#     dollar figure "isn't relevant for billing purposes" for subscribers.
#   - List prices drift, and the drift is not hypothetical: Claude Sonnet 5 ran a
#     promotional $2/$10 rate that reverts to $3/$15 on 2026-08-31. A skill that
#     hardcodes dollars is wrong on a known date.
#   - The ratios below are structural and have been stable across the model
#     generations that support caching. They are what actually explains where
#     the spend went; the dollar figure just rescales them.
#
# Verify against the current pricing page before quoting money. The one ratio
# worth knowing: output is exactly 5x input on every current Claude model
# (Opus 5 $5/$25, Sonnet 5 $3/$15, Haiku 4.5 $1/$5, Fable 5 $10/$50), which is
# why OUTPUT_WEIGHT is model-independent.
W_INPUT = 1.0        # fresh, uncached input
W_CACHE_WRITE_5M = 1.25   # 5-minute TTL cache write
W_CACHE_WRITE_1H = 2.0    # 1-hour TTL cache write
W_CACHE_READ = 0.1        # cache hit
W_OUTPUT = 5.0            # output, including thinking tokens

# Relative model cost, indexed to the cheapest current model (Haiku 4.5 = 1).
# Used only to compare spend ACROSS models within one report. Substring match,
# longest first.
MODEL_WEIGHT = OrderedDict([
    ("claude-fable-5", 10.0),
    ("claude-mythos-5", 10.0),
    ("claude-opus-5", 5.0),
    ("claude-opus-4", 5.0),
    ("claude-sonnet-5", 3.0),
    ("claude-sonnet-4", 3.0),
    ("claude-haiku-4-5", 1.0),
    ("claude-haiku", 1.0),
])


def model_weight(model):
    for prefix, weight in MODEL_WEIGHT.items():
        if model and model.startswith(prefix):
            return weight
    return None  # unknown model: report raw units, don't guess a multiplier


def projects_dir():
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(Path.home(), ".claude")
    return Path(base) / "projects"


def project_slug(cwd):
    """Claude Code encodes the project path by replacing every non-alphanumeric
    run with a dash. Derive it rather than hardcoding, so this works on any repo."""
    out = []
    for ch in str(cwd):
        out.append(ch if ch.isalnum() else "-")
    return "".join(out)


def find_project_dir(cwd):
    root = projects_dir()
    if not root.is_dir():
        return None
    exact = root / project_slug(cwd)
    if exact.is_dir():
        return exact
    # Fall back to a suffix match: handles container paths that differ from the
    # host path the transcript was recorded under.
    tail = Path(cwd).name
    candidates = [d for d in root.iterdir() if d.is_dir() and d.name.endswith(tail)]
    if len(candidates) == 1:
        return candidates[0]
    return None


def session_files(project_dir, days=None):
    if project_dir is None or not project_dir.is_dir():
        return []
    files = sorted(project_dir.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    if days is not None:
        cutoff = datetime.now().timestamp() - days * 86400
        files = [f for f in files if f.stat().st_mtime >= cutoff]
    return files


def subagent_files(session_file):
    """Subagent transcripts live in <session>/subagents/. Missing these makes a
    delegating session look far cheaper than it was."""
    d = session_file.with_suffix("") / "subagents"
    return sorted(d.glob("*.jsonl")) if d.is_dir() else []


def parse_ts(s):
    """Always returns a timezone-aware datetime, or None.

    Transcripts normally carry a trailing Z, but a naive timestamp from any
    source would make the sort raise `can't compare offset-naive and
    offset-aware datetimes` and take the whole run down. Assume UTC."""
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo is not None else dt.replace(tzinfo=timezone.utc)


def load_requests(path):
    """Return one record per API REQUEST (deduped on message.id), in order."""
    requests = OrderedDict()
    for raw in path.read_text(errors="replace").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if entry.get("type") != "assistant":
            continue
        msg = entry.get("message") or {}
        mid = msg.get("id")
        if not mid:
            continue
        usage = msg.get("usage") or {}
        cc = usage.get("cache_creation") or {}
        rec = requests.get(mid)
        if rec is None:
            rec = {
                "id": mid,
                "ts": parse_ts(entry.get("timestamp")),
                "model": msg.get("model") or "unknown",
                "effort": entry.get("effort"),
                "skill": entry.get("attributionSkill"),
                "sidechain": bool(entry.get("isSidechain")),
                "input": usage.get("input_tokens") or 0,
                "cache_write": usage.get("cache_creation_input_tokens") or 0,
                "cache_write_5m": cc.get("ephemeral_5m_input_tokens") or 0,
                "cache_write_1h": cc.get("ephemeral_1h_input_tokens") or 0,
                "cache_read": usage.get("cache_read_input_tokens") or 0,
                "output": usage.get("output_tokens") or 0,
                "thinking": (usage.get("output_tokens_details") or {}).get("thinking_tokens") or 0,
                "tools": [],
                "_tool_ids": set(),
                "blocks": 0,
            }
            requests[mid] = rec
        # Content blocks are spread across lines: each line for this message id
        # is a snapshot, so the same tool_use block reappears on every later
        # line. Dedupe on the block's own id (unique per call), not on the tool
        # name -- two distinct parallel calls to the same tool in one turn
        # (e.g. two Bash calls) must both count, and deduping by name alone
        # would silently collapse them into one.
        rec["blocks"] += 1
        for block in msg.get("content") or []:
            if block.get("type") == "tool_use":
                tool_id = block.get("id")
                name = block.get("name")
                if name and tool_id and tool_id not in rec["_tool_ids"]:
                    rec["_tool_ids"].add(tool_id)
                    rec["tools"].append(name)
    return list(requests.values())


def cache_write_wu_bounds(rec):
    """Returns (low, high, unsplit_tokens) for the cache-write component alone.

    Older transcripts may carry only the flat `cache_creation_input_tokens`
    total with no 5m/1h split (`cache_creation` was added later). For that
    unsplit remainder the TTL actually used is genuinely unknown -- guessing
    either rate and presenting one number as measured spend is the error a
    reviewer caught here. Report a range instead: low assumes every unsplit
    token was a 5m write, high assumes every one was 1h. When nothing is
    unsplit, low == high and the number is exact, not a bound."""
    w5, w1 = rec["cache_write_5m"], rec["cache_write_1h"]
    unsplit = max(0, rec["cache_write"] - w5 - w1)
    known = w5 * W_CACHE_WRITE_5M + w1 * W_CACHE_WRITE_1H
    return (known + unsplit * W_CACHE_WRITE_5M,
            known + unsplit * W_CACHE_WRITE_1H,
            unsplit)


def weighted(rec):
    """Point estimate for a request's total cost. Uses the high bound (1h) for
    any unsplit cache-write tokens, so this number over-states rather than
    under-states when the true TTL mix is unknown -- see cache_write_wu_bounds
    for the honest range, which the report prints separately when it matters."""
    _, cache_write_hi, _ = cache_write_wu_bounds(rec)
    return (
        rec["input"] * W_INPUT
        + cache_write_hi
        + rec["cache_read"] * W_CACHE_READ
        + rec["output"] * W_OUTPUT
    )


def analyze(session_file, include_subagents=True):
    main = load_requests(session_file)
    subs = []
    if include_subagents:
        for sf in subagent_files(session_file):
            subs.extend(load_requests(sf))
    for r in subs:
        r["sidechain"] = True
    reqs = main + subs
    if not reqs:
        return None

    for r in reqs:
        r["cache_write_wu_lo"], r["cache_write_wu_hi"], r["cache_write_unsplit"] = cache_write_wu_bounds(r)
        r["wu"] = weighted(r)
        mw = model_weight(r["model"])
        r["mw"] = mw
        r["cwu"] = r["wu"] * mw if mw else None

    main_sorted = sorted(main, key=lambda r: (r["ts"] or datetime.min.replace(tzinfo=timezone.utc)))

    # --- cache misses: cache_read == 0 on anything but the first request -------
    misses = []
    for i, r in enumerate(main_sorted):
        if i == 0 or r["cache_read"] > 0:
            continue
        prev = main_sorted[i - 1]
        gap = None
        if r["ts"] and prev["ts"]:
            gap = (r["ts"] - prev["ts"]).total_seconds()
        cause = "unknown"
        if prev["model"] != r["model"]:
            cause = f"model switch ({prev['model']} -> {r['model']})"
        elif gap is not None and gap > 3600:
            cause = f"idle {gap/60:.0f} min (past 1h cache TTL)"
        elif gap is not None and gap > 300:
            cause = f"idle {gap/60:.0f} min (past 5m cache TTL)"
        # Use the same high-bound point estimate as weighted() so this figure
        # is consistent with the session total rather than a separate flat guess.
        misses.append({"index": i, "cause": cause, "rewrite_tokens": r["cache_write"],
                       "wu": r["cache_write_wu_hi"], "gap_s": gap})

    # --- context size per turn ------------------------------------------------
    # cache_read + cache_write is the whole prompt that went up on that request.
    curve = [{"i": i, "context": r["cache_read"] + r["cache_write"] + r["input"],
              "added": r["cache_write"], "tools": r["tools"], "model": r["model"]}
             for i, r in enumerate(main_sorted)]

    # cache_write on the first request is the stable prefix Claude Code marks
    # with cache_control -- system prompt, tool schemas, skill listing -- and is
    # genuinely fixed overhead paid before any work happens. `input` on that
    # same request is whatever *wasn't* covered by a cache breakpoint, which is
    # usually trivial but, if the user's first message is large and uncached,
    # can BE that message. Keep them separate so a big first prompt is never
    # mislabeled as trimmable startup configuration.
    startup = main_sorted[0]["cache_write"] if main_sorted else 0
    first_turn_uncached = main_sorted[0]["input"] if main_sorted else 0

    totals = defaultdict(float)
    for r in reqs:
        for k in ("input", "cache_write", "cache_read", "output", "thinking", "wu",
                   "cache_write_wu_lo", "cache_write_wu_hi", "cache_write_unsplit"):
            totals[k] += r[k]
    totals["cwu"] = sum(r["cwu"] for r in reqs if r["cwu"] is not None)
    totals["cwu_complete"] = all(r["cwu"] is not None for r in reqs)

    by_model = defaultdict(lambda: defaultdict(float))
    for r in reqs:
        by_model[r["model"]]["requests"] += 1
        by_model[r["model"]]["wu"] += r["wu"]
        by_model[r["model"]]["output"] += r["output"]
        by_model[r["model"]]["thinking"] += r["thinking"]

    tool_counts = Counter()
    for r in reqs:
        tool_counts.update(r["tools"])

    skill_wu = defaultdict(float)
    for r in reqs:
        if r["skill"]:
            skill_wu[r["skill"]] += r["wu"]

    span = None
    ts = [r["ts"] for r in main_sorted if r["ts"]]
    if len(ts) >= 2:
        span = (ts[-1] - ts[0]).total_seconds()

    return {
        "file": str(session_file),
        "session": session_file.stem,
        "requests": len(main),
        "subagent_requests": len(subs),
        "transcript_lines_assistant": sum(r["blocks"] for r in main),
        "totals": dict(totals),
        "startup_tokens": startup,
        "first_turn_uncached_tokens": first_turn_uncached,
        "misses": misses,
        "curve": curve,
        "by_model": {k: dict(v) for k, v in by_model.items()},
        "efforts": Counter(r["effort"] for r in main if r["effort"]),
        "tools": tool_counts,
        "skills": dict(skill_wu),
        "span_s": span,
        "records": reqs,
    }


def fmt(n):
    return f"{n:,.0f}"


def report(a):
    t = a["totals"]
    print(f"SESSION {a['session']}")
    print(f"  {a['requests']} API requests"
          + (f" (+{a['subagent_requests']} subagent)" if a["subagent_requests"] else "")
          + f", written as {a['transcript_lines_assistant']} transcript lines")
    if a["transcript_lines_assistant"] > a["requests"]:
        ratio = a["transcript_lines_assistant"] / a["requests"]
        print(f"  -> counting transcript lines instead of requests would over-count {ratio:.2f}x")
    if a["span_s"]:
        print(f"  wall clock: {a['span_s']/60:.0f} min")
    if a["efforts"]:
        print("  effort: " + ", ".join(f"{k}x{v}" for k, v in a["efforts"].most_common()))
    print()

    print("LEDGER (wu = weighted input-token equivalents; see header for weights)")
    # Cache writes are a mix of 5m (1.25x) and 1h (2x) TTLs, so a single flat
    # weight for the whole component would disagree with the session TOTAL
    # (which is summed per-request from the real mix). Use the accumulated
    # per-request wu here instead of raw * one weight, and derive an "effective"
    # weight just for display.
    cw_raw = t["cache_write"]
    cw_wu = t["cache_write_wu_hi"]  # matches weighted()'s point estimate
    cw_weight_display = cw_wu / cw_raw if cw_raw else W_CACHE_WRITE_1H
    rows = [
        ("fresh input", t["input"], W_INPUT, t["input"] * W_INPUT),
        ("cache writes", cw_raw, cw_weight_display, cw_wu),
        ("cache reads", t["cache_read"], W_CACHE_READ, t["cache_read"] * W_CACHE_READ),
        ("output", t["output"], W_OUTPUT, t["output"] * W_OUTPUT),
    ]
    raw_total = t["input"] + t["cache_write"] + t["cache_read"] + t["output"]
    print(f"  {'component':<14} {'raw tokens':>12} {'weight':>7} {'wu':>12}  {'share':>6}")
    for name, raw, w, wu in rows:
        share = wu / t["wu"] * 100 if t["wu"] else 0
        tag = "*" if name == "cache writes" and t["cache_write_unsplit"] else ""
        print(f"  {name:<14} {fmt(raw):>12} {w:>6.2f}x {fmt(wu):>12}  {share:>5.1f}%{tag}")
    print(f"  {'TOTAL':<14} {fmt(raw_total):>12} {'':>7} {fmt(t['wu']):>12}")
    if t["cache_write_unsplit"]:
        lo_share = t["cache_write_wu_lo"] / t["wu"] * 100 if t["wu"] else 0
        hi_share = t["cache_write_wu_hi"] / t["wu"] * 100 if t["wu"] else 0
        print(f"  * {fmt(t['cache_write_unsplit'])} cache-write tokens came from older transcript entries "
              f"with no 5m/1h TTL recorded. True cost is unknown, not exact -- ranges "
              f"{fmt(t['cache_write_wu_lo'])}-{fmt(t['cache_write_wu_hi'])} wu ({lo_share:.1f}-{hi_share:.1f}% of "
              f"session) depending on which TTL wrote them. Figures above use the high (1h) bound.")
    if t["thinking"] and t["output"]:
        print(f"  of output, {fmt(t['thinking'])} tokens ({t['thinking']/t['output']*100:.0f}%) were thinking")
    if t.get("cwu_complete") and len(a["by_model"]) > 1:
        print(f"  cross-model total: {fmt(t['cwu'])} cost-weighted units (Haiku 4.5 = 1x)")
    print()

    print("STARTUP")
    print(f"  cached prefix (system prompt, tools, skill listing): {fmt(a['startup_tokens'])} tokens")
    if a["requests"] > 1:
        reread = a["startup_tokens"] * W_CACHE_READ * (a["requests"] - 1)
        print(f"  re-read on each of the {a['requests']-1} later requests: ~{fmt(reread)} wu")
        print(f"  -> every 1,000 tokens trimmed here saves ~{fmt(1000 * W_CACHE_READ * (a['requests']-1))} wu "
              f"at this session length, and more as sessions run longer")
    ftu = a["first_turn_uncached_tokens"]
    if ftu > 500:
        # Large and uncached on request #1 -- most likely the user's own first
        # message, not startup configuration. Don't attribute it to CLAUDE.md/MCP
        # trimming: that's a different lever than "the prompt itself was long".
        print(f"  + {fmt(ftu)} more tokens on that same request were NOT covered by a cache "
              f"breakpoint -- most likely your first message itself, not fixed overhead. Not "
              f"included above, and trimming CLAUDE.md/MCP servers won't touch it; if it needs "
              f"cutting, that's shortening the prompt itself. Check with /context for the exact split.")
    elif ftu:
        print(f"  (+ {fmt(ftu)} uncached tokens on that request, not fixed overhead)")
    print()

    if a["misses"]:
        print("CACHE MISSES (full context re-written at cache-write rates)")
        total = sum(m["wu"] for m in a["misses"])
        for m in a["misses"]:
            print(f"  request #{m['index']+1}: {fmt(m['rewrite_tokens'])} tokens rewritten "
                  f"= {fmt(m['wu'])} wu -- {m['cause']}")
        share = total / t["wu"] * 100 if t["wu"] else 0
        print(f"  total: {fmt(total)} wu ({share:.0f}% of session)")
        print()

    print("CONTEXT GROWTH (tokens in the prompt on each request)")
    peak = max((c["context"] for c in a["curve"]), default=0)
    for c in a["curve"]:
        bar = "#" * int(c["context"] / peak * 40) if peak else ""
        tools = ",".join(c["tools"][:3]) if c["tools"] else ""
        print(f"  #{c['i']+1:>3} {fmt(c['context']):>9} {bar:<40} +{fmt(c['added']):>7} {tools}")
    print()

    if len(a["by_model"]) > 1:
        print("BY MODEL")
        for m, v in sorted(a["by_model"].items(), key=lambda kv: -kv[1]["wu"]):
            print(f"  {m:<20} {int(v['requests']):>3} req  {fmt(v['wu']):>12} wu")
        print()

    if a["skills"]:
        print("BY SKILL (requests attributed to an active skill)")
        for s, wu in sorted(a["skills"].items(), key=lambda kv: -kv[1]):
            print(f"  {s:<20} {fmt(wu):>12} wu")
        print()

    if a["tools"]:
        print("TOOL CALLS")
        print("  " + ", ".join(f"{k}x{v}" for k, v in a["tools"].most_common(12)))
        print()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--session", help="session id (transcript filename without .jsonl)")
    p.add_argument("--cwd", default=os.getcwd(), help="project directory (default: cwd)")
    p.add_argument("--list", action="store_true", help="list available sessions and exit")
    p.add_argument("--all", action="store_true", help="analyze every session found")
    p.add_argument("--days", type=int, help="only sessions modified in the last N days")
    p.add_argument("--no-subagents", action="store_true", help="skip subagent transcripts")
    p.add_argument("--json", action="store_true", help="emit JSON instead of a report")
    args = p.parse_args()

    pdir = find_project_dir(args.cwd)
    if pdir is None:
        print(f"No transcript directory found for {args.cwd} under {projects_dir()}.", file=sys.stderr)
        print("Transcripts are written per-project; if this is a fresh clone or a different", file=sys.stderr)
        print("machine than the one the work happened on, there is nothing here to read.", file=sys.stderr)
        return 2

    files = session_files(pdir, args.days)
    if not files:
        print(f"No session transcripts in {pdir}"
              + (f" newer than {args.days} days." if args.days else "."), file=sys.stderr)
        print("Transcripts are deleted after cleanupPeriodDays (default 30).", file=sys.stderr)
        return 2

    if args.list:
        for f in files:
            mt = datetime.fromtimestamp(f.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
            print(f"{f.stem}  {mt}  {f.stat().st_size/1024:.0f} KB")
        return 0

    if args.session:
        files = [f for f in files if f.stem == args.session]
        if not files:
            print(f"Session {args.session} not found. Use --list.", file=sys.stderr)
            return 2
    elif not args.all:
        files = files[:1]

    results = []
    for f in files:
        a = analyze(f, include_subagents=not args.no_subagents)
        if a:
            results.append(a)

    if not results:
        print("Transcripts found, but none contain assistant requests with usage data.", file=sys.stderr)
        return 2

    if args.json:
        for a in results:
            a.pop("records", None)
            a["efforts"] = dict(a["efforts"])
            a["tools"] = dict(a["tools"])
        print(json.dumps(results, indent=2, default=str))
        return 0

    for i, a in enumerate(results):
        if i:
            print("=" * 72)
        report(a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
