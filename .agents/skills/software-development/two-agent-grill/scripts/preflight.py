#!/usr/bin/env python3
"""
two-agent-grill preflight — run BEFORE spawning any grill subagent.

Checks the three things every grill session needs, and prints the current
Q count + ADR line so the Master Agent can fill in goal templates without
hand-grepping. Exits non-zero if a required file is missing.

Usage:
  python3 preflight.py --code <path> --sidecar <path> --session <path> [--quiet]

Example:
  python3 preflight.py \
    --code /Users/lappier/code/projects/middlewarez/apps/integration/src/lib/pos-adapter.ts \
    --sidecar /Users/lappier/code/projects/middlewarez/apps/integration/src/lib/pos-adapter.ts.md \
    --session /Users/lappier/code/projects/middlewarez/knowledge/planning/pos-adapter/docs/grill-session-v2.md
"""
import argparse
import os
import re
import sys


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--code", required=True)
    p.add_argument("--sidecar", required=True)
    p.add_argument("--session", required=True)
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args()

    ok = True

    for label, path in (("CODE", args.code), ("SIDECAR", args.sidecar), ("SESSION", args.session)):
        if os.path.isfile(path):
            if not args.quiet:
                print(f"OK   {label:8} {path}")
        else:
            ok = False
            print(f"MISS {label:8} {path}", file=sys.stderr)

    if not ok:
        print("\nPreflight FAILED: create missing files before spawning subagents.", file=sys.stderr)
        sys.exit(1)

    # Probe sidecar state for goal-template filling.
    with open(args.sidecar, "r") as f:
        text = f.read()

    q_count = len(re.findall(r"^### Q\d+", text, re.MULTILINE))
    adr_match = re.search(r"^## ADR", text, re.MULTILINE)
    adr_line = adr_match.start() if adr_match else len(text)
    # Convert byte offset to 1-based line number.
    adr_line_no = text.count("\n", 0, adr_match.start()) + 1 if adr_match else q_count + 1

    if not args.quiet:
        print(f"\nProbe (fill into GM/Reviewer goals):")
        print(f"  Q count : {q_count}  -> next Q is Q{q_count + 1}")
        print(f"  ADR line: {adr_line_no}  -> insert Q{{N+1}} BEFORE this line")

    # Machine-readable line for callers.
    print(f"QCOUNT={q_count} ADRLINE={adr_line_no}")


if __name__ == "__main__":
    main()
