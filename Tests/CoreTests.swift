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
        knownHosts()
        print(failures == 0 ? "✓ \(passes) checks passed" : "\(failures) of \(passes + failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func commandGuard() {
        let risky = ["rm -rf /var/www", "sudo rm -fr build", "rm -r old", "DROP TABLE users;", "drop database app",
                     "TRUNCATE orders", "DELETE FROM users;", "update users set admin=1", "sudo reboot", "reboot",
                     "apt upgrade && reboot", "shutdown -h now", "docker rm web", "docker system prune -af",
                     "docker compose down", "git push --force origin main", "git push -f", "git reset --hard HEAD~3",
                     "chmod -R 777 /", "kubectl delete pod x", "terraform destroy", "systemctl restart nginx",
                     "kill -9 1234", "mkfs.ext4 /dev/sdb", "dd if=x of=/dev/sda", "crontab -r", "redis-cli FLUSHALL",
                     "apt remove nginx", "ufw disable", "iptables -F"]
        let safe = ["ls -la", "rm file.txt", "git push origin main", "DELETE FROM users WHERE id=3;",
                    "update users set a=1 where id=2", "docker ps", "systemctl status nginx",
                    "cat /var/log/syslog | grep reboot-required", "grep reboot /var/log/syslog", "less shutdown.log",
                    "echo hello", "kill 1234", "chmod 600 key", "# rm -rf /", "git status", "psql -c 'select 1'"]
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
        check(KnownHosts.fingerprint("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl").hasPrefix("SHA256:"), "fingerprint")
    }
}
