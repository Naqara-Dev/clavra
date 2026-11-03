import Foundation

/// Checks for the parts of Clavra that decide things on their own: which commands are risky, what a
/// prompt line holds, which names are safe on disk, what history may keep, how tunnels and panes
/// are read, and which host keys are trusted. Run with scripts/test.sh.
@main @MainActor
enum CoreTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0

    static func check(_ condition: Bool, _ name: String, file: String = #fileID, line: Int = #line) {
        if condition { passes += 1 } else { failures += 1; print("✗ \(name)  (\(file):\(line))") }
    }

    static func main() {
        commandGuard()
        typedLine()
        promptLine()
        safeNames()
        secrets()
        serverStats()
        forwards()
        panes()
        servers()
        sshConfig()
        places()
        knownHosts()
        blastRadius()
        sudoPrompts()
        newFeatures()
        downAlerts()
        redaction()
        print(failures == 0 ? "✓ \(passes) checks passed" : "\(failures) of \(passes + failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func commandGuard() {
        let risky = ["rm -rf /var/www", "sudo rm -fr build", "rm -r old", "DROP TABLE users;", "drop database app",
                     "TRUNCATE orders", "DELETE FROM users;", "update users set admin=1", "sudo reboot", "reboot",
                     "apt upgrade && reboot", "shutdown -h now", "docker rm web", "docker system prune -af",
                     "docker compose down", "docker compose -f prod.yml -p shop down", "git push --force origin main", "git push -f", "git reset --hard HEAD~3",
                     "chmod -R 777 /", "kubectl delete pod x", "terraform destroy", "systemctl restart nginx",
                     "kill -9 1234", "mkfs.ext4 /dev/sdb", "dd if=x of=/dev/sda", "crontab -r", "redis-cli FLUSHALL",
                     "apt remove nginx", "ufw disable", "iptables -F",
                     "psql -c 'DELETE FROM users;'", "mysql -e \"delete from orders\"", "rm --recursive old",
                     "rm --force x", "rm -i --recursive x", "sudo rm -v -r /srv/a", "find /var/www -name '*.log' -delete",
                     "find . -type f -exec rm {} \\;", "chown --recursive www /srv", "chmod -v -R 755 /srv",
                     "psql -c \"update users set admin=true\""]
        let safe = ["ls -la", "rm file.txt", "git push origin main", "DELETE FROM users WHERE id=3;",
                    "update users set a=1 where id=2", "docker ps", "systemctl status nginx",
                    "cat /var/log/syslog | grep reboot-required", "grep reboot /var/log/syslog", "less shutdown.log",
                    "echo hello", "kill 1234", "chmod 600 key", "# rm -rf /", "git status", "psql -c 'select 1'",
                    "rm -i file.txt", "rm file-rf.txt", "find . -name '*.log'", "psql -c 'DELETE FROM users WHERE id=1;'",
                    "rm -v old.log", "ls -R /srv"]
        for command in risky { check(CommandGuard.check(command) != nil, "risky: \(command)") }
        for command in safe { check(CommandGuard.check(command) == nil, "safe: \(command)") }
    }

    static func typedLine() {
        var line = TypedLine()
        line.feed(ArraySlice(Array("rm -rf xx".utf8)))
        line.feed([0x7F])
        line.feed([0x7F])
        check(line.text == "rm -rf ", "backspace")
        line.feed([0x17])
        check(line.text == "rm ", "⌃W drops a word")
        line.feed(ArraySlice(Array("\u{1b}[200~-rf /\u{1b}[201~".utf8)))
        check(line.text == "rm -rf /", "paste markers are dropped")
        line.feed([0x03])
        check(line.text.isEmpty, "⌃C clears")
    }

    static func promptLine() {
        let cases: [(String, String?)] = [
            ("➜  amplaze git:(master) ✗ ssh amin", "ssh amin"),
            ("➜  ~ ls -la", "ls -la"),
            ("➜  app git:(main) git st", "git st"),
            ("➜  app ", ""),
            ("deploy@web:~$ docker ps", "docker ps"),
            ("root@x:/srv# rm", "rm"),
            ("Password: ", nil),
        ]
        for (line, expected) in cases {
            check(PromptLine.command(in: line, strict: true) == expected, "prompt: \(line)")
        }
        check(PromptLine.command(in: "deploy@halt-01:~$ ls") == "ls", "host names aren't commands")
    }

    static func safeNames() {
        for name in ["notes.txt", ".env", "a b", "ünïcode"] { check(SafeNames.isSafe(name), "safe name \(name)") }
        for name in ["", ".", "..", "../x", "a/b", "x\0y", "/etc"] { check(!SafeNames.isSafe(name), "unsafe name \(name)") }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "clavra-tests-\(UUID().uuidString)")
        check(SafeNames.contained(folder.appending(path: "a.txt"), in: folder) != nil, "inside stays inside")
        check(SafeNames.contained(folder.appending(path: "../a.txt"), in: folder) == nil, "../ is refused")
    }

    static func secrets() {
        let secret = ["export AWS_SECRET_ACCESS_KEY=abc", "curl -u admin:hunter2 https://x", "mysql -uroot -psecret db",
                      "git clone https://me:tok@github.com/x/y", "export GITHUB_TOKEN=ghp_abc", "PGPASSWORD=x psql",
                      "docker login --password abc", "DB_PASSWORD: x"]
        let fine = ["git status", "docker ps -a", "ssh deploy@10.0.0.2", "curl https://example.com/api", "ls -la",
                    "kubectl get pods -n auth", "export PATH=$PATH:/opt/bin", "cd auth-service", "echo token"]
        for line in secret { check(CommandHistory.looksSecret(line), "secret: \(line)") }
        for line in fine { check(!CommandHistory.looksSecret(line), "not secret: \(line)") }
    }

    static func serverStats() {
        let text = "load 0.42\ncpus 4\nmem 61\ndisk 93\nup 1036800\nport 127.0.0.1:5432\nport [::]:80\nport 0.0.0.0:22\n"
            + "port 10.0.0.5:9000\nport *.8080\nport 127.0.0.53%lo:53\nport :::3000\nport 127.0.0.1:50123\n"
        let stats = ServerStats(text, sshPort: 22)
        check(stats.load == 0.42 && stats.cpus == 4 && stats.memory == 61 && stats.disk == 93, "vitals")
        check(stats.uptimeText == "up 12d", "uptime")
        check(stats.ports == [80, 3000, 5432, 8080], "ports: loopback and any, not SSH, DNS, public or temporary")
        check(stats.isDiskHigh && !stats.isMemoryHigh && !stats.isLoadHigh, "hot readings")
    }

    static func forwards() {
        let local = Server.Forward.parse(kind: .local, local: "", remote: "5432")
        check(local?.localPort == 5432 && local?.port == 5432 && local?.host == "localhost", "local by port")
        let behind = Server.Forward.parse(kind: .local, local: "15432", remote: "db.internal:5432")
        check(behind?.localPort == 15432 && behind?.host == "db.internal", "local to a host behind")
        let remote = Server.Forward.parse(kind: .remote, local: "3000", remote: "9000")
        check(remote?.port == 9000 && remote?.localPort == 3000, "remote")
        check(Server.Forward.parse(kind: .socks, local: "1080", remote: "")?.localPort == 1080, "socks")
        // Nothing is guessed: a Mac port that isn't a port stops the tunnel instead of borrowing the server's.
        check(Server.Forward.parse(kind: .local, local: "abc", remote: "5432") == nil, "a non-number Mac port is refused")
        check(Server.Forward.parse(kind: .local, local: "70000", remote: "5432") == nil, "a Mac port above 65535 is refused")
        check(Server.Forward.parse(kind: .local, local: "0", remote: "5432") == nil, "port 0 is refused")
        check(Server.Forward.parse(kind: .remote, local: "3000", remote: "70000") == nil, "a server port above 65535 is refused")
        check(Server.Forward.parse(kind: .local, local: "", remote: "db:99999") == nil, "host:port out of range is refused")
        check(Server.Forward.parse(kind: .socks, local: "-1", remote: "") == nil, "a negative port is refused")
        check(Server.Forward.problem(kind: .local, local: "abc", remote: "5432")?.hasPrefix("Mac side") == true, "the problem names the Mac side")
        check(Server.Forward.problem(kind: .remote, local: "3000", remote: "x")?.hasPrefix("Server side") == true, "the problem names the server side")
        check(Server.Forward.problem(kind: .local, local: "", remote: "") == nil, "an empty form has no problem yet")
        check(Server.Forward.parse(kind: .local, local: "", remote: "99999") == nil, "port out of range")
        check(Server.Forward.parse(kind: .remote, local: "", remote: "9000") == nil, "remote needs a Mac port")
    }

    static func panes() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var tree = PaneNode.leaf(a)
        tree = tree.splitting(a, with: b, along: .sideBySide)
        tree = tree.splitting(b, with: c, along: .sideBySide)
        check(tree == .split(.sideBySide, [.leaf(a), .leaf(b), .leaf(c)]), "same-axis splits stay flat")
        tree = tree.splitting(c, with: d, along: .stacked)
        check(tree.ids == [a, b, c, d], "order is left to right, top to bottom")
        check(tree.removing(d) == .split(.sideBySide, [.leaf(a), .leaf(b), .leaf(c)]), "a split of one collapses")
        check(PaneNode.leaf(a).removing(a) == nil, "the last pane leaves nothing")
        // Dragging a pane onto another one's edge, as in iTerm.
        let row = PaneNode.split(.sideBySide, [.leaf(a), .leaf(b), .leaf(c)])
        check(row.moving(c, to: a, edge: .left) == .split(.sideBySide, [.leaf(c), .leaf(a), .leaf(b)]), "moved to the left of the first")
        check(row.moving(a, to: b, edge: .bottom) == .split(.sideBySide, [.split(.stacked, [.leaf(b), .leaf(a)]), .leaf(c)]), "moved under another")
        check(row.moving(a, to: b, edge: .left) == nil, "already there: no change")
        check(row.moving(a, to: a, edge: .right) == nil, "onto itself: no change")
        check(row.moving(d, to: a, edge: .right) == nil, "a pane from elsewhere isn't moved")
    }

    static func servers() {
        let quick = Server(quick: "ssh deploy@10.0.0.2:2200")
        check(quick?.user == "deploy" && quick?.address == "10.0.0.2" && quick?.port == 2200, "quick connect")
        check(Server(quick: "two words") == nil, "spaces aren't a host")
        check(Server(name: "api prod", address: "x", user: "u").monogram == "ap", "monogram from two words")
        check(Server(name: "", address: "web1.example.com", user: "u").monogram == "we", "monogram from an address")
        // Files from older versions load, with defaults for what they didn't have.
        let old = #"[{"id":"11111111-1111-1111-1111-111111111111","name":"a","address":"h","port":22,"user":"u","auth":"key","place":"production"}]"#
        let decoded = try? JSONDecoder().decode([Server].self, from: Data(old.utf8))
        check(decoded?.first?.forwards == [] && decoded?.first?.guardsCommands == true, "old hosts.json still loads")
    }

    static func sshConfig() {
        let text = """
        Host *
          ServerAliveInterval 30
        Host web
          HostName 10.0.0.5
          User deploy
          Port 2200
          IdentityFile ~/.ssh/web
        Host db
          HostName db.internal
        """
        let hosts = HostStore.parseSSHConfig(text)
        check(hosts.count == 2, "wildcards are skipped")
        check(hosts.first?.address == "10.0.0.5" && hosts.first?.user == "deploy" && hosts.first?.port == 2200
              && hosts.first?.keyPath == "~/.ssh/web", "fields")

        // ssh's rules: the first value wins, Host * fills in what's missing, every alias is a host.
        let resolved = HostStore.sshConfigHosts("""
        Host web api
          HostName %h.example.com
        Host bastion
          HostName 10.0.0.1
          User jump
        Host api
          Port 2222
          ProxyJump bastion
        Host *
          User deploy
          Port 2200
          IdentityFile ~/.ssh/team
        """)
        let byName = Dictionary(uniqueKeysWithValues: resolved.map { ($0.server.name, $0) })
        check(resolved.map(\.server.name) == ["web", "api", "bastion"], "every alias of a Host line is a host")
        check(byName["web"]?.server.address == "web.example.com" && byName["web"]?.server.user == "deploy"
              && byName["web"]?.server.port == 2200, "Host * defaults and %h apply")
        check(byName["api"]?.server.port == 2222 && byName["api"]?.jump == "bastion", "an earlier value beats Host *")
        check(byName["bastion"]?.server.user == "jump" && byName["bastion"]?.server.keyPath == "~/.ssh/team", "IdentityFile from Host *")

        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "clavra-config-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder.appending(path: "config.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try? "Host db\n  HostName 10.0.0.7\n".write(to: folder.appending(path: "config.d/work"), atomically: true, encoding: .utf8)
        let included = HostStore.sshConfigHosts("Include config.d/*\nHost web\n  HostName 10.0.0.5\n", base: folder)
        check(included.map(\.server.name) == ["db", "web"] && included.first?.server.address == "10.0.0.7", "Include is followed")

        // Blocks that only pick a key for git aren't servers to open.
        let git = HostStore.parseSSHConfig("""
        Host github-work
          HostName github.com
          IdentityFile ~/.ssh/work
        Host gitlab.example.id
          User git
        Host box
          HostName 10.0.0.9
        """)
        check(git.map(\.isGitRemote) == [true, true, false], "git remotes are recognised")

        // Automatic finds the key a block names, by alias, by pattern, or by the HostName it points to.
        let keys = """
        Host github-work
          HostName github.com
          IdentityFile ~/.ssh/work
        Host *.prod.example.com !bastion.prod.example.com
          IdentityFile ~/.ssh/prod
        Host web
          IdentityFile ~/.ssh/web
          IdentityFile ~/.ssh/work
        """
        func files(_ address: String, name: String = "") -> [String] {
            HostStore.identityFiles(for: Server(name: name, address: address, user: "u"), in: keys)
        }
        check(files("github.com") == ["~/.ssh/work"], "a HostName finds its block's key")
        check(files("api.prod.example.com") == ["~/.ssh/prod"], "a wildcard pattern matches")
        check(files("bastion.prod.example.com").isEmpty, "a negated pattern doesn't")
        check(files("10.0.0.5", name: "web") == ["~/.ssh/web", "~/.ssh/work"], "the saved name matches an alias, in order")
        check(files("example.org").isEmpty, "nothing for an unknown host")
        let two = """
        Host github.com
          IdentityFile ~/.ssh/id_ed25519
        Host github-work
          HostName github.com
          IdentityFile ~/.ssh/work
        """
        check(HostStore.identityFiles(for: Server(name: "github-work", address: "github.com", user: "git"), in: two)
              == ["~/.ssh/work", "~/.ssh/id_ed25519"], "the block named like the host comes first")
        check(HostStore.glob("db-?", "db-1") && !HostStore.glob("db-?", "db-12") && HostStore.glob("*", "x"), "glob")
    }

    static func places() {
        // Older files store the place as a plain string; they still read, and labels round-trip.
        let old = #"{"address":"a","place":"production"}"#
        let server = try? JSONDecoder().decode(Server.self, from: Data(old.utf8))
        check(server?.place == .production, "old place strings read")
        var custom = Server(name: "", address: "b", user: "u")
        custom.place = Server.Place(rawValue: "label:1234")
        let again = (try? JSONEncoder().encode(custom)).flatMap { try? JSONDecoder().decode(Server.self, from: $0) }
        check(again?.place.rawValue == "label:1234" && again?.place.isBuiltIn == false, "custom labels round-trip")
        check(custom.guardsCommands == false && server?.guardsCommands == true, "only production guards by default")
    }

    static func knownHosts() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "clavra-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ours = folder.appending(path: "ours"), system = folder.appending(path: "system")
        let good = "ssh-ed25519 AAAAgood", bad = "ssh-ed25519 AAAAbad", rsa = "ssh-rsa AAAArsa"
        try? "".write(to: ours, atomically: true, encoding: .utf8)
        try? "web.example.com \(good)\n[db.example.com]:2200 \(rsa)\n".write(to: system, atomically: true, encoding: .utf8)
        func verdict(_ host: String, _ port: Int, _ key: String) -> KnownHosts.Verdict {
            KnownHosts.check(host: host, port: port, key: key, ours: ours, system: system)
        }
        check(verdict("web.example.com", 22, good) == .trusted, "~/.ssh/known_hosts is trusted")
        check(verdict("web.example.com", 22, bad) == .changed, "a different key than ~/.ssh/known_hosts is a change")
        check(verdict("db.example.com", 2200, good) == .unknown, "a new key type is new, not a change")
        check(verdict("new.example.com", 22, good) == .unknown, "an unknown host is new")
        try? "[app]:2222 \(good)\n".write(to: ours, atomically: true, encoding: .utf8)
        check(verdict("app", 2222, bad) == .changed, "Clavra's own record changed")
        try? "web.example.com \(good)\n@revoked * \(bad)\n".write(to: system, atomically: true, encoding: .utf8)
        check(verdict("other.example.com", 22, bad) == .revoked, "@revoked keys are refused, not offered as new")
        check(verdict("web.example.com", 22, good) == .trusted, "other keys are unaffected")
        check(KnownHosts.fingerprint("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl").hasPrefix("SHA256:"), "fingerprint")
    }

    static func blastRadius() {
        func probe(_ line: String, folder: String? = "/tmp") -> BlastRadius.Probe? {
            if case .probe(let probe) = BlastRadius.plan(for: line, folder: folder) { return probe }
            return nil
        }
        // Words: quotes kept as values, anything the look-alike can't repeat refused.
        check(BlastRadius.words("rm -rf 'my dir' \"x y\" a\\ b")?.map(\.text) == ["rm", "-rf", "my dir", "x y", "a b"], "words")
        for unsafe in ["rm -rf $DIR", "rm -rf `pwd`/x", "rm -rf $(ls)", "rm -rf x > y", "rm -rf a | b", "rm -rf \"$HOME\"", "rm -rf x &"] {
            check(BlastRadius.words(unsafe) == nil, "no look-alike for: \(unsafe)")
        }
        check(BlastRadius.segments("cd /srv && rm -rf build; ls || true") == ["cd /srv", "rm -rf build", "ls", "true"], "segments")
        check(BlastRadius.segments("echo 'a && b'") == ["echo 'a && b'"], "quoted && isn't a split")
        // Which commands get a look-alike, and of what kind.
        check(probe("sudo rm -rf /var/www/old")?.kind == .delete && probe("sudo rm -rf /var/www/old")?.withoutSudo == true, "rm, under sudo")
        check(probe("find . -name '*.log' -delete")?.kind == .matches, "find -delete")
        check(probe("find . -type f -exec rm {} \\;")?.command.contains("-exec") == false, "find -exec is dropped")
        check(probe("systemctl restart nginx")?.kind == .services, "systemctl")
        check(probe("docker compose -f prod.yml down")?.command.contains("ps -a") == true, "compose down lists its containers")
        check(probe("kubectl delete pod -l app=web --grace-period=0")?.command.contains("get pod -l app=web -o name") == true, "kubectl delete is a get")
        check(probe("apt remove nginx")?.command.contains("apt-get -s remove nginx") == true, "apt remove is simulated")
        check(probe("git clean -fdx")?.command.contains("git clean -n -dx") == true, "git clean -n")
        check(probe("sudo reboot")?.kind == .reboot, "reboot")
        check(probe("ls -la") == nil && probe("rm -rf $X") == nil, "nothing to preview, or nothing safe")
        if case .needsFolder = BlastRadius.plan(for: "rm -rf build", folder: nil) {} else { check(false, "relative paths need the folder") }
        check(probe("rm -rf /srv/build", folder: nil) != nil, "absolute paths don't need the folder")
        check(probe("cd /srv/app && rm -rf build", folder: nil)?.command.contains(#"cd '"'"'/srv/app'"'"'"#) == true, "a cd before it sets the folder")
        // Prompts that say where the shell is.
        check(BlastRadius.folder(fromPrompt: "deploy@web-1:~/app$ rm -rf x") == "~/app", "folder from a bash prompt")
        check(BlastRadius.folder(fromPrompt: "root@db:/var/lib# ls") == "/var/lib", "folder from a root prompt")
        check(BlastRadius.folder(fromPrompt: "➜  app git:(main) rm -rf x") == nil, "no folder in an oh-my-zsh prompt")
        let me = BlastRadius.identity(fromPrompt: "deploy@web-1:~/app$ rm -rf x")
        check(me?.user == "deploy" && me?.host == "web-1" && me?.root == false, "who and where from a prompt")
        check(BlastRadius.identity(fromPrompt: "root@db:/var/lib# ls")?.root == true, "a root prompt")
        check(BlastRadius.identity(fromPrompt: "(venv) deploy@web-1:~$ ls")?.user == "deploy", "a prompt after a virtualenv")
        check(BlastRadius.identity(fromPrompt: "➜  app ls") == nil, "no identity in an oh-my-zsh prompt")

        // The look-alike really runs, counts what's there, and touches nothing.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "clavra-blast-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder.appending(path: "build/sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["build/a.o", "build/b.o", "build/sub/c.o", "it's.log"] {
            try? Data(count: 2048).write(to: folder.appending(path: name))
        }
        func run(_ line: String) -> [String]? {
            guard let probe = probe(line, folder: folder.path) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", probe.command]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return BlastRadius.describe(output, kind: probe.kind, withoutSudo: probe.withoutSudo)
        }
        let deleted = run("rm -rf build")
        check(deleted?.first?.hasPrefix("Deletes 5 files and folders") == true, "counts what rm -rf would delete: \(deleted ?? [])")
        check(FileManager.default.fileExists(atPath: folder.appending(path: "build/sub/c.o").path), "…and deletes nothing")
        check(run("rm -rf missing-*")?.first?.hasPrefix("Nothing by those names") == true, "a glob that matches nothing")
        check(run("rm -f \"it's.log\"")?.first?.hasPrefix("Deletes 1 file or folder") == true, "quotes in names")
        check(run("find . -name '*.o' -delete")?.first == "Matches 3 files.", "find -delete counts matches")
        check(FileManager.default.fileExists(atPath: folder.appending(path: "build/a.o").path), "…and deletes nothing")
        check(BlastRadius.describe("unit=nginx.service active 2\n", kind: .services, withoutSudo: false) == ["nginx.service is running; 2 units depend on it."], "services")

        // Names that look like find's actions stay names: nothing is deleted before a yes.
        try? Data(count: 10).write(to: folder.appending(path: "-delete"))
        _ = run("rm -rf -- -delete")
        _ = run("rm -rf '-delete'")
        _ = run("rm -rf *")
        _ = run("chmod -R 755 -- -delete")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        check(Set(left) == ["build", "it's.log", "-delete"], "no probe deletes anything: \(left)")
        check(FileManager.default.fileExists(atPath: folder.appending(path: "build/sub/c.o").path), "…inside folders either")
        check(run("rm -rf -- -delete")?.first?.hasPrefix("Deletes 1 file or folder") == true, "a file called -delete is counted as a file")
        // Backing up first, then putting it back.
        let backups = folder.appending(path: "backups")
        func shell(_ command: String) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ProcessInfo.processInfo.environment.merging(["CLAVRA_BACKUPS": backups.path]) { $1 }
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        check(probe("sudo rm -rf build", folder: folder.path)?.backup == nil, "no backup under sudo: it couldn't read everything")
        check(probe("rm -rf $X", folder: folder.path)?.backup == nil && probe("kill -9 1")?.backup == nil, "backups only for rm and chmod -R")
        if let plan = probe("rm -rf build \"it's.log\" missing", folder: folder.path)?.backup,
           case .made(let file, let bytes) = BlastRadius.readBackup(shell(plan)) {
            check(bytes > 0 && file.contains("/backups/clavra-") && !file.contains("/../") && FileManager.default.fileExists(atPath: file), "the backup is made where it should be: \(file)")
            try? FileManager.default.removeItem(at: folder.appending(path: "build"))
            try? FileManager.default.removeItem(at: folder.appending(path: "it's.log"))
            let restored = shell(BlastRadius.restore(file))
            check(restored.contains("restored=0"), "restore says it worked: \(restored)")
            check(FileManager.default.fileExists(atPath: folder.appending(path: "build/sub/c.o").path)
                  && FileManager.default.fileExists(atPath: folder.appending(path: "it's.log").path), "…and the files are back")
            check(BlastRadius.readBackup(shell(BlastRadius.restore(file + ".gone"))) == .skipped("The server didn't say whether the backup worked.")
                  && shell(BlastRadius.restore(file + ".gone")).contains("missing=1"), "a backup that's gone says so")
        } else {
            check(false, "a backup is made for rm -rf")
        }
        check(BlastRadius.readBackup("nospace=1\n") != BlastRadius.readBackup("toobig=1\n"), "why a backup was skipped")
        // What the second review found.
        check(probe("rm -rf src/{a,b} build") == nil, "brace expansion: no look-alike")
        check(probe("rm -rf src/**/cache") == nil, "** : no look-alike")
        check(probe("rm -rf a && rm -rf b")?.backup == nil && probe("rm -rf a && rm -rf b")?.more == true, "two risky parts: shown as such, no backup")
        check(probe("chown -R www /srv")?.backup == nil, "no backup for chown: the owner couldn't be put back")
        check(probe("rm -rf ..")?.backup == nil && probe("rm -rf .")?.backup == nil, "no backup of . or ..")
        if let plan = probe("rm -rf ../../\(folder.lastPathComponent)/build", folder: folder.appending(path: "build").path)?.backup,
           case .made(let file, _) = BlastRadius.readBackup(shell(plan)) {
            let listing = shell("tar -tzf '\(file)' | head -n 1")
            check(listing.hasSuffix("/\(folder.lastPathComponent)/build/\n") && !listing.contains(".."), "`..` resolved to where it really is: \(listing)")
        } else {
            let plan = probe("rm -rf ../../\(folder.lastPathComponent)/build", folder: folder.appending(path: "build").path)?.backup
            check(false, "a backup through ..: \(plan == nil ? "no plan" : shell(plan!))")
        }
        if let plan = probe("rm -rf \(backups.deletingLastPathComponent().path)", folder: "/")?.backup {
            check(BlastRadius.readBackup(shell(plan)) == .skipped("It would remove the backups folder itself, so there's nowhere safe to keep a backup."),
                  "no backup when the command would remove the backups folder")
        } else {
            check(false, "a backup plan for the parent of the backups folder")
        }

        // No look-alike when it would do more than read.
        check(probe("find . -name '*.tmp' -fprint gone.txt -delete") == nil, "find that writes files")
        check(probe("find * -delete") == nil, "find with a bare glob")
        check(probe("docker compose run --rm app ./manage.sh stop") == nil, "compose run isn't a global option")
        check(probe("docker compose exec web rm -rf /app/tmp") == nil, "compose exec isn't either")
        check(probe("docker compose -f prod.yml -p shop down") != nil, "real global options still work")
        check(probe("redis-cli del sessions flushall") == nil, "redis commands before FLUSHALL")
        check(probe("redis-cli -h db -p 6380 flushall") != nil, "connection options before FLUSHALL")
        check(probe("rm -rf /srv/x")?.command.contains("timeout 8") == true, "the whole look-alike has a time limit")
        if case .needsFolder = BlastRadius.plan(for: #"cd "$DIR" && rm -rf build"#, folder: "/tmp") {} else { check(false, "an unreadable cd forgets the folder") }
        if case .needsFolder = BlastRadius.plan(for: "pushd /x && rm -rf build", folder: "/tmp") {} else { check(false, "pushd forgets the folder") }
    }

    static func sudoPrompts() {
        check(SudoFill.isPrompt("[sudo] password for deploy: ", after: nil), "Debian and Ubuntu's sudo prompt")
        check(SudoFill.isPrompt("[sudo: authenticate] Password:", after: nil), "newer sudo's prompt")
        check(SudoFill.isPrompt("Password:", after: "sudo systemctl restart nginx"), "a bare Password: after sudo")
        check(!SudoFill.isPrompt("Password:", after: "su -"), "su's Password: is left alone")
        check(!SudoFill.isPrompt("Password:", after: "mysql -u root -p"), "a program's own prompt is left alone")
        check(!SudoFill.isPrompt("deploy@web:~$ sudo ls", after: nil), "a command line isn't a prompt")
        check(!SudoFill.isPrompt("[sudo] password for deploy: hunter2", after: nil), "only while it's still waiting")
    }

    static func newFeatures() {
        // Runbooks: headings, steps, code fences and $ lines.
        let blocks = RunbookBlock.parse("# Deploy\n\n- [ ] Tell the team\n- [x] Pull\n```\ngit pull\nmake\n```\n$ sudo systemctl restart app\nSome words\nmore words")
        check(blocks.count == 6, "runbook blocks: \(blocks.count)")
        check(blocks.first == .heading("Deploy", level: 1, line: 0), "heading")
        check(blocks.contains(.step("Pull", done: true, line: 3)), "a ticked step")
        check(blocks.contains(.code("git pull\nmake", line: 4)), "a fenced command")
        check(blocks.contains(.code("sudo systemctl restart app", line: 8)), "a $ line")
        check(blocks.last == .text("Some words more words", line: 9), "a paragraph")

        // Comparing: by name for lists, line by line for files.
        let packages = ServerDiff.rows("curl 8.5\nnginx 1.24\nvim 9.1\n", "curl 8.5\nnginx 1.26\nzsh 5.9\n", subject: .packages)
        check(packages.map(\.kind) == [.same, .changed, .onlyLeft, .onlyRight], "packages compared by name")
        let file = ServerDiff.rows("a\nb\nc\n", "a\nB\nc\nd\n", subject: .file)
        check(file.map(\.kind) == [.same, .changed, .same, .onlyRight], "files lined up like diff")
        check(ServerDiff.command(for: .command, input: "rm -rf /tmp/x") == nil, "compare won't run a risky command")
        check(ServerDiff.command(for: .file, input: "/etc/it's.conf")?.contains("it") == true, "file paths are quoted")

        // Log levels.
        check(LogLevel.of("2024/01/01 [error] 123#0: upstream timed out") == .error, "nginx error")
        check(LogLevel.of("level=warn msg=slow") == .warning, "logfmt warning")
        check(LogLevel.of("1.2.3.4 - - \"GET / HTTP/1.1\" 502 0") == .error, "a 5xx in an access log")
        check(LogLevel.of("GET /health 200") == .info, "a plain line")
        check(LogLevel.clean("\u{1b}[31mred\u{1b}[0m\r") == "red", "colour codes go")

        // Recordings: whole UTF-8 characters only, and a file that reads back.
        let snowman = Array("a☃".utf8)
        check(SessionRecorder.completeLength(Array(snowman.prefix(3))) == 1, "a cut character waits for the rest")
        check(SessionRecorder.completeLength(snowman) == 4, "a whole character goes")
        let cast = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "clavra-\(UUID().uuidString).cast")
        defer { try? FileManager.default.removeItem(at: cast) }
        let text = #"{"version":2,"width":80,"height":24,"timestamp":1700000000,"title":"web · deploy@web","clavra":{"host":"web"}}"#
            + "\n" + #"[0.5,"o","$ "]"# + "\n" + #"[1.25,"m","ls -la"]"# + "\n" + #"[1.3,"r","100x30"]"# + "\n" + #"[2.75,"o","total 0\r\n"]"# + "\n"
        try? text.write(to: cast, atomically: true, encoding: .utf8)
        let info = Recordings.info(at: cast)
        check(info?.host == "web" && info?.duration == 2.75 && info?.commands == [Recordings.Marker(time: 1.25, text: "ls -la")], "recording info")
        let tape = Recordings.tape(at: cast)
        check(tape?.cols == 80 && tape?.events.count == 3 && tape?.duration == 2.75, "recording tape")
    }

    static func downAlerts() {
        var tracker = DownTracker<String>()
        let t0 = Date(timeIntervalSince1970: 0)
        check(tracker.record("never-up", up: false, at: t0) == nil && tracker.record("never-up", up: false, at: t0) == nil,
              "a host never seen up is never called down")
        check(tracker.record("web", up: true, at: t0) == nil, "up is quiet")
        check(tracker.record("web", up: false, at: t0) == nil, "one miss is a blip")
        check(tracker.record("web", up: true, at: t0) == nil, "…and answering again after a blip is quiet")
        check(tracker.record("web", up: false, at: t0) == nil, "a new first miss")
        check(tracker.record("web", up: false, at: t0.addingTimeInterval(60)) == .wentDown, "two misses in a row is down")
        check(tracker.record("web", up: false, at: t0.addingTimeInterval(120)) == nil, "down is said once")
        check(tracker.record("web", up: true, at: t0.addingTimeInterval(360)) == .cameBack(after: 300), "back, with how long it was down")
        check(tracker.record("web", up: true, at: t0.addingTimeInterval(420)) == nil, "back is said once")
    }

    static func redaction() {
        func r(_ text: String, words: [String] = [], allow: [String] = []) -> String { Redaction.redact(text, words: words, allow: allow) }
        check(r("export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz12") == "export GITHUB_TOKEN=" + String(repeating: "•", count: 32), "a token after =")
        check(r("curl -H 'Authorization: Bearer abc123def456'").hasSuffix("Bearer ••••••••••••'"), "an Authorization header")
        check(r("mysql -u root -pS3cret shop") == "mysql -u root -p•••••• shop", "mysql -p")
        check(r("git clone https://amin:pa55w0rd@gitlab.example.com/x.git") == "git clone https://amin:••••••••@gitlab.example.com/x.git", "a password in a URL")
        check(!r("token is eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijkl").contains("eyJ"), "a JWT")
        check(r("psql --password hunter2 db") == "psql --password ••••••• db", "--password")
        check(r("ssh deploy@10.0.0.2 && ls -la") == "ssh deploy@10.0.0.2 && ls -la", "ordinary commands stay as they are")
        check(r("[sudo] password for deploy: ") == "[sudo] password for deploy: ", "a password prompt isn't a secret")
        check(r("echo my-db-pass-42", words: ["my-db-pass-42"]) == "echo " + String(repeating: "•", count: 13), "your own words")
        check(r("API_KEY=public-demo-key", allow: ["public-demo-key"]) == "API_KEY=public-demo-key", "the allow list")
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----"
        check(!r(pem).contains("b3Bl") && r(pem).contains("\n"), "a private key, keeping its lines")

        // A whole recording: a token typed a key at a time is still hidden.
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "clavra-redact-\(UUID().uuidString).cast")
        defer { try? FileManager.default.removeItem(at: url) }
        var text = #"{"version":2,"width":80,"height":24,"timestamp":1700000000,"title":"t"}"# + "\n"
        var time = 0.1
        for ch in "export TOKEN=ghp_abcdefghijklmnopqrstuvwxyz12\r\n" {
            let piece = String(data: try! JSONSerialization.data(withJSONObject: [String(ch)]), encoding: .utf8)!.dropFirst().dropLast()
            text += "[\(String(format: "%.3f", time)),\"o\",\(piece)]\n"
            time += 0.05
        }
        text += #"[3.000,"m","export TOKEN=ghp_abcdefghijklmnopqrstuvwxyz12"]"# + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        Redaction.apply(to: url, words: [], allow: [])
        let after = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(!after.contains("ghp_") && !after.contains("xyz12") && after.contains("\"redacted\":true"), "a recording keeps no secret, typed a key at a time")
        check(after.contains(#""o","e"]"#) && after.contains("TOKEN="), "everything else is as it was")
        check(Recordings.tape(at: url)?.events.count == 46, "and it still plays (46 pieces: Swift counts \\r\\n as one character): \(Recordings.tape(at: url)?.events.count ?? -1)")
    }
}
