# Clavra

An SSH client for the Mac, by Naqara Dev. Every server, one key.

Local-first: hosts live in a JSON file on your Mac, passwords and key passphrases in the Keychain, and
there is no account. Calm to look at: warm ink in the dark, paper in the light, one brass accent.

## What it does

**Connecting**
- Hosts grouped by place (production, staging, personal), search, import from `~/.ssh/config`.
- "Where to?": type a saved name or `user@server:port` and press Return.
- Sign in with an ed25519 or RSA key (passphrase supported) or a password.
- Host keys are checked: the first connection shows the SHA-256 fingerprint to trust, and a changed
  key is called out. Keys already in a plain `~/.ssh/known_hosts` line count as trusted.
- Jump hosts: reach a server through a bastion you've saved, like `ProxyJump`. Both host keys are checked.
- A real terminal (xterm-256color) in tabs. ⇧⌘] and ⇧⌘[ move between them.

**Staying safe on production**
- Return on a risky command (`rm -rf`, `DROP TABLE`, `DELETE` without `WHERE`, `shutdown`,
  `docker rm`, `git push --force`, `terraform destroy` and more) holds it back and asks first.
  Nothing reaches the server until you say so. On by default for production, per host otherwise.
  The rules are in `Clavra/Features/CommandGuard.swift`.

**Knowing how a server is doing**
- The sidebar shows whether each host answers on its SSH port, and how fast. A plain TCP connect
  every five minutes, nothing sent; it can be turned off in Settings.
- While connected, the status line shows load, memory, disk on `/` and uptime, read over a side
  channel every 20 seconds. Anything running hot turns coral.

**Ports, files, snippets**
- Port forwarding (`ssh -L`): Clavra lists the ports the server listens on and forwards one with a
  click, or opens the tunnels saved with the host on every connect. ⇧⌘P.
- Files over SFTP beside the terminal: browse, download to ~/Downloads, drop files to upload,
  rename, new folder, delete. ⇧⌘F.
- Snippets: saved commands, typed into the front terminal with ⌘;. Risky ones still ask.

**Keys**
- Every private key in `~/.ssh`, checked: type and size, passphrase or not, permissions, age, and
  which hosts use it. Weak or open keys are called out; loose permissions are one click to fix.
- Make a new Ed25519 key (the Mac's own `ssh-keygen`, the passphrase passed through askpass rather
  than the command line) and install its public key on a connected server.

**Everywhere you work**
- Optionally keep hosts and snippets in iCloud Drive, so your other Macs see them. Passwords and
  passphrases stay in each Mac's Keychain.

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
| `-ClavraJump user@host:port` | Reaches the session's host through this one. |
| `-ClavraForward 18080:8080` | Adds a tunnel that opens on connect. |
| `-ClavraPanel files` or `ports` | Opens that panel beside the terminal. |
| `-ClavraSnippets YES` | Opens the snippet palette. |
| `-ClavraPage keys` or `snippets` | Shows that page instead of "Where to?". |

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
