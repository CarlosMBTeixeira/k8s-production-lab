# Runbook — <session>

Date: <yyyy-mm-dd> · Cluster: <k8slab | crc> · Session: <nn>

## What this covers

One or two sentences. Written for the person who hits this at 03:00 on
someone else's platform, not as a record of progress.

## Table

| Symptom | Tool | Cause | Fix | What would have told me this first |
|---|---|---|---|---|
| What you actually see — the error text, the empty panel, the wrong number | The one command or view that discriminates | The real mechanism, not "a config issue" | The exact command or change | The signal that existed *before* the symptom |

Rules that keep these useful:

- **Symptom** is what a person observes, never a diagnosis. "Dashboard is
  empty" not "sidecar label mismatch".
- **Tool** is one command. If it takes three, the first two are also rows.
- **Cause** names a mechanism. "Grafana's sidecar selects ConfigMaps by
  label and this one didn't match" — not "misconfiguration".
- **What would have told me this first** is the point of the whole
  exercise. If you cannot fill it, the row is incomplete: something was
  knowable earlier, and finding it is the work.

## Things that surprised me

Free text. What you predicted wrong, and why the wrong prediction was
reasonable. This ages better than the table.

## Still open

Anything you could not resolve, with the state it was left in.
