// mac-unlock: unlock this Mac's lock screen from a phone over Tailscale.
//
//   mac-unlock setup   store the login password and a fresh token in the Keychain
//   mac-unlock serve   listen on :7777 for `POST /unlock` with `Authorization: Bearer <token>`
//
// Only Tailscale (100.64.0.0/10) and loopback peers are served. The password is typed
// into the lock screen with synthetic key events, which needs Accessibility permission.

import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Network
import OpenDirectory
import Security

let service = "mac-unlock"
let port: NWEndpoint.Port = 7777

// MARK: Keychain

func keychainRead(_ account: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
    ]
    var out: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
          let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

func keychainWrite(_ account: String, _ value: String) {
    let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    SecItemDelete(base as CFDictionary)
    var item = base
    item[kSecValueData as String] = Data(value.utf8)
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Keychain write failed (\(status))") }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: setup

func setup() {
    var buf = [CChar](repeating: 0, count: 1024)
    guard let raw = readpassphrase("Mac login password: ", &buf, buf.count, 0) else { fail("No password read") }
    let password = String(cString: raw)
    _ = buf.withUnsafeMutableBufferPointer { memset_s($0.baseAddress, $0.count, 0, $0.count) }

    // Refuse a wrong password: typing it would only add failed attempts at the lock screen.
    do {
        let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
        let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        try record.verifyPassword(password)
    } catch {
        fail("That is not the login password for \(NSUserName()).")
    }

    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fail("No randomness") }
    let token = Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")

    keychainWrite("password", password)
    keychainWrite("token", token)

    // The token goes to the clipboard, never to the terminal.
    let pbcopy = Process()
    pbcopy.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
    let pipe = Pipe()
    pbcopy.standardInput = pipe
    try? pbcopy.run()
    pipe.fileHandleForWriting.write(Data(token.utf8))
    pipe.fileHandleForWriting.closeFile()
    pbcopy.waitUntilExit()
    print("Saved. The new token is on the clipboard; paste it into the iPhone Shortcut.")
    print("Restart the agent so it picks up the new token: ./install.sh")
}

// MARK: unlocking

func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

func wakeDisplay() {
    var id: IOPMAssertionID = 0
    IOPMAssertionDeclareUserActivity("mac-unlock" as CFString, kIOPMUserActiveLocal, &id)
    IOPMAssertionRelease(id)
}

func post(_ event: CGEvent?) {
    event?.post(tap: .cghidEventTap)
    usleep(15_000)
}

func type(_ text: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    for unit in text.utf16 {
        var chars = [unit]
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
            post(event)
        }
    }
    let returnKey: CGKeyCode = 36
    post(CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true))
    post(CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false))
}

/// Returns an HTTP status and a one-line message for the phone.
func unlock() -> (Int, String) {
    guard screenIsLocked() else { return (200, "Already unlocked") }
    guard AXIsProcessTrusted() else { return (500, "mac-unlock has no Accessibility permission") }
    guard let password = keychainRead("password") else { return (500, "No password stored; run setup") }

    wakeDisplay()
    Thread.sleep(forTimeInterval: 1.5)  // let the lock screen come up and focus the password field
    type(password)

    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.25)
        if !screenIsLocked() { return (200, "Unlocked") }
    }
    return (500, "Still locked after typing the password")
}

// MARK: serve

/// Peers outside Tailscale and loopback are refused before the token is even read.
func allowed(_ endpoint: NWEndpoint) -> Bool {
    guard case let .hostPort(host, _) = endpoint else { return false }
    switch host {
    case let .ipv4(address):
        let b = [UInt8](address.rawValue)
        return b == [127, 0, 0, 1] || (b[0] == 100 && (b[1] & 0xC0) == 64)
    case let .ipv6(address):
        if address == .loopback { return true }
        // Tailscale's IPv6 range, fd7a:115c:a1e0::/48.
        return [UInt8](address.rawValue).prefix(6).elementsEqual([0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
    default:
        return false
    }
}

func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
}

/// Five wrong tokens shut the door for ten minutes.
final class Throttle {
    private var failures: [Date] = []
    let limit = 5, window: TimeInterval = 600

    var blocked: Bool {
        failures.removeAll { Date().timeIntervalSince($0) > window }
        return failures.count >= limit
    }
    func recordFailure() { failures.append(Date()) }
}

func respond(_ connection: NWConnection, _ status: Int, _ body: String) {
    let reason = [200: "OK", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                  429: "Too Many Requests", 500: "Internal Server Error"][status] ?? "Error"
    let text = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\n"
        + "Content-Length: \(body.utf8.count + 1)\r\nConnection: close\r\n\r\n\(body)\n"
    connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in connection.cancel() })
}

func handle(_ request: String, token: String, throttle: Throttle) -> (Int, String) {
    let lines = request.components(separatedBy: "\r\n")
    guard lines.first?.hasPrefix("POST /unlock ") == true else { return (404, "Not found") }
    if throttle.blocked { return (429, "Too many wrong tokens; try again later") }

    let auth = lines.dropFirst().first { $0.lowercased().hasPrefix("authorization:") }
    let given = auth.map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
    guard constantTimeEqual(given, "Bearer " + token) else {
        throttle.recordFailure()
        return (401, "Wrong token")
    }
    return unlock()
}

func serve() {
    guard let token = keychainRead("token") else { fail("No token stored; run `mac-unlock setup` first") }
    // Asks for Accessibility on behalf of this binary (not the terminal) the first time.
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)

    let queue = DispatchQueue(label: "mac-unlock")  // one request at a time
    let throttle = Throttle()
    let listener: NWListener
    do { listener = try NWListener(using: .tcp, on: port) } catch { fail("Cannot listen on \(port): \(error)") }

    listener.newConnectionHandler = { connection in
        guard allowed(connection.endpoint) else { connection.cancel(); return }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let (status, body) = handle(request, token: token, throttle: throttle)
            NSLog("%@ -> %d %@", "\(connection.endpoint)", status, body)
            respond(connection, status, body)
        }
    }
    listener.stateUpdateHandler = { state in
        if case let .failed(error) = state { fail("Listener failed: \(error)") }
    }
    listener.start(queue: queue)
    NSLog("mac-unlock listening on :%d", Int(port.rawValue))
    dispatchMain()
}

switch CommandLine.arguments.dropFirst().first {
case "setup": setup()
case "serve": serve()
default: fail("usage: mac-unlock setup | serve")
}
