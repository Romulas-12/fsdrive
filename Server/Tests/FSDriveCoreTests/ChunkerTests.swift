import Foundation
import Testing
@testable import FSDriveCore

private func randomData(_ count: Int, seed: UInt64) -> Data {
    var state = seed
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
    }
    return Data(bytes)
}

@Test func chunkSizesStayWithinBounds() {
    let data = randomData(24 << 20, seed: 1)
    let m = Chunker.manifest(of: data)
    #expect(m.size == Int64(data.count))
    for c in m.chunks.dropLast() {
        #expect(c.length >= Chunker.minSize && c.length <= Chunker.maxSize)
    }
    #expect(m.chunks.count > 6)
}

@Test func insertionOnlyChangesNearbyChunks() {
    let data = randomData(16 << 20, seed: 2)
    var edited = data
    edited.insert(contentsOf: Data("hello".utf8), at: 8 << 20)
    let a = Set(Chunker.manifest(of: data).chunks.map(\.hash))
    let b = Chunker.manifest(of: edited).chunks.map(\.hash)
    let changed = b.filter { !a.contains($0) }.count
    #expect(changed <= 2)
}

@Test func fileAndMemoryChunkingAgree() throws {
    let data = randomData(10 << 20 + 12345, seed: 3)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fsdrive-chunk-\(UUID()).bin")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try Chunker.manifest(ofFileAt: url.path) == Chunker.manifest(of: data))
}

@Test func manifestRoundTrip() {
    let m = Chunker.manifest(of: randomData(5 << 20, seed: 4))
    #expect(Manifest.decode(m.encoded()) == m)
    #expect(Manifest(dto: m.dto) == m)
}

@Test func emptyFile() {
    let m = Chunker.manifest(of: Data())
    #expect(m.chunks.isEmpty)
    #expect(m.size == 0)
}

@Test func pathNormalization() throws {
    let nfd = "Cafe\u{301}/звіт.pdf"
    #expect(try VPath.normalize("/" + nfd + "/") == "Café/звіт.pdf")
    #expect(throws: PathError.self) { try VPath.normalize("a/../b") }
    #expect(VPath.key("Звіт.PDF") == VPath.key("звіт.pdf"))
    #expect(VPath.conflictPath("a/b.txt", device: "Mac", date: Date(timeIntervalSince1970: 0)).hasPrefix("a/b (conflict, Mac, "))
    #expect(VPath.isIgnored(name: ".DS_Store"))
    #expect(!VPath.isIgnored(name: "notes.txt"))
}

@Test func sshKeysAreReadableByOpenSSH() throws {
    let pair = SSHKeys.generate(comment: "fsdrive-test")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fsdrive-key-\(UUID())")
    try pair.privateKey.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    chmod(url.path, 0o600)
    // ssh-keygen -y derives the public key from the private file: it must match ours.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    p.arguments = ["-y", "-f", url.path]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    p.waitUntilExit()
    let derived = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(p.terminationStatus == 0)
    #expect(derived.split(separator: " ").prefix(2) == pair.publicKey.split(separator: " ").prefix(2))
}
