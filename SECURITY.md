# Security

This file lists the security measures of the Graceland Guest House ERP in three groups: what is **built into the code today**, what is **designed for a real installation but not built or set up yet**, and what was **deliberately postponed**. It ends with the known limits and the improvements planned next.

This is a prototype that has only been tested with test data. Nothing here is a claim that it has been audited.

---

## 1. Built into the code

**Accounts and passwords**
- Passwords are hashed with bcrypt. No password is stored in readable form.
- There are no built-in passwords or fallback keys in the code. The administrator password is typed at the terminal during first setup.
- The administrator gets a one-time recovery code, shown once and stored only as a hash.
- A wrong username and a wrong password give the same message ("Wrong username or password."), so nobody can learn which usernames exist.

**Login protection**
- Every 5 wrong tries in a row make that username wait longer each time, from 30 seconds up to 15 minutes. A correct login resets the count.
- At 50 wrong tries in a row, a receptionist or shared login has its password destroyed, and the manager must set a new one. The administrator account is never destroyed, so the business cannot be locked out of its own system.
- Login tokens (JWT) expire after 120 minutes. They are signed with a random key the server makes for itself. Changing a username or password signs that account out on every device straight away.
- The apps cover themselves after 5 minutes without a touch and ask for the password to unlock. After one hour untouched, the person is signed out.

**Access control**
- Device allow-list: the server only answers devices listed in `network_config.json`, in three groups (the server itself, manager devices, reception devices). Manager actions are refused from any other device.
- Every manager-only action checks the role of the person calling it.
- Login Record: every login attempt is recorded with its time, the result and the reason for a failure. Unusual cases are flagged, such as a manager login from reception tablet or a login from an address that is not on the list. Flagged attempts are recorded, not blocked.

**Input and files**
- Length and range limits on most inputs, a 10-digit rule for mobile money numbers and a 4-digit rule for bank account digits (only a masked form is shown).
- Photo uploads have a size limit, are checked as a real image, and are then redrawn as a new JPEG under a file name the server chooses.

**Data safety and availability**
- Every save goes to two database files. If the second save fails, the first is undone.
- Money on the server uses fixed-point decimals, not floating point.
- Closing a shift writes a CSV backup, copies employee photos and saves a dated copy of the database.
- If the tablet cannot reach the server, actions are saved on the tablet and sent later. Each carries a one-time tag, so it can never be recorded twice.

**Testing**
- `Backend/pen_test.py` checks some of these rules against a running server.

---

## 2. Designed for a real installation, not set up yet

These are measures decided for the real installation. The code does not enforce them, and they have not been put in place, because the system has not been deployed.

**Physical and operating measures**
- Devices are locked away outside business hours, and the reception area is locked when nobody is in it.
- The reception tablet runs as a locked kiosk that shows only the receptionist app, and the app cannot be quit. The tablet's own screen lock sits in front of it.
- The server runs on a dedicated laptop that only the manager can reach. Its code and databases are kept in a folder protected by the operating system's permissions.
- The manager's phone is a personal device that is not shared.

**Power and network**
- The server is a laptop. It stays plugged in, and its own battery takes over if the power fails, so it keeps running through a power cut. The tablet runs on its own battery.
- The router has no battery of its own, so it is kept on a power bank or a small backup supply. Without the router, the devices could not reach the server.
- The server starts by itself when power returns.
- The server has a fixed address on the local network.
- **IP–MAC binding on the router.** Each approved device's IP address is tied to its hardware (MAC) address, so a device cannot simply take another device's IP address to get past the allow-list. The server's allow-list checks IP addresses, so this router setting is what makes those addresses trustworthy. A MAC address can also be faked by a determined attacker, so this is one layer, not a guarantee.
- The server and the tablet have no internet connection. Only the manager's phone does, and it is used for the exchange-rate lookup at login. This keeps the most sensitive devices out of reach from outside.

---

## 3. Deliberately postponed

- **HTTPS.** The server speaks plain HTTP on the local network. HTTPS with a self-signed certificate is planned for when the system is installed for real, after the router and server are set up.
- **Database encryption.** Postponed on purpose. If the encryption key were lost, all the data would be lost with it. For now the databases rely on the protected folder described above.

---

## Known limits

- Plain HTTP, as above.
- The wrong-password counters are kept in the server's memory, so restarting the server clears them.
- Cross-origin requests are open to all origins, which is a development setting.
- The allow-list checks IP addresses. Without the router's IP–MAC binding (section 2), one device on the network could pretend to be another.
- A stolen or borrowed device that is on the allow-list can still reach the server. The lockout, the kiosk lock, and the manager's ability to reset any login are what limit the damage.
- The security test script covers only some of the rules above.

---

## Planned improvements

These are ideas for later versions. None of them is built yet.

- Rebuild the wrong-password counters from the Login Record when the server starts, so a restart no longer gives anyone a fresh start.
- Lower the number of wrong tries in a row that destroys a receptionist password.
- For the administrator account, after a set number of wrong tries in a row, lock the password and require the recovery code.
- Show a warning on the manager's dashboard when failed logins keep happening.
- Restrict cross-origin requests to the apps only.
- HTTPS, and a written procedure for protecting the server folder, when the system is installed.

If the administrator password and the recovery code are both lost, the only way forward is to move the existing databases to a safe place for review, then run `python security.py` to start afresh.
