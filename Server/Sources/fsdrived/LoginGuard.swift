import Foundation
import Hummingbird
import FSDriveCore

/// Slows down and then blocks password guessing on /v1/login. QTS cannot do this for
/// FSDrive: it sees every check coming from 127.0.0.1.
///
/// Two counters: per client address (one attacker) and per account (many addresses
/// trying one user). Blocks are temporary and kept in memory.
actor LoginGuard {
    struct Entry: Codable {
        var kind: String  // "ip" or "user"
        var value: String
        var failures: Int
        var blockedUntil: Int64?
    }

    let maxPerAddress = 5
    let maxPerAccount = 10
    let window: TimeInterval = 15 * 60
    let blockFor: TimeInterval = 15 * 60

    private var failures: [String: [Date]] = [:]  // key: "ip:<addr>" or "user:<name>"
    private var blocked: [String: Date] = [:]
    private var lastPrune = Date()

    /// Password checks run at once at most: each starts a QTS or DSM process, and a flood of
    /// parallel guesses would otherwise all be checked before any block applies.
    nonisolated let checks = Limiter(4)

    /// Drops what no longer counts, so guesses with ever new names or addresses cannot
    /// grow memory without bound.
    private func prune(_ now: Date) {
        guard now.timeIntervalSince(lastPrune) > 60 else { return }
        lastPrune = now
        failures = failures.compactMapValues { dates in
            let recent = dates.filter { now.timeIntervalSince($0) < window }
            return recent.isEmpty ? nil : recent
        }
        blocked = blocked.filter { $0.value > now }
    }

    private func key(_ kind: String, _ value: String) -> String { "\(kind):\(value)" }

    /// Seconds until this address or account may try again, or nil if it may now.
    func retryAfter(ip: String, user: String) -> TimeInterval? {
        let now = Date()
        let waits = [key("ip", ip), key("user", user)].compactMap { k -> TimeInterval? in
            guard let until = blocked[k] else { return nil }
            if until <= now {
                blocked[k] = nil
                failures[k] = nil
                return nil
            }
            return until.timeIntervalSince(now)
        }
        return waits.max()
    }

    /// Records a wrong password; returns the keys that just became blocked.
    func failed(ip: String, user: String) -> [String] {
        let now = Date()
        prune(now)
        var newlyBlocked = [String]()
        for (k, limit) in [(key("ip", ip), maxPerAddress), (key("user", user), maxPerAccount)] {
            var recent = (failures[k] ?? []).filter { now.timeIntervalSince($0) < window }
            recent.append(now)
            failures[k] = recent
            if recent.count >= limit && blocked[k] == nil {
                blocked[k] = now.addingTimeInterval(blockFor)
                newlyBlocked.append(k)
            }
        }
        return newlyBlocked
    }

    func succeeded(ip: String, user: String) {
        failures[key("ip", ip)] = nil
        failures[key("user", user)] = nil
    }

    func entries() -> [Entry] {
        let now = Date()
        let keys = Set(failures.keys).union(blocked.keys)
        return keys.sorted().compactMap { k in
            let parts = k.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let recent = (failures[k] ?? []).filter { now.timeIntervalSince($0) < window }.count
            let until = blocked[k].flatMap { $0 > now ? Int64($0.timeIntervalSince1970) : nil }
            guard recent > 0 || until != nil else { return nil }
            return Entry(kind: parts[0], value: parts[1], failures: recent, blockedUntil: until)
        }
    }

    func unblock(kind: String, value: String) {
        blocked[key(kind, value)] = nil
        failures[key(kind, value)] = nil
    }
}

/// The address of the client. Behind a reverse proxy the connection comes from the
/// proxy, so X-Forwarded-For is used — but only when the proxy is listed as trusted,
/// otherwise anyone could pick an address to dodge the block.
func clientAddress(_ request: Request, peer: String?, trusted: [String]) -> String {
    let peer = peer ?? "unknown"
    guard trusted.contains(peer), let header = request.headers[.init("X-Forwarded-For")!] else { return peer }
    // Rightmost address that is not one of our proxies is the real client.
    let hops = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    return hops.reversed().first { !trusted.contains($0) && !$0.isEmpty } ?? peer
}

/// Writes a warning to the QTS system log (QuLog), so blocks show up where QTS
/// administrators already look. A no-op elsewhere: on DSM they are in fsdrived.log and
/// on the settings page.
func nasLogWarning(_ message: String) {
    let tool = "/sbin/log_tool"
    guard FileManager.default.isExecutableFile(atPath: tool) else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = ["-t", "1", "-a", message]
    try? p.run()
}
