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
- Sign in with ed25519, RSA or ECDSA (P-256, P-384, P-521; OpenSSH or PEM) keys, or a password.
- A real terminal (xterm-256color) in tabs. ⇧⌘] and ⇧⌘[ move between them.
- Split panes like iTerm: ⌘D beside, ⇧⌘D below, ⌥⌘ arrows to move, drag the dividers, ⌘W closes a pane.
- Suggestions as you type, like zsh-autosuggestions: commands you ran on that host appear in grey
  after the cursor; → takes them. Clavra's own history stays on this Mac and skips anything that
  looks like a password; the server's shell history is read at connect and kept in memory only.
- Find in scrollback (⌘F, ⌘G), font size (⌘+, ⌘-, ⌘0), clear scrollback (⌥⌘K), save output (⇧⌘S).
- Type into every pane at once (⌥⌘I), with each production pane still asking before risky commands.
- A dropped connection comes back on its own, tunnels and all, a few times before giving up.
- The bell bounces the Dock icon and marks the tab when you're elsewhere.
- Per host: a command to type once the shell is up (`cd /srv/app && tmux attach`), and notes.
- `ssh://user@host:port` links open in Clavra; a menu bar list opens any saved host in one click;
  tabs come back after a relaunch.

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
- Tunnels, ⇧⌘P: local (`ssh -L`), remote (`ssh -R`) and a SOCKS5 proxy (`ssh -D`), written in
  Clavra rather than borrowed. The ports the server listens on are offered one click away; tunnels
  saved with a host open on every connect.
- Files over SFTP beside the terminal, ⇧⌘F: browse, download files or whole folders to ~/Downloads,
  drop files or folders to upload, edit a file in any Mac app (each save goes back up),
  permissions, rename, new file or folder, delete.
- Snippets: saved commands, typed into the front terminal with ⌘;. Risky ones still ask.

**Keys**
- Every private key in `~/.ssh`, checked: type and size, passphrase or not, permissions, age, and
  which hosts use it. Weak or open keys are called out; loose permissions are one click to fix.
- Make a new Ed25519 key (the Mac's own `ssh-keygen`, the passphrase passed through askpass rather
  than the command line) and install its public key on a connected server.

**From your phone**
- Phone Access (⌥⌘3): turn it on, scan the QR code with a phone on the same Wi-Fi, allow the phone
  on the Mac, and your tabs are in its browser. Nothing to install. The Mac does the terminal; the
  phone draws the screen and types back, with a row for Esc, Tab, Ctrl and the arrows.
- The QR code carries the Mac's address and a fresh 256-bit key after the `#`, so the key never
  crosses the network. Everything on the socket is sealed with ChaCha20-Poly1305 (CryptoKit on the
  Mac, `Clavra/Remote/aead.js` on the phone, checked against RFC 8439 and CryptoKit), bound to a
  per-connection challenge and numbered so nothing can be replayed. Production tabs are view-only
  from a phone unless you allow typing; access turns itself off after 30 idle minutes.
- The page loads over plain HTTP (a phone won't trust a certificate the Mac makes up), so someone
  able to rewrite traffic on the network as the page loads could tamper with it. Use it at home or
  in the office, not on public Wi-Fi.

**Everywhere you work**
- Optionally keep hosts and snippets in iCloud Drive, so your other Macs see them. Passwords and
  passphrases stay in each Mac's Keychain.
- Export and import hosts and snippets as one JSON file (never with secrets). Trusted host keys can
  be reviewed and forgotten in Settings.

## Build

Xcode 26 or later, macOS 15 or later.

```sh
xcodebuild -project Clavra.xcodeproj -scheme Clavra -configuration Debug \
  -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages build
```

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
