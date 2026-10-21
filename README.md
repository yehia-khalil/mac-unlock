# mac-unlock

Unlock your Mac's lock screen with one tap on your iPhone, from the next room or the other side of
the world.

A small background agent on the Mac listens for an unlock request over [Tailscale](https://tailscale.com).
When the request carries the right token, it wakes the display and types your login password into
the lock screen. On the phone, a plain Apple Shortcut sends the request; there is no app to install.

The iPhone is just the handiest client. The request is plain HTTP, so any device on your tailnet can
send it: another Mac, a Linux box, an Android phone, a script.

```sh
curl -X POST -H "Authorization: Bearer <token>" http://<mac-tailscale-ip>:7777/unlock
```

A single small binary with no dependencies. Runs on macOS 13 or later, Apple silicon and Intel; tested on macOS 27.

## How it works

```
iPhone Shortcut ──POST /unlock + Bearer token──▶ Tailscale (WireGuard) ──▶ mac-unlock :7777
                                                                             │ wake display
                                                                             │ type password (Keychain)
                                                                             ▼
                                                                         lock screen
```

macOS has no API that dismisses the lock screen, so mac-unlock types the password with synthetic
key events, the same way proximity-unlock apps do. That needs Accessibility permission.

## Security

Read this before installing: **the token is the only thing that decides who may unlock.** The
agent does not know or check which device is calling. Any request that carries the token unlocks
the Mac if it comes from:

- any device on your tailnet, not only your iPhone;
- any device or person you have [shared the Mac with](https://tailscale.com/kb/1084/sharing)
  through Tailscale, and anyone else who joins your tailnet.

Keep the token as private as your password. Lock down who can reach the Mac with the steps below.

- The agent listens only on the Tailscale interface (the `utun` holding a `fd7a:115c:a1e0::/48`
  address), so the kernel never hands it a connection that arrived over Wi-Fi, Ethernet or
  loopback. Your LAN, a router port forward, programs on the Mac and the internet get no
  response. It also checks that the caller has a Tailscale address (`100.64.0.0/10` or
  `fd7a:115c:a1e0::/48`), which rules out hosts behind someone's subnet router.
- If Tailscale is off when the agent starts, or Tailscale replaces its interface, the agent exits
  and launchd starts it again within seconds, on the new interface.
- Requests travel inside Tailscale's WireGuard tunnel, so the plain HTTP is encrypted end to end.
- The token is 256 random bits, compared in constant time. Five wrong tokens shut the endpoint for
  ten minutes.
- Your password and the token live in the login Keychain, readable only by the `mac-unlock` binary.
- `setup` checks the password against your account before storing it, so a typo is never typed
  at the lock screen, and it puts the token on the clipboard rather than printing it.
- Use [Tailscale access controls](https://tailscale.com/kb/1018/acls) to allow only your phone
  to reach port 7777 on the Mac, for example:
  `{"action": "accept", "src": ["<your-iphone>"], "dst": ["<your-mac>:7777"]}`.
- If the token may have leaked, run `setup` again (see Everyday use). The old token stops working
  at once.

## Install

You need Tailscale on the Mac and the iPhone, signed in to the same tailnet.

**From the release (no tools needed):** download `mac-unlock-<version>.dmg` from
[Releases](https://github.com/yehia-khalil/mac-unlock/releases), open it and double-click
**Install mac-unlock.command**. The release is not notarized, so the first time macOS blocks it:
open **System Settings → Privacy & Security**, click **Open Anyway**, and run it again.

**From source** (needs `swiftc`: `xcode-select --install`):

```sh
git clone https://github.com/yehia-khalil/mac-unlock.git
cd mac-unlock
./install.sh
```

Either way the installer copies the binary to `~/Library/Application Support/mac-unlock`, asks for
your login password on the first run, copies a new token to the clipboard and starts the agent at
login. Then:

1. **System Settings → Privacy & Security → Accessibility** (the installer opens it): switch on
   `mac-unlock`. If it is not listed, click **+**, press Cmd+Shift+G and enter
   `~/Library/Application Support/mac-unlock/mac-unlock`.
2. If macOS asks whether `mac-unlock` may use its Keychain items, choose **Always Allow**.
3. Find the Mac's Tailscale address: `tailscale ip -4`.
4. **On the iPhone**, create a Shortcut:
   - **Get Contents of URL**: `http://<tailscale-ip>:7777/unlock`, Method **POST**,
     Header `Authorization` = `Bearer <token>` (paste the token; Universal Clipboard carries it
     over for about two minutes).
   - **Show Result**.
   - Add it to the Home Screen, a widget or the Action button.
5. Lock the Mac (Ctrl+Cmd+Q) and run the Shortcut. It should answer **Unlocked**.

The Mac's `*.ts.net` name works in place of the IP only if **Use Tailscale DNS** is on in the
iPhone's Tailscale app.

## Responses

| Status | Body | Meaning |
|---|---|---|
| 200 | `Unlocked` | The lock screen accepted the password |
| 200 | `Already unlocked` | Nothing to do |
| 401 | `Wrong token` | Check the Shortcut's header |
| 429 | `Too many wrong tokens…` | Wait ten minutes |
| 500 | `…no Accessibility permission` | Do step 1 again |
| 500 | `Still locked after typing the password` | Password changed? Run setup again (below) |

## Everyday use

- **New token or changed password:**
  `~/Library/Application\ Support/mac-unlock/mac-unlock setup` (restarts the agent for you).
- **Update:** run the new release's installer, or `git pull && ./install.sh`.
- **Logs:** `~/Library/Logs/mac-unlock.log` (one line per request, never the token).
- **Remove:** **Uninstall mac-unlock.command** from the DMG, or `./uninstall.sh`.

## Building a release

`./make-dmg.sh 0.1.0` builds a universal binary and writes `dist/mac-unlock-0.1.0.dmg`.

## Limits

- A Mac asleep on battery may not answer. On power, turn on **Wake for network access**.
- Each new build is a new binary, and macOS ties Accessibility to the exact build. After an
  update the old entry can still show as on while the new build gets `no Accessibility
  permission`. Remove every `mac-unlock` from Accessibility with **−**, run
  `launchctl kickstart -k gui/$UID/com.github.yehia-khalil.mac-unlock`, and switch it on when
  macOS asks. If the Keychain asks to allow `mac-unlock`, choose **Always Allow**.
- It unlocks a locked screen in a logged-in session. It cannot log in after a restart or get past
  FileVault.

## License

[MIT](LICENSE)
