#!/usr/bin/env python3
"""Compare two sandboxd versions' answers to the file-operation probes and
print a before/after table and a verdict. This reads the per-version JSON that
run.sh assembles (probe.py output plus the fixtures that survived); it talks to
nothing.

    verdict.py <baseline.json> <candidate.json>   measure
    verdict.py plant                              self-test the gate

The gate reacts or it proves nothing (AGENTS.md, "A check is trusted only
after it has failed"). It demands positive evidence on every dimension and
every control, and fails closed: a dimension whose baseline is neither the old
behaviour nor the fix, or a run where a control did not hold, is INCONCLUSIVE,
never "fixed". `plant` tampers a clean run two ways and fails unless the gate
rejects each.

Dimensions, each an upstream fix measured across the two tags:

  fifo     #2222  GET of a named pipe: hangs open (baseline) -> 400
                  INVALID_ARGUMENT (candidate).
  device   #2222  GET of a device node: opens and answers 200 (baseline) ->
                  400 INVALID_ARGUMENT (candidate).
  symlink_file  #2218  DELETE of an in-root symlink to a file: 204, follows
                  the link and deletes the target (baseline) -> 204, removes
                  the link, target survives (candidate).
  symlink_dir   #2218  DELETE ?recursive=true of an in-root symlink to a
                  directory: 204, follows the link and clears the directory
                  (baseline) -> 204, removes the link, directory survives
                  (candidate).

Controls, enforced on BOTH tags, so a verdict cannot pass on a broken endpoint
or a run that lost a file it must not touch: GET of a regular file is 200,
DELETE of a regular file is 204, and the escaping symlink's out-of-root target
survives (on the baseline because the DELETE is refused with 403, on the
candidate because only the link is removed).
"""
import copy
import json
import sys

CONFIRMED, INCONCLUSIVE, FAILED = "CONFIRMED", "INCONCLUSIVE", "FAILED"
DIMS = ["fifo", "device", "symlink_file", "symlink_dir"]


def fixed(v, dim):
    """Does version v show the fixed (candidate) behaviour on dimension dim?
    Positive evidence only: a no-op or errored delete is not "fixed"."""
    p, after = v["probes"], v.get("after", {})
    if dim == "fifo":
        q = p["get_fifo"]
        return q.get("status") == 400 and q.get("code") == "INVALID_ARGUMENT"
    if dim == "device":
        q = p["get_device"]
        return q.get("status") == 400 and q.get("code") == "INVALID_ARGUMENT"
    if dim == "symlink_file":
        return (p["delete_inroot_link_file"].get("status") == 204
                and after.get("realfile") == "yes" and after.get("link_file") == "gone")
    if dim == "symlink_dir":
        return (p["delete_inroot_link_dir"].get("status") == 204
                and after.get("realdir_keep") == "yes" and after.get("link_dir") == "gone")
    raise KeyError(dim)


def old(v, dim):
    """Does version v show the baseline (pre-fix) behaviour on dimension dim?"""
    p, after = v["probes"], v.get("after", {})
    if dim == "fifo":
        return p["get_fifo"].get("timed_out") is True          # the handler hung open
    if dim == "device":
        return p["get_device"].get("status") == 200            # opened and served the device
    if dim == "symlink_file":
        return p["delete_inroot_link_file"].get("status") == 204 and after.get("realfile") == "no"
    if dim == "symlink_dir":
        return p["delete_inroot_link_dir"].get("status") == 204 and after.get("realdir_keep") == "no"
    raise KeyError(dim)


def controls_ok(v):
    """The per-dimension controls that must hold on every tag: the endpoint
    works (GET 200, DELETE 204 on a regular file), and the escaping symlink's
    out-of-root target survives."""
    p, after = v["probes"], v.get("after", {})
    return (p.get("control_get_regular", {}).get("status") == 200
            and p.get("control_delete_regular", {}).get("status") == 204
            and after.get("outside_sentinel") == "yes")


def evaluate(baseline, candidate):
    """Return (verdict, rows, reasons). CONFIRMED needs both controls to hold
    and every dimension to move from the baseline behaviour to the fix. Fails
    closed: an undecided dimension or a broken control is INCONCLUSIVE."""
    reasons = []
    if not controls_ok(baseline) or not controls_ok(candidate):
        reasons.append("a control did not hold: GET regular 200, DELETE regular 204, "
                       "or the out-of-root sentinel survived")
        return INCONCLUSIVE, [], reasons

    rows, deltas, regressions, undecided, already = [], 0, [], [], []
    for d in DIMS:
        bo, bf, cf = old(baseline, d), fixed(baseline, d), fixed(candidate, d)
        rows.append((d, bf, cf))
        if not cf:
            regressions.append(d)          # candidate must be fixed
        elif bo:
            deltas += 1                     # a real before -> after move
        elif bf:
            already.append(d)               # baseline was already fixed
        else:
            undecided.append(d)             # baseline is neither: fixture/behaviour off

    if regressions:
        reasons.append("candidate is not fixed on: " + ", ".join(regressions))
        return FAILED, rows, reasons
    if undecided:
        reasons.append("baseline is neither the old behaviour nor the fix on: "
                       + ", ".join(undecided))
        return INCONCLUSIVE, rows, reasons
    if deltas == 0:
        reasons.append("no dimension showed a before/after difference")
        return INCONCLUSIVE, rows, reasons
    if already:
        reasons.append("baseline already fixed on: " + ", ".join(already))
    return CONFIRMED, rows, reasons


def behaviour(v, dim):
    """One-cell description of what version v did on dimension dim."""
    p, after = v["probes"], v.get("after", {})
    if dim == "fifo":
        q = p["get_fifo"]
        if q.get("status") == 400:
            return "400 INVALID_ARGUMENT"
        if q.get("timed_out"):
            return "hang (no answer in %ss)" % q.get("elapsed")
        return "status %s" % q.get("status")
    if dim == "device":
        q = p["get_device"]
        if q.get("status") == 400:
            return "400 INVALID_ARGUMENT"
        if q.get("status") == 200:
            return "200, opened device (%s bytes, eof=%s)" % (q.get("bytes"), q.get("eof"))
        return "status %s" % q.get("status")
    if dim == "symlink_file":
        s = p["delete_inroot_link_file"].get("status")
        return "%s, target %s, link %s" % (s, after.get("realfile"), after.get("link_file"))
    if dim == "symlink_dir":
        s = p["delete_inroot_link_dir"].get("status")
        return "%s, dir keep %s, link %s" % (s, after.get("realdir_keep"), after.get("link_dir"))
    return "?"


def table(baseline, candidate, bt, ct):
    out = ["| fix | probe | %s (baseline) | %s (candidate) |" % (bt, ct),
           "|-----|-------|---------------|----------------|"]
    fixpr = {
        "fifo": ("#2222", "GET named pipe"),
        "device": ("#2222", "GET device node"),
        "symlink_file": ("#2218", "DELETE symlink to file"),
        "symlink_dir": ("#2218", "DELETE symlink to dir (recursive)"),
    }
    for d in DIMS:
        fx, pr = fixpr[d]
        out.append("| %s | %s | %s | %s |"
                   % (fx, pr, behaviour(baseline, d), behaviour(candidate, d)))
    return "\n".join(out)


def _clean_pair():
    good = {"control_get_regular": {"status": 200}, "control_delete_regular": {"status": 204}}
    baseline = {
        "probes": dict(good, get_fifo={"status": None, "timed_out": True},
                       get_device={"status": 200, "bytes": 0},
                       delete_inroot_link_file={"status": 204},
                       delete_inroot_link_dir={"status": 204}),
        "after": {"realfile": "no", "realdir_keep": "no", "outside_sentinel": "yes",
                  "link_file": "present", "link_dir": "present"},
    }
    candidate = {
        "probes": dict(good, get_fifo={"status": 400, "code": "INVALID_ARGUMENT"},
                       get_device={"status": 400, "code": "INVALID_ARGUMENT"},
                       delete_inroot_link_file={"status": 204},
                       delete_inroot_link_dir={"status": 204}),
        "after": {"realfile": "yes", "realdir_keep": "yes", "outside_sentinel": "yes",
                  "link_file": "gone", "link_dir": "gone"},
    }
    return baseline, candidate


def plant():
    """A CONFIRMED pair, then two sabotages the gate must each reject: the
    candidate did not reject the named pipe, and the out-of-root sentinel was
    lost."""
    baseline, candidate = _clean_pair()
    if evaluate(baseline, candidate)[0] != CONFIRMED:
        print("PLANT BROKEN: clean pair did not verify")
        return 1
    c1 = copy.deepcopy(candidate)
    c1["probes"]["get_fifo"] = {"status": None, "timed_out": True}
    v1 = evaluate(baseline, c1)[0]
    if v1 == CONFIRMED:
        print("PLANT NOT CAUGHT: gate verified a still-vulnerable candidate (fifo)")
        return 1
    c2 = copy.deepcopy(candidate)
    c2["after"]["outside_sentinel"] = "no"
    v2 = evaluate(baseline, c2)[0]
    if v2 == CONFIRMED:
        print("PLANT NOT CAUGHT: gate verified a run that lost the out-of-root sentinel")
        return 1
    print("plant caught: fifo-tampered -> %s, sentinel-tampered -> %s" % (v1, v2))
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "plant":
        return plant()
    if len(argv) not in (5, 6):
        print("usage: verdict.py <baseline.json> <candidate.json> <baseline_tag> <candidate_tag> [out.json]",
              file=sys.stderr)
        return 2
    baseline = json.load(open(argv[1]))
    candidate = json.load(open(argv[2]))
    bt, ct = argv[3], argv[4]
    verdict, rows, reasons = evaluate(baseline, candidate)
    print(table(baseline, candidate, bt, ct))
    print()
    print("verdict: %s" % verdict)
    for r in reasons:
        print("  - %s" % r)
    result = {
        "measurement": "agent-sandbox sandboxd file-op defaults, %s vs %s" % (bt, ct),
        "baseline": {"tag": bt, "commit": baseline.get("commit"), "probes": baseline["probes"],
                     "after": baseline.get("after")},
        "candidate": {"tag": ct, "commit": candidate.get("commit"), "probes": candidate["probes"],
                      "after": candidate.get("after")},
        "verdict": verdict,
        "reasons": reasons,
    }
    out = argv[5] if len(argv) > 5 else None
    if out:
        json.dump(result, open(out, "w"), indent=2)
    return {CONFIRMED: 0, INCONCLUSIVE: 2, FAILED: 1}[verdict]


if __name__ == "__main__":
    sys.exit(main(sys.argv))
