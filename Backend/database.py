# ====================================================================
# DATABASE CONNECTION HUB & DUAL-WRITE MIRROR LIFECYCLE CONTROLLER
# ====================================================================

# Import the core engine constructor to bridge network pipes directly to local storage files
from sqlalchemy import create_engine

# Import the modern declarative configuration base to structure your uppercase data models
from sqlalchemy.orm import DeclarativeBase

# Import the custom factory engine to spawn isolated database sessions for your api requests
from sqlalchemy.orm import sessionmaker

# Import structural event listeners to inject operational optimization flags on database startup
from sqlalchemy import event

# Import the shared HTTP error type used to report a failed dual-write cleanly to the caller
from fastapi import HTTPException

# Define the primary workspace path pointing directly to your active live database file
DATABASE_URL = "sqlite:///guesthouse.db"

# Define the independent backup pathway protecting your system transactions against disk corruption
MIRROR_DATABASE_URL = "sqlite:///guesthouse_mirror.db"


# --- PRIMARY WORKSPACE STORAGE ENGINE CONFIGURATION ---

# Instantiate the central database coordinator to manage standard counter read and write streams
engine = create_engine(
    DATABASE_URL,
    connect_args={
        # Set to False to allow multi-threaded background workers to securely share this single data pipe
        "check_same_thread": False,
        # Force the driver to wait up to 30.0 seconds in queue before throwing a database lock timeout
        "timeout": 30.0
    }
)


# --- DISK RESILIENCY BACKUP ENGINE CONFIGURATION ---

# Instantiate the parallel backup engine to intercept and clone live data updates instantly
mirror_engine = create_engine(
    MIRROR_DATABASE_URL,
    connect_args={
        # Maintain multi-threaded execution capabilities across your mirrored backup platform safely
        "check_same_thread": False,
        # Set matching 30.0 second timeout gates to maintain operational speed boundaries under load
        "timeout": 30.0
    }
)


# --- CONCURRENCY PERIMETER SHIELD: WAL-MODE SQLITE INJECTORS ---

# Bind a startup listener onto the primary connection core to execute instant hardware tuning flags
@event.listens_for(engine, "connect")
def set_sqlite_pragma(dbapi_connection, connection_record):
    # Establish a fast database cursor object to issue low-level query configurations directly
    cursor = dbapi_connection.cursor()
    # Enable Write-Ahead Logging to separate tracking lanes so read and write loops never block each other
    cursor.execute("PRAGMA journal_mode=WAL;")
    # Set to FULL rather than NORMAL: a guesthouse server is not guaranteed to
    # be on a UPS, and a power cut is a real, expected failure mode here, not
    # an edge case. FULL means every commit is actually flushed to disk before
    # it is considered saved, so a power cut can never lose a save that was
    # already confirmed back to the tablet. This costs a little write speed;
    # given the booking volume this system handles, that cost is not
    # noticeable, and losing a real transaction in a power cut would be far
    # more costly than the extra milliseconds this spends on every commit.
    cursor.execute("PRAGMA synchronous=FULL;")
    # Securely destroy the active connection cursor memory block to free up workspace ram spaces
    cursor.close()


# Bind an identical startup listener onto your mirror file system to lock down backup reliability boundaries
@event.listens_for(mirror_engine, "connect")
def set_mirror_pragma(dbapi_connection, connection_record):
    # Establish a tracking cursor across your secondary backup architecture files natively
    cursor = dbapi_connection.cursor()
    # Force the mirror framework to use WAL-mode to prevent multi-device tablet connection crashes
    cursor.execute("PRAGMA journal_mode=WAL;")
    # Same reasoning as the primary engine above: a lost save on only one of
    # the two files is exactly how they end up silently disagreeing with each
    # other, so both files get the same durability guarantee.
    cursor.execute("PRAGMA synchronous=FULL;")
    # Securely drop the active cursor pipeline reference to keep memory boundaries lightweight
    cursor.close()
# --- FIXED-POINT RUNTIME SESSION FACTORIES ---

# Construct the master session coordinator to spawn atomic data manipulation loops for your main file
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# Construct the parallel backup session coordinator to record matched mirror entries on the drive
MirrorSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=mirror_engine)


# --- DECLARATIVE BLUEPRINT SYSTEM SCHEMAS ---

# Build the structural foundation class that all uppercase relational database schemas will inherit from
class Base(DeclarativeBase):
    # Leave empty as this class functions purely as a blueprint template registration hub
    pass


# --- TABLE CREATION FOR BOTH DATABASE FILES ---

def create_missing_tables():
    """
    Creates any table that does not exist yet, in BOTH database files.

    The table definitions live in models.py (which has its own Base), so
    they are imported here, inside the function, to avoid the two files
    importing each other at start-up. Tables that already exist are left
    exactly as they are: this only ever adds what is missing, so it is
    safe to call every time the server starts.
    """
    import models
    models.Base.metadata.create_all(bind=engine)
    models.Base.metadata.create_all(bind=mirror_engine)


def check_mirror_consistency() -> list[str]:
    """
    A quick startup sanity check: counts every row in every table on both
    the primary and mirror database files and reports any table where the
    two counts do not match.

    This is meant to catch the one scenario the dual-write design cannot
    protect against by itself: a power cut that lands between the primary
    commit and the mirror commit in commit_dual_write, so one file ends up
    with a row the other one does not have. That should now be rare with
    synchronous=FULL, but "rare" is not "impossible", so this makes sure a
    drift like that gets noticed at the next startup instead of sitting
    unnoticed until someone needs the mirror and finds it does not match.

    Deliberately a row-count check, not a full row-by-row comparison: a
    full comparison would be slow to run on every startup, and a count
    mismatch is already enough to say "these two files need a person to
    look at them" without needing to pinpoint the exact row.

    Returns a list of plain-English warning lines (empty if everything
    matches). Never raises: a drift here is something to flag loudly, not
    something that should stop the server from starting, since the
    business still needs to run off the primary file.
    """
    import models

    from sqlalchemy import func, select

    warnings = []
    primary_session = SessionLocal()
    mirror_session = MirrorSessionLocal()
    try:
        for table_name, table in models.Base.metadata.tables.items():
            try:
                primary_count = primary_session.execute(select(func.count()).select_from(table)).scalar_one()
                mirror_count = mirror_session.execute(select(func.count()).select_from(table)).scalar_one()
            except Exception as e:
                # A table missing from one file entirely is itself worth
                # flagging, not silently skipping.
                warnings.append(f"  - {table_name}: could not be compared ({e}).")
                continue

            if primary_count != mirror_count:
                warnings.append(
                    f"  - {table_name}: primary has {primary_count} row(s), mirror has {mirror_count} row(s)."
                )
    finally:
        primary_session.close()
        mirror_session.close()

    return warnings


# --- CONTEXT-DRIVEN HARDWARE RESOURCE GENERATORS ---

# Design the primary gateway function that feeds clean database pipelines into your fastapi routes
def get_db():
    """
    Spawns clean database connection session matrices for every incoming device api request.
    Packages BOTH primary and secondary mirror data sessions into a paired structural tuple.
    Forces global system rollbacks across both files if an application runtime failure occurs.
    """
    # Instantiate an active transactional window pointing straight into your primary database file
    db = SessionLocal()
    # Instantiate a secondary mirror transactional window to keep backup lines cleanly synchronized
    mirror_db = MirrorSessionLocal()
    
    # Open the operational try block to begin delivering memory assets to your network layers
    try:
        # 🚀 THE CRITICAL LAYER UPDATE: Yield both sessions bundled together as a single paired package tuple
        yield (db, mirror_db)
    # Catch any unexpected server errors or backend code exceptions mid-stream
    except Exception:
        # Force a complete database level structural rollback on your main file to guard state continuity
        db.rollback()
        # Mirror the exact same rollback structure on your backup file to prevent broken record tracks
        mirror_db.rollback()
        # Escalate the error up the software line so your system administrators can log the crash
        raise
    # Execute the final execution cleanup sequence regardless of whether the transaction passed or failed
    finally:
        # Terminate the primary communication pipe and return the socket asset back to the central engine pool
        db.close()
        # Securely sever the backup engine connection link to free up local computer memory spacing
        mirror_db.close()


# --- LINKED DUAL-DATABASE COMMIT HELPER ---

def commit_dual_write(db, mirror_db, new_db_records=None, restore_snapshots=None, deleted_records=None):
    """
    Saves to the main database, then the backup database, as a single linked
    action: either both succeed, or neither does.

    If saving to the backup fails after the main save already went through,
    this undoes whatever changed on the main database, putting it back to
    matching the backup. The caller then gets a clean error, so a retry is
    always safe and can never create a duplicate or leave a stray change.

    new_db_records: brand new objects that were just added with db.add(...).
    These are simply deleted if the backup save fails.

    restore_snapshots: for records that already existed and just had fields
    changed (not newly added or deleted), a list of (record, {field_name:
    old_value}) pairs. These fields are set back to their old values if
    the backup save fails.

    deleted_records: for records that were just removed with db.delete(...),
    a list of (ModelClass, {field_name: value}) pairs describing what the
    record looked like beforehand. These are recreated if the backup save
    fails.
    """
    try:
        db.commit()
    except Exception:
        db.rollback()
        raise HTTPException(status_code=500, detail="Save failed. Try again.")

    try:
        mirror_db.commit()
    except Exception:
        mirror_db.rollback()

        # Undo new rows by removing them.
        if new_db_records:
            for record in new_db_records:
                db.delete(record)

        # Undo changed fields by restoring their prior values.
        if restore_snapshots:
            for record, old_values in restore_snapshots:
                for field_name, old_value in old_values.items():
                    setattr(record, field_name, old_value)

        # Undo a deletion by recreating the record from its saved details.
        if deleted_records:
            for model_class, field_values in deleted_records:
                db.add(model_class(**field_values))

        db.commit()
        # The wording shown to staff is kept plain on purpose: it never mentions
        # the second database. Everything already saved on the main database was
        # undone above, so trying again is always safe.
        raise HTTPException(status_code=500, detail="Save failed. Try again.")
