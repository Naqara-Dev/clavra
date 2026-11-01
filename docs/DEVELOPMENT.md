# Developing Clavra

## Build

Xcode 26 or later, macOS 15 or later.

```sh
xcodebuild -project Clavra.xcodeproj -scheme Clavra -configuration Debug \
  -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages build
```

## Release

```sh
./scripts/release.sh   # tests, then dist/Clavra-X.dmg and dist/appcast.xml
gh release create vX dist/Clavra-X.dmg dist/appcast.xml --title "Clavra X" --notes-file notes.md
```

Bump `CURRENT_PROJECT_VERSION` (and usually `MARKETING_VERSION`) first: Sparkle compares the build
number. Both files must be on the release, since the app reads
`releases/latest/download/appcast.xml`. The DMG is signed with the "Naqara Dev Code Signing"
certificate, and the appcast with the EdDSA key in the login Keychain (account `naqara-clavra`);
its public half is `SUPublicEDKey` in `Config/Info.plist`. Keep backups of both: without the
certificate, macOS treats an update as a different app; without the key, existing copies can't
update at all.

## Tests

```sh
./scripts/test.sh   # logic: risky commands, prompts, safe names, secrets, tunnels, panes, host keys, phone crypto
./scripts/e2e.sh    # the Debug build against a throwaway sshd on 127.0.0.1:2222, every feature end to end
```

`e2e.sh` needs the Debug build and ports 2222, 8765, 18765, 19876 and 11080 free. It makes its
own server, keys and files in a temporary folder and removes everything it added when it's done.

## Dependencies

| Package | Version | Why pinned there |
|---|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) | 0.12.1 | SSH client on SwiftNIO SSH, with RSA keys and SFTP. |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0 | In-place updates, the same version Novra ships. |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.11.2 | 1.12+ needs the Metal Toolchain (GPU renderer); 1.19+ also runs a build plugin. Move up once both are acceptable. |

Citadel 0.12.1 pulls `swift-nio-ssh` from a contributor's fork,
[Wellz26/swift-nio-ssh](https://github.com/Wellz26/swift-nio-ssh), with the range `0.3.4 ..< 0.4.0`.
Version 0.3.7 was read line by line against Joannis/swift-nio-ssh (Citadel's upstream): it adds a
NIO product dependency and a fix that stops sending a window adjust to a closing channel. Nothing
else. `Package.resolved` pins it to commit `d88989f`; **read the diff before letting it move.**

## Debug launch arguments

Debug builds only:

| Argument | Effect |
|---|---|
| `-ClavraOpen user@host:port` | Opens a session on launch. |
| `-ClavraKey path` | Key for that session. |
| `-ClavraPlace production` | Marks it as production. |
| `-ClavraAutoTrust YES` | Trusts the host key after showing the prompt for 2.5 s. |
| `-ClavraType 'ls\r\|ec\e[C'` | Types into the shell once it's up, a key at a time; `\|` pauses, `\e` is Escape. |
| `-ClavraNewHost YES` | Opens the host editor. |
| `-ClavraJump user@host:port` | Reaches the session's host through this one. |
| `-ClavraForward 18080:8080,socks:1080,remote:9000:3000` | Adds tunnels that open on connect. |
| `-ClavraSplit beside,below` | Splits the new tab. |
| `-ClavraStartup 'cd /srv'` | Sets the command typed once the shell is up. |
| `-ClavraRemote YES` | Turns on Phone Access and prints the link. |
| `-ClavraRemoteAllow YES` | Allows phones without asking (testing only). |
| `-ClavraPanel files` or `ports` | Opens that panel beside the terminal. |
| `-ClavraSnippets YES` | Opens the snippet palette. |
| `-ClavraPage keys`, `snippets` or `remote` | Shows that page instead of "Where to?". |
| `-ClavraOpenSaved api-prod,web-staging` | Opens saved hosts by name, a tab each. |
| `-ClavraTypes '("ls\\r", "top\\r")'` | Like `-ClavraType`, one entry per session in the order they were made. |
| `-ClavraWindow 1440x880` | Sizes the window, for screenshots. |
| `-ClavraDemoTargets '{ "<host id>" = "deploy@10.0.1.12"; }'` | Shows a made-up address for a saved host, so screenshots don't show a real account. |
| `-ClavraRelay ws://127.0.0.1:8790` | Points Phone Access at `Tests/relay-mock.js` instead of clavra.naqara.dev. |
| `-ClavraFilesTest dir`, `-ClavraEditNoOpen YES` | Drive the file browser for `scripts/e2e.sh`. |
| `-ClavraTestUpdate YES -SUFeedURL <appcast>` | Installs whatever the feed offers without asking, to try an update end to end. |

To try a real connection without touching System Settings, run a throwaway `sshd` as yourself on
localhost: generate a host key and a client key with `ssh-keygen`, point a small `sshd_config` at them
(`ListenAddress 127.0.0.1`, `Port 2222`, `PasswordAuthentication no`, `UsePAM no`, `StrictModes no`),
start `/usr/sbin/sshd -f sshd_config`, and launch with `-ClavraOpen $USER@127.0.0.1:2222 -ClavraKey <client key>`.

## App icon

`swift scripts/icon.swift out.png 1024` draws it; the sizes in `Assets.xcassets` come from the same
script.

## Design

Depth from small steps in lightness and 1-pixel hairlines; no glows, gradients or looping animation.
SF Pro at 13 pt, mostly regular and medium. Tokens are in `Clavra/UI/Theme.swift`.

## clavra.naqara.dev

`site/` is the Cloudflare Worker behind clavra.naqara.dev: the landing page (`site/public`), the
phone page at `/connect`, and the Phone Access relay (`site/worker.js`, a Durable Object per room).
Cloudflare builds it from this repository on every push to `main` (`npx wrangler deploy` in `site/`).

- The relay only passes frames along. Phone and Mac seal everything with the key in the QR code;
  a room is named after the SHA-256 of a secret only the Mac holds, so nobody else can be its Mac.
- `/connect` is the same page the Mac serves on Wi-Fi. `scripts/sync-site.sh` copies it from
  `Clavra/Remote`, and `scripts/test.sh` fails when the two differ.
- `Tests/relay-mock.js` speaks the same protocol on this Mac, for tests without a deploy.
- The share image is drawn from `site/tools/og.html`.
