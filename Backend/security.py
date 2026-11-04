import datetime
import getpass    # Reads the administrator's password from the terminal without echoing it on screen
import secrets    # Generates the one-time recovery code shown at first setup
import bcrypt
from database import SessionLocal, MirrorSessionLocal, engine, mirror_engine, create_missing_tables
import models


def _ensure_buffer_account_exists(db, mirror_db):
    """
    Creates the Buffer account if it does not already exist on both
    databases. A dedicated login for whoever is physically on site during
    a buffer-shift period when it is not the regular receptionist
    (security, a family member, and so on). Deliberately NOT linked to any
    employee record, so it never shows up in Employee Management, Payroll,
    or Money Brought In — it exists purely as a shared login, not a person
    on the books. A real receptionist's own login keeps working normally
    at any time, including during a buffer period; Buffer is only there
    for everyone else. Safe to call every time the server is set up: does
    nothing once the account already exists on both files.

    Like the administrator's own password, its temporary password is
    shown once, here, and must be changed on the Change Login screen
    before real use — the account is created with must_change_password
    set, so this cannot be skipped.
    """
    existing = db.query(models.User).filter(models.User.username == "buffer").first()
    mirror_existing = mirror_db.query(models.User).filter(models.User.username == "buffer").first()
    if existing and mirror_existing:
        return

    buffer_temporary_password = secrets.token_urlsafe(6)
    buffer_password_hash = bcrypt.hashpw(buffer_temporary_password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')

    if not existing:
        db.add(models.User(
            username="buffer", password_hash=buffer_password_hash, role="Buffer",
            is_active=True, must_change_password=True,
        ))
    if not mirror_existing:
        mirror_db.add(models.User(
            username="buffer", password_hash=buffer_password_hash, role="Buffer",
            is_active=True, must_change_password=True,
        ))
    db.commit()
    mirror_db.commit()

    print("\n" + "=" * 66)
    print("  BUFFER ACCOUNT CREATED")
    print("=" * 66)
    print("  Username: buffer")
    print(f"  Temporary password: {buffer_temporary_password}")
    print("This password must be changed on the Change Login screen before")
    print("the Buffer account is used. Give it to whoever covers the buffer")
    print("shift when the regular receptionist is not available.")


def initialize_security_vault():
    """
    Runs once, by hand, before the server is started for the first time on
    a fresh installation: `python security.py`.

    Creates every table in both databases, then asks for the
    administrator's password directly at the terminal (never shown on
    screen while typing), and shows a one-time recovery code that must be
    written down and kept somewhere safe — it is the only way into the
    administrator account if the password is ever forgotten, and it is
    never shown again after this.

    Also creates the Buffer account here, the same way, with its own
    one-time temporary password shown at the end of this run. Safe to run
    again later on an existing installation too: if the administrator
    account already exists but the Buffer account does not yet (an
    installation set up before Buffer existed), only the Buffer account is
    added, and the administrator account is left untouched.

    No receptionist account is created here. Receptionists are created
    from inside the app once the administrator has logged in, and each one
    gets their own login at that point (see the Employee Management
    screen). There are no built-in passwords anywhere in this file.
    """
    print("[SECURITY INITIALIZATION]: Commencing secure boot sequence...")

    db = SessionLocal()
    mirror_db = MirrorSessionLocal()

    print("[METADATA ENGINE]: Mapping system blueprints onto both registry hubs...")
    create_missing_tables()

    # If an administrator already exists on both files, first-time setup
    # has already been run before, so the administrator account itself is
    # left untouched. This install may still predate the Buffer account
    # (added in a later batch), so that part is checked separately below
    # and created on its own if it is still missing, even on an existing
    # installation.
    admin_exists = db.query(models.User).filter(models.User.role == "Owner").first()
    mirror_admin_exists = mirror_db.query(models.User).filter(models.User.role == "Owner").first()

    if admin_exists and mirror_admin_exists:
        print("[VAULT STATUS]: An administrator account already exists on both databases.")
        _ensure_buffer_account_exists(db, mirror_db)
        db.close()
        mirror_db.close()
        return

    print("\nFirst-time setup: creating the administrator account.")
    while True:
        owner_password = getpass.getpass("Choose the administrator's password (hidden while typing): ")
        if len(owner_password) < 8:
            print("Please choose a password of at least 8 characters.")
            continue
        confirm_password = getpass.getpass("Type it again to confirm: ")
        if owner_password != confirm_password:
            print("Those did not match. Please try again.")
            continue
        break

    owner_hash = bcrypt.hashpw(owner_password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')

    # The recovery code is only ever shown this once. It is stored only as
    # a scrambled hash, exactly like a password, so nobody who later reads
    # the database can recover it — the person must have written it down.
    recovery_code = secrets.token_hex(8).upper()
    recovery_code_hash = bcrypt.hashpw(recovery_code.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')

    print("[IDENTITY MANAGEMENT]: Provisioning the administrator account...")
    owner_user = models.User(
        username="administrator", password_hash=owner_hash, role="Owner",
        is_active=True, recovery_code_hash=recovery_code_hash,
    )
    mirror_owner_user = models.User(
        username="administrator", password_hash=owner_hash, role="Owner",
        is_active=True, recovery_code_hash=recovery_code_hash,
    )
    db.add(owner_user)
    mirror_db.add(mirror_owner_user)

    _ensure_buffer_account_exists(db, mirror_db)

    print("[TEMPORAL ISOLATION]: Instantiating the initial buffer-shift session...")
    now_utc = datetime.datetime.now(datetime.timezone.utc)

    # The very first session starts as a buffer shift, exactly like the
    # gap between two official shifts: the business can already take
    # bookings from the moment the server first starts, even before the
    # manager formally opens the first official shift. current_usd_rate
    # starts at a placeholder; the manager's app corrects it at first login.
    db.add(models.SessionLog(
        start_time=now_utc, is_closed=False, closure_type="Buffer_Shift", current_usd_rate=15.0000
    ))
    mirror_db.add(models.SessionLog(
        start_time=now_utc, is_closed=False, closure_type="Buffer_Shift", current_usd_rate=15.0000
    ))

    db.commit()
    mirror_db.commit()

    print("\n[VAULT STATUS]: Administrator account created successfully on both databases.")
    print("=" * 66)
    print(f"  RECOVERY CODE: {recovery_code}")
    print("=" * 66)
    print("Write this down and keep it somewhere safe. It is shown only once,")
    print("and is the only way to reset the administrator password if it is")
    print("ever forgotten. Nobody can recover this for you.")

    db.close()
    mirror_db.close()


if __name__ == "__main__":
    initialize_security_vault()
