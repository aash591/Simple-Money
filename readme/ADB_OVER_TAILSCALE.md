# ADB over the internet (Tailscale)

Run and debug the app on a phone that is not on your local network, using
Android Wireless debugging over Tailscale (Android 11+).

## Requirements

- Tailscale installed and connected on both the PC and the phone (same tailnet).
- Phone: Developer options enabled.
- PC: `adb` from Android platform-tools. On this machine it is at
  `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe` (not on PATH).

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
```

## 1. Get the phone's Tailscale IP

Tailscale app on the phone, or the admin console. It starts with `100.`
This phone: `100.80.43.64`.

## 2. Pair (first time only)

On the phone: **Developer options › Wireless debugging › Pair device with
pairing code**. It shows a pairing port and a 6-digit code.

```powershell
& $adb pair 100.80.43.64:33207 138351
```

Use the Tailscale IP, not the Wi-Fi IP shown on the phone.

## 3. Connect

Close the pairing dialog. On the main **Wireless debugging** screen, read the
port next to "IP address & Port". This is a different port from the pairing one.

```powershell
& $adb connect 100.80.43.64:42961
& $adb devices        # should list the phone as "device"
```

## 4. Run the app

```powershell
cd app
flutter devices
flutter run -d 100.80.43.64:42961
```

## Reconnecting

The connect port changes whenever Wireless debugging is toggled or the phone
restarts. Read the new port from the phone and run step 3 again. Pairing is
usually not needed again.

```powershell
& $adb disconnect
& $adb connect 100.80.43.64:<NEW_PORT>
```

## Alternative: fixed port via USB

If you can plug the phone in once, this gives a stable port (`5555`), but it
resets on reboot.

```powershell
& $adb tcpip 5555          # phone connected by USB
# unplug, then:
& $adb connect 100.80.43.64:5555
```

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `connect` times out | Check both devices show as connected in Tailscale; run `tailscale ping <phone-name>`; check ACLs. |
| Connection drops | Turn off battery optimization for the Tailscale app on the phone. |
| `device unauthorized` | Accept the "Allow USB debugging?" prompt on the phone. |
| Stuck or odd state | `& $adb kill-server`, then connect again. |
| Wireless debugging won't turn on | Some phones need to be on Wi-Fi to enable it. Connect to Wi-Fi, enable it, then use the Tailscale IP. |

Keep the port reachable only through Tailscale. Do not forward it on a router
or expose it to the public internet.
