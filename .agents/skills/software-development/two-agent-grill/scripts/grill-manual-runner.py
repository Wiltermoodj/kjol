#!/usr/bin/env python3
"""
Two-Agent Grill — Manual Session Runner (v2.5.5)

This script implements the actual grill protocol as exercised in session 2f163eba:
1. Generates a SESSION_TOKEN
2. Creates sidecar.md with pre-written Q1, Q2 (GM writes directly, no subagent)
3. Spawns Reviewer subprocesses via `hermes chat -q "$(cat prompt)" -m stepfun/step-3.7-flash:free -t file -Q`
4. Polls for R hashes at 5s intervals (up to 300s)
5. Verifies verdicts extracted correctly

Usage:
    python3 grill-manual.py --repo <repo_path> --module <module_name> --sidecar <sidecar_path>

Note: This is a thin orchestrator. The GM (Master Agent) writes Q1/Q2 directly into the
sidecar. The Reviewer prompts are generated as temp files and spawned via CLI.
"""

import argparse
import os
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path


def generate_token() -> str:
    """8-char hex session token."""
    return secrets.token_hex(4)


def spawn_reviewer(prompt_file: str, token: str, q_num: int, repo_path: str, timeout_s: int = 300) -> int:
    """
    Spawn a Reviewer subprocess via hermes chat CLI.
    
    Key fix: use -q "$(cat <file>" not --query-file (which doesn't exist).
    """
    prompt_content = Path(prompt_file).read_text()
    
    cmd = [
        "hermes", "chat",
        "-q", prompt_content,
        "-m", "stepfun/step-3.7-flash:free",
        "-t", "file",
        "-Q",
        "--max-turns", "12",
    ]
    
    print(f"[spawn_reviewer] Q{q_num} — launching Reviewer subprocess (PID will be forked)")
    proc = subprocess.Popen(
        cmd,
        cwd=repo_path,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    print(f"[spawn_reviewer] Q{q_num} — Reviewer PID: {proc.pid}")
    return proc.pid


def poll_for_hash(sidecar_path: str, token: str, q_num: int, timeout_s: int = 300, interval_s: int = 5) -> bool:
    """
    Poll the sidecar for the Reviewer completion hash.
    
    Pattern: <!--{TOKEN}_R_Q{N}_DONE-->
    After hash appears, poll an additional 15-30s for verdict text (Reviewer writes hash before verdict).
    """
    hash_marker = f"<!--{token}_R_Q{q_num}_DONE-->"
    
    elapsed = 0
    hash_found = False
    
    while elapsed < timeout_s:
        content = Path(sidecar_path).read_text()
        if hash_marker in content:
            hash_found = True
            break
        time.sleep(interval_s)
        elapsed += interval_s
        if elapsed % 30 == 0:
            print(f"[poll_for_hash] Q{q_num} — waiting for R hash... ({elapsed}s elapsed)")
    
    if not hash_found:
        print(f"[poll_for_hash] Q{q_num} — TIMEOUT: R hash not found after {timeout_s}s")
        return False
    
    print(f"[poll_for_hash] Q{q_num} — R hash found at {elapsed}s. Polling for verdict text...")
    
    # Poll additional 15-30s for verdict text after hash appears
    verdict_pattern = rf"Verdict.*?\s*(Agree|Partially agree|Disagree)"
    verdict_found = False
    
    verdict_elapsed = 0
    max_verdict_wait = 30
    
    while verdict_elapsed < max_verdict_wait:
        content = Path(sidecar_path).read_text()
        hash_idx = content.find(hash_marker)
        if hash_idx >= 0:
            # Look backwards from hash for the verdict (reviewer writes hash before verdict in patch call)
            # Actually, reviewer writes hash BEFORE review text — so look AFTER the hash line
            section_after = content[hash_idx:]
            # Also check before the hash (some reviewers write review then hash)
            section_before = content[:hash_idx]
            
            if re.search(verdict_pattern, section_after) or re.search(verdict_pattern, section_before):
                verdict_found = True
                break
        
        time.sleep(5)
        verdict_elapsed += 5
    
    if not verdict_found:
        print(f"[poll_for_hash] Q{q_num} — WARNING: Hash found but verdict text not detected after {max_verdict_wait}s")
        # Extract what we can
        content = Path(sidecar_path).read_text()
        # Find the Review section near the hash
        return True  # Hash found, verdict may be delayed
    
    print(f"[poll_for_hash] Q{q_num} — Verdict text confirmed at {elapsed + verdict_elapsed}s")
    return True


def extract_verdict(sidecar_path: str, token: str, q_num: int) -> str:
    """
    Extract the verdict from the sidecar using regex that matches both formats:
    - **Verdict:** Agree (bold markdown)
    - Verdict: Agree (plain text)
    """
    content = Path(sidecar_path).read_text()
    hash_marker = f"<!--{token}_R_Q{q_num}_DONE-->"
    
    # Look in the region around the R hash
    hash_idx = content.find(hash_marker)
    if hash_idx < 0:
        return "Unknown"
    
    # Check both sides of the hash (Reviewer writes hash before or after review)
    region = content[max(0, hash_idx - 500):hash_idx + 500]
    
    match = re.search(r'Verdict.*?\s*(Agree|Partially agree|Disagree)', region, re.IGNORECASE | re.DOTALL)
    if match:
        return match.group(1).strip()
    
    return "Unknown"


def main():
    parser = argparse.ArgumentParser(description="Two-Agent Grill manual session runner")
    parser.add_argument("--repo", required=True, help="Path to the repo being grilled")
    parser.add_argument("--module", required=True, help="Module name (e.g., KjolHelper/main.swift)")
    parser.add_argument("--sidecar", required=True, help="Path to the sidecar.md file")
    parser.add_argument("--prompt-q1", required=True, help="Path to Reviewer prompt for Q1")
    parser.add_argument("--prompt-q2", required=True, help="Path to Reviewer prompt for Q2")
    parser.add_argument("--timeout", type=int, default=300, help="Polling timeout in seconds")
    parser.add_argument("--parallel", action="store_true", default=True, help="Spawn Reviewers in parallel")
    
    args = parser.parse_args()
    
    token = generate_token()
    print(f"[grill] Session token: {token}")
    
    sidecar_path = args.sidecar
    
    # Verify GM hashes are present
    for qn in [1, 2]:
        gm_hash = f"<!--{token}_GM_Q{qn}_DONE-->"
        if gm_hash not in Path(sidecar_path).read_text():
            print(f"[grill] ERROR: GM hash {gm_hash} not found in sidecar!")
            sys.exit(1)
        print(f"[grill] Verified GM Q{qn} hash present")
    
    # Spawn Reviewers
    pids = []
    
    if args.parallel:
        print("[grill] Spawning both Reviewers in parallel...")
        pid1 = spawn_reviewer(args.prompt_q1, token, 1, args.repo)
        pids.append(("Q1", pid1))
        pid2 = spawn_reviewer(args.prompt_q2, token, 2, args.repo)
        pids.append(("Q2", pid2))
    else:
        print("[grill] Spawning Q1 Reviewer...")
        pid1 = spawn_reviewer(args.prompt_q1, token, 1, args.repo)
        pids.append(("Q1", pid1))
        # Wait for Q1 before spawning Q2
        poll_for_hash(sidecar_path, token, 1, timeout_s=args.timeout)
        print("[grill] Spawning Q2 Reviewer...")
        pid2 = spawn_reviewer(args.prompt_q2, token, 2, args.repo)
        pids.append(("Q2", pid2))
    
    # Wait for all reviewers (parallel mode)
    for q_label, pid in pids:
        print(f"[grill] Waiting for {q_label} Reviewer (PID {pid})...")
        proc = subprocess.run(["wait", str(pid)], capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"[grill] WARNING: {q_label} Reviewer exited with code {proc.returncode}")
    
    # Poll for hashes
    for qn in [1, 2]:
        found = poll_for_hash(sidecar_path, token, qn, timeout_s=args.timeout)
        if found:
            verdict = extract_verdict(sidecar_path, token, qn)
            print(f"[grill] Q{qn} verdict: {verdict}")
        else:
            print(f"[grill] Q{qn} — FAILED to get Reviewer completion")
    
    print("[grill] Session complete. Verdicts collected.")


if __name__ == "__main__":
    main()
