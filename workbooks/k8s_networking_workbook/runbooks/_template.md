# Runbook — <phase or capstone>

Date: <yyyy-mm-dd> · Environment: <netlab | k8slab | kind:<name>> · Labs: <x.yy–x.zz>

## What this covers

One or two sentences. Written for the person who hits this at 03:00 on
someone else's platform, not as a record of progress.

## Table

| Symptom | Tool | Cause | Fix | What would have told me this first |
|---|---|---|---|---|
| What you actually see — the error text, the timeout, the wrong IP | The one command that discriminates | The mechanism, not "a network issue" | The exact command or change | The signal that existed *before* the symptom |

Rules that keep these useful:

- **Symptom** is what a person observes, never a diagnosis. "curl hangs
  after the TLS ClientHello" not "MTU mismatch".
- **Tool** is one command. If it takes three, the first two are also rows.
- **Cause** names a mechanism. "The reply left eth1 but rp_filter=1 drops it
  because the route back points at eth0" — not "routing problem".
- **What would have told me this first** is the point. If you cannot fill
  it, the row is incomplete: something was knowable earlier.

## Things that surprised me

What you predicted wrong, and why the wrong prediction was reasonable.

## Still open

Anything unresolved, with the state it was left in.
