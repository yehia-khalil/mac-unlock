// mac-unlock: unlock this Mac's lock screen from a phone over Tailscale.
//
//   mac-unlock setup   store the login password and a fresh token in the Keychain
//   mac-unlock serve   listen on :7777 for `POST /unlock` with `Authorization: Bearer <token>`
//
// Only connections arriving through the Tailscale interface, from Tailscale addresses, are served.
// The password is typed into the lock screen with synthetic key events, which needs Accessibility.

import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Network
import OpenDirectory
import Security

let service = "mac-unlock"
let agentLabel = "com.github.yehia-khalil.mac-unlock"  // also in install.sh and uninstall.sh
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

    // Restart a running agent so it serves the new token; harmless before the first install.
    let kick = Process()
    kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    kick.arguments = ["kickstart", "-k", "gui/\(getuid())/\(agentLabel)"]
    kick.standardError = FileHandle.nullDevice
    try? kick.run()
    kick.waitUntilExit()
}

// MARK: unlocking

func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

/// Wakes the display and keeps it on until the returned release is called. The lock screen turns
/// the display off after a few idle seconds; keys typed while it is off or still waking are lost.
func holdDisplayAwake() -> () -> Void {
    var activity: IOPMAssertionID = 0, noSleep: IOPMAssertionID = 0
    IOPMAssertionDeclareUserActivity("mac-unlock" as CFString, kIOPMUserActiveLocal, &activity)
    // The timeout makes powerd drop the hold itself: releasing it by hand after waking a sleeping
    // display was seen to leave it behind, and a leaked hold keeps the display on for good.
    IOPMAssertionCreateWithDescription(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                       "mac-unlock" as CFString, nil, nil, nil, 30,
                                       kIOPMAssertionTimeoutActionRelease as CFString, &noSleep)
    return { IOPMAssertionRelease(activity); IOPMAssertionRelease(noSleep) }
}

func waitForDisplay() -> Bool {
    for _ in 0..<40 {
        if CGDisplayIsAsleep(CGMainDisplayID()) == 0 { return true }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return false
}

func post(_ event: CGEvent?) {
    event?.post(tap: .cghidEventTap)
    usleep(15_000)
}

func key(_ source: CGEventSource?, _ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        post(event)
    }
}

func type(_ text: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    // Clear whatever an earlier, interrupted attempt left in the password field.
    key(source, 0, .maskCommand)  // ⌘A
    key(source, 51)               // Delete
    for unit in text.utf16 {
        var chars = [unit]
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
            post(event)
        }
    }
    key(source, 36)  // Return
}

/// Returns an HTTP status and a one-line message for the phone.
func unlock() -> (Int, String) {
    guard screenIsLocked() else { return (200, "Already unlocked") }
    guard AXIsProcessTrusted() else { return (500, "mac-unlock has no Accessibility permission") }
    guard let password = keychainRead("password") else { return (500, "No password stored; run setup") }

    let release = holdDisplayAwake()
    defer { release() }
    guard waitForDisplay() else { return (500, "The display did not wake") }
    Thread.sleep(forTimeInterval: 1.0)  // let the lock screen come up and focus the password field
    type(password)

    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.25)
        if !screenIsLocked() { return (200, "Unlocked") }
    }
    return (500, "Still locked after typing the password")
}

// MARK: serve

func isTailscaleIPv4(_ b: [UInt8]) -> Bool { b[0] == 100 && (b[1] & 0xC0) == 64 }  // 100.64.0.0/10
// Tailscale's own IPv6 range, fd7a:115c:a1e0::/48. Unlike 100.64.0.0/10, which other VPNs and
// carrier-grade NAT also use, nothing else claims it.
func isTailscaleIPv6(_ b: [UInt8]) -> Bool { b.prefix(6).elementsEqual([0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]) }

/// The listener only sees connections that came in through the Tailscale interface; this further
/// limits them to Tailscale devices themselves, not hosts behind someone's subnet router.
func allowed(_ endpoint: NWEndpoint) -> Bool {
    guard case let .hostPort(host, _) = endpoint else { return false }
    switch host {
    case let .ipv4(address):
        return isTailscaleIPv4([UInt8](address.rawValue))
    case let .ipv6(address):
        return isTailscaleIPv6([UInt8](address.rawValue))
    default:
        return false
    }
}

/// The name of the Tailscale tunnel interface (a `utun`): the one holding an fd7a:115c:a1e0::/48 address.
func tailscaleInterfaceName() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return nil }
    defer { freeifaddrs(head) }
    var next = head
    while let ifa = next {
        next = ifa.pointee.ifa_next
        guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
        let bytes = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
            withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
        }
        if isTailscaleIPv6(bytes) { return String(cString: ifa.pointee.ifa_name) }
    }
    return nil
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
    // Read the password now, not at the first unlock: after an upgrade the Keychain asks to allow
    // the new binary, and that prompt must appear while someone is at the Mac, not behind the lock.
    guard keychainRead("password") != nil else { fail("No password stored; run `mac-unlock setup` first") }
    // Asks for Accessibility on behalf of this binary (not the terminal) the first time.
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)

    let queue = DispatchQueue(label: "mac-unlock")  // one request at a time
    let throttle = Throttle()

    // Bind to the Tailscale interface, so the kernel never hands us a connection that arrived on
    // Wi-Fi, Ethernet or loopback, port forwarding included. If Tailscale is down, or later
    // replaces its interface, exit and let launchd start us again on the new one.
    var bound: NWInterface?
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { path in
        let name = tailscaleInterfaceName()
        let tunnel = path.availableInterfaces.first { $0.name == name }
        if let bound {
            if tunnel?.name != bound.name || tunnel?.index != bound.index { fail("Tailscale interface changed; restarting") }
            return
        }
        guard let tunnel else { fail("Tailscale is not connected; launchd will retry") }
        bound = tunnel

        let parameters = NWParameters.tcp
        parameters.requiredInterface = tunnel
        let listener: NWListener
        do { listener = try NWListener(using: parameters, on: port) } catch { fail("Cannot listen on \(port): \(error)") }

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
        NSLog("mac-unlock listening on %@:%d", tunnel.name, Int(port.rawValue))
    }
    monitor.start(queue: queue)
    dispatchMain()
}

switch CommandLine.arguments.dropFirst().first {
case "setup": setup()
case "serve": serve()
default: fail("usage: mac-unlock setup | serve")
}
