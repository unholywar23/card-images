#!/usr/bin/env python3
"""pod_watchdog.py - the card's OWN kill switch, running INSIDE the pod.

This is the belt-and-suspenders companion to the PC-side watchdog.py. The PC
one reaches in over ssh from home and kills idle/finished cards; but if the PC
is asleep, the tab froze, or the main session died, nothing kills the card and
it bills forever. THIS watchdog lives inside the pod and terminates the pod
ITSELF, so a forgotten card can never bill for long even with the PC gone.

How a pod kills itself (no API key needed):
  Every RunPod pod ships `runpodctl` pre-installed with a pod-scoped credential
  auto-injected, and the pod's own id in $RUNPOD_POD_ID. So the pod can remove
  itself with `runpodctl remove pod $RUNPOD_POD_ID` and no key file anywhere.
  (If a full RUNPOD_API_KEY is also present in the env we just inherit it, which
  lets `delete`/`remove` work even on hosts where the pod-scoped key is stop-only.)

It kills the pod when ANY of these is true:
  * the work-done marker file appears        -> job finished, results are home
  * the GPU sits idle (util < threshold) for > N minutes   -> forgotten/hung card
  * (optional) the pod has lived > max-life minutes         -> ultimate backstop
A card that is actually working (GPU busy) resets the idle clock every poll.

Terminate vs stop: we try `remove`/`delete` FIRST (pod gone, zero further bill),
and only fall back to `stop` (suspend, GPU released) if remove is refused. Either
way the expensive GPU billing ends.

Usage inside the pod (started once at job start, backgrounded):
  nohup python3 pod_watchdog.py --idle-minutes 20 \
        --done-marker /workspace/.card_done >/workspace/pod_watchdog.log 2>&1 &

Config comes from flags OR env vars (so the image entrypoint can set it):
  PODWD_IDLE_MIN, PODWD_POLL_S, PODWD_SAMPLE_S, PODWD_UTIL_PCT,
  PODWD_DONE_MARKER, PODWD_MAX_LIFE_MIN, PODWD_GRACE_S

Testing: --mock makes it use fake readings and record the kill instead of doing
it, so the whole decision logic runs on any PC with no card and no RunPod
account. See test_pod_watchdog.py.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

NO_WINDOW = 0x08000000  # CREATE_NO_WINDOW; only matters if ever run on Windows


# --------------------------------------------------------------- tiny helpers ---

def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, "").strip() or default)
    except ValueError:
        return default


def _run(cmd: list[str], timeout: int | None = None) -> subprocess.CompletedProcess:
    kw = dict(capture_output=True, text=True, timeout=timeout)
    if os.name == "nt":  # never flash a window (real runs are on Linux pods; harmless here)
        kw["creationflags"] = NO_WINDOW
    return subprocess.run(cmd, **kw)


# ------------------------------------------------------------------ watchdog ---

class PodWatchdog:
    """Holds the config + idle clock; `step()` is a PURE decision so tests can
    drive every branch with no sleeping and no real card."""

    def __init__(self, *, idle_limit_s: int, util_threshold: int, done_marker: str,
                 max_life_s: int, grace_s: int, started: float, logfn=print):
        self.idle_limit_s = idle_limit_s
        self.util_threshold = util_threshold
        self.done_marker = Path(done_marker) if done_marker else None
        self.max_life_s = max_life_s          # 0 = off
        self.grace_s = grace_s
        self.started = started
        self.busy_last = started              # last time the card looked busy
        self._done_seen_at: float | None = None
        self.log = logfn

    # -- the whole decision, as one pure function -------------------------------
    def step(self, util: int, done_present: bool, now: float) -> tuple[str, str]:
        """Return (action, detail). action is one of:
        continue | kill_done | kill_idle | kill_deadline.
        Mutates only the idle clock / done timer, never touches the real card."""
        # 1. work-done marker (with optional grace so a last copy/flush finishes)
        if done_present:
            if self._done_seen_at is None:
                self._done_seen_at = now
            if now - self._done_seen_at >= self.grace_s:
                return "kill_done", "work-done marker present"
            return "continue", f"done marker seen, grace {now - self._done_seen_at:.0f}/{self.grace_s}s"
        else:
            self._done_seen_at = None  # marker removed again -> cancel

        # 2. hard max-life backstop (catches a process wedged at 100% forever)
        if self.max_life_s and (now - self.started) >= self.max_life_s:
            return "kill_deadline", f"lived {(now - self.started) / 60:.1f} min (cap {self.max_life_s / 60:.0f})"

        # 3. idle check
        if util >= self.util_threshold:
            self.busy_last = now
            return "continue", f"gpu {util}% busy; idle clock reset"
        idle_for = now - self.busy_last
        if idle_for >= self.idle_limit_s:
            return "kill_idle", f"idle {idle_for / 60:.1f} min (limit {self.idle_limit_s / 60:.0f}); gpu {util}%"
        return "continue", f"idle {idle_for / 60:.1f}/{self.idle_limit_s / 60:.0f} min; gpu {util}%"


# ------------------------------------------------------------ real pod actions ---

def sample_gpu_util(sample_s: int) -> int:
    """Average GPU utilisation over `sample_s` one-second reads via nvidia-smi.
    Unreachable / no reading -> 0 (treated as idle, so a broken card still trips
    the idle timer, same policy as the PC-side watchdog)."""
    reads: list[int] = []
    for _ in range(max(1, sample_s)):
        try:
            res = _run(["nvidia-smi", "--query-gpu=utilization.gpu",
                        "--format=csv,noheader,nounits"], timeout=15)
            for tok in res.stdout.split():
                if tok.strip().isdigit():
                    reads.append(int(tok.strip()))
                    break
        except (OSError, subprocess.SubprocessError):
            pass
        time.sleep(1)
    return round(sum(reads) / len(reads)) if reads else 0


def terminate_self(pod_id: str, dry: bool, logfn) -> bool:
    """Kill THIS pod with runpodctl. Try remove/delete (pod gone, zero bill)
    first; fall back to stop (suspend, GPU released). Returns True if a command
    succeeded. runpodctl is pre-installed with a pod-scoped key, so no key is
    needed; a full RUNPOD_API_KEY in the env (if present) is inherited and lets
    delete work on hosts where the pod-scoped key is stop-only."""
    if not pod_id:
        logfn("pod_watchdog: no $RUNPOD_POD_ID - cannot self-terminate")
        return False
    # ordered best-effort: terminate variants, then suspend variants
    candidates = [
        ["runpodctl", "remove", "pod", pod_id],   # terminate (legacy syntax)
        ["runpodctl", "pod", "delete", pod_id],    # terminate (new syntax)
        ["runpodctl", "stop", "pod", pod_id],      # suspend  (legacy)
        ["runpodctl", "pod", "stop", pod_id],      # suspend  (new)
    ]
    if dry:
        logfn(f"pod_watchdog[dry]: would run: {' '.join(candidates[0])}")
        return True
    for cmd in candidates:
        try:
            res = _run(cmd, timeout=60)
        except (OSError, subprocess.SubprocessError) as e:
            logfn(f"pod_watchdog: {' '.join(cmd[:3])} errored ({e}); trying next")
            continue
        if res.returncode == 0:
            logfn(f"pod_watchdog: self-terminate OK via `{' '.join(cmd)}`")
            return True
        logfn(f"pod_watchdog: `{' '.join(cmd)}` rc={res.returncode} "
              f"{(res.stderr or res.stdout).strip()[:120]}; trying next")
    logfn("pod_watchdog: ALL runpodctl kill commands failed - card still up!")
    return False


# ------------------------------------------------------------------- mock I/O ---

class MockIO:
    """Fake nvidia-smi + runpodctl for tests. Reads a scripted list of util
    values and records the kill to a list instead of removing a real pod."""

    def __init__(self, utils: list[int]):
        self.utils = list(utils)
        self.kills: list[str] = []
        self.lines: list[str] = []

    def log(self, msg: str) -> None:
        self.lines.append(msg)

    def sample(self, _sample_s: int) -> int:
        return self.utils.pop(0) if self.utils else 0   # runs dry -> idle

    def kill(self, pod_id: str, dry: bool, logfn) -> bool:
        self.kills.append(pod_id)
        logfn(f"pod_watchdog[mock]: terminated {pod_id}")
        return True


# ---------------------------------------------------------------------- runner ---

def run(wd: PodWatchdog, *, pod_id: str, poll_s: int, sample_s: int, dry: bool,
        once: bool, sampler, killer, logfn, clock=time.time, sleeper=time.sleep) -> str:
    """Loop: sample -> decide -> act. Returns the kill action that ended it
    ('kill_done'/'kill_idle'/'kill_deadline') or 'stopped' if --once saw nothing."""
    while True:
        util = sampler(sample_s)
        done = bool(wd.done_marker and wd.done_marker.exists())
        action, detail = wd.step(util, done, clock())
        logfn(f"pod_watchdog: {action} - {detail}")
        if action != "continue":
            killer(pod_id, dry, logfn)
            return action
        if once:
            return "stopped"
        sleeper(poll_s)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="In-pod self-terminating idle watchdog")
    ap.add_argument("--idle-minutes", type=int, default=_env_int("PODWD_IDLE_MIN", 20))
    ap.add_argument("--poll-seconds", type=int, default=_env_int("PODWD_POLL_S", 60))
    ap.add_argument("--sample-seconds", type=int, default=_env_int("PODWD_SAMPLE_S", 5))
    ap.add_argument("--util-threshold", type=int, default=_env_int("PODWD_UTIL_PCT", 5),
                    help="GPU %% below this counts as idle")
    ap.add_argument("--done-marker", default=os.environ.get("PODWD_DONE_MARKER", "/workspace/.card_done"))
    ap.add_argument("--max-life-minutes", type=int, default=_env_int("PODWD_MAX_LIFE_MIN", 0),
                    help="hard cap on total pod life (0 = off)")
    ap.add_argument("--grace-seconds", type=int, default=_env_int("PODWD_GRACE_S", 0),
                    help="wait this long after the done marker before killing")
    ap.add_argument("--pod-id", default=os.environ.get("RUNPOD_POD_ID", ""))
    ap.add_argument("--mock", action="store_true", help="fake card+runpodctl (tests)")
    ap.add_argument("--once", action="store_true", help="one evaluation then exit")
    ap.add_argument("--dry-run", action="store_true", help="log the kill but don't do it")
    args = ap.parse_args(argv)

    start = time.time()
    wd = PodWatchdog(
        idle_limit_s=args.idle_minutes * 60,
        util_threshold=args.util_threshold,
        done_marker=args.done_marker,
        max_life_s=args.max_life_minutes * 60,
        grace_s=args.grace_seconds,
        started=start,
    )

    def logfn(msg: str) -> None:
        print(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {msg}", flush=True)

    if args.mock:
        mio = MockIO(utils=[])   # no readings -> idle -> trips the timer
        sampler, killer = mio.sample, mio.kill
    else:
        sampler, killer = sample_gpu_util, terminate_self

    logfn(f"pod_watchdog: watching pod {args.pod_id or '(no id)'} - idle>{args.idle_minutes}m "
          f"or marker {args.done_marker}" + (f" or life>{args.max_life_minutes}m" if args.max_life_minutes else ""))
    action = run(wd, pod_id=args.pod_id, poll_s=args.poll_seconds, sample_s=args.sample_seconds,
                 dry=args.dry_run, once=args.once, sampler=sampler, killer=killer, logfn=logfn)
    logfn(f"pod_watchdog: done ({action})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
