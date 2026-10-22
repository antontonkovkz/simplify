# Simplefy privacy policy

Effective date: October 22, 2026

Simplefy is an open-source music player developed by Anton Tonkov. It plays music from a Jellyfin server you choose and audio files you import. Simplefy does not provide a music catalog or require a separate Simplefy account.

## Advertising and analytics

Simplefy does not include advertising, tracking, analytics, or automatic crash-reporting services. The app does not send your music library or credentials to a separate Simplefy service.

## Connecting to your server

When you sign in, your server receives the username and password you enter. The app does not save the password. It retains the server address, account information, and authentication session using platform secure storage so you can stay signed in.

Browsing, playback, downloads, and playlist actions send requests and the authentication information needed for those requests to your chosen server. The server can see information such as your IP address, client identifier, and requested media. Its administrator may keep logs and has their own data practices. Use a server you trust and HTTPS to protect traffic in transit; connections to an HTTP server are not encrypted.

Authenticated background downloads pass the information needed to complete the transfer to the operating system's transfer facilities. Operating-system behavior and retention also apply to these transfers.

## Data on your device

The app stores settings, cached library metadata, playback queue and position, browsing location, local playlists, and imported or downloaded audio on your device. These records may include media names, paths, artists, and identifiers. Imports use files or folders you select through the system picker. Playback controls and notifications may display media information on your lock screen.

You can remove downloads and imported music using the app's controls. Signing out removes the app's saved sign-in session; it does not delete your server account or promise to erase all local music and account-specific cached files. Uninstalling removes the app's local container subject to platform behavior; iOS may retain Keychain entries, so sign out before uninstalling if you want to clear the saved session.

## Permissions and external links

The app uses internet access for your server, system file selection for imports, background facilities for audio and downloads, and notifications where permitted. The operating system controls the relevant permissions and system services.

Support, source-code, and author links open external websites only when selected. Those websites, including GitHub and madnum.me, have their own privacy policies. Information you voluntarily post in a GitHub issue is public. Never post passwords, authentication tokens, or private server logs without removing sensitive information.

## Contact and changes

For questions about Simplefy, use [GitHub Issues](https://github.com/antontonkovkz/simplify/issues) or the contact options on [madnum.me](https://madnum.me). For information held by your Jellyfin server, contact its administrator.

This policy may change when the app's behavior changes. Updates are published in this repository with a revised effective date.
