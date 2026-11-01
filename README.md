# Clavra

An SSH client for the Mac, by Naqara Dev. Every server, one key.

Local-first: hosts live in a JSON file on your Mac, passwords and key passphrases in the Keychain, and
there is no account. Calm to look at: warm ink in the dark, paper in the light, one brass accent.

## What works today (0.1)

- Hosts grouped by place (production, staging, personal), search, import from `~/.ssh/config`.
- "Where to?": type a saved name or `user@server:port` and press Return.
- Sign in with an ed25519 or RSA key (passphrase supported) or a password.
- Host keys are checked: the first connection shows the SHA-256 fingerprint to trust, and a changed
  key is called out. Keys already in a plain `~/.ssh/known_hosts` line count as trusted.
- A real terminal (xterm-256color) in tabs, resizing with the window. Production hosts get a red mark.

## Build

Xcode 26 or later, macOS 15 or later.

```sh
xcodebuild -project Clavra.xcodeproj -scheme Clavra -configuration Debug \
  -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages build
```

## Dependencies

| Package | Version | Why pinned there |
|---|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) | 0.12.1 | SSH client on SwiftNIO SSH, with RSA keys and SFTP. |
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
| `-ClavraType 'ls\r'` | Types into the shell once it's up. |
| `-ClavraNewHost YES` | Opens the host editor. |

To try a real connection without touching System Settings, run a throwaway `sshd` as yourself on
localhost: generate a host key and a client key with `ssh-keygen`, point a small `sshd_config` at them
(`ListenAddress 127.0.0.1`, `Port 2222`, `PasswordAuthentication no`, `UsePAM no`, `StrictModes no`),
start `/usr/sbin/sshd -f sshd_config`, and launch with `-ClavraOpen $USER@127.0.0.1:2222 -ClavraKey <client key>`.

## Design

Depth from small steps in lightness and 1-pixel hairlines; no glows, gradients or looping animation.
SF Pro at 13 pt, mostly regular and medium. Tokens are in `Clavra/UI/Theme.swift`.
