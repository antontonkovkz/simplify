# Simplefy

<img src="assets/branding/simplefy-icon.png" alt="Simplefy" width="128" height="128">

**Just music. Just play.**<br>
**Your music. Your way.**

A simple [Jellyfin](https://jellyfin.org/) music player built with Flutter. Browse your actual folders, edit one playback queue, and keep music available offline.

The app targets **iPhone, iOS 14+**, and **Android 7.0+ (API 24+)**. The Android host supports foreground media playback and imports user-selected files or folders through the system document picker. The app interface is currently in Russian. App Store and Google Play distribution are being prepared separately.

## Features

- Collections → folders → tracks, preserving the server's folder structure. Search file names, artists, and track titles.
- Play buttons at the right edge of collections, folders, and playlists replace the queue and start immediately: the first track in sequential mode, a random occurrence in shuffle mode. Queue order stays unchanged, and the play button opens the queue immediately while preparing playback in the background. The queue reveals the current occurrence when playback advances and uses the latest occurrence when reopened. Manual browsing stays in place until the next track change.
- Collections, folders, albums, and playlists show their saved contents immediately and refresh in the background. Snapshots remain available when an update fails.
- One editable queue: append folders, playlists, or tracks, reorder entries, and switch between sequential and shuffle playback.
- Server and local playlists. Edit an opened server playlist directly: add tracks from the library, reorder or remove entries, then save to the server with permission or create a named local copy. Queue editing and saving remain available separately.
- Download tracks, folders, and playlists. Settings → downloaded songs lists completed files once, with search and individual deletion across download groups. Removing downloads affects only this device.
- Import audio files and folders from the iOS Files app into a separate local library. Local music works without a Jellyfin account.
- Background audio, headset commands, and lock-screen playback controls.
- Preload the next track and restore the queue, playback position, and last opened folder or playlist.
- Volume normalization using Jellyfin metadata, enabled by default. Choose track, album, or off. Missing metadata leaves the original volume unchanged; audio analysis and amplification are not implemented yet.
- Compact playback controls and library rows. The queue shows its playlist source, unsaved changes, track count, and total duration when known. Pull the queue down or hold its title to search; swipe left to remove an entry, or use its long-press menu. Partial downloads show available/total counts instead of a completion checkmark.

Tap a track to replace the queue with its current folder or playlist and start that occurrence. Long-press an item to open its actions. Editing the queue or a playlist draft never changes the source playlist until you explicitly save it. Playlist drafts leave current playback and its queue untouched. Server saves recheck permissions and ask before overwriting a changed playlist.

Long music lists build only viewport rows, including the playback queue. Queue snapshots and entry indices are reused between structural edits.

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

The public entry point is `lib/main.dart`. Enter your own Jellyfin server address and account details in the app, or import local music. No test credentials are included. Passwords are not stored; the session is kept in Keychain. Sign out or switch accounts in Settings.

The optional personal entry point, `lib/main_personal.dart`, accepts an initial session through `BOOTSTRAP_SESSION`. The build tool accepts private definitions only from a file **outside this project**, using `--variant personal --definitions <file>`. These builds contain a session and are intended for personal use. The public entry point rejects a nonempty `BOOTSTRAP_SESSION`.

## Checks

```sh
flutter analyze
flutter test
```

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
