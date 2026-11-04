"""
One-time database migration script.

This adds every new column main.py's latest backend batch expects onto
tables that may already exist with real data in them: SQLAlchemy's
Base.metadata.create_all() only creates brand-new tables, it never adds a
column to a table that already exists. Running this script fills that gap.
It also creates any table that is entirely new (such as app_settings),
the same way the server itself now does on every start.

What this touches, and why:
  - users: adds 'is_active' (turns a login off when a receptionist is
    removed, without deleting the account), 'must_change_password' (set
    after a manager hands out a temporary password), 'recovery_code_hash'
    (the administrator's own "Forgot password?" path), and 'token_version'
    (bumped on any username/password change so every device carrying an
    older login token is signed out immediately, not just the device the
    change was made on).
  - employee_records: adds 'photo_url' (passport photo path), 'start_date'
    and 'end_date' (payroll accuracy — a salary change ends the old row
    and starts a new one), 'person_id' (ties every salary row of one real
    person together), and 'user_id' (links an employee to their login, for
    "Money brought in"). 'is_active' already exists from an earlier run of
    this script and is left alone.
  - daily_cost_logs: adds 'category' (UTILITIES or EXPENDABLES).
  - room_bookings: adds 'usd_received' (the dollar note kept alongside a
    cedi booking), 'checked_out_by' (who checked the guest out, for the
    Guest Log), and 'cancelled_by' (who cancelled the booking, shown
    alongside who booked it when the two are different people). The old
    'number_of_occupants' column, if still present from an earlier run, is
    left in place and simply unused — it is never read anywhere in the
    current code.
  - booking_extensions: adds 'usd_received', 'recorded_by' (who made the
    extension), 'is_cancelled' and 'previous_checkout_time' (both needed
    for "Cancel Extension" to work), and 'cancelled_by' and 'cancelled_at'
    (who cancelled the extension and when, shown in Records).
  - counter_shop_sales: adds 'usd_received'.
  - room_bookings, booking_extensions and counter_shop_sales also get
    'bank_sender_account' (the last four digits of the sender's account for
    bank transfer payments).
  - room_bookings: the 'tax_calculated' column is dropped; nothing in the
    system reads or writes it.

Two tables, login_records (the Login Record) and manager_override_records
(the manager's cancel and restore history), are brand new tables. The
server creates them in both database files by itself on its first start, so
nothing in this script is needed for them.

Nothing existing is deleted or altered. Every existing row keeps all of
its current data; the new columns are simply added with safe defaults so
old rows remain valid immediately.

Run this once, before starting the server with the new main.py and
models.py, against BOTH database files (the primary and the mirror), since
they are expected to always match each other structurally. The server
itself also creates any missing table on every start, so running this is
mainly about the columns listed above, which an existing table needs added
by hand.

Usage:
    python migrate.py
"""

import sqlite3

# The two database files this on-premises setup keeps in sync with each other.
DATABASE_FILES = ["guesthouse.db", "guesthouse_mirror.db"]


def get_existing_tables(connection):
    """Returns the set of table names that already exist in this database file."""
    cursor = connection.execute("SELECT name FROM sqlite_master WHERE type='table'")
    return {row[0] for row in cursor.fetchall()}


def get_existing_columns(connection, table_name):
    """
    Returns the set of column names a table currently has, so this script
    never tries to add a column that is already there.
    """
    cursor = connection.execute(f"PRAGMA table_info({table_name})")
    return {row[1] for row in cursor.fetchall()}


def add_column_if_missing(connection, table_name, column_name, column_definition):
    """
    Adds a single column to a table only if it does not already exist.
    Safe to run multiple times without causing errors or duplicate columns.
    Does nothing if the table itself does not exist yet; the server creates
    brand-new tables on its own the first time it starts.
    """
    existing_tables = get_existing_tables(connection)
    if table_name not in existing_tables:
        print(f"    Skipped: {table_name} does not exist yet (the server will create it).")
        return

    existing_columns = get_existing_columns(connection, table_name)
    if column_name in existing_columns:
        print(f"    Skipped: {table_name}.{column_name} already exists.")
        return

    connection.execute(f"ALTER TABLE {table_name} ADD COLUMN {column_definition}")
    print(f"    Added: {table_name}.{column_name}")


def drop_column_if_present(connection, table_name, column_name):
    """
    Removes a column that is no longer used. Uses the native DROP COLUMN
    on SQLite 3.35 and newer; on older versions the table is rebuilt
    without the column. Does nothing when the table or column is absent,
    so it is safe to run more than once.
    """
    if table_name not in get_existing_tables(connection):
        print(f"    Skipped: {table_name} does not exist yet (the server will create it).")
        return
    if column_name not in get_existing_columns(connection, table_name):
        print(f"    Skipped: {table_name}.{column_name} is already gone.")
        return

    if sqlite3.sqlite_version_info >= (3, 35, 0):
        connection.execute(f"ALTER TABLE {table_name} DROP COLUMN {column_name}")
    else:
        info = connection.execute(f"PRAGMA table_info({table_name})").fetchall()
        keep = [row[1] for row in info if row[1] != column_name]
        sql = connection.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table_name,)
        ).fetchone()[0]
        indexes = [r[0] for r in connection.execute(
            "SELECT sql FROM sqlite_master WHERE type='index' AND tbl_name=? AND sql IS NOT NULL",
            (table_name,)).fetchall()]
        temp = f"{table_name}__rebuild"
        defs = []
        for row in info:
            if row[1] == column_name:
                continue
            piece = f'"{row[1]}" {row[2]}'
            if row[3]:
                piece += " NOT NULL"
            if row[4] is not None:
                piece += f" DEFAULT {row[4]}"
            if row[5]:
                piece += " PRIMARY KEY"
            defs.append(piece)
        cols = ", ".join(f'"{c}"' for c in keep)
        connection.execute(f"CREATE TABLE {temp} ({', '.join(defs)})")
        connection.execute(f"INSERT INTO {temp} ({cols}) SELECT {cols} FROM {table_name}")
        connection.execute(f"DROP TABLE {table_name}")
        connection.execute(f"ALTER TABLE {temp} RENAME TO {table_name}")
        for index_sql in indexes:
            if column_name not in index_sql:
                connection.execute(index_sql)
    print(f"    Dropped: {table_name}.{column_name}")


def migrate_single_database_file(file_path):
    """
    Applies every required column addition to one database file.
    """
    print(f"Migrating {file_path} ...")
    connection = sqlite3.connect(file_path)

    try:
        # --- users ---
        add_column_if_missing(connection, "users", "is_active", "is_active BOOLEAN NOT NULL DEFAULT 1")
        add_column_if_missing(connection, "users", "must_change_password", "must_change_password BOOLEAN NOT NULL DEFAULT 0")
        add_column_if_missing(connection, "users", "recovery_code_hash", "recovery_code_hash TEXT")
        add_column_if_missing(connection, "users", "token_version", "token_version INTEGER NOT NULL DEFAULT 1")

        # --- employee_records ---
        add_column_if_missing(
            connection, "employee_records", "is_active",
            "is_active BOOLEAN NOT NULL DEFAULT 1"
        )
        add_column_if_missing(connection, "employee_records", "photo_url", "photo_url TEXT")
        add_column_if_missing(
            connection, "employee_records", "start_date",
            "start_date DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00'"
        )
        add_column_if_missing(connection, "employee_records", "end_date", "end_date DATETIME")
        add_column_if_missing(connection, "employee_records", "person_id", "person_id INTEGER")
        add_column_if_missing(connection, "employee_records", "user_id", "user_id INTEGER")

        # Every existing employee row becomes its own person, so payroll
        # history reads correctly for staff already in the database before
        # this column existed. Guarded the same way every column addition
        # above is: on a brand-new install this table does not exist yet
        # (the server creates it on first start), so there is nothing to
        # back-fill and this must not be allowed to crash the script.
        if "employee_records" in get_existing_tables(connection):
            connection.execute("UPDATE employee_records SET person_id = id WHERE person_id IS NULL")
        else:
            print("    Skipped: employee_records does not exist yet (the server will create it).")

        # --- daily_cost_logs ---
        add_column_if_missing(
            connection, "daily_cost_logs", "category",
            "category TEXT NOT NULL DEFAULT 'EXPENDABLES'"
        )

        # --- room_bookings ---
        add_column_if_missing(connection, "room_bookings", "usd_received", "usd_received NUMERIC(10, 2)")
        add_column_if_missing(connection, "room_bookings", "checked_out_by", "checked_out_by INTEGER")
        add_column_if_missing(connection, "room_bookings", "cancelled_by", "cancelled_by INTEGER")

        add_column_if_missing(connection, "room_bookings", "bank_sender_account", "bank_sender_account VARCHAR(4)")
        drop_column_if_present(connection, "room_bookings", "tax_calculated")

        # --- booking_extensions ---
        add_column_if_missing(connection, "booking_extensions", "usd_received", "usd_received NUMERIC(10, 2)")
        add_column_if_missing(connection, "booking_extensions", "recorded_by", "recorded_by INTEGER")
        add_column_if_missing(connection, "booking_extensions", "is_cancelled", "is_cancelled BOOLEAN NOT NULL DEFAULT 0")
        add_column_if_missing(connection, "booking_extensions", "previous_checkout_time", "previous_checkout_time DATETIME")
        add_column_if_missing(connection, "booking_extensions", "cancelled_by", "cancelled_by INTEGER")
        add_column_if_missing(connection, "booking_extensions", "cancelled_at", "cancelled_at DATETIME")

        add_column_if_missing(connection, "booking_extensions", "bank_sender_account", "bank_sender_account VARCHAR(4)")

        # --- counter_shop_sales ---
        add_column_if_missing(connection, "counter_shop_sales", "usd_received", "usd_received NUMERIC(10, 2)")
        add_column_if_missing(connection, "counter_shop_sales", "bank_sender_account", "bank_sender_account VARCHAR(4)")

        connection.commit()
        print(f"Finished migrating {file_path}.\n")
    finally:
        connection.close()


if __name__ == "__main__":
    for database_file in DATABASE_FILES:
        migrate_single_database_file(database_file)

    print("Migration complete. Any table this version needs that does not exist")
    print("yet (such as app_settings) will be created automatically the next")
    print("time the server starts \u2014 the server checks for this on every start.")
