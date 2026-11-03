# Existing Play Store AVD: local inventory and proposed human update handoff

**No boot or account action is authorized or executed by this report.** Local read-only inventory completed at **2026-11-03T22:24:01Z**. All network probes are stopped. The SE and root17e work retain priority; the parent must release resources before preparing a visible Android window. Current stable acceptance remains **UNRUN**.

## Existing device and retained versions

| Item | Exact local value |
|---|---|
| AVD name / display name | `RITC_Chrome_API34` / `RITC Chrome API34 isolated` |
| AVD index | `/tmp/ritc-android/avd/RITC_Chrome_API34.ini` |
| Existing userdata/config directory | `/tmp/ritc-android/avd/RITC_Chrome_API34.avd` |
| SDK / emulator | `/tmp/ritc-android/sdk`; emulator37.2.13, build16740729 |
| System image | `/tmp/ritc-android/sdk/system-images/android-34/google_apis_playstore/arm64-v8a/` |
| Image identity | `system-images;android-34;google_apis_playstore;arm64-v8a`, revision14, Android14/API34, extension7, ARM64 (`arm64-v8a`); Google Play tag, `PlayStore.enabled=true` |
| Build / patch level | `UE1A.230829.036.A4`, incremental12096271, build2024-07-16; security patch2023-09-05. This is the retained older test OS. |
| Platform tools |37.0.1; `/tmp/ritc-android/sdk/platform-tools/adb` |
| Installed browser, last actual observation | Chrome149.0.7827.5 on `emulator-5554` at2026-11-03T20:17:38.234Z. No fresh runtime query was made while stopped. |
| Retained matching APKs | Chrome `com.android.chrome` and Trichrome `com.google.android.trichromelibrary`, version149.0.7827.5 / code782700532, minSDK29 / targetSDK36, ARM64. Existing APK hashes were rechecked locally and match the earlier preparation. |
| Play Store / Play services app versions | Not retained in the inspected local evidence. They require a later authorized running-device query; no value is inferred from the OS image. |
| Last verified official stable target |156.0.8078.79 from the retained official API response at21:52UTC. No network refresh was performed for this local plan. A different version offered later requires parent review before a current-stable claim. |

This is the same existing API34 AVD used for historical113/149 acceptance. The API37.2 image used only to obtain the149 APKs is **not** this AVD's OS and is not needed for the proposed Play route.

## Disk, RAM and renderer

`config.ini` requests2 CPU cores,2048MB RAM,256MB VM heap,1080×1920 at420dpi, and a6GiB data partition (`6442450944`bytes). The prior running emulator raised RAM to **2560MB** and VM heap to576MB; `hardware-qemu.ini` records those effective values. Do not plan this as a2GiB guest.

The last successful continuation used `-gpu swiftshader -feature -Vulkan`, after the earlier gfxstream/Vulkan host crash. The retained generated hardware records `hw.gpu.mode=swiftshader`. The static config still says `hw.gpu.mode=auto`, so the future command must explicitly preserve the successful renderer override. Cold boot/no snapshot is configured. Do not wipe data or create another AVD.

At22:24UTC, allocated sizes were SDK4,758,368KiB, AVD1,973,464KiB, and stopped fixture156,704KiB. The AVD's userdata QCOW2 currently occupies1,986,330,624bytes; the virtual guest data partition is6GiB. `/tmp`'s filesystem reported481,973,952KiB available. No image, archive, SDK or APK download/copy is needed to prepare the sign-in screen.

The host has24GiB RAM. `memory_pressure -Q` reported63% free at22:24UTC; an earlier local query reported36%, so this is a point-in-time observation, not a resource lease. One `xcodebuild` process was observed. The inventory does not infer whether either parent-owned simulator is safe to interrupt.

**Resource plan:** wait until the parent explicitly releases the SE/root17e priority work; repeat only local process/memory/port checks immediately before boot. Run one Android AVD with2 cores and2560MB guest RAM. Budget roughly4GiB of additional host headroom for the guest, software graphics and visible window; this is a planning allowance, not measured peak RSS. Avoid concurrent heavy builds. Defer on pressure or insufficient headroom; never stop parent-owned jobs/devices to make room. No fixture server or DevTools forwarding is needed merely to prepare Play's sign-in screen.

## Stopped jobs and local transport

Fresh filtered process inspection found **no emulator, QEMU or ADB process**. Local listener inspection found none on5037,5554,5555,9227 or65502. The prior cleanup record also confirms fixture/emulator jobs exited0 and their ADB daemon was stopped at20:29UTC. No Android job was started by this inventory.

The prior fixture's TLS CA and disposable TLS key were removed; old fixture URLs/ports must not be reused for browser acceptance. Rebuilding the eventual acceptance transport is separate from signing in and updating Chrome.

The retained emulator user key exists at `/tmp/ritc-android/user/adbkey` (contents not read). The task-created host defaults `/Users/palatis/.android/adbkey` and `.pub` remain absent. The prior run showed that ADB could create host-default keys despite the emulator's isolated environment. Future boot/ADB setup must account for that local side effect and use scoped ownership checks before cleanup. Do not read or copy key material into evidence. The login phase can use the visible native UI without starting an acceptance ADB/DevTools harness.

## Proposed next steps after the parent's resource release

1. Prepare a visible window for this exact existing AVD, preserving userdata and the renderer overrides. The old `/tmp/ritc-android/launch-authorized.sh` hardcodes `-no-window`; do not run it unchanged for a human handoff. `visible-launch-plan.txt` records the proposed command, **not executed**. No SDK manager, wipe, snapshot clone, second AVD or download is part of preparation.
2. In the visible Android UI, open the existing Play Store app. Inspect only the pre-login screen, then stop. The retained screen `20-play-chrome-update.png` was visually inspected locally: it shows Google Play's **Sign in** button. Its XML agrees. That is historical screen evidence, not a newly prepared live screen; the current foreground must be checked after the authorized boot.
3. Once the live sign-in screen is concrete and visible, the parent can ask the human to take control. The human supplies the Google account credentials,2-step verification and any required Google/Play decisions directly in the emulator. No password/code/account identifier should be sent to an agent, pasted into a tool call, captured in screenshots/logs, or saved in this report. The parent must wait for the human to say they have returned to Play Store before resuming automation.
4. With the human's account scope and update permission explicit, use Play's existing **Google Chrome by Google LLC** listing (`com.android.chrome`). Select **Update** only if offered for that package. Avoid Update all, purchases, subscriptions and unrelated installations. Chrome's update is intended to be free; no payment method or paid service is part of this plan. If Play requires an unexpected account/terms/payment decision, leave it to the human. Update availability and device eligibility are not guaranteed by this stopped-device inventory.
5. Record the installed Chrome package/version after the official update and its package identity/signing evidence. A successful Play operation or an Open button alone is insufficient. Compare the actual version with the retained stable156 target; seek parent direction for any different offered version. Only then allocate a fresh browser-acceptance fixture and perform the required actual Android journeys. Updating Chrome alone does not complete acceptance.
6. Before leaving a signed-in AVD or copying its userdata, agree on account cleanup with the human. Account removal is a later explicit action; do not wipe this AVD or remove accounts automatically. Shut down only the owned Android instance when finished, retaining the evidence and updated app state as authorized.

## Human login prerequisites and expected side effects

The human needs an existing Google account they authorize for this test emulator, access to its password and any2-step verification/recovery method, and willingness to review any Google/Play terms shown. A dedicated test account avoids bringing personal mail/contacts/history into the test device, but this report does not create or select an account. Internet access to Google is required during the later user-led flow; it was not tested here.

Signing into Play adds a Google account and authentication tokens to this AVD's persistent userdata and may register the virtual Android device in the account's device/security history or trigger a security notification. Google services can present sync, backup/restore, personalization or other consent choices; the human should review them and avoid importing personal data. Chrome can separately offer browser sign-in/sync after the update. Those options are outside this update plan unless explicitly chosen by the human. Treat the AVD userdata as sensitive after login and do not archive/duplicate it while signed in without direction. No account database was inspected, so this report makes no fresh claim about the stopped device's account list.

`local-inventory.json` preserves exact configuration, file sizes/hashes, process/port checks and resource output. Large image and userdata files were inspected by metadata only; neither was mounted or rewritten. `preservation-manifest.json` hashes this report directory. No live repository edit, Git action, network probe, emulator/ADB execution, SDK/AVD mutation, sign-in, account creation, terms acceptance, physical-device install or download occurred.
