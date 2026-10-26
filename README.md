# Simplefy

<img src="assets/branding/simplefy-icon.png" alt="Simplefy" width="128" height="128">

**Just music. Just play.**<br>
**Your music. Your way.**

A simple [Jellyfin](https://jellyfin.org/) music player built with Flutter. Browse your actual folders, edit one playback queue, and keep music available offline.

The app targets **iPhone, iOS 14+**, and **Android 7.0+ (API 24+)**. The Android host supports foreground media playback and imports user-selected files or folders through the system document picker. The interface supports English, Russian, Spanish, Brazilian Portuguese, German, and French. It follows the system language by default and uses English when that language is unsupported. Choose a language in Settings → Language or on the sign-in screen. Regional Spanish, German, and French system locales use their shared translation; Portuguese uses the Brazilian translation. App Store and Google Play distribution are being prepared separately.

## Features

- Playback progress, elapsed and total time, and tap/drag seeking directly in the mini-player or full player. Collapse the mini-player to free space and restore it without interrupting playback.
- Collections → folders → tracks, preserving the server's folder structure. Search file names, artists, and track titles.
- Play buttons at the right edge of collections, folders, and playlists replace the queue and start immediately: the first track in sequential mode, a random occurrence in shuffle mode. Queue order stays unchanged, and the play button opens the queue immediately while preparing playback in the background. The queue reveals the current occurrence when playback advances and uses the latest occurrence when reopened. Manual browsing stays in place until the next track change.
- Collections, folders, albums, and playlists show their saved contents immediately and refresh in the background. Snapshots remain available when an update fails.
- One editable queue: append folders, playlists, or tracks, reorder entries, and switch between sequential and shuffle playback.
- Server and local playlists. Jellyfin-managed playlists appear first; imported playlist files such as M3U appear in a separate group at the bottom, collapsed by default. Save the current queue as a new private server playlist, preserving order and repeated tracks. Long-press a playlist → Delete playlists to select server or local playlists for deletion, with the original item already selected. Cancel leaves everything unchanged; deletion confirms the selection and retains failed items for retry. Audio files, downloads, and the queue are preserved. Edit an opened server playlist directly: add tracks from the library, reorder or remove entries, then save to the server with permission or create a named local copy. Queue editing and saving remain available separately.
- Download tracks, folders, and playlists. A sliding status panel shows the current track, batch progress, remaining songs, and connection errors across screens. Interrupted downloads retry automatically; Continue provides a manual retry and respects Wi-Fi-only settings. Settings → downloaded songs lists completed files once, with search and individual deletion across download groups. Removing downloads affects only this device.
- Import audio files and folders from the iOS Files app into a separate local library. Local music works without a Jellyfin account.
- Background audio, headset commands, and lock-screen playback controls.
- Preload the next track and restore the queue, playback position, and last opened folder or playlist. Position updates are saved separately from the queue; playback history retains the latest 1,000 transitions.
- Volume normalization using Jellyfin metadata, enabled by default. Choose track, album, or off. Missing metadata leaves the original volume unchanged; audio analysis and amplification are not implemented yet.
- Compact playback controls and library rows. The queue shows its playlist source, unsaved changes, track count, and total duration when known. Pull the queue down or hold its title to search; swipe left to remove an entry, or use its long-press menu. Partial downloads show available/total counts instead of a completion checkmark.

Tap a track to replace the queue with its current folder or playlist and start that occurrence. Long-press an item to open its actions. Editing the queue or a playlist draft never changes the source playlist until you explicitly save it. Playlist drafts leave current playback and its queue untouched. Server saves recheck permissions and ask before overwriting a changed playlist.

When the server is unreachable, cached folders remain available and mixed queues rotate through locally available tracks, including completed temporary audio caches. Remote tracks return to rotation after reconnection. Unavailable tracks and groups are dimmed without removing them from the library or queue.

Long music lists build only viewport rows, including the playback queue. Queue snapshots and entry indices are reused between structural edits.

The sign-in screen explains how to connect a Jellyfin server or import files. About Simplefy is available from sign-in and Settings, with the installed version, support, source code, offline license notices, and a privacy summary. Read the [privacy policy](PRIVACY.md) for details.

Settings are grouped by purpose. The full player shows queue context with responsive artwork; login reduces branding when entering credentials. Context menus scroll on smaller screens and with larger text.

## Build and run

For Android, install Flutter stable, JDK 17, and an Android SDK with platform 36 and Flutter's default NDK. Then run:

```sh
flutter build apk --debug
flutter run -d <android-device-id>
```

The release build currently uses the local debug signing key for device testing. Configure a private upload keystore before distributing through Google Play; keep signing files and passwords outside the repository. No server credentials are embedded in public builds.


For iOS, install Flutter stable and Xcode with the iOS SDK on macOS. The project's working environment is Flutter 3.44.5, Dart 3.12.2, and Xcode 26.3. Dependency versions are pinned in `pubspec.lock`.

```sh
git clone https://github.com/antontonkovkz/simplify.git
cd simplify
flutter pub get
flutter devices
flutter run -d <simulator-id>
```

Build for the simulator:

```sh
python3 tool/build_ios.py --variant public --simulator
```

For a physical iPhone, configure your own signing team:

```sh
cp ios/Flutter/Signing.example.xcconfig ios/Flutter/Signing.local.xcconfig
```

Replace `YOUR_TEAM_ID` in `Signing.local.xcconfig` with your Apple Development Team ID. This file is ignored by Git. If necessary, open `ios/Runner.xcworkspace` and change the Bundle Identifier to one available to your account. Then build:

```sh
python3 tool/build_ios.py --variant public
```

The public entry point is `lib/main.dart`. Enter your own Jellyfin server address and account details in the app, or import local music. No test credentials are included. Passwords are not stored; the session is kept in Keychain. Sign out or switch accounts in Settings. Sign-out cancels and forgets account-scoped background transfers and attempts to revoke the server session. If cleanup cannot be confirmed, the app reports it; local sign-out still works without a server connection.

The optional personal entry point, `lib/main_personal.dart`, accepts an initial session through `BOOTSTRAP_SESSION`. The build tool accepts private definitions only from a file **outside this project**, using `--variant personal --definitions <file>`. These builds contain a session and are intended for personal use. The public entry point rejects a nonempty `BOOTSTRAP_SESSION`.

A self-contained playlist-management scenario checks creation and batch deletion with fixture data, including confirmation, partial failure, and large text. It never writes to a real server:

```sh
python3 tool/run_integration.py --device <simulator-id> --suite playlist_management
```

## Localization

Keep the message keys and placeholders in all `lib/l10n/app_*.arb` catalogs in sync with the English source. Brazilian Portuguese is in `app_pt_BR.arb`; Flutter also requires `app_pt.arb` as its base fallback. Keep both Portuguese catalogs identical apart from locale metadata; tests check this. Keep user and server metadata unchanged. Flutter generates the localization classes during `flutter pub get`; generated Flutter files are ignored by Git. After changing messages, regenerate the deferred service messages and Flutter classes:

```sh
python3 tool/generate_messages.py
flutter gen-l10n
python3 tool/generate_messages.py --check
```

A self-contained simulator scenario checks language changes, preserved queue and sign-in state, system fallback, and large text:

```sh
python3 tool/run_integration.py --device <simulator-id> --suite localization
```

Playback negotiates audio compatibility through Jellyfin PlaybackInfo and a platform device profile. Unsupported formats use an HTTP MP3 transcode; servers without that endpoint use a conservative platform-specific fallback. HTTPS is the default. Explicitly entered HTTP server addresses remain supported, including background downloads; certificate validation is never bypassed. Playback uses a growing temporary file behind a loopback-only HTTP source: playback can start before the file finishes downloading, and completing the cache does not reload the player. The current track downloads first, followed by the reserved next track; promoting an unfinished prefetch preserves its transfer. Cached byte ranges remain readable offline. Validated HTTP range requests support forward seeks and interrupted downloads; servers without validators restart with prefix verification. Temporary files use the system cache directory, retain only the current and next tracks (up to 256 MiB each), and are separate from explicit offline downloads. HLS/DASH manifests and oversized files use native streaming instead. Native background and interruption behavior still needs device verification.

## Checks

```sh
flutter analyze
flutter test
```

GitHub Actions runs these checks and verifies generated messages for pushes and pull requests. The analyzer enables strict casts, explicit asynchronous futures, and typed catch clauses.

Run integration checks on a dedicated simulator: they modify the test app's local data. For example, the self-contained volume-normalization scenario:

```sh
python3 tool/run_integration.py --device <simulator-id> --suite volume_normalization
```

A self-contained large-list regression exercises 5,000-track folders and queues:

```sh
python3 tool/run_integration.py --device <simulator-id> --suite large_lists
```

The direct playlist editor has a self-contained native UI scenario, using fixture data and no live server writes:

```sh
python3 tool/run_integration.py --device <simulator-id> --suite playlist_editor
```

Completed-download management has a fixture-only native scenario that creates and removes temporary files:

```sh
python3 tool/run_integration.py --device <simulator-id> --suite downloaded_tracks
```

The group playback controls and initial shuffle selection have a fixture-only scenario:

```sh
python3 tool/run_integration.py --device <simulator-id> --suite group_play
```

Queue navigation and tracking have a fixture-only native scenario, including distant positions in a 10,000-entry queue:

```sh
python3 tool/run_integration.py --device <simulator-id> --suite queue_follow
```

Server scenarios accept `JELLYFIN_TEST_SERVER`, `JELLYFIN_TEST_USER`, and `JELLYFIN_TEST_PASSWORD` through the environment, or a private file outside the project (`--credentials <file>`, containing `TEST_SERVER`, `TEST_USERNAME`, and `TEST_PASSWORD`). Run all suites sequentially with `--suite all`. Simulator background checks are complemented by manual checks on an iPhone.

## Code layout

| Directory | Responsibility |
| --- | --- |
| `lib/domain` | Catalog, queue, and playback rules |
| `lib/application` | Application workflows and external service interfaces |
| `lib/infrastructure` | Jellyfin, audio, downloads, import, and storage |
| `lib/presentation` | Screens, widgets, navigation, and theme |
| `ios`, `android` | Native hosts, media integration, and document pickers |
| `test`, `integration_test` | Automated checks |
| `tool` | Build and verification tools |

Fixes and suggestions are welcome through [Issues](https://github.com/antontonkovkz/simplify/issues) and pull requests. Run the analyzer and relevant tests before submitting changes. Write commit messages and public documentation in English. Keep passwords, tokens, personal signing settings, and private configuration outside the repository.

## License

Copyright 2026 Anton Tonkov. The code is distributed under the [Apache License 2.0](LICENSE); attribution and project links are in [NOTICE](NOTICE). Third-party components retain their respective licenses.

[Repository](https://github.com/antontonkovkz/simplify) · [Author's website](https://madnum.me)

### Download recovery checks

Start a generated-data fixture server on your Mac:

```sh
python3 tool/download_fixture_server.py --bind 0.0.0.0 --port 8765
```

Keep a definitions JSON file outside the repository with `TEST_DOWNLOAD_FIXTURE` set to `http://<mac-lan-address>:8765`. Use `http://127.0.0.1:8765` for iOS Simulator. Add `TEST_DOWNLOAD_BACKGROUND: true` for the background scenario. Then run:

```sh
python3 tool/run_integration.py --device <device-id> --suite download_status --credentials <external-definitions.json>
```

For physical iOS, add `--platform ios --reactivate-device <core-device-id>`. For Android, add `--platform android` and provide `adb` on PATH or set `ANDROID_HOME`. The fixture simulates interrupted connections, checks automatic and manual recovery, and optionally opens the app settings while a native download continues. It uses a separate fixture download namespace and generated files; existing accounts and music stay untouched. The UI checks also run without fixture definitions.

For development, `--dart-define=SERVER_URL=https://your-server.example` optionally prefills the login server address. Do not put credentials or tokens in build definitions or source code. Public builds do not require this setting.
