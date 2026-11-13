# Android companion-web setup resumed

November 6, 2026. This is environment recovery evidence, not current-browser or household acceptance.

The retained `RITC_Chrome_API34` AVD was started without wiping userdata or downloading an image. Its first launch waited for a crash-report consent dialog. The installed emulator explicitly documents `-crash-report-mode disabled`; after terminating only the verified owned first process, root relaunched with that option. The emulator then booted successfully.

The fresh task-owned ADB daemon initially lacked the AVD's existing trusted task key. Root verified the daemon identity and that only `emulator-5554` was attached, then restarted that daemon with `ADB_VENDOR_KEYS=/tmp/ritc-android/user/adbkey`. The connection became authorized through the existing key. No private-key contents were read by the agent, copied into evidence, or bypassed. A leftover prompt for the default key was explicitly cancelled; no new debugging trust was granted.

At 18:54:23 UTC the device reported boot complete, automatic time enabled and UTC within approximately one second of the host. Package metadata still shows active Chrome149.0.7827.5, plus its older system package113.0.5672.136, Play Store35.6.11-21 and Play Services23.18.18. The latter packages' presence/version does not establish service health. Root visually verified the Android home screen and then Google Play's signed-out Sign in screen. The user has been asked to complete sign-in directly, or provide only the exact error wording if it fails. No account credentials, verification codes, account databases or tokens were inspected. No sign-in, terms acceptance or update was performed.

Google's official Version History API now lists158.0.8127.22 followed by157.0.8103.47 in the stable channel; Google's November5 release announcement identifies158 as early stable rollout. This supersedes the previous156 acquisition target but does not prove which version Play currently offers this device. Use the version actually offered through the official store and verify its stable-channel status at acceptance time. Chrome149 remains historical-engine evidence.

Current emulator PID26580 remains running for the human handoff. No screenshot or log capture should occur while the user enters credentials. The underlying Google sign-in failure remains undiagnosed; correct clock, boot and ADB connectivity do not prove network/TLS or account eligibility. Current-stable tasks, deployed grant/stale-cache flows and human cook acceptance remain open.

Original startup logs, screenshots and process receipts are private local artifacts in `.build/AndroidResume20261106/`. Only the three explicit nonsecret metadata receipts below are retained here.

Sources: [Google Version History](https://versionhistory.googleapis.com/v1/chrome/platforms/android/channels/stable/versions?pageSize=5), [November5 Android early-stable announcement](https://chromereleases.googleblog.com/2026/11/chrome-for-android-update_0698823948.html).
