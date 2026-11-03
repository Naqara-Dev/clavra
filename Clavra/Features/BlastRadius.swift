import Foundation

/// What a held command would touch, read on the server before anyone says yes: how many files
/// `rm -rf` would delete and how big they are, which units depend on a service about to stop, who
/// is signed in before a reboot, which containers `docker compose down` takes with it.
///
/// Each check is a look-alike that only reads (`find` instead of `rm`, `kubectl get` instead of
/// `kubectl delete`, `apt-get -s`), run over a side channel in POSIX `sh`. A command that leans on
/// anything the look-alike couldn't repeat exactly (variables, `$(…)`, pipes, redirection) gets no
/// preview rather than a wrong one.
enum BlastRadius {
    /// A look-alike to run, and how to read what it prints.
    struct Probe: Sendable {
        /// The full line for the server: `sh -c '…'`.
        var command: String
        var kind: Kind
        /// `sudo` was dropped, so anything only root can see is missing.
        var withoutSudo: Bool
        /// Archives what the command would touch first, so it can be put back; for `rm` and
        /// recursive `chmod`/`chown` run as you. Prints `backup=<file>` and `bytes=<n>`, or why not.
        var backup: String?
        /// The line has more risky parts after this one; only this one is shown, and nothing is backed up.
        var more = false
    }

    enum Kind: Sendable, Equatable {
        case delete, matches, permissions, services, processes, containers, compose, dockerSpace
        case kube, drain, packages, cron, reboot, gitReset, gitClean, gitPush, disk, redis, firewall
    }

    enum Plan: Sendable {
        case probe(Probe)
        /// It could be checked, but only knowing the folder the shell is in, and that isn't known.
        case needsFolder
    }

    struct Word: Equatable {
        var text: String
        /// Some or all of it was quoted or escaped, so the shell wouldn't expand it.
        var quoted: Bool
    }

    // MARK: Planning

    /// The look-alike for `line`, or nil when there's nothing to preview or no safe way to.
    /// `folder` is where the shell is (`~/app`, `/srv/www`), when known.
    static func plan(for line: String, folder: String?) -> Plan? {
        var folder = folder
        let parts = segments(line)
        let risky = parts.filter { CommandGuard.check($0) != nil }.count
        for segment in parts {
            guard var words = words(segment), !words.isEmpty else {
                // Something here can't be repeated safely; if it's the risky part, stop. If not,
                // it may still have moved the shell (`cd "$DIR"`), so the folder is no longer known.
                if CommandGuard.check(segment) != nil { return nil }
                folder = nil
                continue
            }
            let sudo = stripPrefixes(&words)
            guard let first = words.first else { continue }
            if ["cd", "pushd", "popd"].contains(first.text) {
                // `cd /srv/app && rm -rf build`: the rm runs there. Anything less plain
                // (`cd -P`, `pushd`) and the folder is no longer known.
                if first.text == "cd", words.count == 2, !words[1].text.hasPrefix("-") {
                    folder = resolve(words[1].text, in: folder)
                } else if first.text == "cd", words.count == 1 {
                    folder = "~"
                } else {
                    folder = nil
                }
                continue
            }
            guard CommandGuard.check(segment) != nil else { continue }
            // Braces and `**` expand in bash and zsh but not in sh: the look-alike would look at
            // something else than the command touches.
            if words.contains(where: { !$0.quoted && ($0.text.contains("**") || $0.text.range(of: #"\{[^}]*(,|\.\.)[^}]*\}"#, options: .regularExpression) != nil) }) { return nil }
            guard let (kind, look, wantsFolder) = body(for: words) else { return nil }
            var script = "T=; command -v timeout >/dev/null 2>&1 && T='timeout 5'; "
            if wantsFolder {
                guard let folder else { return .needsFolder }
                script += "cd \(render(folder: folder)) 2>/dev/null || { echo nofolder=1; exit 0; }; "
            }
            script += look + "; exit 0"
            var backup: String?
            if !sudo, risky == 1, let list = backupList(words) {
                let into = wantsFolder ? folder.map { "cd \(render(folder: $0)) 2>/dev/null || { echo failed=folder; exit 0; }; " } : ""
                backup = into.map { wrap($0 + archive(list) + "; exit 0", seconds: 300) }
            }
            return .probe(Probe(command: wrap(script), kind: kind, withoutSudo: sudo, backup: backup, more: risky > 1))
        }
        return nil
    }

    /// The whole look-alike under an 8-second limit where the server has `timeout`, so nothing it
    /// asks (docker, kubectl, a find over a huge tree) can hold its channel open.
    static func wrap(_ script: String, seconds: Int = 8) -> String {
        let outer = "command -v timeout >/dev/null 2>&1 && exec timeout \(seconds) sh -c \"$1\"; exec sh -c \"$1\""
        return "sh -c " + quote(outer) + " clavra " + quote(script)
    }

    /// Who and where a prompt like `deploy@web-1:~/app$ ` says the shell is, and whether it ends
    /// in `#` (root).
    static func identity(fromPrompt line: String) -> (user: String, host: String, root: Bool)? {
        let pattern = #"^(?:\([^)]*\)\s*)?([^\s@]+)@([^\s:]+):[^$#]*?\s*([$#])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let user = Range(match.range(at: 1), in: line), let host = Range(match.range(at: 2), in: line),
              let mark = Range(match.range(at: 3), in: line) else { return nil }
        return (String(line[user]), String(line[host]), line[mark] == "#")
    }

    /// The folder a prompt like `deploy@web-1:~/app$ ` or `root@db:/var/lib# ` shows.
    static func folder(fromPrompt line: String) -> String? {
        let pattern = #"^(?:\([^)]*\)\s*)?[^\s@]+@[^\s:]+:(~[^$#]*|/[^$#]*?)\s*[$#]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        let folder = line[range].trimmingCharacters(in: .whitespaces)
        return folder.isEmpty ? nil : folder
    }

    private static func resolve(_ path: String, in folder: String?) -> String? {
        if path.hasPrefix("/") || path.hasPrefix("~") { return path }
        if path == "-" { return nil }
        guard let folder else { return nil }
        return folder.hasSuffix("/") ? folder + path : folder + "/" + path
    }

    /// The command's own words for the look-alike, and whether relative paths matter.
    private static func body(for words: [Word]) -> (Kind, String, Bool)? {
        let name = (words[0].text as NSString).lastPathComponent
        let rest = Array(words.dropFirst())
        switch name {
        case "rm":
            let paths = operands(rest)
            guard !paths.isEmpty, let list = render(paths) else { return nil }
            return (.delete, existing(list) + "; " + count(paths: list) + "; " + size(list), needsFolder(paths))
        case "find":
            // A find that writes files of its own, or whose words a glob could turn into actions,
            // has no look-alike.
            let writes = ["-fprint", "-fprint0", "-fprintf", "-fls", "-okdir"]
            guard !rest.contains(where: { writes.contains($0.text) }),
                  !rest.contains(where: { !$0.quoted && $0.text.contains(where: { "*?[".contains($0) }) }),
                  let list = render(findWithoutActions(rest)) else { return nil }
            return (.matches, count(find: list), needsFolder(rest))
        case "chmod", "chown", "chgrp":
            let paths = Array(operands(rest).dropFirst())
            guard !paths.isEmpty, let list = render(paths) else { return nil }
            return (.permissions, count(paths: list) + "; " + size(list), needsFolder(paths))
        case "systemctl":
            guard let verb = rest.first(where: { !$0.text.hasPrefix("-") }) else { return nil }
            let units = operands(rest).filter { $0 != verb }
            guard ["stop", "restart", "disable", "mask", "kill"].contains(verb.text), !units.isEmpty, let list = render(units) else { return nil }
            return (.services, services(list), false)
        case "service":
            guard rest.count >= 2, let list = render([rest[0]]) else { return nil }
            return (.services, services(list), false)
        case "kill":
            let pids = rest.filter { $0.text.allSatisfy(\.isNumber) && !$0.text.isEmpty }
            guard !pids.isEmpty else { return nil }
            return (.processes, "ps -o pid=,etime=,comm= -p \(pids.map(\.text).joined(separator: ",")) 2>/dev/null | sed 's/^ *//' | sed 's/^/proc=/'", false)
        case "pkill":
            guard let list = render(withoutSignal(rest)), !list.isEmpty else { return nil }
            return (.processes, "pgrep -l \(list) 2>/dev/null | sed 's/^/proc=/'", false)
        case "killall":
            let names = operands(withoutSignal(rest))
            guard !names.isEmpty, let list = render(names) else { return nil }
            return (.processes, "for n in \(list); do pgrep -lx \"$n\"; done 2>/dev/null | sed 's/^/proc=/'", false)
        case "docker", "docker-compose":
            return docker(name == "docker-compose" ? [Word(text: "compose", quoted: false)] + rest : rest)
        case "kubectl":
            return kubectl(rest)
        case "apt", "apt-get":
            guard let verb = rest.first(where: { !$0.text.hasPrefix("-") }), ["remove", "purge", "autoremove"].contains(verb.text),
                  let list = render(operands(rest).filter { $0 != verb }) else { return nil }
            return (.packages, "apt-get -s \(verb.text) \(list) 2>/dev/null | grep '^Remv' | cut -d' ' -f2 | sed 's/^/pkg=/'", false)
        case "crontab":
            guard rest.contains(where: { $0.text == "-r" }) else { return nil }
            var user = ""
            if let index = rest.firstIndex(where: { $0.text == "-u" }), index + 1 < rest.count, let who = render([rest[index + 1]]) { user = "-u \(who) " }
            return (.cron, "c=$(crontab \(user)-l 2>/dev/null) && j=$(echo \"$c\" | grep -cvE '^[[:space:]]*(#|$)'); [ -n \"$j\" ] && echo \"jobs=$j\"", false)
        case "reboot", "shutdown", "poweroff", "halt", "init":
            return (.reboot, "w=$(who 2>/dev/null | wc -l); u=$(uptime -p 2>/dev/null || uptime); echo \"who=$w\"; echo \"up=$u\"", false)
        case "git":
            return git(rest)
        case _ where name.hasPrefix("mkfs"):
            guard let device = operands(rest).last, device.text.hasPrefix("/dev/"), let list = render([device]) else { return nil }
            return (.disk, disk(list), false)
        case "dd":
            guard let target = rest.first(where: { $0.text.hasPrefix("of=/dev/") }),
                  let list = render([Word(text: String(target.text.dropFirst(3)), quoted: target.quoted)]) else { return nil }
            return (.disk, disk(list), false)
        case "redis-cli":
            // Only connection options may come before FLUSHALL; anything else is a command of its
            // own that the look-alike would run.
            guard let index = rest.firstIndex(where: { ["flushall", "flushdb"].contains($0.text.lowercased()) }),
                  connectionOnly(Array(rest[..<index]), valued: ["-h", "-p", "-a", "-n", "-u", "-s", "--user", "--pass", "--sni", "--cacert", "--cacertdir", "--cert", "--key"],
                                 bare: ["--tls", "--insecure", "--askpass", "--no-auth-warning"]),
                  let options = render(Array(rest[..<index])) else { return nil }
            if rest[index].text.lowercased() == "flushdb" {
                return (.redis, "k=$(redis-cli \(options) dbsize 2>/dev/null) && echo \"keys=$k\"", false)
            }
            return (.redis, "i=$(redis-cli \(options) info keyspace 2>/dev/null) && k=$(echo \"$i\" | grep -o 'keys=[0-9]*' | cut -d= -f2 | awk '{s+=$1} END {print s+0}'); echo \"keys=$k\"", false)
        case "iptables", "ip6tables":
            return (.firewall, "r=$(\(name) -S 2>/dev/null) && n=$(echo \"$r\" | grep -c '^-A'); [ -n \"$r\" ] && echo \"rules=$n\"", false)
        default:
            return nil
        }
    }

    private static func docker(_ rest: [Word]) -> (Kind, String, Bool)? {
        guard let verb = rest.first(where: { !$0.text.hasPrefix("-") }) else { return nil }
        switch verb.text {
        case "rm", "kill", "stop":
            let names = operands(rest).filter { $0 != verb }
            guard !names.isEmpty, let list = render(names) else { return nil }
            return (.containers, "docker inspect --format '{{.Name}} {{.State.Status}}' \(list) 2>/dev/null | sed 's|^/||' | sed 's/^/item=/'", false)
        case "system", "container", "volume", "image", "network":
            return (.dockerSpace, "docker system df --format '{{.Type}}: {{.Reclaimable}} of {{.Size}}' 2>/dev/null | sed 's/^/item=/'", false)
        case "compose":
            // `docker compose -f prod.yml -p shop down`: the options before `down` say which project.
            let after = Array(rest.drop { $0 != verb }.dropFirst())
            guard let sub = after.firstIndex(where: { ["down", "rm", "kill", "stop"].contains($0.text) }),
                  connectionOnly(Array(after[..<sub]), valued: ["-f", "--file", "-p", "--project-name", "--env-file", "--profile", "--project-directory", "--ansi", "--parallel", "--progress"],
                                 bare: ["--compatibility", "--dry-run", "--all-resources"]),
                  let global = render(Array(after[..<sub])) else { return nil }
            let all = after[sub].text == "stop" || after[sub].text == "kill" ? "" : "-a "
            return (.compose, "docker compose \(global) ps \(all)--format '{{.Name}} {{.State}}' 2>/dev/null | sed 's/^/item=/'", true)
        default:
            return nil
        }
    }

    private static func kubectl(_ rest: [Word]) -> (Kind, String, Bool)? {
        guard let index = rest.firstIndex(where: { !$0.text.hasPrefix("-") }) else { return nil }
        let before = Array(rest[..<index]), after = Array(rest[(index + 1)...])
        switch rest[index].text {
        case "delete":
            let dropped = ["--grace-period", "--force", "--now", "--wait", "--cascade", "--timeout", "--ignore-not-found", "--dry-run"]
            let kept = after.filter { word in !dropped.contains { word.text == $0 || word.text.hasPrefix($0 + "=") } }
            guard let list = render(before + kept) else { return nil }
            return (.kube, "kubectl get \(list) -o name 2>/dev/null | sed 's/^/item=/'", false)
        case "drain":
            guard let node = after.first(where: { !$0.text.hasPrefix("-") }), let list = render(before), let name = render([node]) else { return nil }
            return (.drain, "p=$(kubectl \(list) get pods -A --field-selector spec.nodeName=\(name) -o name 2>/dev/null | wc -l); echo \"pods=$p\"", false)
        default:
            return nil
        }
    }

    private static func git(_ rest: [Word]) -> (Kind, String, Bool)? {
        guard let index = rest.firstIndex(where: { !$0.text.hasPrefix("-") }) else { return nil }
        let after = Array(rest[(index + 1)...])
        switch rest[index].text {
        case "reset":
            return (.gitReset, "s=$(git status --porcelain 2>/dev/null) || exit 0; n=$(echo \"$s\" | grep -v '^??' | grep -c .); echo \"changed=$n\"", true)
        case "clean":
            // The same options without the one that makes it act: -fdx is -dx with -n.
            var options: [Word] = []
            for word in after {
                if word.text == "--force" { continue }
                if word.text.hasPrefix("-"), !word.text.hasPrefix("--") {
                    let letters = word.text.dropFirst().filter { $0 != "f" }
                    if !letters.isEmpty { options.append(Word(text: "-" + letters, quoted: word.quoted)) }
                } else {
                    options.append(word)
                }
            }
            guard let list = render(options) else { return nil }
            return (.gitClean, "git clean -n \(list) 2>/dev/null | sed 's/^Would remove /item=/'", true)
        case "push":
            return (.gitPush, "n=$(git rev-list --count 'HEAD..@{u}' 2>/dev/null) && echo \"behind=$n\"", true)
        default:
            return nil
        }
    }

    // MARK: Backups

    /// The paths `rm` or `chmod -R` names, ready for `sh`. Not `chown`/`chgrp`: without root an
    /// owner can't be put back, so a restore would only look like one.
    private static func backupList(_ words: [Word]) -> String? {
        let name = (words[0].text as NSString).lastPathComponent
        let rest = Array(words.dropFirst())
        let paths = name == "rm" ? operands(rest) : name == "chmod" ? Array(operands(rest).dropFirst()) : []
        // `rm -rf .` or `..`: there's no single folder to archive by name.
        guard !paths.isEmpty, !paths.contains(where: { [".", ".."].contains(($0.text as NSString).lastPathComponent) }) else { return nil }
        return render(paths)
    }

    /// Up to this much is archived; bigger takes too long to be worth waiting for.
    static let backupLimitKB = 512_000

    /// Archives the paths that exist into ~/.clavra-backups, by absolute path, so a restore puts
    /// them back where they were. Checks size and free space first; old archives (14 days) go.
    private static func archive(_ list: String) -> String {
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false).timeSeparator(.omitted))
            + "-" + UUID().uuidString.prefix(6).lowercased()
        return [
            #"H="${CLAVRA_BACKUPS:-$HOME/.clavra-backups}"; mkdir -p "$H" && chmod 700 "$H" && H=$(cd "$H" && pwd -P) || { echo failed=folder; exit 0; }"#,
            // Old archives go after 14 days; pieces a cut-off backup left behind after an hour.
            #"find "$H" \( -name 'clavra-*.tar.gz' -mtime +14 -o -name '*.part' -mmin +60 -o -name '.list-*' -mmin +60 \) -exec rm -f {} + 2>/dev/null"#,
            "need=$(du -sck -- \(list) 2>/dev/null | tail -n 1 | cut -f1)",
            #"[ "${need:-0}" -gt \#(backupLimitKB) ] && { echo toobig=1; exit 0; }"#,
            #"free=$(df -Pk "$H" | awk 'NR==2 {print $4}')"#,
            #"[ "${free:-0}" -gt $(( ${need:-0} + 10240 )) ] || { echo nospace=1; exit 0; }"#,
            #"L="$H/.list-$$"; : > "$L" || { echo failed=list; exit 0; }"#,
            #"D=$(pwd -P)"#,
            // Each path by where it really is: symlinked folders and `..` resolved, so a restore
            // lands in the same place. If the command would remove or lock the backups folder
            // itself, there's no backup.
            #"for p in \#(list); do if [ -e "$p" ] || [ -L "$p" ]; then a="$p"; [ "${p#/}" = "$p" ] && a="$D/$p"; while [ "${a%/}" != "$a" ] && [ "$a" != / ]; do a="${a%/}"; done; d=$(cd "$(dirname "$a")" 2>/dev/null && pwd -P) || continue; b=$(basename "$a"); [ "$d" = / ] && a="/$b" || a="$d/$b"; if [ "$a" = / ] || [ "$H" = "$a" ] || [ "${H#"$a"/}" != "$H" ]; then rm -f "$L"; echo inside=1; exit 0; fi; r="${a#/}"; [ "${r#-}" != "$r" ] && r="./$r"; echo "$r" >> "$L"; fi; done"#,
            #"[ -s "$L" ] || { rm -f "$L"; echo nothing=1; exit 0; }"#,
            #"F="$H/clavra-\#(stamp).tar.gz""#,
            // GNU tar's 1 means a file changed while it was read: the archive is still whole. Any
            // other tar's 1 is an error.
            #"G=; tar --version 2>/dev/null | grep -q GNU && G=1"#,
            #"e=$(tar -czf "$F.part" -C / -T "$L" 2>&1); s=$?; rm -f "$L""#,
            #"if { [ $s = 0 ] || { [ $s = 1 ] && [ -n "$G" ]; }; } && [ -s "$F.part" ] && mv "$F.part" "$F"; then echo "backup=$F"; echo "bytes=$(wc -c < "$F")"; else rm -f "$F.part"; echo "failed=tar $s: $(echo "$e" | head -n 1)"; fi"#,
        ].joined(separator: "\n")
    }

    /// Puts an archive's files back where they were. Prints `restored=<tar's status>`.
    static func restore(_ file: String) -> String {
        wrap(#"F=\#(quote(file)); [ -f "$F" ] || { echo missing=1; exit 0; }; K=; tar --keep-directory-symlink --version >/dev/null 2>&1 && K=--keep-directory-symlink; e=$(tar $K -xpzf "$F" -C / 2>&1); echo "restored=$?"; [ -n "$e" ] && echo "error=$e"; exit 0"#, seconds: 300)
    }

    static func forget(_ file: String) -> String {
        "rm -f -- " + quote(file)
    }

    /// The size `du` gave in a look-alike's output, in KB.
    static func kilobytes(in output: String) -> Int? {
        output.split(separator: "\n").first { $0.hasPrefix("kb=") }.flatMap { Int($0.dropFirst(3).trimmingCharacters(in: .whitespaces)) }
    }

    /// What making a backup said: the archive and its size, or why there isn't one.
    enum BackupResult: Equatable {
        case made(file: String, bytes: Int)
        case skipped(String)
    }

    static func readBackup(_ output: String) -> BackupResult {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        if let file = values["backup"], let bytes = values["bytes"].flatMap({ Int($0) }) { return .made(file: file, bytes: bytes) }
        if values["toobig"] != nil { return .skipped("It's over \(backupLimitKB / 1024) MB, too big to back up first.") }
        if values["nospace"] != nil { return .skipped("There isn't enough free space in your home folder on the server for a backup.") }
        if values["inside"] != nil { return .skipped("It would remove the backups folder itself, so there's nowhere safe to keep a backup.") }
        if values["nothing"] != nil { return .skipped("None of those paths are there, so there's nothing to back up.") }
        if let why = values["failed"] { return .skipped("The backup didn't work (\(why)).") }
        return .skipped("The server didn't say whether the backup worked.")
    }

    // MARK: Pieces of the look-alikes

    /// Only the options listed, each with its value where it takes one (`-p 6380`, `--file=x.yml`).
    private static func connectionOnly(_ words: [Word], valued: Set<String>, bare: Set<String>) -> Bool {
        var index = 0
        while index < words.count {
            let text = words[index].text
            if bare.contains(text) { index += 1; continue }
            if valued.contains(text) { index += 2; continue }
            if let eq = text.firstIndex(of: "="), valued.contains(String(text[..<eq])) { index += 1; continue }
            return false
        }
        return index == words.count
    }

    /// Names given that are really there, a few by name.
    private static func existing(_ list: String) -> String {
        "n=0; for p in \(list); do if [ -e \"$p\" ] || [ -L \"$p\" ]; then n=$((n+1)); [ $n -le 5 ] && echo \"item=$p\"; fi; done; echo \"paths=$n\""
    }

    /// Everything inside the paths, counted, and whether the count was cut short by the time limit.
    /// Each path goes to find on its own as `./name`, so a name like `-delete` (typed, or from a
    /// glob) is only ever a name, never an action.
    private static func count(paths list: String) -> String {
        let walk = "r=0; for p in \(list); do [ \"${p#/}\" = \"$p\" ] && p=\"./$p\"; $T find \"$p\" 2>/dev/null; s=$?; [ $s = 124 ] && r=124; done; echo __rc=$r"
        return tally(walk)
    }

    /// What a find with its actions taken out matches.
    private static func count(find list: String) -> String {
        tally("$T find \(list) 2>/dev/null; echo __rc=$?")
    }

    private static func tally(_ walk: String) -> String {
        "c=$({ \(walk); } | awk '/^__rc=/ {rc=substr($0, 6); next} {n++} END {print n+0, rc}'); echo \"entries=$c\""
    }

    private static func size(_ list: String) -> String {
        "k=$($T du -sck -- \(list) 2>/dev/null | tail -n 1 | cut -f1); echo \"kb=$k\""
    }

    private static func services(_ list: String) -> String {
        "for u in \(list); do a=$(systemctl is-active \"$u\" 2>/dev/null); d=$(systemctl list-dependencies --reverse --plain \"$u\" 2>/dev/null | tail -n +2 | wc -l); echo \"unit=$u $a $d\"; done"
    }

    private static func disk(_ list: String) -> String {
        "lsblk -no NAME,SIZE,FSTYPE,MOUNTPOINT \(list) 2>/dev/null | sed 's/^/item=/'"
    }

    /// Words that aren't options, honouring `--`.
    private static func operands(_ words: [Word]) -> [Word] {
        var result: [Word] = []
        var ended = false
        for word in words {
            if !ended, word.text == "--", !word.quoted { ended = true; continue }
            if !ended, word.text.hasPrefix("-"), !word.quoted { continue }
            result.append(word)
        }
        return result
    }

    private static func needsFolder(_ paths: [Word]) -> Bool {
        paths.contains { !$0.text.hasPrefix("/") && !$0.text.hasPrefix("~") }
    }

    /// `find` without what it would do to each file: -delete, and -exec/-execdir … ; or +.
    private static func findWithoutActions(_ words: [Word]) -> [Word] {
        var result: [Word] = []
        var skipping = false
        for word in words {
            if skipping {
                if word.text == ";" || word.text == "+" { skipping = false }
                continue
            }
            if word.text == "-exec" || word.text == "-execdir" || word.text == "-ok" { skipping = true; continue }
            if word.text == "-delete" { continue }
            result.append(word)
        }
        return result
    }

    private static func withoutSignal(_ words: [Word]) -> [Word] {
        var result: [Word] = []
        var skipNext = false
        for word in words {
            if skipNext { skipNext = false; continue }
            if word.text == "-s" || word.text == "--signal" { skipNext = true; continue }
            if word.text.hasPrefix("--signal=") { continue }
            let body = word.text.dropFirst()
            if word.text.hasPrefix("-"), !body.isEmpty, body.allSatisfy(\.isNumber) || body.allSatisfy(\.isUppercase) { continue }
            result.append(word)
        }
        return result
    }

    // MARK: Words

    /// The command split at `&&`, `||` and `;`, outside quotes.
    static func segments(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if let open = quote {
                current.append(c)
                if c == open { quote = nil } else if c == "\\", open == "\"", let next = chars.popFirst() { current.append(next) }
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                current.append(c)
            case "\\":
                current.append(c)
                if let next = chars.popFirst() { current.append(next) }
            case ";":
                parts.append(current)
                current = ""
            case "&" where chars.first == "&", "|" where chars.first == "|":
                chars.removeFirst()
                parts.append(current)
                current = ""
            default:
                current.append(c)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// One command's words, or nil when it uses anything a look-alike couldn't repeat as written:
    /// `$`, backticks, pipes, redirection, background jobs, subshells, or a backslash in a value.
    static func words(_ command: String) -> [Word]? {
        var words: [Word] = []
        var current = ""
        var quoted = false
        var started = false
        var chars = Array(command)[...]
        func finish() {
            if started { words.append(Word(text: current, quoted: quoted)) }
            current = ""; quoted = false; started = false
        }
        while let c = chars.popFirst() {
            switch c {
            case "'":
                guard let end = chars.firstIndex(of: "'") else { return nil }
                current += String(chars[..<end])
                chars = chars[(end + 1)...]
                quoted = true; started = true
            case "\"":
                var closed = false
                while let d = chars.popFirst() {
                    if d == "\"" { closed = true; break }
                    if d == "$" || d == "`" { return nil }
                    if d == "\\" {
                        guard let next = chars.popFirst(), next == "\"" || next == "\\" else { return nil }
                        current.append(next)
                    } else {
                        current.append(d)
                    }
                }
                guard closed else { return nil }
                quoted = true; started = true
            case "\\":
                guard let next = chars.popFirst() else { return nil }
                current.append(next)
                quoted = true; started = true
            case " ", "\t":
                finish()
            case "$", "`", ";", "|", "&", "<", ">", "(", ")", "\n", "\r":
                return nil
            default:
                current.append(c)
                started = true
            }
        }
        finish()
        return words.contains { $0.text.contains("\\") } ? nil : words
    }

    /// Drops `sudo` (and its options), `env`, `VAR=value`, `nohup`, `time`, `nice`. True when sudo was there.
    private static func stripPrefixes(_ words: inout [Word]) -> Bool {
        var sudo = false
        while let first = words.first {
            switch first.text {
            case "sudo":
                sudo = true
                words.removeFirst()
                while let option = words.first, option.text.hasPrefix("-") {
                    words.removeFirst()
                    if ["-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U"].contains(option.text), !words.isEmpty { words.removeFirst() }
                }
            case "env", "nohup", "time", "nice", "command", "exec":
                words.removeFirst()
            default:
                let name = first.text.prefix(while: { $0 != "=" })
                let isAssignment = !first.quoted && first.text.contains("=") && !name.isEmpty
                    && name.first.map({ $0.isLetter || $0 == "_" }) == true
                    && name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
                if isAssignment {
                    words.removeFirst()
                } else {
                    return sudo
                }
            }
        }
        return sudo
    }

    /// Characters a word can have and still be passed bare, so globs and `~` expand as typed.
    private static let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-*?[]~@%+=:,^")

    /// The words for `sh`: plain ones as typed (globs expand), anything else in single quotes.
    private static func render(_ words: [Word]) -> String? {
        words.map { word in
            !word.quoted && !word.text.isEmpty && word.text.allSatisfy(plain.contains) ? word.text : quote(word.text)
        }.joined(separator: " ")
    }

    private static func render(folder: String) -> String {
        if folder == "~" { return "~" }
        if folder.hasPrefix("~/") { return "~/" + quote(String(folder.dropFirst(2))) }
        return quote(folder)
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }

    // MARK: Reading the answer

    /// One line that says what happens, then a few details. Nil when the look-alike found nothing
    /// worth saying (it couldn't read anything).
    static func describe(_ output: String, kind: Kind, withoutSudo: Bool) -> [String]? {
        var values: [String: String] = [:]
        var items: [String] = []
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if ["item", "proc", "pkg", "unit"].contains(key) { items.append(value) } else { values[key] = value }
        }
        if values["nofolder"] != nil { return ["Couldn't open the folder the shell is in, so there's no preview."] }
        let note = withoutSudo ? " Checked without sudo, so it may be more." : ""
        let number = { (key: String) -> Int? in values[key].flatMap { Int($0.split(separator: " ").first ?? "") } }
        let cut = values["entries"].map { $0.split(separator: " ").dropFirst().first == "124" } ?? false
        let atLeast = cut ? "at least " : ""

        var lines: [String]
        switch kind {
        case .delete:
            guard let paths = number("paths") else { return nil }
            if paths == 0 { return ["Nothing by those names is there, so nothing would be deleted."] }
            let entries = number("entries") ?? paths
            let size = number("kb").map { ByteCountFormatter.string(fromByteCount: Int64($0) * 1024, countStyle: .file) }
            lines = ["Deletes \(atLeast)\(count(entries, "file or folder", "files and folders"))" + (size.map { cut ? "" : ", \($0)" } ?? "") + "." + note]
            lines += items.map { "· " + $0 }
        case .matches:
            guard let entries = number("entries") else { return nil }
            lines = [entries == 0 ? "Nothing matches, so nothing would be deleted." : "Matches \(atLeast)\(count(entries, "file", "files"))." + note]
        case .permissions:
            guard let entries = number("entries") else { return nil }
            lines = [entries == 0 ? "Nothing by those names is there." : "Changes \(atLeast)\(count(entries, "file or folder", "files and folders"))." + note]
        case .services:
            guard !items.isEmpty else { return nil }
            lines = items.map { item in
                let parts = item.split(separator: " ").map(String.init)
                let unit = parts.first ?? item, state = parts.count > 1 ? parts[1] : "", dependents = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
                let running = state == "active" ? "is running" : state.isEmpty ? "isn't known here" : "is \(state)"
                return "\(unit) \(running)" + (dependents > 0 ? "; \(count(dependents, "unit depends", "units depend")) on it." : ".")
            }
        case .processes:
            if items.isEmpty { return ["No running process matches."] }
            lines = ["Ends \(count(items.count, "process", "processes"))."] + items.prefix(5).map { "· " + $0 }
        case .containers, .compose:
            if items.isEmpty { return [kind == .compose ? "This project has no containers here." : "No container by those names."] }
            lines = ["\(kind == .compose ? "Takes down" : "Affects") \(count(items.count, "container", "containers"))."] + items.prefix(6).map { "· " + $0 }
        case .dockerSpace:
            guard !items.isEmpty else { return nil }
            lines = ["Reclaimable now:"] + items.map { "· " + $0 }
        case .kube:
            if items.isEmpty { return ["Nothing in the cluster matches."] }
            lines = ["Deletes \(count(items.count, "object", "objects"))."] + items.prefix(6).map { "· " + $0 }
        case .drain:
            guard let pods = number("pods") else { return nil }
            lines = ["Evicts \(count(pods, "pod", "pods")) from that node."]
        case .packages:
            if items.isEmpty { return ["Nothing would be uninstalled."] }
            lines = ["Uninstalls \(count(items.count, "package", "packages")): " + items.prefix(8).joined(separator: ", ") + (items.count > 8 ? "…" : "")]
        case .cron:
            guard let jobs = number("jobs") else { return nil }
            lines = [jobs == 0 ? "There are no cron jobs to lose." : "Removes \(count(jobs, "cron job", "cron jobs")), with no copy kept."]
        case .reboot:
            guard let who = number("who") else { return nil }
            lines = ["\(count(who, "session is", "sessions are")) signed in right now, yours included."]
            if let up = values["up"], !up.isEmpty { lines.append("· " + up) }
        case .gitReset:
            guard let changed = number("changed") else { return nil }
            lines = [changed == 0 ? "There are no uncommitted changes to lose." : "Throws away uncommitted changes to \(count(changed, "file", "files"))."]
        case .gitClean:
            if items.isEmpty { return ["There's nothing untracked to delete."] }
            lines = ["Deletes \(count(items.count, "untracked file", "untracked files"))."] + items.prefix(5).map { "· " + $0 }
        case .gitPush:
            guard let behind = number("behind") else { return nil }
            lines = [behind == 0 ? "The remote has nothing your branch doesn't, as of the last fetch."
                : "Overwrites \(count(behind, "commit", "commits")) on the remote that your branch doesn't have, as of the last fetch."]
        case .disk:
            guard !items.isEmpty else { return nil }
            lines = items.map { "· " + $0 }
            lines.insert(items.contains { $0.split(separator: " ").count >= 4 } ? "Something on it is mounted:" : "On that disk:", at: 0)
        case .redis:
            guard let keys = number("keys") else { return nil }
            lines = ["Removes \(count(keys, "key", "keys"))."]
        case .firewall:
            guard let rules = number("rules") else { return nil }
            lines = ["Removes \(count(rules, "rule", "rules"))."]
        }
        return lines
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n.formatted()) \(n == 1 ? one : many)"
    }
}
