# mac-unlock

Unlock your Mac's lock screen with one tap on your iPhone, from the next room or the other side of
the world.

A small background agent on the Mac listens for an unlock request over [Tailscale](https://tailscale.com).
When the request carries the right token, it wakes the display and types your login password into
the lock screen. On the phone, a plain Apple Shortcut sends the request; there is no app to install.

No dependencies beyond the Swift compiler that ships with Xcode Command Line Tools. Tested on macOS 27.

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

Read this before installing: **anyone who has the token and can reach your Mac over your tailnet
can unlock it.**

- Only Tailscale peers (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) and loopback are answered. Your
  LAN and the internet get no response.
- Requests travel inside Tailscale's WireGuard tunnel, so the plain HTTP is encrypted end to end.
- The token is 256 random bits, compared in constant time. Five wrong tokens shut the endpoint for
  ten minutes.
- Your password and the token live in the login Keychain, readable only by the `mac-unlock` binary.
- `setup` checks the password against your account before storing it, so a typo is never typed
  at the lock screen, and it puts the token on the clipboard rather than printing it.
- Use Tailscale ACLs to limit which of your devices may reach port 7777 on the Mac.

## Install

Requirements: macOS, `swiftc` (`xcode-select --install`), Tailscale on the Mac and the iPhone,
signed in to the same tailnet.

```sh
git clone https://github.com/yehia-khalil/mac-unlock.git
cd mac-unlock
./install.sh
```

The first run builds `bin/mac-unlock`, asks for your login password, copies a new token to the
clipboard and starts the agent at login. Then:

1. **System Settings → Privacy & Security → Accessibility**: switch on `mac-unlock`
   (add `bin/mac-unlock` with **+** if it is not listed).
2. Find the Mac's Tailscale address: `tailscale ip -4`.
3. **On the iPhone**, create a Shortcut:
   - **Get Contents of URL**: `http://<tailscale-ip>:7777/unlock`, Method **POST**,
     Header `Authorization` = `Bearer <token>` (paste the token; Universal Clipboard carries it
     over for about two minutes).
   - **Show Result**.
   - Add it to the Home Screen, a widget or the Action button.
4. Lock the Mac (Ctrl+Cmd+Q) and run the Shortcut. It should answer **Unlocked**.

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
| 500 | `Still locked after typing the password` | Password changed? Run `bin/mac-unlock setup`, then `./install.sh` |

## Everyday use

- **New token / changed password:** `bin/mac-unlock setup`, then `./install.sh`.
- **Logs:** `~/Library/Logs/mac-unlock.log` (one line per request, never the token).
- **Remove:** `./uninstall.sh`.

## Limits

- A Mac asleep on battery may not answer. On power, turn on **Wake for network access**.
- Rebuilding changes the binary, so macOS may ask again for Keychain access and Accessibility.
- It unlocks a locked screen in a logged-in session. It cannot log in after a restart or get past
  FileVault.

## License

[MIT](LICENSE)
