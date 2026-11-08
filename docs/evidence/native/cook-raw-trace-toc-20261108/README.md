# Raw trace recovery: readable metadata, pre-Play range

One documented raw `.atrc` import/TOC export succeeded on a verified APFS clone, exit 0 in 163.529 seconds. It produced 172,315 bytes of XML and no stderr. The original and clone hashes, source and earlier capture/strict receipts remained unchanged. No app run, recording, retry or shared staging-file access occurred.

The imported TOC declares 65 tables, including `thread-state` and `syscall`. Its reported run range is 17:34:34.277–17:34:42.611 UTC on November 8 (8.334749 seconds). Actual Play began at 17:34:43.962 and Pause at 17:34:47.132. This reported range is before the controls and cannot qualify their waits. Table declarations and run metadata do not establish actual row contents, minimum/maximum event timestamps, wakers or acoustic output. No table rows were exported.

`selected-toc-metadata.json` preserves only the run summary and relevant declarations; the complete TOC and raw all-process data remain private. The preceding native test still passed and strict warning validation still failed. Reading the raw data does not repair those warnings.

A smaller app-PID capture is being prepared separately, based on supported target sampling and the measured full-system capture cost. Its cost and cross-process stack coverage remain unproven. No further capture has run at this checkpoint.
