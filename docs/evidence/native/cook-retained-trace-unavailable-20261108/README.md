# Retained speech trace: unavailable

The earlier disk-limited speech trace was cloned and checked once with `xctrace export --toc`. The exporter exited 10 in 2.054 seconds with `Document Missing Template Error`, producing no table of contents. Its original two files and original run receipt remained unchanged. No new recording, app run, import fallback or retry occurred.

The original capture had required forced termination after a 15-second finalization allowance. Its readiness notification and approximately 2 GB of retained data do not establish a usable trace or scheduler tables. The failed TOC check therefore cannot identify a speech wait, waker or duration. The raw trace stays private; this directory contains only the bounded inspection receipt and error.

A future capture needs explicit diagnostics collection, independent native-test completion, measured storage usage and adequate bounded finalization. No new capture or causal repair is claimed here.
