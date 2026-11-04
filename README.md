# Graceland Guest House ERP

A custom management system for a guesthouse business in Ghana. It handles hourly room bookings, shifts, shop sales, daily costs, staff payroll and financial reports in both Ghanaian cedis and US dollars.

It is made of two parts: a **FastAPI server** that keeps all the data, and a **Flutter app** that is built twice, once for the manager's phone and once for the front-desk tablet.

> **Status:** a working prototype, tested with test data on a laptop (server) and an Android phone (apps). It has not been put into live use yet.
>
> **Built with AI assistance.** See [How this project was built](#how-this-project-was-built) for who did what.

---

## What it does

**Rooms and bookings**
- Live room grid with four states: Available, Occupied (with a countdown of the time left), Time's Up and Needs Cleaning.
- Bookings only use prices the manager has approved for that room type.
- Extend a stay, check a guest in and out, mark a room clean.
- A receptionist can cancel a booking, or its newest extension, within 10 minutes. The manager can cancel or restore any booking from the Records tab.

**Shifts**
- The manager opens and closes official shifts.
- Between official shifts the system runs an automatic Buffer Shift, so guests can be booked at any hour.
- Closing a shift writes a CSV backup, copies employee photos and saves a dated copy of the database.

**Money**
- Payment by cash, US dollars, mobile money or bank transfer.
- Change is always given in cedis, rounded down to amounts that can be handed over with real coins. Dollar prices are rounded up.
- The exchange rate is looked up by the manager's phone at login and shared with the tablet.
- Shop sales, daily costs (utilities and expendables) and monthly payroll that is shared out per day.

**Reports (manager)**
- Business Summary: income, deductions and net profit for a day, week, month, year or custom range, with an up or down arrow against the period before, and drill-downs into rooms, sales, costs and payroll.
- Records: Guest Log, Shop Sales, Money Brought In per receptionist, and a Login Record.

**Guest text messages**
- The tablet sends texts from its own SIM card: on booking, on extension, 30 minutes before time is up, and when time is up.
- A full-screen alarm rings on the tablet when a room's time runs out.

**Works when the connection drops**
- If the tablet cannot reach the server, bookings, extensions, checkouts and sales are saved on the tablet and sent when the connection returns.
- Every saved action carries a one-time tag, so it can never be recorded twice.

---

## Security features

- **Passwords:** hashed with bcrypt. There are no built-in passwords anywhere in the code. The administrator password is typed at the terminal during first setup, and a one-time recovery code is shown once and stored only as a hash.
- **Login tokens:** JWT, signed with a random key the server makes for itself. Changing a username or password signs that account out on every device straight away.
- **Wrong-password lockout:** every 5 wrong tries in a row make that username wait longer each time (30 seconds up to 15 minutes). A wrong username and a wrong password get the same message, so nobody can find out which usernames exist.
- **Device allow-list:** the server only talks to devices listed in `network_config.json`, in three groups (the server itself, manager devices, reception devices). Manager actions are refused from any other device, and refused login attempts are recorded.
- **Roles:** the manager-only endpoints check the role of the person calling them.
- **Login Record:** every login attempt, with a note when something looks wrong, such as a manager login from a tablet.
- **Input checks:** length and range limits on most inputs, a 10-digit rule for mobile money numbers and a 4-digit rule for bank accounts.
- **Photo uploads:** size limit, checked as a real image, then redrawn as a new JPEG under a file name the server chooses.
- **Data safety:** every save goes to two database files, and if the second save fails the first is undone. Money on the server uses fixed-point decimals, not floating point.
- **Screens:** the apps cover themselves after 5 minutes without a touch and ask for the password to unlock. After an hour untouched the person is signed out.
- **Security test:** `Backend/pen_test.py` checks some of these rules against a running server.

The full list, including the physical and operating measures planned for a real installation and the improvements still to come, is in [SECURITY.md](SECURITY.md).

---

## Built with

| Part | Technology |
|------|------------|
| Server | Python, FastAPI, SQLAlchemy, SQLite (two files), bcrypt, PyJWT, Pillow |
| Apps | Flutter (Dart) for Android |
| Phone features | `another_telephony` (texts), `flutter_ringtone_player` (alarm), `image_picker` (photos) |

---

## Folders

```
graceland-guesthouse-erp/
├── Backend/      the server (main.py, models.py, database.py, security.py ...)
├── App/          the Flutter app (manager app and receptionist app)
└── SECURITY.md   security measures, limits and planned improvements
```

---

## Running it

### 1. The server

You need Python 3.10 or newer.

```
cd Backend
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
```

**Set the allowed devices.** Copy `network_config.example.json` to `network_config.json` and put in the real addresses of your devices. Without this file the server will not start, and any device whose address is not in the lists is turned away. The addresses `127.0.0.1` and `::1` let you test on one computer. On a real installation, also bind each device's IP address to its MAC address on the router, so one device cannot pretend to be another (see [SECURITY.md](SECURITY.md)).

**Create the first account.** Run this once:

```
python security.py
```

It creates the databases, asks you to choose the administrator password, and shows a recovery code. It also creates a shared `buffer` login with a temporary password.

**Write down the recovery code, and the `buffer` login's name and temporary password, and keep them in a safe place.** They are shown only once. Then close the terminal window and open a new one. The terminal keeps everything it printed, so anyone who can scroll up in the old window could read them.

**Start the server:**

```
python -m uvicorn main:app --host 0.0.0.0 --port 8000
```

Add `--reload` while developing, so the server restarts when a file changes.

### 2. The apps

You need Flutter installed. To build the APK files you also need the Android SDK, which comes with Android Studio. The `flutter` command must work from any folder. If typing `flutter` gives "not recognized", add Flutter's `bin` folder to your system PATH (see the [Flutter install guide](https://docs.flutter.dev/get-started/install)).

```
cd App
flutter pub get
```

Open `lib/config/server_addresses.json` and list the address of your server. A second address can be added as a fallback. The app tries them in order at login and uses the first one that answers. To try everything on one computer, use `http://127.0.0.1:8000`.

**Try it without building an APK.** Run either app straight from the source, on a connected phone, an emulator, or in Chrome:

```
flutter run --dart-define=APP_EDITION=manager
flutter run --dart-define=APP_EDITION=receptionist
```

To run it in Chrome, add web support once with `flutter create . --platforms web`, then add `-d chrome` to the command. This does not change the app's code. In a browser, the text messages and the alarm sound do not work, because they need a real phone. Everything else can be tried.

**Build the installable apps** (APK files for Android):

```
flutter build apk --release --flavor manager -t lib/main_manager.dart
flutter build apk --release --flavor reception -t lib/main_receptionist.dart
```

- **Manager app:** opens on a password-only login for the administrator account.
- **Receptionist app:** opens on a username and password login. Receptionist logins are created from Employee Management in the manager app.

### 3. The security test (optional)

Run `python pen_test.py`. It asks for the server address (press Enter to use `http://127.0.0.1:8000` when you run it on the server computer), then a receptionist login and the administrator login.

---

## Known limitations

- The server speaks plain HTTP. HTTPS is planned for when it is set up for real use.
- Cross-origin requests are open to all origins, which is a development setting.
- The wrong-password counters are kept in the server's memory, so restarting the server clears them.
- The exchange rate only updates when the manager's phone has internet at login. The server and the tablet have none.
- Text messages need a SIM card with airtime in the tablet.

More limits, and the improvements planned next, are in [SECURITY.md](SECURITY.md).

---

## How this project was built

This project was built with AI assistance. Here is who did what.

**My role: Product Owner and Tester**
- Came up with the idea and described what the guesthouse needs.
- Decided the business rules: how bookings, shifts, payments, change, payroll and reports should work, and who can do what.
- Tested every feature on a laptop and an Android phone, and reported the bugs and security weaknesses I found.
- Reviewed the code and each change, found bugs in it, said where it was wrong, and decided what should be changed or built next.

**AI's role**
- The first version of the server was built with Google Gemini. The foundation and a first set of features came from that stage.
- I then continued with Claude (Anthropic), which restructured the server and the app, added more features, strengthened the security and the backups, and wrote the code for every change since. It also recommended the technologies and the technical design. We discussed those choices before anything was built.

I am a cybersecurity student. I have basic Python knowledge and can read the code well enough to follow what it does and spot mistakes. I did not write it myself. This project shows how I specify, test and review a real system, and how I work with AI tools to build one.

---

## Use

This project is shown for portfolio purposes. Please ask before reusing it.

---

## Author

William Kwame Ayesu · creedify.hq@gmail.com · www.linkedin.com/in/william-ayesu
