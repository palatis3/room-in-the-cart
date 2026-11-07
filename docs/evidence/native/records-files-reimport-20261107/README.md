# Records backup import through Files

The iPhone simulator used the system document picker and the local **On My iPhone → Downloads** provider. The test saved a newer pack comparison through normal entry, then imported an older encrypted kitchen recipe. The archive generator uses the same RecordArchive encoder and authenticated encryption as the app. It removes the algorithm value from a second copy to produce invalid JSON with balanced delimiters.

On iOS 27.0, the fresh-install UI case passed in 301.46 seconds. The strict checker recorded one start and completion and zero runtime warnings. All 38 selected Records model cases also passed with zero warnings. [UI result](ui-strict.txt) · [Model results](models-strict.txt) · [Build, inputs and scope](validation.json).

The selected archive showed its source, saved date and immutable recipe revision. After review, the saved copy contained the original yield, ingredient, instruction, note and source URL. The later comparison still showed two packs per option, costing $6.00 and $4.00. [Backup review on the simulator](backup-review.png).

At picker cancellation, damaged-file rejection and valid-preview cancellation, the live comparison had the same revision and envelope digest as the baseline. The recovery registry held zero copies until explicit import. After relaunch, selecting the same backup showed **Identical — reopen existing copy**. Applying it kept the single recovered copy and the same registry bytes. A read-only observer sampled the app’s SQLite comparison store and atomic recovery manifest at each checkpoint. [Storage fingerprints](storage.json).

## Replay

Use a Mac with Xcode 27.1 and the iOS 27.0 runtime. From the repository root, run the following command.

```sh
zsh diagnostics/records-files/replay.zsh
```

The script creates an isolated source copy, test database and simulator. It provisions only the two fictional files in the simulator’s local provider. The app opens both files through Files. The key is a fixed synthetic input for this archive. The script retains a local result bundle, selector and runtime-warning report and removes its simulator.

The historic real-exporter test separately covers creating an encrypted backup through the app and saving it through Files. Physical devices, iCloud Drive and third-party providers still need their own acceptance. [Exporter round trip](../coordinated-recovery-20261104/validation.json).
