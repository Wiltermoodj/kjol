#!/usr/bin/env python3
"""
Verify verdict extraction from sidecar files.
Run after the grill pipeline to check for missing verdicts or R hashes.

Usage: python3 verify-sidecars.py [repo_path]
"""
import sys, os, re, glob

REPO = sys.argv[1] if len(sys.argv) > 1 else "/Users/lappier/code/projects/trail-tune-new"
WORKSPACE = f"{REPO}/src/services"

SKIP = {"data-health-service", "tune-recommendation", "index", "types"}

issues = []
total = 0
missing_verdicts = 0
missing_hashes = 0
missing_fe = 0

for f in sorted(glob.glob(f"{WORKSPACE}/*.ts.md")):
    base = os.path.basename(f).replace(".ts.md", "")
    if base in SKIP:
        continue
    # Skip spec docs
    content = open(f).read()
    if "type: sidecar-spec" in content or "type: spec" in content:
        continue
    
    # Must have Q1 R hash
    if "_R_Q1_DONE-->" not in content:
        issues.append(f"  {base}: Missing Q1 R hash")
        missing_hashes += 1
        continue
    
    total += 1
    
    # Check Q1 verdict
    q1_section = content.split("### Q2")[0] if "### Q2" in content else content
    q1_verdicts = re.findall(r'\*\*Verdict:\*\*\s*(Agree|Partially agree|Disagree)', q1_section)
    if not q1_verdicts:
        issues.append(f"  {base}: Q1 has R hash but no Verdict")
        missing_verdicts += 1
    
    # Check Q2 verdict
    q2_section = content.split("### Q2")[1].split("## Proposed")[0] if "### Q2" in content else ""
    q2_verdicts = re.findall(r'\*\*Verdict:\*\*\s*(Agree|Partially agree|Disagree)', q2_section)
    if not q2_verdicts:
        issues.append(f"  {base}: Q2 has R hash but no Verdict")
        missing_verdicts += 1
    
    # Check FE
    if "## Feature Expansion" in content and "_R_FE_DONE-->" not in content:
        issues.append(f"  {base}: FE section exists but no R_FE_DONE hash")
        missing_fe += 1
    elif "## Feature Expansion" in content and "_R_FE_DONE-->" in content:
        fe_section = content.split("## Feature Expansion")[1]
        fe_verdicts = re.findall(r'\*\*Verdict:\*\*\s*(Agree|Partially agree|Disagree)', fe_section)
        if not fe_verdicts:
            issues.append(f"  {base}: FE has hash but no Verdict")
            missing_verdicts += 1

print(f"=== Sidecar Verification Report ===")
print(f"Total grilled domains: {total}")
print(f"Missing R hashes: {missing_hashes}")
print(f"Missing verdicts: {missing_verdicts}")
print(f"Missing FE verdicts: {missing_fe}")

if issues:
    print(f"\n=== Issues Found ({len(issues)}) ===")
    for issue in issues:
        print(issue)
else:
    print("\n✅ All sidecars verified — no issues found")

sys.exit(1 if issues else 0)
