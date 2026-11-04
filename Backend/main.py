# ====================================================================
# FASTAPI BACKEND SYSTEM CORE ENGINE - PART 1: MODULE INITIALIZATION
# ====================================================================

# Import structural system date and time libraries for accurate timezone logs
import datetime

# Import calendar helper engines to isolate dates and determine days in months
import calendar

# Import the native plain-text table handler to write un-corruptible shift sheets
import csv

# Import the host operating system utility to read secure hardware variables
import os

# Import a secure random generator, used to make the server's own secret key
# and the temporary passwords a manager hands to a receptionist
import secrets

# Import file-copy tools, used to keep employee photos and the dated database
# copy in the backup folder when a shift closes
import shutil

# Import the built-in SQLite driver, used to take a safe, consistent copy of
# the live database while the server is still running
import sqlite3

# Import the pattern-matching tools used to check usernames and the
# ending of a pesewa amount
import re

# Import the type helper used to mark a field as optional
from typing import Optional

# Import JSON processing tools to manipulate structural currency strings safely
import json

# Import a collision-free identifier generator, used to name uploaded photo files uniquely
import uuid

# Import the in-memory byte buffer, used to check and redraw an uploaded photo
# without writing the original to disk
import io

# Import the image library that opens an uploaded photo as a real picture,
# so only genuine pixels are ever saved
from PIL import Image, ImageOps

# Import JSON Web Token tools to encode and decode signed user session identifiers
import jwt

# Import cryptographic hashing utilities to verify secure password matches safely
import bcrypt

# Link directly to your uppercase relational schemas tracking data models on disk
import models

# Import the high-precision decimal math structure to block floating point leak holes
from decimal import Decimal

# Import the central FastAPI tracking app frameworks and routing dependencies
from fastapi import FastAPI, Depends, HTTPException, status, Security, Request, BackgroundTasks, UploadFile, File

# Import security bearer schemas to catch token strings out of connection headers
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials, OAuth2PasswordRequestForm

# Import cross-origin rules to open communication pipelines safely over local Wi-Fi
from fastapi.middleware.cors import CORSMiddleware 

# Import structured JSON responses to ship clean error logs back to desk tablets
from fastapi.responses import JSONResponse 

# Import the static file server used to serve uploaded employee passport photos back to the app
from fastapi.staticfiles import StaticFiles

# Import logic filters from the database core to merge complex sub-queries cleanly
from sqlalchemy import and_, func, or_

# Import active session pipelines to manage individual transaction operations
from sqlalchemy.orm import Session

# Import form data flooding protective schemas from the central Pydantic tier
from pydantic import BaseModel, Field, field_validator

# Import network connection tools to execute background external lookups smoothly
import requests

# Import all your database engine pipes and tracking sessions from your config file
from database import (
    engine, mirror_engine, Base, get_db, SessionLocal, MirrorSessionLocal,
    commit_dual_write, create_missing_tables, check_mirror_consistency,
)



# Instantiate the central FastAPI application core engine
app = FastAPI(title="Hardened Guest House ERP Engine v3.0 [OFFLINE LINKED]")





# Create any table that does not exist yet, in BOTH database files, every
# time the server starts. Tables that already exist are never touched, so
# this is safe to run on the live databases. Both files are always checked
# against the full set of table definitions, so the mirror file cannot be
# left missing a table.
create_missing_tables()


# --------------------------------------------------------------------
# THE ONE NAME RULE
# --------------------------------------------------------------------
# Every name typed anywhere in the app (guest, employee, room type, shop
# item, daily-cost item) goes through canonical_name() before it is saved,
# so "mineral water", "MINERAL WATER" and "mInEral wAter" are all stored as
# "Mineral Water". The Flutter app applies the very same rule while typing
# (capitalize_words_formatter.dart), but the server does not trust the app:
# this is the version that decides what is actually stored, so no screen,
# old tablet or queued offline action can ever store a different spelling.
#
# The rule, in plain words:
#   1. A word containing a digit is kept exactly as typed ("A4", "B12").
#   2. A word typed in capitals, four letters or fewer, is an abbreviation
#      or brand and is kept as typed ("TV", "AC", "UP", "USB", "WIFI") ...
#   3. ... UNLESS the whole entry is typed in capitals and has more than
#      one word ("MINERAL WATER" is shouting, not two abbreviations).
#      An entry that is just one such word ("TV") is kept as typed.
#   4. Every other word: first letter capital, the rest lowercase.
# Letters after a hyphen also start a word ("mary-jane" -> "Mary-Jane").
# Extra spaces are squeezed to one and the ends are trimmed.
def _canonical_word(word: str) -> str:
    out = []
    start_of_part = True
    for ch in word:
        if ch.isalpha():
            out.append(ch.upper() if start_of_part else ch.lower())
            start_of_part = False
        else:
            out.append(ch)
            start_of_part = (ch == "-")
    return "".join(out)


def canonical_name(text, keep_abbreviations=True):
    """
    keep_abbreviations=False is used for the names of PEOPLE (guests and
    employees): a short name typed in capitals such as "KOFI" or "AMA" is
    a name, not an abbreviation, so it becomes "Kofi" / "Ama". Rules 2 and 3
    below (the abbreviation exception) therefore only apply to things like
    shop items, room types and cost items, where TV, AC and A4 live.
    """
    if text is None:
        return text
    words = str(text).split()
    if not words:
        return ""
    letters = [c for c in " ".join(words) if c.isalpha()]
    whole_entry_in_capitals = len(words) > 1 and bool(letters) and all(c.isupper() for c in letters)

    cleaned = []
    for word in words:
        if any(c.isdigit() for c in word):
            cleaned.append(word)
        elif keep_abbreviations and (not whole_entry_in_capitals) and word.isalpha() and word.isupper() and len(word) <= 4:
            cleaned.append(word)
        else:
            cleaned.append(_canonical_word(word))
    return " ".join(cleaned)


def _tidy_one_database(session) -> int:
    """
    Rewrites every stored name into its final form, so every entry reads
    the same in Records, Business Summary and Shop Sales. Only the spelling
    of a name changes, never an amount, a date or any payroll figure. Safe to run on every start: a name that is
    already in its final form is left untouched.
    """
    changed = 0
    for model_class, column, keeps_abbreviations in (
        (models.Booking, "guest_name", False),
        (models.AncillarySale, "item_name", True),
        (models.Payroll, "employee_name", False),
        (models.DailyExpense, "item_or_reason", True),
        (models.RoomAsset, "description", True),
    ):
        for row in session.query(model_class).all():
            current = getattr(row, column)
            tidy = canonical_name(current, keeps_abbreviations)
            if current is not None and tidy != current:
                setattr(row, column, tidy)
                changed += 1
    session.commit()
    return changed


def tidy_stored_names():
    """Runs the tidy above on BOTH database files at start-up. Never raises."""
    for session_factory in (SessionLocal, MirrorSessionLocal):
        session = session_factory()
        try:
            _tidy_one_database(session)
        except Exception as error:
            session.rollback()
            print(f"WARNING: could not tidy stored names: {error}")
        finally:
            session.close()

# Bring names saved before the name rule existed into the same form.
tidy_stored_names()

# A quick sanity check that the primary and mirror files still agree with
# each other, run once at every startup. This is only ever expected to
# find something after an unclean shutdown (a power cut mid-write); it
# never blocks the server from starting, since the business still needs
# to run off the primary file either way, but it prints clearly so a
# mismatch gets a person's attention instead of going unnoticed.
_mirror_drift_warnings = check_mirror_consistency()
if _mirror_drift_warnings:
    print("=" * 66)
    print("  WARNING: the primary and mirror databases do not match.")
    print("=" * 66)
    for _line in _mirror_drift_warnings:
        print(_line)
    print("This can happen after a power cut during a save. The server will")
    print("still start and run normally off the primary database, but this")
    print("mismatch should be looked at directly rather than left as is.")
    print("=" * 66)

# The server will not start without an administrator account. The first
# account is created once, by hand, with "python security.py", which asks
# for the password. Nothing is created automatically with a built-in password.
_startup_check_session = SessionLocal()
try:
    if not _startup_check_session.query(models.User).filter(models.User.role == "Owner").first():
        raise RuntimeError(
            "No administrator account was found. Run 'python security.py' once to create it, then start the server again."
        )
finally:
    _startup_check_session.close()



# --- SECURE CRYPTOGRAPHIC SETTINGS ---
# The key that signs every login token. There is no built-in key in the code.
# An environment variable is used if one is set; otherwise the server reads
# its own key from a file next to it, and on the very first start it makes a
# fresh random key and saves it there. The key file must be kept private and
# must not be copied to other machines.
SECRET_KEY_FILE = "server_secret.key"


def load_or_create_secret_key() -> str:
    """
    Returns the signing key for login tokens, creating and saving a new
    random one the first time this ever runs.
    """
    from_environment = os.getenv("GUESTHOUSE_SECRET_KEY")
    if from_environment:
        return from_environment
    if os.path.exists(SECRET_KEY_FILE):
        with open(SECRET_KEY_FILE, "r", encoding="utf-8") as key_file:
            saved_key = key_file.read().strip()
        if saved_key:
            return saved_key
    new_key = secrets.token_urlsafe(64)
    with open(SECRET_KEY_FILE, "w", encoding="utf-8") as key_file:
        key_file.write(new_key)
    return new_key


SECRET_KEY = load_or_create_secret_key()
ALGORITHM = "HS256" 
ACCESS_TOKEN_EXPIRE_MINUTES = 120  # Sets a practical balance for on-premises shift durations
security_bearer = HTTPBearer() 



# --- HARDWARE-LAYER NETWORK SEPARATION ENGINE ---
# The three address lists are read from network_config.json, which sits in the
# same folder as this file. The server does not start if the file is missing
# or does not contain all three lists.
NETWORK_CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "network_config.json")


def load_network_config(config_path):
    """Reads the three address lists from the configuration file and stops the server if they cannot be read."""
    if not os.path.isfile(config_path):
        raise SystemExit(f"Startup stopped: network configuration file not found at {config_path}")
    try:
        with open(config_path, "r", encoding="utf-8") as config_file:
            config = json.load(config_file)
    except (OSError, ValueError) as read_error:
        raise SystemExit(f"Startup stopped: network configuration file could not be read ({read_error})")
    required_keys = ("DEVELOPMENT_LOOPBACK_TIER", "MANAGER_HARDWARE_TIER", "RECEPTION_HARDWARE_TIER")
    for key in required_keys:
        value = config.get(key) if isinstance(config, dict) else None
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            raise SystemExit(f"Startup stopped: network configuration entry '{key}' must be a list of address strings")
    return config


_NETWORK_CONFIG = load_network_config(NETWORK_CONFIG_PATH)
# Local diagnostic addresses allowing testing scripts to verify configurations on-device
DEVELOPMENT_LOOPBACK_TIER = _NETWORK_CONFIG["DEVELOPMENT_LOOPBACK_TIER"]
# Addresses belonging to the workstation and the manager's laptop
MANAGER_HARDWARE_TIER = _NETWORK_CONFIG["MANAGER_HARDWARE_TIER"]
# Addresses belonging to the front-desk counter tablets
RECEPTION_HARDWARE_TIER = _NETWORK_CONFIG["RECEPTION_HARDWARE_TIER"]



# --- SECURITY HOOKS: HARDWARE-LAYER PRIVILEGE ENFORCEMENT ---
def enforce_managerial_hardware_gate(request: Request):
    """
    Validates that an incoming operational request originates strictly from an administrative hardware node.
    """
    client_ip = request.client.host
    if client_ip not in MANAGER_HARDWARE_TIER and client_ip not in DEVELOPMENT_LOOPBACK_TIER:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="ACCESS DENIED: This operation is restricted strictly to Manager terminals."
        )


def enforce_global_network_perimeter(request: Request):
    """
    Global network perimeter check used by the application firewall middleware.
    """
    client_ip = request.client.host
    all_valid_devices = DEVELOPMENT_LOOPBACK_TIER + MANAGER_HARDWARE_TIER + RECEPTION_HARDWARE_TIER
    if client_ip not in all_valid_devices:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="ACCESS DENIED: Device address is untrusted on this local router network."
        )


# --- DATA FLOODING INTAKE PROTECTION (Pydantic Frameworks with Fixed-Point Decimals) ---
class RoomPricingSubmission(BaseModel):
    room_id: str = Field(..., max_length=10)
    duration_hours: int = Field(..., ge=1, le=48)
    price: Decimal = Field(..., ge=0)
    client_action_id: str = Field(None, max_length=100)


class DescriptionPricingSubmission(BaseModel):
    """
    Submitted when a manager sets a duration and price for every room that
    shares a given description, rather than for a single room at a time.
    Rooms with the same description (for example, several identical
    standard rooms) are treated as one group here, since a real guesthouse
    prices them identically rather than negotiating each one separately.
    """
    description: str = Field(..., max_length=255)
    duration_hours: int = Field(..., ge=1, le=48)
    price: Decimal = Field(..., ge=0)
    client_action_id: str = Field(None, max_length=100)

    @field_validator("description")
    @classmethod
    def _tidy_description(cls, value):
        # The one name rule (see canonical_name above).
        return canonical_name(value)


class BookingSubmission(BaseModel):
    room_number: str = Field(..., max_length=10)
    guest_name: str = Field(..., max_length=100)
    guest_phone: str = Field(..., max_length=20)
    duration_hours: int = Field(..., ge=1, le=24)  # Out-of-Bounds time-bomb protective gate
    payment_mode: str = Field("CASH", max_length=10)  
    currency_used: str = Field("GHS", max_length=10)  

    # Cash received, always in cedis. When a guest pays in dollars, the tablet
    # converts the dollars to cedis first and sends only the cedi figure here.
    cash_tendered: Decimal = Field(..., ge=0)

    # Change handed back, always in cedis, worked out by the tablet.
    change_returned: Decimal = Field(default=Decimal("0.00"), ge=0)

    # Only when the guest paid in dollars: the dollars handed over, kept as a note.
    usd_received: Decimal = Field(default=None, ge=0)

    momo_number: str = Field(None, max_length=10)  # Exactly 10 digits when paying by MoMo
    bank_sender_account: str = Field(None, max_length=4)  # Last four digits of the sender's account, bank transfers only
    client_action_id: str = Field(None, max_length=100)  # One-time tag set by the tablet for safe offline retries    

    # The moment the receptionist pressed confirm on the tablet. Used as the
    # booking time so a booking saved while the server was unreachable never
    # gives the guest extra time.
    client_time: str = Field(None, max_length=40)

    # The username of the person who made this booking on the tablet.
    acted_by_username: str = Field(None, max_length=100)

    @field_validator("guest_name")
    @classmethod
    def _tidy_guest_name(cls, value):
        # The one name rule (see canonical_name above); a person's name
        # never keeps an "abbreviation" capital run, so KOFI becomes Kofi.
        return canonical_name(value, keep_abbreviations=False)


class BookingExtensionSubmission(BaseModel):
    """
    Submitted when a receptionist adds extra time to an already-occupied or
    time-expired booking. The additional_hours value must match one of the
    room's own manager-approved durations, exactly like a fresh booking, so
    an extension can never be granted at a price nobody approved.
    """
    additional_hours: int = Field(..., ge=1, le=48)
    payment_mode: str = Field("CASH", max_length=10)
    cash_tendered: Decimal = Field(..., ge=0)          # Cash received, always in cedis
    change_returned: Decimal = Field(default=Decimal("0.00"), ge=0)  # Change given, always in cedis
    usd_received: Decimal = Field(default=None, ge=0)  # Dollars handed over, only when paid in dollars
    momo_number: str = Field(None, max_length=10)
    bank_sender_account: str = Field(None, max_length=4)  # Last four digits of the sender's account, bank transfers only
    client_action_id: str = Field(None, max_length=100)
    client_time: str = Field(None, max_length=40)      # When the receptionist pressed confirm
    acted_by_username: str = Field(None, max_length=100)


class AncillaryItemSubmission(BaseModel):
    item_name: str = Field(..., max_length=100)
    quantity: int = Field(..., ge=1)
    unit_price: Decimal
    payment_mode: str = Field("CASH", max_length=10)
    cash_tendered: Decimal = Field(default=Decimal("0.00"), ge=0)   # Cash received, always in cedis
    change_returned: Decimal = Field(default=Decimal("0.00"), ge=0) # Change given, always in cedis
    usd_received: Decimal = Field(default=None, ge=0)               # Dollars handed over, only when paid in dollars
    momo_number: str = Field(None, max_length=10)
    bank_sender_account: str = Field(None, max_length=4)  # Last four digits of the sender's account, bank transfers only
    client_action_id: str = Field(None, max_length=100)  # One-time tag set by the tablet for safe offline retries   
    client_time: str = Field(None, max_length=40)        # When the receptionist pressed confirm
    acted_by_username: str = Field(None, max_length=100)


    @field_validator("item_name")
    @classmethod
    def _tidy_item_name(cls, value):
        # The one name rule (see canonical_name above).
        return canonical_name(value)


class ChangeLoginSubmission(BaseModel):
    """
    Submitted by the manager on the Change Login screen. The manager picks
    an employee and changes the username, the password, or both. The
    manager's own password is required as confirmation, so a phone left
    unlocked cannot be used to take over someone's account.
    """
    target_username: str = Field(..., max_length=100)
    new_username: str = Field(None, max_length=100)
    new_password: str = Field(None, min_length=8)

    # True when the manager is handing over a temporary password (for
    # example after "Forgot password?"). The receptionist must then choose
    # their own password at their next login.
    is_temporary_password: bool = Field(default=False)

    manager_password: str = Field(..., min_length=1)
    client_action_id: str = Field(None, max_length=100)


class OwnPasswordChangeSubmission(BaseModel):
    """Submitted by any logged-in person choosing their own new password."""
    current_password: str = Field(..., min_length=1)
    new_password: str = Field(..., min_length=8)


class AdministratorRecoverySubmission(BaseModel):
    """Submitted from "Forgot password?" by the administrator, using the recovery code."""
    recovery_code: str = Field(..., min_length=1, max_length=100)
    new_password: str = Field(..., min_length=8)


class ExchangeRateSubmission(BaseModel):
    """
    The dollar-to-cedi rate, looked up by the manager's phone (the only
    device with internet) and sent here so the server and the tablets share
    one figure.
    """
    usd_to_ghs_rate: Decimal = Field(..., gt=0, lt=1000)
    client_action_id: str = Field(None, max_length=100)


class BackupFolderSubmission(BaseModel):
    """The folder on the server where the dated copy of the database is saved."""
    backup_folder: str = Field(..., min_length=1, max_length=300)
    client_action_id: str = Field(None, max_length=100)
    client_action_id: str = Field(None, max_length=100)  # One-time tag set by the tablet for safe offline retries



# The only roles an employee record can hold. Adding and editing an employee
# are held to this same list, so an edit can never save a role that adding
# one would have refused.
ALLOWED_EMPLOYEE_ROLES = ("Receptionist", "Manager", "Cleaner", "Security")


def _check_employee_role(value: str) -> str:
    cleaned = value.strip()
    if cleaned not in ALLOWED_EMPLOYEE_ROLES:
        raise ValueError("Role must be one of: " + ", ".join(ALLOWED_EMPLOYEE_ROLES) + ".")
    return cleaned


class EmployeeOnboardSubmission(BaseModel):
    employee_name: str = Field(..., max_length=100)
    role: str = Field(..., max_length=50)
    monthly_salary: Decimal = Field(..., ge=0)

    # Only used when the role is Receptionist: the login this person will use.
    username: str = Field(None, max_length=100)
    password: str = Field(None, min_length=8)

    client_action_id: str = Field(None, max_length=100)  # One-time tag set by the tablet for safe offline retries

    @field_validator("employee_name")
    @classmethod
    def _tidy_employee_name(cls, value):
        # The one name rule (see canonical_name above); a person's name
        # never keeps an "abbreviation" capital run, so KOFI becomes Kofi.
        return canonical_name(value, keep_abbreviations=False)

    @field_validator("role")
    @classmethod
    def _valid_role(cls, value):
        return _check_employee_role(value)


class EmployeeEditSubmission(BaseModel):
    """
    Submitted when a manager edits an existing employee. The employee's
    name is deliberately not accepted here: it stays fixed once the record
    is created, since it has no real business need to change and doing so
    would only risk confusing payroll and booking history tied to that name.

    username/password are only used when the role is being changed TO
    Receptionist for someone who does not already have a login (the same
    step onboarding takes) — the app must prompt for these first, the same
    way it does when onboarding a brand-new receptionist.
    """
    role: str = Field(..., max_length=50)
    monthly_salary: Decimal = Field(..., ge=0)
    username: str = Field(None, max_length=100)
    password: str = Field(None, min_length=8)
    client_action_id: str = Field(None, max_length=100)

    @field_validator("role")
    @classmethod
    def _valid_role(cls, value):
        return _check_employee_role(value)


class RoomAssetSubmission(BaseModel):
    room_name: str = Field(..., max_length=50)
    description: str = Field(..., max_length=255)
    client_action_id: str = Field(None, max_length=100)  # One-time tag set by the tablet for safe offline retries

    @field_validator("description")
    @classmethod
    def _tidy_description(cls, value):
        # The one name rule (see canonical_name above).
        return canonical_name(value)


class RoomEditSubmission(BaseModel):
    """
    Submitted when a manager edits an existing room. The room name is
    deliberately not accepted here: it is also the room's permanent
    database identifier and is already linked to that room's pricing
    entries and booking history, so it stays fixed once created.
    """
    description: str = Field(..., max_length=255)
    client_action_id: str = Field(None, max_length=100)

    @field_validator("description")
    @classmethod
    def _tidy_description(cls, value):
        # The one name rule (see canonical_name above).
        return canonical_name(value)


class DailyExpenseSubmission(BaseModel):
    item_or_reason: str = Field(..., max_length=200)
    amount_spent: Decimal = Field(..., ge=0)
    category: str = Field(..., max_length=20)
    client_action_id: str = Field(None, max_length=100)

    @field_validator("category")
    @classmethod
    def validate_category(cls, value):
        if value not in ("UTILITIES", "EXPENDABLES"):
            raise ValueError("Category must be either UTILITIES or EXPENDABLES.")
        return value

    @field_validator("item_or_reason")
    @classmethod
    def _tidy_item_or_reason(cls, value):
        # The one name rule (see canonical_name above).
        return canonical_name(value)


class DailyExpenseEditSubmission(BaseModel):
    item_or_reason: str = Field(..., max_length=200)
    amount_spent: Decimal = Field(..., ge=0)
    client_action_id: str = Field(None, max_length=100)

    @field_validator("item_or_reason")
    @classmethod
    def _tidy_item_or_reason(cls, value):
        # The one name rule (see canonical_name above).
        return canonical_name(value)




# --- OFFLINE-RETRY SAFETY NET: ACTION TAG HELPERS ---

def find_previously_processed_action(db, client_action_id: str):
    """
    Looks up whether this action tag has already been saved before. Used so
    a retried offline action from a tablet can never be saved twice. If
    found, returns the exact response given the first time; otherwise None.
    """
    if not client_action_id:
        return None
    existing = db.query(models.ProcessedClientAction).filter(
        models.ProcessedClientAction.client_action_id == client_action_id
    ).first()
    return json.loads(existing.response_payload) if existing else None


def build_processed_action_records(client_action_id: str, response_payload: dict):
    """
    Prepares the main and mirror tracking rows for a freshly processed
    action tag, ready to be added alongside the real save and committed
    together as one linked action.
    """
    if not client_action_id:
        return None, None
    payload_text = json.dumps(response_payload)
    main_record = models.ProcessedClientAction(client_action_id=client_action_id, response_payload=payload_text)
    mirror_record = models.ProcessedClientAction(client_action_id=client_action_id, response_payload=payload_text)
    return main_record, mirror_record


# --- WHEN AN ACTION REALLY HAPPENED, AND WHO DID IT ---

# How far into the future a tablet's clock may be before it is ignored, and
# how old a saved action may be before its time is no longer trusted. An
# action older than this still gets saved; it is simply stamped with the
# moment the server received it.
MAX_CLIENT_CLOCK_AHEAD = datetime.timedelta(minutes=5)
MAX_CLIENT_ACTION_AGE = datetime.timedelta(days=7)


def resolve_action_time(client_time: Optional[str]) -> datetime.datetime:
    """
    Returns the moment an action really happened, as a naive UTC time (the
    form used everywhere else in the database).

    A tablet that was cut off from the server saves the action with the time
    the receptionist pressed confirm, and sends it later. Using that time,
    not the moment it finally arrives, is what stops a guest getting extra
    time. If the tablet sent no time, or a time that makes no sense (far in
    the future, or very old), the server's own clock is used instead.
    """
    now = datetime.datetime.utcnow()
    if not client_time:
        return now
    try:
        parsed = datetime.datetime.fromisoformat(client_time.replace("Z", "+00:00"))
    except ValueError:
        return now
    if parsed.tzinfo is not None:
        parsed = parsed.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    if parsed > now + MAX_CLIENT_CLOCK_AHEAD:
        return now
    if parsed < now - MAX_CLIENT_ACTION_AGE:
        return now
    # A time only slightly ahead of the server is treated as "now".
    return min(parsed, now)


def resolve_acting_user(db, current_user: models.User, acted_by_username: Optional[str]) -> models.User:
    """
    Decides which person an action is credited to.

    Normally that is whoever is logged in. But an action saved while the
    server was unreachable may be sent later, after that person has logged
    out and someone else has logged in. The tablet therefore writes the
    username of the person who made the action into it, and the server
    credits that person instead.

    The claim is only honoured for a real, active receptionist account, and
    only when the request itself comes from a logged-in receptionist or
    manager (every request here already does). Anything else falls back to
    the logged-in user.
    """
    if not acted_by_username or acted_by_username.strip() == current_user.username:
        return current_user
    claimed_user = db.query(models.User).filter(
        models.User.username == acted_by_username.strip(),
        models.User.role.in_(["Receptionist", "Buffer"]),
        models.User.is_active == True
    ).first()
    return claimed_user if claimed_user else current_user


def validate_cash_payment(payment_mode: str, price: Decimal, cash_tendered: Decimal, change_returned: Decimal) -> Decimal:
    """
    The safety check on cash handling: the cash received must cover the price
    plus the change given back. The business can never hand back more than
    it took in. Returns the change to be recorded (always zero for MoMo and
    bank transfers, where no change is given). A transfer must still bring in
    at least the price; anything above it is recorded as an extra.
    """
    if payment_mode in ("MOMO", "BANK"):
        if cash_tendered.quantize(Decimal("0.01")) < price:
            raise HTTPException(status_code=400, detail="The amount received is less than the price.")
        return Decimal("0.00")
    if payment_mode != "CASH":
        return Decimal("0.00")
    if cash_tendered < price + change_returned:
        raise HTTPException(status_code=400, detail="Insufficient currency tendered.")
    return change_returned


def check_transfer_details(payload) -> Optional[str]:
    """
    Checks the details that go with a transfer payment and returns the
    sender's account digits to store (None for any other payment type).
      - MOMO: the wallet number must be exactly 10 digits, and the payment
        is in cedis only (MoMo does not move dollars).
      - BANK: the sender's account must be exactly 4 digits.
    """
    mode = payload.payment_mode
    if mode not in ("CASH", "USD", "MOMO", "BANK"):
        raise HTTPException(status_code=400, detail="Unknown payment type.")
    if mode == "MOMO" and (not payload.momo_number or len(payload.momo_number.strip()) != 10):
        raise HTTPException(status_code=400, detail="Momo Verification Failure: 10-Digit number required.")
    if mode == "MOMO" and payload.usd_received:
        raise HTTPException(status_code=400, detail="MoMo payments are in cedis only.")
    if mode == "BANK":
        digits = (payload.bank_sender_account or "").strip()
        if len(digits) != 4 or not digits.isdigit():
            raise HTTPException(status_code=400, detail="Bank Transfer: the sender's account needs exactly 4 digits.")
        return digits
    return None


def clean_new_password(password: str) -> str:
    """Turns a plain password into the scrambled form that is stored."""
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def is_valid_username(username: str) -> bool:
    """Usernames are 3 to 30 letters, numbers, dots, dashes or underscores."""
    return bool(re.fullmatch(r"[A-Za-z0-9._-]{3,30}", username or ""))


# --- NETWORK GATEWAY PERIMETER MIDDLEWARE ---
# --- LOGIN RECORD HELPERS ---
def _record_blocked_login_attempt(client_ip: Optional[str]):
    """
    Writes one BLOCKED row in the Login Record for a login request that came
    from a device address the firewall does not recognise. The request never
    reaches the login itself, so the username is not known. A device that
    keeps hammering the login is written down at most once every ten
    seconds, so a flood of requests cannot fill the records.
    Never raises: failing to write this down must not change the refusal.
    """
    primary_session = SessionLocal()
    mirror_session = MirrorSessionLocal()
    try:
        recent_cutoff = datetime.datetime.utcnow() - datetime.timedelta(seconds=10)
        already_recorded = primary_session.query(models.LoginRecord).filter(
            models.LoginRecord.outcome == "BLOCKED",
            models.LoginRecord.client_ip == client_ip,
            models.LoginRecord.attempted_at >= recent_cutoff,
        ).first()
        if already_recorded:
            return
        for session in (primary_session, mirror_session):
            session.add(models.LoginRecord(
                username_tried="(not read)", outcome="BLOCKED", client_ip=client_ip,
                role=None, flag_note="Device address is not on the approved list; refused before login.",
            ))
        primary_session.commit()
        mirror_session.commit()
    except Exception:
        primary_session.rollback()
        mirror_session.rollback()
    finally:
        primary_session.close()
        mirror_session.close()


def _record_login_attempt(db_tuple, username_tried: str, outcome: str, client_ip: Optional[str], role: Optional[str], flag_note: Optional[str]):
    """
    Writes one row in the Login Record for a login that reached the server,
    on both database files. Never raises: if the record cannot be saved the
    login itself carries on exactly as it would have.
    """
    db, mirror_db = db_tuple
    try:
        primary_row = models.LoginRecord(
            username_tried=username_tried[:100], outcome=outcome, client_ip=client_ip, role=role, flag_note=flag_note,
        )
        mirror_row = models.LoginRecord(
            username_tried=username_tried[:100], outcome=outcome, client_ip=client_ip, role=role, flag_note=flag_note,
        )
        db.add(primary_row)
        mirror_db.add(mirror_row)
        commit_dual_write(db, mirror_db, new_db_records=[primary_row])
    except Exception:
        db.rollback()
        mirror_db.rollback()


@app.middleware("http")
async def ip_firewall_gateway(request: Request, call_next):
    """
    Intercepts incoming socket traffic and blocks unauthorized device IPs instantly.
    """
    try:
        enforce_global_network_perimeter(request)
    except HTTPException as e:
        # A refused attempt to reach the login is worth showing the manager
        # in the Login Record, so it is written down before the refusal.
        if request.method == "POST" and request.url.path.rstrip("/") == "/auth/login":
            _record_blocked_login_attempt(request.client.host if request.client else None)
        return JSONResponse(status_code=e.status_code, content={"detail": e.detail})
    return await call_next(request)


# --- CORSMIDDLEWARE WI-FI PERIMETER REALIGNMENT ---
# Registered after the IP firewall so it wraps around it. This way, even a
# request rejected by the firewall still gets a proper CORS header attached,
# so a browser client (like Flutter web) can actually read the real error
# message instead of reporting a raw, unexplained network failure.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,        
    allow_methods=["*"],           
    allow_headers=["*"],           
)


# --- EMPLOYEE PASSPORT PHOTO STORAGE ---
# Uploaded photos are saved to a local folder on disk and served back out
# under the /employee-photos/ URL path, the same way the rest of this
# on-premises setup keeps everything self-contained without needing an
# external file hosting service.
EMPLOYEE_PHOTO_STORAGE_DIRECTORY = "employee_photos"
os.makedirs(EMPLOYEE_PHOTO_STORAGE_DIRECTORY, exist_ok=True)

def _delete_employee_photo_file(stored_file_name: str) -> None:
    """
    Deletes one stored passport photo by its file name. Only a plain file
    name inside the photo folder is ever accepted, and a file that is
    already gone is not an error.
    """
    if not stored_file_name or stored_file_name != os.path.basename(stored_file_name):
        return
    try:
        os.remove(os.path.join(EMPLOYEE_PHOTO_STORAGE_DIRECTORY, stored_file_name))
    except OSError:
        pass


# Limits applied to every uploaded passport photo.
MAX_EMPLOYEE_PHOTO_BYTES = 2 * 1024 * 1024
MAX_EMPLOYEE_PHOTO_PIXELS = 25_000_000
EMPLOYEE_PHOTO_OUTPUT_PIXELS = 600
ALLOWED_EMPLOYEE_PHOTO_FORMATS = {"JPEG", "PNG", "WEBP"}
app.mount("/employee-photos", StaticFiles(directory=EMPLOYEE_PHOTO_STORAGE_DIRECTORY), name="employee-photos")


# --- CRYPTOGRAPHIC SIGNATURE GENERATORS ---
def create_access_token(data: dict):
    """
    Computes an encrypted web signature encoded with an expiration tracking timestamp.
    """
    to_encode = data.copy()
    expire = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode.update({"exp": int(expire.timestamp())})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)

def get_current_user(credentials: HTTPAuthorizationCredentials = Security(security_bearer), db_tuple: tuple = Depends(get_db)):
    """
    Decodes the incoming token and extracts the authenticated user profile.
    Peels the primary tracking session from the synchronized tuple dependency for identity validation.
    """
    db = db_tuple[0]  # Extract primary tracking engine session

    # One plain message is used for every way a login can stop being valid
    # (expired, tampered with, or the account was removed). The apps look for
    # the 401 status and send the person back to the login screen.
    session_ended = HTTPException(status_code=401, detail="Your session has ended. Please log in again.")

    try:
        payload = jwt.decode(credentials.credentials, SECRET_KEY, algorithms=[ALGORITHM])
        username: str = payload.get("sub")
        token_version: int = payload.get("tv")
        if username is None: raise session_ended
    except jwt.PyJWTError:
        raise session_ended
    
    user = db.query(models.User).filter(models.User.username == username).first()

    # A removed receptionist has their login switched off, which stops it
    # working straight away, even if their token has not expired yet.
    if not user or not user.is_active: raise session_ended

    # A changed username or password bumps this account's token_version
    # (see the change-login and change-own-password endpoints). A token
    # signed under an older number is treated as ended immediately, on
    # every device carrying it, not only the device where the change was
    # made — this is what forces a real, immediate logout on a login
    # change, rather than waiting for the token's own 2-hour expiry.
    if token_version is None or token_version != user.token_version: raise session_ended

    return user
    


def verify_admin_roles(current_user: models.User = Depends(get_current_user)):
    """
    Verifies that the user has administrative privileges before granting route access.
    """
    if current_user.role not in ["Owner", "Manager"]:
        raise HTTPException(status_code=403, detail="Privilege Escalation Intercepted: Access Denied.")
    return current_user

# NOTE ON THE EXCHANGE RATE:
# The server has no internet of its own, and neither does the receptionist
# tablet. Only the manager's phone does. So the server never looks the rate
# up itself: the manager's app looks it up when the manager logs in and sends
# it to POST /sessions/exchange-rate/ (see below). Everyone else only reads it.


# --- ACTIVE API ROUTER ENDPOINTS ---

def _destroy_password(db_tuple, user):
    """
    Makes a login's password unusable: it is replaced with a long random
    secret nobody knows, every device carrying that login is signed out, and
    the manager must set a new password from Change Login.
    """
    db, mirror_db = db_tuple
    unusable_hash = bcrypt.hashpw(secrets.token_urlsafe(48).encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
    previous_values = {
        "password_hash": user.password_hash,
        "must_change_password": user.must_change_password,
        "token_version": user.token_version,
    }
    user.password_hash = unusable_hash
    user.must_change_password = True
    user.token_version = (user.token_version or 1) + 1

    mirror_user = mirror_db.query(models.User).filter(models.User.username == user.username).first()
    if mirror_user:
        mirror_user.password_hash = unusable_hash
        mirror_user.must_change_password = True
        mirror_user.token_version = user.token_version

    commit_dual_write(db, mirror_db, restore_snapshots=[(user, previous_values)])


# --- WRONG-PASSWORD LOCKOUT ---
# Every five wrong passwords in a row for a username lock that username out
# for longer each time: 30 seconds, 1 minute, 2 minutes, 5 minutes, then
# 10 and 15 minutes. The count of wrong tries only goes back to zero after a
# correct login, or when the manager changes that login. At 50 wrong tries
# in a row, a receptionist's (or the Buffer) password is destroyed, so the
# manager has to set a new one from Change Login. The manager's own account
# is never destroyed (that would lock the owner out of the business); it
# stays at the longest wait instead, and the recovery code remains.
#
# The count is kept in the server's memory and is shared by every device,
# so closing the app or using another tablet does not reset it. Unknown
# usernames are counted exactly like real ones, so the wait never reveals
# which usernames exist.

LOGIN_TRIES_PER_LOCKOUT = 5
LOGIN_LOCKOUT_SECONDS = [30, 60, 120, 300, 600, 900]
LOGIN_TRIES_BEFORE_PASSWORD_DESTROYED = 50

_login_failures = {}


def _lockout_key(username: str) -> str:
    return (username or "").strip().lower()


def _forget_login_failures(*usernames):
    """Clears the wrong-password count (and any wait) for these usernames."""
    for username in usernames:
        _login_failures.pop(_lockout_key(username), None)


def _wait_text(seconds: int) -> str:
    seconds = max(1, int(seconds))
    if seconds < 60:
        return f"{seconds} second{'s' if seconds != 1 else ''}"
    minutes = (seconds + 59) // 60
    return f"{minutes} minute{'s' if minutes != 1 else ''}"


def _lockout_message(seconds: int) -> str:
    return f"Too many wrong tries. Wait {_wait_text(seconds)}."


@app.post("/auth/login/")
def login_employee(request: Request, form_data: OAuth2PasswordRequestForm = Depends(), db_tuple: tuple = Depends(get_db)):
    """
    Checks a username and password and hands back a login token.

    Any failure (unknown username, wrong password, or a removed account)
    gets the same single message, so nobody can use the answer to find out
    which usernames exist or which half of a guess was right.
    """

    db = db_tuple[0]  # Read-Only Track: Extract the primary tracking session engine from the dependency container
    client_ip = request.client.host if request.client else None

    # While a username is waiting out a lockout, nothing is checked at all:
    # not even a correct password gets in until the wait is over.
    lockout_key = _lockout_key(form_data.username)
    failures = _login_failures.get(lockout_key)
    if failures and failures.get("locked_until") and failures["locked_until"] > datetime.datetime.utcnow():
        seconds_left = int((failures["locked_until"] - datetime.datetime.utcnow()).total_seconds()) + 1
        _record_login_attempt(db_tuple, form_data.username, "FAILED", client_ip, None, f"Locked out after too many wrong passwords ({seconds_left} seconds left).")
        raise HTTPException(status_code=429, detail=_lockout_message(seconds_left))

    user = db.query(models.User).filter(models.User.username == form_data.username).first()
    password_ok = bool(user) and bcrypt.checkpw(form_data.password.encode('utf-8'), user.password_hash.encode('utf-8'))

    if not user or not user.is_active or not password_ok:
        # The person is told only one thing; the Login Record keeps the
        # real reason for the manager to read.
        if not user:
            reason = "Username does not exist."
        elif not user.is_active:
            reason = "Account is switched off."
        else:
            reason = "Wrong password."
        _record_login_attempt(db_tuple, form_data.username, "FAILED", client_ip, user.role if user else None, reason)

        # Count the wrong try. Every fifth one starts a longer wait.
        failures = _login_failures.setdefault(lockout_key, {"wrong": 0, "locked_until": None})
        failures["wrong"] += 1
        if failures["wrong"] % LOGIN_TRIES_PER_LOCKOUT == 0:
            lockout_number = failures["wrong"] // LOGIN_TRIES_PER_LOCKOUT
            wait_seconds = LOGIN_LOCKOUT_SECONDS[min(lockout_number, len(LOGIN_LOCKOUT_SECONDS)) - 1]

            if failures["wrong"] >= LOGIN_TRIES_BEFORE_PASSWORD_DESTROYED:
                if user and user.role not in ("Owner", "Manager"):
                    _destroy_password(db_tuple, user)
                    _record_login_attempt(
                        db_tuple, form_data.username, "FAILED", client_ip, user.role,
                        f"Password destroyed after {failures['wrong']} wrong tries in a row; the manager must set a new one.",
                    )
                    _forget_login_failures(form_data.username)
                    raise HTTPException(
                        status_code=429,
                        detail="Too many wrong tries. This login is locked until the manager sets a new password.",
                    )

            failures["locked_until"] = datetime.datetime.utcnow() + datetime.timedelta(seconds=wait_seconds)
            raise HTTPException(status_code=429, detail=_lockout_message(wait_seconds))

        raise HTTPException(status_code=401, detail="Wrong username or password.")

    # A correct login ends the run of wrong tries.
    _forget_login_failures(form_data.username)

    # A successful login is flagged (never blocked) when the kind of
    # account does not match the kind of device it came from.
    flag_note = None
    is_loopback = client_ip in DEVELOPMENT_LOOPBACK_TIER
    if user.role in ("Owner", "Manager") and client_ip not in MANAGER_HARDWARE_TIER and not is_loopback:
        flag_note = "Manager login from a device that is not manager hardware."
    elif user.role in ("Receptionist", "Buffer") and client_ip not in RECEPTION_HARDWARE_TIER and not is_loopback:
        flag_note = "Staff login from a device that is not a front-desk tablet."
    _record_login_attempt(db_tuple, form_data.username, "SUCCESS", client_ip, user.role, flag_note)

    token_payload = {"sub": user.username, "role": user.role, "user_id": user.id, "tv": user.token_version}
    return {
        "access_token": create_access_token(data=token_payload),
        "token_type": "bearer",
        "role": user.role,
        "username": user.username,
        # True after a manager handed out a temporary password: the app then
        # makes the person choose their own before doing anything else.
        "must_change_password": bool(user.must_change_password),
    }


@app.post("/auth/renew/")
def renew_login(current_user: models.User = Depends(get_current_user)):
    """
    Hands back a fresh login token for the person already logged in, valid
    for another full period. The app asks for one every few minutes while
    the device is being used, so a login never runs out in the middle of
    work, while a device left untouched stops asking and its login ends.
    """
    token_payload = {"sub": current_user.username, "role": current_user.role, "user_id": current_user.id, "tv": current_user.token_version}
    return {"access_token": create_access_token(data=token_payload), "token_type": "bearer"}


@app.post("/auth/change-own-password/")
def change_own_password(payload: OwnPasswordChangeSubmission, db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    """
    Lets a logged-in person choose their own new password. Used when a
    manager handed them a temporary one. The current password must be given.
    """
    db, mirror_db = db_tuple

    if not bcrypt.checkpw(payload.current_password.encode('utf-8'), current_user.password_hash.encode('utf-8')):
        raise HTTPException(status_code=400, detail="The current password is not correct.")

    new_hash = clean_new_password(payload.new_password)
    previous_values = {
        "password_hash": current_user.password_hash,
        "must_change_password": current_user.must_change_password,
        "token_version": current_user.token_version,
    }
    current_user.password_hash = new_hash
    current_user.must_change_password = False
    current_user.token_version += 1

    mirror_user = mirror_db.query(models.User).filter(models.User.username == current_user.username).first()
    if mirror_user:
        mirror_user.password_hash = new_hash
        mirror_user.must_change_password = False
        mirror_user.token_version = current_user.token_version

    commit_dual_write(db, mirror_db, restore_snapshots=[(current_user, previous_values)])
    _forget_login_failures(current_user.username)
    return {"status": "Password changed."}


# The recovery code is long and random, but the attempts are still limited:
# after 5 wrong tries the recovery path locks for 15 minutes, so a guessing
# program cannot keep trying. Kept in memory only; restarting the server
# clears it.
_recovery_failed_attempts = []
RECOVERY_MAX_FAILURES = 5
RECOVERY_LOCK_MINUTES = 15


@app.post("/auth/admin-recover/")
def recover_administrator_password(payload: AdministratorRecoverySubmission, db_tuple: tuple = Depends(get_db)):
    """
    "Forgot password?" for the administrator. Works with no internet: the
    administrator types the recovery code that was shown once at first setup,
    plus a new password. Receptionists never use this path; a manager resets
    their password from the app instead.
    """
    db, mirror_db = db_tuple
    now = datetime.datetime.utcnow()

    # Forget failures older than the lock window, then check if locked.
    window_start = now - datetime.timedelta(minutes=RECOVERY_LOCK_MINUTES)
    _recovery_failed_attempts[:] = [t for t in _recovery_failed_attempts if t > window_start]
    if len(_recovery_failed_attempts) >= RECOVERY_MAX_FAILURES:
        raise HTTPException(status_code=429, detail="Too many wrong tries. Please wait 15 minutes and try again.")

    administrator = db.query(models.User).filter(models.User.role == "Owner").first()
    code_ok = bool(administrator and administrator.recovery_code_hash) and bcrypt.checkpw(
        payload.recovery_code.strip().upper().encode('utf-8'), administrator.recovery_code_hash.encode('utf-8')
    )
    if not code_ok:
        _recovery_failed_attempts.append(now)
        raise HTTPException(status_code=400, detail="The recovery code is not correct.")

    new_hash = clean_new_password(payload.new_password)
    previous_values = {
        "password_hash": administrator.password_hash,
        "must_change_password": administrator.must_change_password,
        "token_version": administrator.token_version,
    }
    administrator.password_hash = new_hash
    administrator.must_change_password = False
    administrator.token_version += 1

    mirror_admin = mirror_db.query(models.User).filter(models.User.username == administrator.username).first()
    if mirror_admin:
        mirror_admin.password_hash = new_hash
        mirror_admin.must_change_password = False
        mirror_admin.token_version = administrator.token_version

    commit_dual_write(db, mirror_db, restore_snapshots=[(administrator, previous_values)])
    _recovery_failed_attempts.clear()
    return {"status": "Password changed. You can now log in."}




@app.post("/bookings/", status_code=status.HTTP_201_CREATED)
def create_hourly_booking(payload: BookingSubmission, db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    """
    Front-Desk Booking Intake Core. Enforces package pricing, checks space
    states, and verifies payments.

    A booking made while the server could not be reached is sent here once
    the connection returns. Its real moment is payload.client_time (the
    instant the receptionist pressed confirm on the tablet), never the
    moment this request happens to land here, so a guest can never gain
    extra minutes just because the network was briefly down.
    """

    db, mirror_db = db_tuple  # Write-Replication Track: Extract the concurrent twin-engine connection handles

    # If this exact booking was already saved before (a retry from a tablet
    # that queued it while offline), hand back the original confirmation
    # instead of processing it all over again.
    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    active_session = db.query(models.SessionLog).filter(models.SessionLog.is_closed == False).first()
    if not active_session: raise HTTPException(status_code=400, detail="No active runtime session footprint. System locked.")

    # A booking is only accepted if it matches an exact, manager-approved
    # duration and price for this specific room. Anything outside this list
    # is not something a receptionist can resolve alone; it requires the
    # manager to add the combination to the price list first.
    approved_price = db.query(models.RoomPricingOption).filter(
        models.RoomPricingOption.room_id == payload.room_number.strip(),
        models.RoomPricingOption.duration_hours == payload.duration_hours
    ).first()
    if not approved_price:
        raise HTTPException(
            status_code=400,
            detail="This room and duration combination is not on the approved price list."
        )
    assigned_flat_price = approved_price.price
    
    latest_room_entry = db.query(models.Booking).filter(models.Booking.room_number == payload.room_number.strip()).order_by(models.Booking.id.desc()).first()
    if latest_room_entry:
        if latest_room_entry.room_status == "OCCUPIED": raise HTTPException(status_code=400, detail="Room Asset Collision: Occupied.")
        if latest_room_entry.room_status == "DIRTY": raise HTTPException(status_code=400, detail="Housekeeping Block: Room must clear clean gate.")

    bank_account_digits = check_transfer_details(payload)

    # The safety check on cash: what was received must cover the price plus
    # whatever change is being handed back. cash_tendered and
    # change_returned are always in cedis here — the tablet has already
    # converted any dollar amount before sending this request.
    change_due = validate_cash_payment(payload.payment_mode, assigned_flat_price, payload.cash_tendered, payload.change_returned)

    # The moment the receptionist actually pressed confirm, not the moment
    # this request happens to reach the server.
    check_in_now = resolve_action_time(payload.client_time)
    calculated_checkout = check_in_now + datetime.timedelta(hours=payload.duration_hours)

    # Credits the person who actually made the booking, even if it is being
    # sent late by whoever is now logged in on this tablet.
    acting_user = resolve_acting_user(db, current_user, payload.acted_by_username)

    booking_fields = dict(
        session_id=active_session.id, recorded_by=acting_user.id,
        room_number=payload.room_number.strip(), guest_name=payload.guest_name, guest_phone=payload.guest_phone,
        check_in_time=check_in_now, duration_hours=payload.duration_hours, expected_checkout_time=calculated_checkout,
        room_status="OCCUPIED", payment_mode=payload.payment_mode, currency_used=payload.currency_used,
        usd_exchange_rate=active_session.current_usd_rate, total_paid=assigned_flat_price,
        cash_tendered=payload.cash_tendered, change_returned=change_due, usd_received=payload.usd_received,
        momo_number=payload.momo_number, bank_sender_account=bank_account_digits, is_cancelled=False
    )
    new_booking = models.Booking(**booking_fields)
    db.add(new_booking)

    mirror_booking = models.Booking(**booking_fields)
    mirror_db.add(mirror_booking)  # Register identical tracking transaction to the backup storage unit

    response_payload = {
        "receipt_status": "LOCKED", "total_due": float(assigned_flat_price),
        "cash_tendered": float(payload.cash_tendered), "change_returned": float(change_due), "checkout_deadline": calculated_checkout.isoformat()
    }

    # Record the action tag alongside the booking, as one linked save, so a
    # retry of this exact tag can be recognized and answered without redoing the work.
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    new_records_to_track = [new_booking]
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track)

    return response_payload




# How long after the moment something happened it may still be undone with
# one tap. The same 10 minutes applies to a fresh booking (Cancel Booking)
# and to the newest extension on a booking (Cancel Extension) — see the
# single cancel endpoint below, which decides which of the two applies.
CANCELLATION_WINDOW_MINUTES = 10


# --------------------------------------------------------------------
# CANCEL AND EXTEND BY ROOM NAME
# --------------------------------------------------------------------
# The receptionist's tablet must keep working while the server is down. A
# booking made during an outage does not have a booking number yet (the
# server hands that out when the booking finally arrives), so a later
# Cancel or Extend of that same booking cannot name it by number. These two
# routes name it by ROOM instead: they find the room's current, active
# booking and then run exactly the same cancel / extend code the numbered
# routes below run, so the rules, the 10-minute window, the price check and
# the money records are identical. The tablet sends its saved actions in the
# order they were made, so by the time one of these arrives the room's
# booking has already been saved.
def _find_active_booking_in_room(db, room_number: str):
    """The room's current booking: not cancelled, not checked out, newest first."""
    return db.query(models.Booking).filter(
        models.Booking.room_number == room_number,
        models.Booking.is_cancelled == False,
        models.Booking.room_status == "OCCUPIED",
    ).order_by(models.Booking.check_in_time.desc(), models.Booking.id.desc()).first()


@app.post("/counter/cancel-room-booking/")
def cancel_current_booking_in_room(
    room_number: str,
    client_action_id: str = None,
    acted_by_username: str = None,
    client_time: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """Same as the numbered Cancel, for the booking currently in this room."""
    cached_response = find_previously_processed_action(db_tuple[0], client_action_id)
    if cached_response:
        return cached_response
    booking = _find_active_booking_in_room(db_tuple[0], room_number.strip())
    if not booking:
        raise HTTPException(status_code=404, detail="No active booking was found in that room.")
    return execute_one_tap_cancellation(
        booking_id=booking.id,
        client_action_id=client_action_id,
        acted_by_username=acted_by_username,
        client_time=client_time,
        db_tuple=db_tuple,
        current_user=current_user,
    )


class RoomExtensionSubmission(BookingExtensionSubmission):
    """An extension that names the room instead of the booking number."""
    room_number: str = Field(..., max_length=100)


@app.post("/counter/extend-room-booking/")
def extend_current_booking_in_room(
    payload: RoomExtensionSubmission,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """Same as the numbered Extend, for the booking currently in this room."""
    cached_response = find_previously_processed_action(db_tuple[0], payload.client_action_id)
    if cached_response:
        return cached_response
    booking = _find_active_booking_in_room(db_tuple[0], payload.room_number.strip())
    if not booking:
        raise HTTPException(status_code=404, detail="No active booking was found in that room.")
    return execute_stay_extension(
        booking_id=booking.id,
        payload=payload,
        db_tuple=db_tuple,
        current_user=current_user,
    )


@app.post("/bookings/{booking_id}/cancel/")
def execute_one_tap_cancellation(
    booking_id: int,
    client_action_id: str = None,
    acted_by_username: str = None,
    client_time: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """
    The single Cancel button used on the receptionist's app. It always
    undoes only the most recent thing that happened to this booking:

      - If the booking has a most recent extension that is not already
        cancelled, and that extension is still within its own 10-minute
        window, THIS is undone: the checkout time goes back to what it was
        right before that extension, the extension's money drops out of
        every report, and the booking itself is left exactly as it was.
        This does NOT reopen or extend the booking's own 10-minute window,
        which is fixed to the moment the booking itself was made.

      - Otherwise, if the booking itself is still within its own 10-minute
        window, THE BOOKING is cancelled: the room goes to DIRTY and the
        booking is dropped from every revenue figure.

      - If neither is within its window, nothing can be undone, and the
        server says so plainly.
    """

    db, mirror_db = db_tuple  # Write-Replication Track: Extract the concurrent twin-engine connection handles

    # If this exact cancellation was already saved before (a retry from a
    # tablet that queued it while offline), hand back the original confirmation.
    cached_response = find_previously_processed_action(db, client_action_id)
    if cached_response:
        return cached_response

    target_booking = db.query(models.Booking).filter(models.Booking.id == booking_id).first()
    if not target_booking: raise HTTPException(status_code=404, detail="Target transaction block not found.")
    if target_booking.is_cancelled: raise HTTPException(status_code=400, detail="Booking line is already flag-staged as cancelled.")

    # The moment the receptionist actually pressed Cancel, not the moment
    # this request happens to reach the server, so a cancellation saved
    # offline and sent later still lands inside the real 10-minute window.
    now = resolve_action_time(client_time)

    # Credits whoever actually pressed Cancel, even if it is being sent
    # late by someone else now logged in on this tablet.
    acting_user = resolve_acting_user(db, current_user, acted_by_username)

    # The most recent extension still standing on this booking, if any.
    latest_extension = db.query(models.BookingExtension).filter(
        models.BookingExtension.booking_id == booking_id,
        models.BookingExtension.is_cancelled == False
    ).order_by(models.BookingExtension.id.desc()).first()

    if latest_extension:
        minutes_since_extension = (now - latest_extension.timestamp).total_seconds() / 60.0
        if minutes_since_extension <= CANCELLATION_WINDOW_MINUTES:
            # Cancel the extension, not the booking. The checkout time goes
            # back to what it was recorded as right before this extension.
            previous_extension_values = {
                "is_cancelled": latest_extension.is_cancelled,
                "cancelled_by": latest_extension.cancelled_by,
                "cancelled_at": latest_extension.cancelled_at,
            }
            previous_booking_values = {"expected_checkout_time": target_booking.expected_checkout_time}

            latest_extension.is_cancelled = True
            latest_extension.cancelled_by = acting_user.id
            latest_extension.cancelled_at = now
            restored_checkout_time = latest_extension.previous_checkout_time or target_booking.expected_checkout_time
            target_booking.expected_checkout_time = restored_checkout_time

            mirror_extension = mirror_db.query(models.BookingExtension).filter(models.BookingExtension.id == latest_extension.id).first()
            mirror_booking = mirror_db.query(models.Booking).filter(models.Booking.id == booking_id).first()
            if mirror_extension:
                mirror_extension.is_cancelled = True
                mirror_extension.cancelled_by = acting_user.id
                mirror_extension.cancelled_at = now
            if mirror_booking:
                mirror_booking.expected_checkout_time = restored_checkout_time

            response_payload = {
                "action_taken": "EXTENSION_CANCELLED",
                "room": target_booking.room_number,
                "restored_checkout_time": restored_checkout_time.isoformat(),
            }
            tag_record, mirror_tag_record = build_processed_action_records(client_action_id, response_payload)
            new_records_to_track = []
            if tag_record:
                db.add(tag_record)
                mirror_db.add(mirror_tag_record)
                new_records_to_track.append(tag_record)

            commit_dual_write(
                db, mirror_db, new_db_records=new_records_to_track,
                restore_snapshots=[(latest_extension, previous_extension_values), (target_booking, previous_booking_values)]
            )
            return response_payload

    # No cancellable extension: fall back to cancelling the booking itself,
    # measured from when the booking was made, not from now.
    minutes_since_check_in = (now - target_booking.check_in_time).total_seconds() / 60.0
    if minutes_since_check_in > CANCELLATION_WINDOW_MINUTES:
        raise HTTPException(
            status_code=400,
            detail=f"This booking can no longer be cancelled. The {CANCELLATION_WINDOW_MINUTES}-minute cancellation window has passed."
        )

    # Remember the booking's current values before changing them, in case the
    # backup save fails and this change needs to be put back the way it was.
    previous_values = {
        "is_cancelled": target_booking.is_cancelled,
        "room_status": target_booking.room_status,
        "actual_checkout_time": target_booking.actual_checkout_time,
        "cancelled_by": target_booking.cancelled_by,
    }

    target_booking.is_cancelled = True
    target_booking.room_status = "DIRTY"
    target_booking.actual_checkout_time = now
    target_booking.cancelled_by = acting_user.id
    
    mirror_booking = mirror_db.query(models.Booking).filter(models.Booking.id == booking_id).first()
    if mirror_booking:
        mirror_booking.is_cancelled = True
        mirror_booking.room_status = "DIRTY"
        mirror_booking.actual_checkout_time = target_booking.actual_checkout_time  # Synchronize exact timing metrics
        mirror_booking.cancelled_by = acting_user.id

    response_payload = {"action_taken": "BOOKING_CANCELLED", "room": target_booking.room_number, "status": "DIRTY", "is_cancelled": True}
    tag_record, mirror_tag_record = build_processed_action_records(client_action_id, response_payload)
    new_records_to_track = []
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track, restore_snapshots=[(target_booking, previous_values)])
    return response_payload


@app.post("/bookings/{booking_id}/extend/")
def execute_stay_extension(
    booking_id: int,
    payload: BookingExtensionSubmission,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """
    Adds extra time onto an existing, still-active booking. The extension
    is saved as its own separate charge rather than replacing the original
    booking amount, and the room's checkout deadline is pushed forward by
    the additional hours purchased. Only permitted on a booking that has
    not been checked out or cancelled, and only at one of the room's own
    manager-approved durations, exactly as a fresh booking would be.
    """

    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    target_booking = db.query(models.Booking).filter(models.Booking.id == booking_id).first()
    if not target_booking:
        raise HTTPException(status_code=404, detail="Target booking not found.")
    if target_booking.is_cancelled:
        raise HTTPException(status_code=400, detail="A cancelled booking cannot be extended.")
    if target_booking.room_status != "OCCUPIED":
        raise HTTPException(status_code=400, detail="Only an active, occupied booking can be extended.")

    # The extension must match one of this room's own manager-approved
    # duration and price combinations, the same rule a fresh booking follows.
    approved_price = db.query(models.RoomPricingOption).filter(
        models.RoomPricingOption.room_id == target_booking.room_number,
        models.RoomPricingOption.duration_hours == payload.additional_hours
    ).first()
    if not approved_price:
        raise HTTPException(
            status_code=400,
            detail="This additional duration is not on the room's approved price list."
        )
    extension_price = approved_price.price

    bank_account_digits = check_transfer_details(payload)

    change_due = validate_cash_payment(payload.payment_mode, extension_price, payload.cash_tendered, payload.change_returned)

    # Remember the booking's current checkout deadline before changing it,
    # in case the backup save fails and this change needs to be undone. This
    # is also the value a later "Cancel Extension" restores.
    checkout_time_before_this_extension = target_booking.expected_checkout_time
    previous_values = {"expected_checkout_time": checkout_time_before_this_extension}

    # A stay still running is extended by stacking the extra hours onto its
    # existing deadline. A stay that has already run out (Time's Up) is
    # instead extended from this exact moment: stacking onto an already-past
    # deadline could still land in the past, which would leave the room
    # showing as Time's Up even though it was just paid for and extended.
    now = resolve_action_time(payload.client_time)
    extension_base_time = max(checkout_time_before_this_extension, now)
    new_checkout_deadline = extension_base_time + datetime.timedelta(hours=payload.additional_hours)
    target_booking.expected_checkout_time = new_checkout_deadline

    mirror_booking = mirror_db.query(models.Booking).filter(models.Booking.id == booking_id).first()
    if mirror_booking:
        mirror_booking.expected_checkout_time = new_checkout_deadline

    # Credits the person who actually made the extension, even if it is
    # being sent late by whoever is now logged in on this tablet.
    acting_user = resolve_acting_user(db, current_user, payload.acted_by_username)

    extension_fields = dict(
        booking_id=booking_id, additional_hours=payload.additional_hours, price=extension_price,
        payment_mode=payload.payment_mode, cash_tendered=payload.cash_tendered,
        change_returned=change_due, usd_received=payload.usd_received, momo_number=payload.momo_number,
        bank_sender_account=bank_account_digits,
        recorded_by=acting_user.id, is_cancelled=False,
        previous_checkout_time=checkout_time_before_this_extension, timestamp=now,
    )
    new_extension = models.BookingExtension(**extension_fields)
    mirror_extension = models.BookingExtension(**extension_fields)
    db.add(new_extension)
    mirror_db.add(mirror_extension)

    response_payload = {
        "status": "Stay extended.",
        "additional_hours": payload.additional_hours,
        "extension_price": float(extension_price),
        "cash_tendered": float(payload.cash_tendered),
        "change_returned": float(change_due),
        "new_checkout_deadline": new_checkout_deadline.isoformat(),
    }
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    new_records_to_track = [new_extension]
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track, restore_snapshots=[(target_booking, previous_values)])
    return response_payload




@app.post("/shop/sale/")
def record_ancillary_shop_sale(payload: AncillaryItemSubmission, db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    """
    Point-of-Sale Route. Accepts item entries, records quantities, and processes total costs,
    along with the payment method and amounts used for the sale.
    """

    db, mirror_db = db_tuple  # Write-Replication Track: Extract the concurrent twin-engine connection handles

    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    active_session = db.query(models.SessionLog).filter(models.SessionLog.is_closed == False).first()
    if not active_session: raise HTTPException(status_code=400, detail="No active runtime session footprint.")

    bank_account_digits = check_transfer_details(payload)

    calculated_total = Decimal(str(payload.quantity)) * payload.unit_price
    change_due = validate_cash_payment(payload.payment_mode, calculated_total, payload.cash_tendered, payload.change_returned)
    sale_time = resolve_action_time(payload.client_time)
    acting_user = resolve_acting_user(db, current_user, payload.acted_by_username)

    sale_fields = dict(
        session_id=active_session.id, recorded_by=acting_user.id, item_name=payload.item_name.strip(),
        quantity=payload.quantity, unit_price=payload.unit_price, total_cost=calculated_total,
        payment_mode=payload.payment_mode, cash_tendered=payload.cash_tendered,
        change_returned=change_due, usd_received=payload.usd_received, momo_number=payload.momo_number,
        bank_sender_account=bank_account_digits,
        timestamp=sale_time,
    )
    new_sale = models.AncillarySale(**sale_fields)
    db.add(new_sale)

    mirror_sale = models.AncillarySale(**sale_fields)
    mirror_db.add(mirror_sale)  # Register identical stock transaction line to the backup ledger stream

    response_payload = {"status": "Sale Stamped", "total_cost": float(calculated_total)}
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    new_records_to_track = [new_sale]
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track)
    return response_payload


@app.get("/shop/sales/today/")
def list_todays_shop_sales(db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    """
    Returns every item sold during the currently active shift, so the
    receptionist can see what has actually been sold so far rather than
    the screen going blank after each sale. Scoped to the active session
    rather than the calendar day, so it lines up with the same shift
    boundary the rest of the system already uses.
    """
    db = db_tuple[0]
    active_session = db.query(models.SessionLog).filter(models.SessionLog.is_closed == False).first()
    if not active_session:
        return {"sales": []}

    todays_sales = db.query(models.AncillarySale).filter(
        models.AncillarySale.session_id == active_session.id
    ).order_by(models.AncillarySale.id.desc()).all()

    return {
        "sales": [
            {
                "id": sale.id,
                "item_name": canonical_name(sale.item_name),
                "quantity": sale.quantity,
                "unit_price": float(sale.unit_price),
                "total_cost": float(sale.total_cost),
                "payment_mode": sale.payment_mode,
                "timestamp": sale.timestamp.isoformat(),
            }
            for sale in todays_sales
        ]
    }
@app.post("/counter/checkout-room/")
def execute_room_checkout(
    room_number: str,
    client_action_id: str = None,
    acted_by_username: str = None,
    client_time: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """
    Checkout Gate. Shifts room flags from 'OCCUPIED' to 'DIRTY' and stamps exit times.
    """

    db, mirror_db = db_tuple  # Write-Replication Track: Extract the concurrent twin-engine connection handles

    cached_response = find_previously_processed_action(db, client_action_id)
    if cached_response:
        return cached_response

    active_booking = db.query(models.Booking).filter(
        and_(models.Booking.room_number == room_number.strip(), models.Booking.room_status == "OCCUPIED")
    ).order_by(models.Booking.id.desc()).first()
    
    if not active_booking: raise HTTPException(status_code=404, detail="No active occupied room found.")

    # The moment the receptionist actually pressed Checkout, not the moment
    # this request happens to reach the server — kept accurate in the
    # Guest Log even when this was queued offline and sent later.
    checkout_moment = resolve_action_time(client_time)

    # Credits whoever actually pressed Checkout, even if it is being sent
    # late by someone else now logged in on this tablet. This is what the
    # Guest Log shows as "checked out by", separate from who booked (and
    # so checked in) the guest.
    acting_user = resolve_acting_user(db, current_user, acted_by_username)

    # Remember the booking's current values before changing them, in case the
    # backup save fails and this change needs to be put back the way it was.
    previous_values = {
        "room_status": active_booking.room_status,
        "actual_checkout_time": active_booking.actual_checkout_time,
        "checked_out_by": active_booking.checked_out_by,
    }

    active_booking.room_status = "DIRTY"
    active_booking.actual_checkout_time = checkout_moment
    active_booking.checked_out_by = acting_user.id


    mirror_booking = mirror_db.query(models.Booking).filter(
    and_(models.Booking.room_number == room_number.strip(), models.Booking.room_status == "OCCUPIED")
    ).order_by(models.Booking.id.desc()).first()
    if mirror_booking:
        mirror_booking.room_status = "DIRTY"
        mirror_booking.actual_checkout_time = active_booking.actual_checkout_time  # Match temporal timestamps identically
        mirror_booking.checked_out_by = acting_user.id

    response_payload = {"room": room_number, "status": "DIRTY", "housekeeping_required": True}
    tag_record, mirror_tag_record = build_processed_action_records(client_action_id, response_payload)
    new_records_to_track = []
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track, restore_snapshots=[(active_booking, previous_values)])
    return response_payload




@app.post("/counter/clean-room/")
def clear_housekeeping_buffer(room_number: str, client_action_id: str = None, db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    """
    Housekeeping Release Gate. Toggles a 'DIRTY' room back to 'AVAILABLE' for fresh arrivals.
    """

    db, mirror_db = db_tuple  # Write-Replication Track: Extract the concurrent twin-engine connection handles

    cached_response = find_previously_processed_action(db, client_action_id)
    if cached_response:
        return cached_response

    dirty_booking = db.query(models.Booking).filter(
        and_(models.Booking.room_number == room_number.strip(), models.Booking.room_status == "DIRTY")
    ).order_by(models.Booking.id.desc()).first()
    
    if not dirty_booking: raise HTTPException(status_code=400, detail="Room is not currently flag-staged as dirty.")

    # Remember the current value before changing it, in case the backup save
    # fails and this change needs to be put back the way it was.
    previous_values = {"room_status": dirty_booking.room_status}
    dirty_booking.room_status = "AVAILABLE"

    mirror_booking = mirror_db.query(models.Booking).filter(
    and_(models.Booking.room_number == room_number.strip(), models.Booking.room_status == "DIRTY")
    ).order_by(models.Booking.id.desc()).first()
    if mirror_booking:
        mirror_booking.room_status = "AVAILABLE"  # Release asset space synchronously back to intake desk pool

    response_payload = {"room": room_number, "status": "AVAILABLE", "ready_for_check_in": True}
    tag_record, mirror_tag_record = build_processed_action_records(client_action_id, response_payload)
    new_records_to_track = []
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track, restore_snapshots=[(dirty_booking, previous_values)])
    return response_payload






def _get_app_setting(db, key: str, default: str = "") -> str:
    """Reads one small named setting, such as the backup folder path."""
    row = db.query(models.AppSetting).filter(models.AppSetting.setting_key == key).first()
    return row.setting_value if row else default


def _write_shift_backup_file(db, active_session, now_utc) -> str:
    """
    Writes one CSV file for the shift that just closed, with a Type column
    so bookings, extensions, shop sales and costs all sit in one file
    instead of four. Saved into the configured backup folder if one has
    been set, otherwise into a local "backups" folder next to the server.
    """
    backup_folder = _get_app_setting(db, "backup_folder", "backups")
    os.makedirs(backup_folder, exist_ok=True)
    csv_file_name = os.path.join(backup_folder, f"shift_{active_session.id}_{now_utc.strftime('%Y_%m_%d_%H%M')}.csv")

    shift_bookings = db.query(models.Booking).filter(models.Booking.session_id == active_session.id).all()
    booking_ids = [b.id for b in shift_bookings]
    shift_extensions = db.query(models.BookingExtension).filter(models.BookingExtension.booking_id.in_(booking_ids)).all() if booking_ids else []
    shift_sales = db.query(models.AncillarySale).filter(models.AncillarySale.session_id == active_session.id).all()
    shift_costs = db.query(models.DailyExpense).filter(models.DailyExpense.session_id == active_session.id).all()

    with open(csv_file_name, mode="w", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)
        writer.writerow(["Type", "Reference", "Detail", "Amount (GHS)", "Payment Mode", "Cancelled", "Timestamp"])
        for b in shift_bookings:
            writer.writerow(["Booking", b.room_number, b.guest_name, float(b.total_paid), b.payment_mode, b.is_cancelled, b.check_in_time.isoformat()])
        for e in shift_extensions:
            writer.writerow(["Extension", f"Booking #{e.booking_id}", f"+{e.additional_hours}h", float(e.price), e.payment_mode, e.is_cancelled, e.timestamp.isoformat()])
        for s in shift_sales:
            writer.writerow(["Shop Sale", s.item_name, f"{s.quantity} sold", float(s.total_cost), s.payment_mode, False, s.timestamp.isoformat()])
        for c in shift_costs:
            writer.writerow(["Cost", c.category, c.item_or_reason, float(c.amount_spent), "", False, c.timestamp.isoformat()])

    return csv_file_name


def _copy_employee_photos_to_backup(db, backup_folder: str):
    """
    Copies every employee photo that exists on disk into a "photos"
    subfolder of the backup folder, so a lost server computer does not
    also mean losing every passport photo on file. A photo that is
    missing or unreadable is skipped rather than stopping the backup.
    """
    photo_backup_dir = os.path.join(backup_folder, "photos")
    os.makedirs(photo_backup_dir, exist_ok=True)
    employees_with_photos = db.query(models.Payroll).filter(models.Payroll.photo_url.isnot(None)).all()
    for employee in employees_with_photos:
        source_path = employee.photo_url.lstrip("/")
        try:
            if os.path.exists(source_path):
                shutil.copy2(source_path, os.path.join(photo_backup_dir, os.path.basename(source_path)))
        except OSError:
            # A single unreadable photo must never stop the shift from closing.
            continue


def _copy_database_to_backup(backup_folder: str, now_utc) -> Optional[str]:
    """
    Takes a dated, consistent copy of the live main database and saves it
    into the backup folder, so a lost or stolen server computer does not
    mean losing the business's records entirely. Uses SQLite's own backup
    call rather than a plain file copy, since the live database may be
    mid-write; this way the copy is always a clean, complete snapshot.
    A failure here is logged and swallowed — a missing USB stick must
    never stop the shift from closing or business from continuing.
    """
    try:
        os.makedirs(backup_folder, exist_ok=True)
        destination_path = os.path.join(backup_folder, f"guesthouse_{now_utc.strftime('%Y_%m_%d_%H%M')}.db")
        source_connection = sqlite3.connect("guesthouse.db")
        destination_connection = sqlite3.connect(destination_path)
        with destination_connection:
            source_connection.backup(destination_connection)
        source_connection.close()
        destination_connection.close()
        return destination_path
    except Exception as backup_error:
        print(f"[BACKUP WARNING] Could not copy the database at shift close: {backup_error}")
        return None


@app.post("/sessions/close/")
def manual_manager_shift_closure(request: Request, client_action_id: str = None, db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(verify_admin_roles)):
    """
    Shift Closure Gate. Writes the shift's backup file, copies employee
    photos and a dated database snapshot into the backup folder, and opens
    the buffer shift that quietly covers bookings between shifts.
    """
    enforce_managerial_hardware_gate(request)

    db, mirror_db = db_tuple  # Write-Replication Track: Extract the concurrent twin-engine connection handles

    cached_response = find_previously_processed_action(db, client_action_id)
    if cached_response:
        return cached_response

    active_session = db.query(models.SessionLog).filter(models.SessionLog.is_closed == False).first()
    if not active_session: raise HTTPException(status_code=400, detail="No active runtime session footprint.")
        
    now_utc = datetime.datetime.utcnow()
    time_delta = now_utc - active_session.start_time
    calculated_hours = Decimal(str(time_delta.total_seconds() / 3600.0))

    # Remember the session's current values before changing them, in case the
    # backup save fails and this change needs to be put back the way it was.
    previous_values = {
        "is_closed": active_session.is_closed,
        "end_time": active_session.end_time,
        "duration_hours": active_session.duration_hours,
        "closed_by_user_id": active_session.closed_by_user_id,
        "closure_type": active_session.closure_type,
    }

    active_session.is_closed = True
    active_session.end_time = now_utc
    active_session.duration_hours = round(calculated_hours, 2)
    active_session.closed_by_user_id = current_user.id
    active_session.closure_type = "Manual_Close"
    
    
    mirror_session = mirror_db.query(models.SessionLog).filter(models.SessionLog.id == active_session.id).first()
    if mirror_session:
        mirror_session.is_closed = True
        mirror_session.end_time = now_utc
        mirror_session.duration_hours = round(calculated_hours, 2)
        mirror_session.closed_by_user_id = current_user.id
        mirror_session.closure_type = "Manual_Close"  # Duplicate the operational runtime ceiling

    # Prepare the new buffer-shift session that takes over immediately after closure
    buffer_shift = models.SessionLog(start_time=now_utc, is_closed=False, closure_type="Buffer_Shift", current_usd_rate=active_session.current_usd_rate)
    mirror_buffer = models.SessionLog(start_time=now_utc, is_closed=False, closure_type="Buffer_Shift", current_usd_rate=active_session.current_usd_rate)

    db.add(buffer_shift)
    mirror_db.add(mirror_buffer)  # Provisions a backup runtime allocation footprint for upcoming operations

    response_payload = {"status": "Shift closed."}
    tag_record, mirror_tag_record = build_processed_action_records(client_action_id, response_payload)
    new_records_to_track = [buffer_shift]
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    # Save the closed session and the new buffer shift together, as one linked action
    commit_dual_write(
        db, mirror_db,
        new_db_records=new_records_to_track,
        restore_snapshots=[(active_session, previous_values)],
    )

    # --- BACKUP FILE, PHOTOS AND DATABASE COPY ---
    # Only run once the closure above is confirmed saved on both databases.
    # Nothing here can ever stop the shift from having closed: a failure in
    # any one of these three steps is swallowed so business can carry on.
    backup_folder = _get_app_setting(db, "backup_folder", "backups")
    try:
        _write_shift_backup_file(db, active_session, now_utc)
    except OSError as backup_error:
        print(f"[BACKUP WARNING] Could not write the shift backup file: {backup_error}")
    try:
        _copy_employee_photos_to_backup(db, backup_folder)
    except OSError as backup_error:
        print(f"[BACKUP WARNING] Could not copy employee photos: {backup_error}")
    _copy_database_to_backup(backup_folder, now_utc)

    return response_payload





@app.post("/sessions/open-main/")
def open_new_official_business_day(request: Request, client_action_id: str = None, db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(verify_admin_roles)):
    """
    Official Shift Opener. Enforces administrative hardware verification.
    """

    db, mirror_db = db_tuple  # Write-Replication Track: Extract the concurrent twin-engine connection handles

    enforce_managerial_hardware_gate(request)

    cached_response = find_previously_processed_action(db, client_action_id)
    if cached_response:
        return cached_response

    # Locate whatever session is currently open, if any. This must be checked for
    # None before any of its fields are read, since there may genuinely be no
    # open session (for example, right after server setup, or if the primary
    # and mirror databases have drifted out of sync with each other).
    current_session = db.query(models.SessionLog).filter(models.SessionLog.is_closed == False).first()

    if current_session is None:
        raise HTTPException(status_code=400, detail="No session footprint found to promote. System state invalid.")

    if current_session.closure_type != "Buffer_Shift":
        # A session is already open and it is not a buffer shift waiting to be
        # promoted, so an official shift must already be running.
        raise HTTPException(status_code=400, detail="Main business day stream is already active.")

    # Promote the buffer shift into the official shift. The record itself is
    # kept as one continuous row (so all bookings taken during the buffer
    # shift remain part of the same shift for reporting purposes), but the
    # start_time is refreshed to this exact moment so the shift's recorded
    # start honestly reflects when the manager opened for business, rather
    # than the earlier moment the buffer shift quietly began.
    # Remember the session's current values before changing them, in case the
    # backup save fails and this promotion needs to be put back the way it was.
    previous_values = {
        "closure_type": current_session.closure_type,
        "start_time": current_session.start_time,
    }

    official_open_time = datetime.datetime.utcnow()
    current_session.closure_type = "Manual_Close"
    current_session.start_time = official_open_time

    mirror_session = mirror_db.query(models.SessionLog).filter(models.SessionLog.id == current_session.id).first()
    if mirror_session:
        mirror_session.closure_type = "Manual_Close"  # Seal the temporary background ledger slot on backup storage
        mirror_session.start_time = official_open_time  # Match the refreshed official start time on the backup copy

    response_payload = {"status": "New Main Shift Initialized successfully."}
    tag_record, mirror_tag_record = build_processed_action_records(client_action_id, response_payload)
    new_records_to_track = []
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track, restore_snapshots=[(current_session, previous_values)])
    return response_payload


@app.get("/sessions/current-rate/")
def get_current_usd_to_ghs_rate(db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    """
    Reports the single, authoritative USD-to-GHS conversion rate every
    device should display and use, so both apps show the same number
    instead of each guessing independently. The server never looks this
    rate up itself — it has no internet. The manager's app looks the rate
    up when the manager logs in and sends it here (see the endpoint just
    below); this endpoint only ever reports whatever was last sent, and
    otherwise simply holds its last known value. Available to any
    logged-in device, including receptionist tablets with no internet
    access of their own, since they only need to read this value over the
    local network.
    """
    db = db_tuple[0]
    active_session = db.query(models.SessionLog).filter(models.SessionLog.is_closed == False).first()
    if not active_session:
        raise HTTPException(status_code=400, detail="No active session to read a rate from.")
    return {"usd_to_ghs_rate": float(active_session.current_usd_rate)}


@app.post("/sessions/exchange-rate/")
def set_usd_to_ghs_rate(payload: ExchangeRateSubmission, request: Request, db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(verify_admin_roles)):
    """
    Saves the dollar-to-cedi rate the manager's phone looked up on its own
    internet connection, onto whichever session is currently open, in both
    databases together. Restricted to manager hardware, the same as every
    other manager-only action.
    """
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    active_session = db.query(models.SessionLog).filter(models.SessionLog.is_closed == False).first()
    if not active_session:
        raise HTTPException(status_code=400, detail="No active session to save a rate onto.")

    previous_values = {"current_usd_rate": active_session.current_usd_rate}
    active_session.current_usd_rate = payload.usd_to_ghs_rate

    mirror_session = mirror_db.query(models.SessionLog).filter(models.SessionLog.id == active_session.id).first()
    if mirror_session:
        mirror_session.current_usd_rate = payload.usd_to_ghs_rate

    response_payload = {"status": "Exchange rate saved.", "usd_to_ghs_rate": float(payload.usd_to_ghs_rate)}
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    new_records_to_track = []
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track, restore_snapshots=[(active_session, previous_values)])
    return response_payload


@app.post("/settings/backup-folder/")
def set_backup_folder(payload: BackupFolderSubmission, request: Request, db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(verify_admin_roles)):
    """Saves where the shift backup file, employee photos, and the dated database copy are written."""
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    existing = db.query(models.AppSetting).filter(models.AppSetting.setting_key == "backup_folder").first()
    mirror_existing = mirror_db.query(models.AppSetting).filter(models.AppSetting.setting_key == "backup_folder").first()
    new_records_to_track = []
    restore_snapshots = []

    if existing:
        restore_snapshots.append((existing, {"setting_value": existing.setting_value}))
        existing.setting_value = payload.backup_folder
        if mirror_existing:
            mirror_existing.setting_value = payload.backup_folder
    else:
        existing = models.AppSetting(setting_key="backup_folder", setting_value=payload.backup_folder)
        mirror_new = models.AppSetting(setting_key="backup_folder", setting_value=payload.backup_folder)
        db.add(existing)
        mirror_db.add(mirror_new)
        new_records_to_track.append(existing)

    response_payload = {"status": "Backup folder saved.", "backup_folder": payload.backup_folder}
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track, restore_snapshots=restore_snapshots)
    return response_payload


@app.get("/settings/backup-folder/")
def read_backup_folder(db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(verify_admin_roles)):
    db = db_tuple[0]
    return {"backup_folder": _get_app_setting(db, "backup_folder", "backups")}


@app.get("/sessions/current/")
def get_current_shift_state(db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(verify_admin_roles)):
    """
    Reports the real, current shift state, so the manager's Shift Control
    screen never has to assume or guess it. An official shift is
    considered active only when the open session has been promoted out of
    the buffer shift state; a session still sitting in the buffer
    shift means no official shift has been opened yet.
    """
    db = db_tuple[0]
    current_session = db.query(models.SessionLog).filter(models.SessionLog.is_closed == False).first()

    is_official_shift_active = bool(current_session and current_session.closure_type != "Buffer_Shift")

    return {
        "is_official_shift_active": is_official_shift_active,
        "session_id": current_session.id if current_session else None,
        "start_time": current_session.start_time.isoformat() if current_session else None,
    }


def _sum_period_financials(db, window_start: datetime.datetime, window_end: datetime.datetime, num_days: int):
    """
    Totals every income and deduction line for one time window, so the
    same logic can be run twice — once for the period being viewed, once
    for the equal-length period right before it — to build the up/down
    comparison shown on each line of the Business Summary. num_days is
    passed in explicitly (1, 7, 30, or 365) rather than recalculated from
    the two datetimes, since the window's start and end fall at whatever
    time of day "now" happens to be, and a calendar-date difference
    between them can land one day short or long depending on that time.
    """
    rooms_revenue = db.query(func.sum(models.Booking.total_paid)).filter(
        and_(models.Booking.timestamp >= window_start, models.Booking.timestamp < window_end, models.Booking.is_cancelled == False)
    ).scalar() or Decimal("0.00")
    # A cancelled extension was refunded and is left out of income, exactly
    # like a cancelled booking (it stays visible in the Guest Log as an audit line).
    extension_revenue = db.query(func.sum(models.BookingExtension.price)).filter(
        and_(
            models.BookingExtension.timestamp >= window_start, models.BookingExtension.timestamp < window_end,
            models.BookingExtension.is_cancelled == False,
        )
    ).scalar() or Decimal("0.00")
    rooms_revenue += extension_revenue

    ancillary_revenue = db.query(func.sum(models.AncillarySale.total_cost)).filter(
        and_(models.AncillarySale.timestamp >= window_start, models.AncillarySale.timestamp < window_end)
    ).scalar() or Decimal("0.00")

    # COSTS COUNT ONLY ONCE THEIR SHIFT HAS CLOSED.
    # Every cost is still recorded the moment it is typed in (the Daily
    # Costs screen shows it straight away), but it is not taken off the
    # profit until the shift it belongs to has been officially closed.
    # A utility or expendable entered at the start of a shift, before a
    # single booking exists, therefore never shows as an instant loss: the
    # profit shows what has been earned so far, and the costs join it when
    # the shift closes. The same rule applies to payroll in
    # _payroll_days_in_window below.
    expendables_total = db.query(func.sum(models.DailyExpense.amount_spent)).join(
        models.SessionLog, models.DailyExpense.session_id == models.SessionLog.id
    ).filter(
        and_(models.DailyExpense.timestamp >= window_start, models.DailyExpense.timestamp < window_end,
             models.DailyExpense.category == "EXPENDABLES", models.SessionLog.is_closed == True)
    ).scalar() or Decimal("0.00")
    utilities_total = db.query(func.sum(models.DailyExpense.amount_spent)).join(
        models.SessionLog, models.DailyExpense.session_id == models.SessionLog.id
    ).filter(
        and_(models.DailyExpense.timestamp >= window_start, models.DailyExpense.timestamp < window_end,
             models.DailyExpense.category == "UTILITIES", models.SessionLog.is_closed == True)
    ).scalar() or Decimal("0.00")

    payroll_total = _prorate_payroll_for_window(db, window_start.date(), num_days)

    net_profit = (rooms_revenue + ancillary_revenue) - expendables_total - utilities_total - payroll_total

    return {
        "rooms_revenue": rooms_revenue, "ancillary_revenue": ancillary_revenue,
        "expendables_total": expendables_total, "utilities_total": utilities_total,
        "payroll_total": payroll_total, "net_profit": net_profit,
    }


def _payroll_days_in_window(db, start_date: datetime.date, num_days: int):
    """
    The calendar dates, inside one period, on which the business was
    actually operating: from the later of the period's first day and the
    business's own first day, up to the earlier of the period's last day
    and today. Payroll is only ever counted for these days.

    This is what stops an empty stretch from showing a false loss. A
    Yearly view opened a few days after the business began is charged
    only for the days that really happened, not a whole year of salary. A period that ended
    before the business began, or one that has not started yet, has no
    operating days at all, so its payroll is zero.
    """
    earliest_activity = _earliest_business_activity(db)
    if earliest_activity is None:
        return []

    # PAYROLL FOLLOWS THE SAME "ONLY AFTER THE SHIFT HAS CLOSED" RULE AS
    # THE COSTS. A day's salary share is counted only up to the date of the
    # most recent shift that has been officially closed, so opening a new
    # shift (or the start of a new day) never shows a loss from salaries
    # before a single booking has been made. Until the very first shift is
    # closed, no payroll is counted at all. How one day's share is worked
    # out is untouched; only which days are counted changes.
    last_closed_end = db.query(func.max(models.SessionLog.end_time)).filter(
        models.SessionLog.is_closed == True
    ).scalar()
    if last_closed_end is None:
        return []

    first_day = max(start_date, earliest_activity.date())
    last_day = min(
        start_date + datetime.timedelta(days=num_days - 1),
        datetime.datetime.utcnow().date(),
        last_closed_end.date(),
    )

    operating_days = []
    current_date = first_day
    while current_date <= last_day:
        operating_days.append(current_date)
        current_date += datetime.timedelta(days=1)
    return operating_days


def _prorate_payroll_for_window(db, start_date: datetime.date, num_days: int) -> Decimal:
    """
    Spreads every active employee's monthly salary evenly across the days
    of its own month, then adds up one daily share for every day in the
    period on which the business was actually operating (see
    _payroll_days_in_window) and on which the person had already started.

    Each day is worked out with the salary the person had on that day. A
    salary change ends one row and starts another for the same person; the
    new salary applies from the day after the change, so the days before it
    keep the old salary and nothing already counted is ever re-priced.
    """
    payroll_rows = db.query(models.Payroll).all()

    # Every row of one person, oldest first. A row with no person_id stands
    # for one person alone. Only people who still have an active row count.
    rows_by_person = {}
    for row in payroll_rows:
        key = row.person_id if row.person_id is not None else ("row", row.id)
        rows_by_person.setdefault(key, []).append(row)
    people = [
        sorted(rows, key=lambda r: (r.start_date, r.id))
        for rows in rows_by_person.values()
        if any(r.is_active for r in rows)
    ]

    total = Decimal("0.00")
    for current_date in _payroll_days_in_window(db, start_date, num_days):
        days_in_month = calendar.monthrange(current_date.year, current_date.month)[1]
        for rows in people:
            salary_row = None
            for position, row in enumerate(rows):
                row_start = row.start_date.date()
                # The first row counts from its own start day; a later row
                # (a salary change) counts from the day after it was made.
                started = current_date >= row_start if position == 0 else current_date > row_start
                if started:
                    salary_row = row
            if salary_row is None:
                continue
            total += Decimal(str(salary_row.monthly_salary)) / Decimal(str(days_in_month))
    return total


def _trend_for(current_value: Decimal, previous_value: Decimal) -> str:
    if current_value > previous_value:
        return "UP"
    if current_value < previous_value:
        return "DOWN"
    return "FLAT"


def _is_unusually_high(current_value: Decimal, previous_value: Decimal) -> bool:
    # A line is flagged only when there is a real prior figure to compare
    # against and the current one has jumped by at least 30% over it — a
    # deliberately simple, visible-at-a-glance rule rather than a precise
    # statistical one, so a manager can trust what a flag means.
    if previous_value <= 0:
        return False
    return current_value > previous_value * Decimal("1.3")


def _earliest_business_activity(db) -> Optional[datetime.datetime]:
    """
    The earliest moment there is any real record of the business actually
    operating — the earlier of the first booking ever made and the first
    shift ever opened. Used to tell a genuinely empty stretch (correctly
    "no history yet") apart from a period that simply predates the
    business itself (which should say so plainly, rather than showing a
    misleadingly small or "loss" figure for a period that could not
    possibly have any real data in it).
    """
    earliest_booking = db.query(func.min(models.Booking.timestamp)).scalar()
    earliest_session = db.query(func.min(models.SessionLog.start_time)).scalar()
    candidates = [moment for moment in (earliest_booking, earliest_session) if moment is not None]
    return min(candidates) if candidates else None


def _grouped_expense_breakdown(db, category: str, window_start: datetime.datetime, window_end: datetime.datetime):
    """
    Groups Daily Costs entries of one category (UTILITIES or EXPENDABLES)
    by their item/reason text within one time window, matched without
    regard to capitalization or stray spacing — the same rule already
    used for ancillary sales — so the same utility or expendable logged
    slightly differently each time is still counted as one line.
    """
    # Only costs whose shift has closed are counted, the same rule as in
    # _sum_period_financials, so the breakdown always adds up to the total.
    rows = db.query(models.DailyExpense).join(
        models.SessionLog, models.DailyExpense.session_id == models.SessionLog.id
    ).filter(and_(
        models.DailyExpense.timestamp >= window_start,
        models.DailyExpense.timestamp < window_end,
        models.DailyExpense.category == category,
        models.SessionLog.is_closed == True,
    )).all()

    grouped = {}
    for row in rows:
        key = row.item_or_reason.strip().lower()
        entry = grouped.setdefault(key, {"display_name": canonical_name(row.item_or_reason), "total_amount": Decimal("0.00"), "entry_count": 0})
        entry["total_amount"] += row.amount_spent
        entry["entry_count"] += 1

    breakdown = [
        {"item_name": entry["display_name"], "total_amount": float(entry["total_amount"]), "entry_count": entry["entry_count"]}
        for entry in grouped.values()
    ]
    breakdown.sort(key=lambda item: item["total_amount"], reverse=True)
    return breakdown


@app.get("/analytics/financials/")
def get_business_summary(
    request: Request,
    period: str = None,
    days_back: int = None,
    start_date: str = None,
    end_date: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Business Summary data source. Returns the current period's income and
    deduction lines alongside the equal-length period immediately before
    it (for the up/down comparison), plus full drill-down breakdowns for
    rooms, ancillary sales, utilities, expendables, payroll, and cancelled
    bookings. Cancelled bookings are counted separately and never included
    in any revenue figure.

    Either period (daily, weekly, monthly or yearly — real calendar
    periods, see _resolve_period_window) or a start_date/end_date pair
    (the Custom range picker, each an ISO date such as "2026-09-01") is
    expected — Custom takes priority if both are somehow present.
    start_date/end_date describe whole calendar days; end_date is treated
    as running through the end of that day.
    """
    enforce_managerial_hardware_gate(request)
    db = db_tuple[0]

    current_window_start, now = _resolve_period_window(days_back, start_date, end_date, period)
    period_kind = None if (start_date and end_date) else _normalise_period_kind(period, days_back)
    num_days = _window_day_count(current_window_start, now)
    previous_window_start, previous_window_end = _previous_comparison_window(period_kind, current_window_start, now)

    current = _sum_period_financials(db, current_window_start, now, num_days)
    previous = _sum_period_financials(
        db, previous_window_start, previous_window_end, _window_day_count(previous_window_start, previous_window_end)
    )

    # True only when there is genuinely nothing to show: the business has
    # no activity at all yet, or the period being looked at ended before
    # the business began. A period the business only partly covers (a
    # month it started in the middle of, say) is NOT insufficient — it
    # shows the real figures from the business's first day onward, and
    # payroll is only counted for the days the business actually ran.
    earliest_activity = _earliest_business_activity(db)
    insufficient_history = earliest_activity is None or now <= earliest_activity

    cancelled_bookings = db.query(models.Booking).filter(
        and_(models.Booking.timestamp >= current_window_start, models.Booking.timestamp < now, models.Booking.is_cancelled == True)
    ).order_by(models.Booking.id.desc()).all()
    cancelled_count = len(cancelled_bookings)

    # Real employee names, looked up once for the whole request.
    _display_names = _staff_display_names(db)

    def _username_for(user_id):
        return _display_names.get(user_id) if user_id else None

    cancelled_breakdown = [
        {
            "room_number": booking.room_number,
            "duration_hours": booking.duration_hours,
            "booked_at": booking.check_in_time.isoformat(),
            "cancelled_at": (booking.actual_checkout_time or booking.timestamp).isoformat(),
            "booked_by": _username_for(booking.recorded_by),
            "cancelled_by": _username_for(booking.cancelled_by),
        }
        for booking in cancelled_bookings
    ]

    # --- Rooms drill-down: room -> (new bookings, extensions) grouped by duration ---
    room_bookings = db.query(models.Booking).filter(
        and_(models.Booking.timestamp >= current_window_start, models.Booking.timestamp < now, models.Booking.is_cancelled == False)
    ).all()
    room_extensions = db.query(models.BookingExtension).join(
        models.Booking, models.BookingExtension.booking_id == models.Booking.id
    ).filter(
        models.BookingExtension.timestamp >= current_window_start,
        models.BookingExtension.timestamp < now,
        models.BookingExtension.is_cancelled == False,
    ).all()

    rooms_map = {}
    for booking in room_bookings:
        room_entry = rooms_map.setdefault(booking.room_number, {"times_booked": 0, "total_revenue": Decimal("0.00"), "packages": {}})
        room_entry["times_booked"] += 1
        room_entry["total_revenue"] += booking.total_paid
        package_key = (booking.duration_hours, "new")
        package = room_entry["packages"].setdefault(package_key, {"count": 0, "subtotal": Decimal("0.00")})
        package["count"] += 1
        package["subtotal"] += booking.total_paid

    for extension in room_extensions:
        source_booking = db.query(models.Booking).filter(models.Booking.id == extension.booking_id).first()
        if not source_booking:
            continue
        room_entry = rooms_map.setdefault(source_booking.room_number, {"times_booked": 0, "total_revenue": Decimal("0.00"), "packages": {}})
        room_entry["times_booked"] += 1
        room_entry["total_revenue"] += extension.price
        package_key = (extension.additional_hours, "extension")
        package = room_entry["packages"].setdefault(package_key, {"count": 0, "subtotal": Decimal("0.00")})
        package["count"] += 1
        package["subtotal"] += extension.price

    highest_earning_room = max(rooms_map, key=lambda name: rooms_map[name]["total_revenue"]) if rooms_map else None
    most_booked_room = max(rooms_map, key=lambda name: rooms_map[name]["times_booked"]) if rooms_map else None

    rooms_breakdown = []
    for room_name, entry in rooms_map.items():
        packages = [
            {"duration_hours": key[0], "kind": key[1], "count": pkg["count"], "subtotal": float(pkg["subtotal"])}
            for key, pkg in sorted(entry["packages"].items(), key=lambda kv: (kv[0][0], kv[0][1]))
        ]
        rooms_breakdown.append({
            "room_name": room_name,
            "times_booked": entry["times_booked"],
            "total_revenue": float(entry["total_revenue"]),
            "is_highest_earner": room_name == highest_earning_room,
            "is_most_booked": room_name == most_booked_room,
            "packages": packages,
        })
    rooms_breakdown.sort(key=lambda r: r["total_revenue"], reverse=True)

    # --- Ancillary drill-down: item -> price points, matched without regard
    # to capitalization or stray spacing, so "Beer", "beer", and "BEER "
    # are all counted as the one item. ---
    ancillary_sales = db.query(models.AncillarySale).filter(
        models.AncillarySale.timestamp >= current_window_start, models.AncillarySale.timestamp < now
    ).all()
    ancillary_map = {}
    for sale in ancillary_sales:
        normalized_key = sale.item_name.strip().lower()
        item_entry = ancillary_map.setdefault(normalized_key, {
            "display_name": canonical_name(sale.item_name), "total_quantity": 0, "total_revenue": Decimal("0.00"), "price_points": {}
        })
        item_entry["total_quantity"] += sale.quantity
        item_entry["total_revenue"] += sale.total_cost
        price_point = item_entry["price_points"].setdefault(sale.unit_price, {"quantity": 0, "subtotal": Decimal("0.00")})
        price_point["quantity"] += sale.quantity
        price_point["subtotal"] += sale.total_cost

    highest_earning_item = max(ancillary_map, key=lambda key: ancillary_map[key]["total_revenue"]) if ancillary_map else None
    most_sold_item = max(ancillary_map, key=lambda key: ancillary_map[key]["total_quantity"]) if ancillary_map else None

    ancillary_breakdown = []
    for normalized_key, entry in ancillary_map.items():
        price_points = [
            {"unit_price": float(price), "quantity": pp["quantity"], "subtotal": float(pp["subtotal"])}
            for price, pp in sorted(entry["price_points"].items())
        ]
        ancillary_breakdown.append({
            "item_name": entry["display_name"],
            "total_quantity": entry["total_quantity"],
            "total_revenue": float(entry["total_revenue"]),
            "is_highest_earner": normalized_key == highest_earning_item,
            "is_most_sold": normalized_key == most_sold_item,
            "price_points": price_points,
        })
    ancillary_breakdown.sort(key=lambda i: i["total_revenue"], reverse=True)

    # --- Payroll drill-down: one prorated amount per active employee ---
    payroll_records = db.query(models.Payroll).filter(models.Payroll.is_active == True).all()
    payroll_breakdown = []
    operating_days = _payroll_days_in_window(db, current_window_start.date(), num_days)
    for record in payroll_records:
        employee_total = Decimal("0.00")
        for current_date in operating_days:
            days_in_month = calendar.monthrange(current_date.year, current_date.month)[1]
            employee_total += Decimal(str(record.monthly_salary)) / Decimal(str(days_in_month))
        payroll_breakdown.append({"employee_name": record.employee_name, "prorated_amount": float(round(employee_total, 2))})
    payroll_breakdown.sort(key=lambda p: p["prorated_amount"], reverse=True)

    # --- Utilities and Expendables drill-downs, the same tap-to-open
    # treatment Rooms and Sales already had. ---
    utilities_breakdown = _grouped_expense_breakdown(db, "UTILITIES", current_window_start, now)
    expendables_breakdown = _grouped_expense_breakdown(db, "EXPENDABLES", current_window_start, now)

    def _line(current_value: Decimal, previous_value: Decimal, flag_if_high: bool = False):
        line = {
            "current": float(round(current_value, 2)),
            "previous": float(round(previous_value, 2)),
            "trend": _trend_for(current_value, previous_value),
        }
        if flag_if_high:
            line["is_unusually_high"] = _is_unusually_high(current_value, previous_value)
        return line

    return {
        "period_days": num_days,
        "period_kind": period_kind,
        "period_start": current_window_start.isoformat(),
        "period_end": now.isoformat(),
        "insufficient_history": insufficient_history,
        "cancelled_count": cancelled_count,
        "cancelled_breakdown": cancelled_breakdown,
        "income": {
            "rooms": _line(current["rooms_revenue"], previous["rooms_revenue"]),
            "ancillary": _line(current["ancillary_revenue"], previous["ancillary_revenue"]),
        },
        "deductions": {
            "expendables": _line(current["expendables_total"], previous["expendables_total"], flag_if_high=True),
            "utilities": _line(current["utilities_total"], previous["utilities_total"], flag_if_high=True),
            "payroll": _line(current["payroll_total"], previous["payroll_total"], flag_if_high=True),
        },
        "net_profit": _line(current["net_profit"], previous["net_profit"]),
        "rooms_breakdown": rooms_breakdown,
        "ancillary_breakdown": ancillary_breakdown,
        "utilities_breakdown": utilities_breakdown,
        "expendables_breakdown": expendables_breakdown,
        "payroll_breakdown": payroll_breakdown,
    }



# The four fixed period tabs, as the screens send them. Older app builds
# still send days_back (1, 7, 30 or 365), so those are mapped onto the
# same four calendar periods instead of a rolling window.
_FIXED_PERIODS = ("daily", "weekly", "monthly", "yearly")
_LEGACY_DAYS_BACK_TO_PERIOD = {1: "daily", 7: "weekly", 30: "monthly", 365: "yearly"}


def _normalise_period_kind(period: Optional[str], days_back: Optional[int]) -> Optional[str]:
    """Returns "daily", "weekly", "monthly" or "yearly", or None when neither was given."""
    if period:
        kind = period.strip().lower()
        if kind not in _FIXED_PERIODS:
            raise HTTPException(status_code=400, detail="Unknown period. Use daily, weekly, monthly or yearly.")
        return kind
    return _LEGACY_DAYS_BACK_TO_PERIOD.get(days_back)


def _calendar_period_start(kind: str, today: datetime.date) -> datetime.date:
    """
    The first day of the calendar period containing today: today itself
    for Daily, the most recent Sunday for Weekly (a week runs Sunday to
    Saturday), the 1st of the month for Monthly, and 1 January for Yearly.
    """
    if kind == "daily":
        return today
    if kind == "weekly":
        # Python counts Monday as 0 and Sunday as 6, so this is how many
        # days have passed since the last Sunday (0 on a Sunday itself).
        return today - datetime.timedelta(days=(today.weekday() + 1) % 7)
    if kind == "monthly":
        return today.replace(day=1)
    return today.replace(month=1, day=1)


def _previous_calendar_period_start(kind: str, current_start: datetime.date) -> datetime.date:
    """The first day of the calendar period immediately before the one starting on current_start."""
    if kind == "daily":
        return current_start - datetime.timedelta(days=1)
    if kind == "weekly":
        return current_start - datetime.timedelta(days=7)
    if kind == "monthly":
        return (current_start - datetime.timedelta(days=1)).replace(day=1)
    return current_start.replace(year=current_start.year - 1)


def _resolve_period_window(days_back: Optional[int], start_date: Optional[str], end_date: Optional[str], period: Optional[str] = None):
    """
    Shared by every screen offering the same period choice (Business
    Summary, the Guest Log, Shop Sales, Money Brought In).

    Works by calendar date, never by a rolling count of hours:
      - Daily   = today's date, from midnight, however many shifts or
                  buffer periods ran inside it.
      - Weekly  = Sunday to Saturday.
      - Monthly = the calendar month.
      - Yearly  = the calendar year.
    Each of these runs from the start of the period up to right now, so
    the current period is always "so far". A Custom start_date/end_date
    pair (each an ISO date such as "2026-09-01", end_date running through
    the end of that day) takes priority over everything else.

    Returns (window_start, window_end) as naive UTC datetimes, which for
    Ghana is the same as local time.
    """
    if start_date and end_date:
        window_start = datetime.datetime.fromisoformat(start_date)
        window_end = datetime.datetime.fromisoformat(end_date) + datetime.timedelta(days=1)
        if window_end <= window_start:
            raise HTTPException(status_code=400, detail="The end date must be on or after the start date.")
        return window_start, window_end

    kind = _normalise_period_kind(period, days_back)
    if kind:
        window_end = datetime.datetime.utcnow()
        first_day = _calendar_period_start(kind, window_end.date())
        window_start = datetime.datetime.combine(first_day, datetime.time.min)
        return window_start, window_end

    if days_back:
        window_end = datetime.datetime.utcnow()
        return window_end - datetime.timedelta(days=days_back), window_end
    raise HTTPException(status_code=400, detail="Either a period or a start_date/end_date range is required.")


def _window_day_count(window_start: datetime.datetime, window_end: datetime.datetime) -> int:
    """
    How many calendar dates a window touches, counting a part-finished
    last day as a whole one. The window's end is exclusive, so a Custom
    range ending at midnight does not count the day after its last day.
    """
    last_moment = window_end - datetime.timedelta(microseconds=1)
    return max((last_moment.date() - window_start.date()).days + 1, 1)


def _previous_comparison_window(kind: Optional[str], window_start: datetime.datetime, window_end: datetime.datetime):
    """
    The stretch the current period is compared against for the up/down
    arrows. A calendar period is compared with the same amount of time
    at the start of the previous one: Sunday to Wednesday this week
    against Sunday to Wednesday last week. Comparing a half-finished week
    with a whole finished one would show "down" almost every time. A
    Custom range is compared with the equal-length stretch right before it.
    """
    elapsed = window_end - window_start
    if kind:
        previous_first_day = _previous_calendar_period_start(kind, window_start.date())
        previous_start = datetime.datetime.combine(previous_first_day, datetime.time.min)
        # Never reach past the start of the current period (a 31-day
        # month being compared against a 30-day one, for example).
        previous_end = min(previous_start + elapsed, window_start)
        return previous_start, previous_end
    return window_start - elapsed, window_start


# ------------------------------------------------------------------
# Shared lookups used by every Records screen
# ------------------------------------------------------------------
def _staff_display_names(db) -> dict:
    """
    Maps every login id to the name a person should see: the employee's
    real name from Employee Management when their login is linked to an
    employee record, otherwise the account's own username with a capital
    (so the shared "buffer" login and the administrator read as "Buffer"
    and "Administrator"). Built once per request rather than once per row.
    """
    names = {
        user.id: ("Manager" if user.role in ("Owner", "Manager") else user.username.strip().capitalize())
        for user in db.query(models.User).all()
    }
    linked_employee_rows = db.query(models.Payroll).filter(models.Payroll.user_id != None).order_by(models.Payroll.id.asc()).all()
    for row in linked_employee_rows:
        if row.employee_name and row.employee_name.strip():
            # Rows are read oldest first, so if a salary change left more
            # than one row for the same person, the newest one wins.
            names[row.user_id] = row.employee_name.strip()
    return names


def _session_id_at(db, moment):
    """The shift that was running at a given instant, or None."""
    session = db.query(models.SessionLog).filter(
        models.SessionLog.start_time <= moment,
        or_(models.SessionLog.end_time == None, models.SessionLog.end_time >= moment),
    ).order_by(models.SessionLog.id.desc()).first()
    return session.id if session else None


def _shift_summaries(db, session_ids) -> list:
    """
    The shifts the Records tables group their entries under: for each shift
    that has at least one entry, when it started, when it ended (nothing
    while it is still open) and whether it is the buffer shift.

    A buffer shift is the open stretch between two official shifts. When
    the manager opens the next shift, that same stretch becomes the shift,
    so only the buffer shift open right now is ever reported as one.
    """
    wanted = {session_id for session_id in session_ids if session_id is not None}
    if not wanted:
        return []
    sessions = db.query(models.SessionLog).filter(models.SessionLog.id.in_(list(wanted))).all()
    return [
        {
            "id": session.id,
            "start": session.start_time.isoformat(),
            "end": session.end_time.isoformat() if session.end_time else None,
            "is_open": not session.is_closed,
            "is_buffer_shift": session.closure_type == "Buffer_Shift",
        }
        for session in sessions
    ]


def _payment_summary(payment_mode, price, cash_tendered, usd_received, momo_number, bank_sender_account=None) -> dict:
    """
    One plain description of how something was paid for, the same shape
    for a room booking, an extension and a shop sale:
      - CASH: just the price, in cedis.
      - USD:  the dollar amount handed over and its cedi equivalent.
      - MOMO: the cedis received, the extra over the price, and the wallet number.
      - BANK: the cedis received (or the dollars sent, their cedi value and
              the rate used), the extra over the price, and the last four
              digits of the sender's account.
    "price" is always what the room or sale cost, in cedis. For a transfer,
    "extra" is what arrived above the price (for example the sender's
    charges); it is shown for the record only and is never part of a total.
    """
    mode = (payment_mode or "CASH").upper()
    price_value = float(price or 0)
    tendered_value = float(cash_tendered or 0)
    usd_value = float(usd_received) if usd_received else None

    if mode in ("MOMO", "BANK"):
        received = tendered_value or price_value
        summary = {
            "method": mode, "price": price_value,
            "amount_sent": received,
            "extra": round(max(received - price_value, 0.0), 2),
            "usd_received": None, "momo_number": None, "bank_sender_account": None,
        }
        if mode == "MOMO":
            summary["momo_number"] = momo_number
        else:
            summary["bank_sender_account"] = bank_sender_account
            if usd_value:
                # The rate the tablet used, worked out from what it recorded.
                summary["usd_received"] = usd_value
                summary["cedi_equivalent"] = received
                summary["rate"] = round(received / usd_value, 2)
        return summary
    if usd_value:
        return {
            "method": "USD", "price": price_value,
            "usd_received": usd_value, "cedi_equivalent": tendered_value or price_value,
            "momo_number": None, "bank_sender_account": None,
        }
    return {"method": "CASH", "price": price_value, "usd_received": None, "momo_number": None, "bank_sender_account": None}


@app.get("/records/guest-log/")
def get_guest_log(
    request: Request,
    period: str = None,
    days_back: int = None,
    start_date: str = None,
    end_date: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    The Guest Log sub-view of the Records tab: every booking made in the
    chosen period (Daily/Weekly/Monthly/Yearly/Custom, by calendar date).
    Unlike every revenue figure elsewhere, a cancelled booking is NOT left
    out here — the whole point of this screen is a complete record of
    what happened, cancellations included.

    An extension normally comes back inside the booking it belongs to, as
    a small "extensions" list, so the screen can show it as a short line
    under that booking: when the extension started (the checkout time it
    carried on from), the new scheduled checkout it created, how it was
    paid and who made it. The booking itself then carries the ORIGINAL
    scheduled checkout and the one actual checkout, which covers the whole
    stay.

    The one exception: an extension made inside the chosen period on a
    booking that was checked in OUTSIDE it (an extension made today on
    yesterday's booking, seen in the Daily view) is also listed as a row of
    its own, with kind "extension_only", so it is recorded on the day it
    was made. Over a longer period that holds both the booking and the
    extension, the extension stays under its booking only.

    Searching is done on the screen, over whatever it shows, so every
    column is searchable the moment something is typed.
    """
    enforce_managerial_hardware_gate(request)
    db = db_tuple[0]
    window_start, window_end = _resolve_period_window(days_back, start_date, end_date, period)

    bookings = db.query(models.Booking).filter(
        models.Booking.check_in_time >= window_start,
        models.Booking.check_in_time < window_end,
    ).order_by(models.Booking.check_in_time.desc()).all()
    booking_ids = [b.id for b in bookings]

    # Every extension of these bookings (cancelled ones too, as audit
    # lines), grouped by booking and kept in the order they were made.
    extensions_by_booking = {}
    if booking_ids:
        extension_rows = db.query(models.BookingExtension).filter(
            models.BookingExtension.booking_id.in_(booking_ids)
        ).order_by(models.BookingExtension.timestamp.asc(), models.BookingExtension.id.asc()).all()
        for extension in extension_rows:
            extensions_by_booking.setdefault(extension.booking_id, []).append(extension)

    # Room descriptions and real employee names, each looked up once.
    room_descriptions = {room.room_name: room.description for room in db.query(models.RoomAsset).all()}
    display_names = _staff_display_names(db)

    def _name_for(user_id):
        return display_names.get(user_id) if user_id else None

    # The newest manager action on each booking, so the Guest Log can show
    # whether a cancelled booking was cancelled by the manager and whether
    # a booking was later restored.
    latest_override_by_booking = {}
    if booking_ids:
        override_rows = db.query(models.ManagerOverrideRecord).filter(
            models.ManagerOverrideRecord.booking_id.in_(booking_ids),
            models.ManagerOverrideRecord.action.in_(["CANCEL", "RESTORE"]),
        ).order_by(models.ManagerOverrideRecord.id.asc()).all()
        for override_row in override_rows:
            latest_override_by_booking[override_row.booking_id] = override_row

    # Extensions made in this period on a booking checked in outside it.
    outside_extension_pairs = db.query(models.BookingExtension, models.Booking).join(
        models.Booking, models.BookingExtension.booking_id == models.Booking.id
    ).filter(
        models.BookingExtension.timestamp >= window_start,
        models.BookingExtension.timestamp < window_end,
        or_(models.Booking.check_in_time < window_start, models.Booking.check_in_time >= window_end),
    ).order_by(models.BookingExtension.timestamp.desc(), models.BookingExtension.id.desc()).all()

    # Whether each extension's newest manager action was a cancel (so the
    # line can say "Cancelled by Manager" and the manager can restore it).
    latest_extension_action = {}
    relevant_booking_ids = set(booking_ids) | {booking.id for _, booking in outside_extension_pairs}
    if relevant_booking_ids:
        extension_override_rows = db.query(models.ManagerOverrideRecord).filter(
            models.ManagerOverrideRecord.booking_id.in_(list(relevant_booking_ids)),
            models.ManagerOverrideRecord.action.in_(["CANCEL_EXTENSION", "RESTORE_EXTENSION"]),
        ).order_by(models.ManagerOverrideRecord.id.asc()).all()
        for override_row in extension_override_rows:
            if override_row.cancelled_extension_ids and override_row.cancelled_extension_ids.strip().isdigit():
                latest_extension_action[int(override_row.cancelled_extension_ids.strip())] = override_row.action

    guests = []
    for booking in bookings:
        extensions = extensions_by_booking.get(booking.id, [])
        standing_extensions = [e for e in extensions if not e.is_cancelled]

        # The booking's own expected_checkout_time moves forward with
        # every extension, so the ORIGINAL scheduled checkout is the
        # checkout time the very first extension carried on from.
        first_extension_start = next((e.previous_checkout_time for e in extensions if e.previous_checkout_time), None)
        original_checkout = first_extension_start or booking.expected_checkout_time

        extension_lines = []
        for extension in extensions:
            # An extension carries on from the old checkout time, or from
            # the moment it was made if the stay had already run out —
            # the same rule execute_stay_extension uses to set the new
            # deadline, so the two always agree.
            carried_on_from = max(extension.previous_checkout_time, extension.timestamp) if extension.previous_checkout_time else None
            extension_lines.append({
                "extension_id": extension.id,
                "additional_hours": extension.additional_hours,
                "cancelled": extension.is_cancelled,
                "starts_at": carried_on_from.isoformat() if carried_on_from else None,
                "new_scheduled_checkout": (carried_on_from + datetime.timedelta(hours=extension.additional_hours)).isoformat() if carried_on_from else None,
                "made_at": extension.timestamp.isoformat(),
                "made_by": _name_for(extension.recorded_by),
                "cancelled_by_manager": bool(extension.is_cancelled and latest_extension_action.get(extension.id) == "CANCEL_EXTENSION"),
                "cancelled_by": _name_for(extension.cancelled_by) if extension.is_cancelled else None,
                "cancelled_at": extension.cancelled_at.isoformat() if (extension.is_cancelled and extension.cancelled_at) else None,
                "payment": _payment_summary(extension.payment_mode, extension.price, extension.cash_tendered, extension.usd_received, extension.momo_number, extension.bank_sender_account),
            })

        guests.append({
            "kind": "booking",
            "session_id": booking.session_id,
            "sort_at": booking.check_in_time.isoformat(),
            "booking_id": booking.id,
            "guest_name": canonical_name(booking.guest_name, False),
            "guest_phone": booking.guest_phone,
            "room_number": booking.room_number,
            "room_description": room_descriptions.get(booking.room_number, ""),
            "duration_hours": booking.duration_hours,
            "extended": len(standing_extensions) > 0,
            "cancelled": booking.is_cancelled,
            "checked_in_at": booking.check_in_time.isoformat(),
            "scheduled_checkout": original_checkout.isoformat(),
            "actual_checkout": booking.actual_checkout_time.isoformat() if (booking.actual_checkout_time and not booking.is_cancelled) else None,
            # A cancelled booking has no checkout at all; it has a cancel
            # time instead, worked out the same way the Business Summary's
            # cancelled list does.
            "cancelled_at": (booking.actual_checkout_time or booking.timestamp).isoformat() if booking.is_cancelled else None,
            "checked_in_by": _name_for(booking.recorded_by),
            "checked_out_by": _name_for(booking.checked_out_by),
            "cancelled_by": _name_for(booking.cancelled_by) if booking.is_cancelled else None,
            "cancelled_by_manager": bool(
                booking.is_cancelled
                and latest_override_by_booking.get(booking.id) is not None
                and latest_override_by_booking[booking.id].action == "CANCEL"
            ),
            "restored_by_manager": bool(
                not booking.is_cancelled
                and latest_override_by_booking.get(booking.id) is not None
                and latest_override_by_booking[booking.id].action == "RESTORE"
            ),
            "payment": _payment_summary(booking.payment_mode, booking.total_paid, booking.cash_tendered, booking.usd_received, booking.momo_number, booking.bank_sender_account),
            "extensions": extension_lines,
        })

    # Each extension made in this period on an earlier booking becomes a
    # row of its own, placed among the others by the time it was made.
    for extension, source_booking in outside_extension_pairs:
        carried_on_from = max(extension.previous_checkout_time, extension.timestamp) if extension.previous_checkout_time else None
        guests.append({
            "kind": "extension_only",
            "sort_at": extension.timestamp.isoformat(),
            "booking_id": source_booking.id,
            "extension_id": extension.id,
            "guest_name": canonical_name(source_booking.guest_name, False),
            "guest_phone": source_booking.guest_phone,
            "room_number": source_booking.room_number,
            "room_description": room_descriptions.get(source_booking.room_number, ""),
            "additional_hours": extension.additional_hours,
            "cancelled": extension.is_cancelled,
            "cancelled_by_manager": bool(extension.is_cancelled and latest_extension_action.get(extension.id) == "CANCEL_EXTENSION"),
            "cancelled_by": _name_for(extension.cancelled_by) if extension.is_cancelled else None,
            "cancelled_at": extension.cancelled_at.isoformat() if (extension.is_cancelled and extension.cancelled_at) else None,
            # The booking this extension belongs to is checked in earlier, so
            # its actual checkout (if the guest has left) is shown here too.
            "actual_checkout": source_booking.actual_checkout_time.isoformat() if (source_booking.actual_checkout_time and not source_booking.is_cancelled) else None,
            "checked_out_by": _name_for(source_booking.checked_out_by) if (source_booking.actual_checkout_time and not source_booking.is_cancelled) else None,
            "session_id": _session_id_at(db, extension.timestamp),
            "starts_at": carried_on_from.isoformat() if carried_on_from else None,
            "new_scheduled_checkout": (carried_on_from + datetime.timedelta(hours=extension.additional_hours)).isoformat() if carried_on_from else None,
            "made_at": extension.timestamp.isoformat(),
            "made_by": _name_for(extension.recorded_by),
            "payment": _payment_summary(extension.payment_mode, extension.price, extension.cash_tendered, extension.usd_received, extension.momo_number, extension.bank_sender_account),
        })

    guests.sort(key=lambda row: row["sort_at"], reverse=True)
    return {"guests": guests, "shifts": _shift_summaries(db, [row.get("session_id") for row in guests])}


@app.get("/records/shop-sales/")
def get_shop_sales_record(
    request: Request,
    period: str = None,
    days_back: int = None,
    start_date: str = None,
    end_date: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    The Shop Sales sub-view of the Records tab: every counter sale in the
    chosen period, newest first, with who sold it and exactly how it was
    paid for (cash, dollars with their cedi equivalent, or MoMo with the
    amount sent and the wallet number). Searched on the screen.
    """
    enforce_managerial_hardware_gate(request)
    db = db_tuple[0]
    window_start, window_end = _resolve_period_window(days_back, start_date, end_date, period)

    sales = db.query(models.AncillarySale).filter(
        models.AncillarySale.timestamp >= window_start,
        models.AncillarySale.timestamp < window_end,
    ).order_by(models.AncillarySale.timestamp.desc()).all()

    display_names = _staff_display_names(db)

    return {
        "sales": [
            {
                "sale_id": sale.id,
                "session_id": sale.session_id,
                "item_name": canonical_name(sale.item_name),
                "quantity": sale.quantity,
                "unit_price": float(sale.unit_price),
                "total_cost": float(sale.total_cost),
                "timestamp": sale.timestamp.isoformat(),
                "sold_by": display_names.get(sale.recorded_by) if sale.recorded_by else None,
                "payment": _payment_summary(sale.payment_mode, sale.total_cost, sale.cash_tendered, sale.usd_received, sale.momo_number, sale.bank_sender_account),
            }
            for sale in sales
        ],
        "shifts": _shift_summaries(db, [sale.session_id for sale in sales]),
    }




@app.post("/management/change-login/")
def change_employee_login(
    payload: ChangeLoginSubmission,
    request: Request, db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
    ):
    """
    The Change Login screen: picks an employee and changes the username,
    the password, or both. The manager's own password confirms the
    action, so a phone left unlocked cannot be used to take over an
    account. When is_temporary_password is set, the receptionist must
    choose their own password the next time they log in.
    """
    db, mirror_db = db_tuple  # Write-Replication Track: Extract the concurrent twin-engine connection handles

    enforce_managerial_hardware_gate(request)

    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    if not bcrypt.checkpw(payload.manager_password.encode('utf-8'), current_user.password_hash.encode('utf-8')):
        raise HTTPException(status_code=400, detail="Your password is not correct.")

    user_record = db.query(models.User).filter(models.User.username == payload.target_username.strip()).first()
    if not user_record:
        raise HTTPException(status_code=404, detail="Target employee profile not found.")

    previous_values = {
        "username": user_record.username,
        "password_hash": user_record.password_hash,
        "must_change_password": user_record.must_change_password,
        "token_version": user_record.token_version,
    }
    mirror_user = mirror_db.query(models.User).filter(models.User.username == payload.target_username.strip()).first()

    login_actually_changed = False

    if payload.new_username:
        cleaned_username = payload.new_username.strip()
        if not is_valid_username(cleaned_username):
            raise HTTPException(status_code=400, detail="Usernames use 3 to 30 letters, numbers, dots, dashes or underscores.")
        collision = db.query(models.User).filter(models.User.username == cleaned_username, models.User.id != user_record.id).first()
        if collision:
            raise HTTPException(status_code=400, detail="That username is already in use.")
        user_record.username = cleaned_username
        if mirror_user:
            mirror_user.username = cleaned_username
        login_actually_changed = True

    if payload.new_password:
        new_hash = clean_new_password(payload.new_password)
        user_record.password_hash = new_hash
        user_record.must_change_password = payload.is_temporary_password
        if mirror_user:
            mirror_user.password_hash = new_hash
            mirror_user.must_change_password = payload.is_temporary_password
        login_actually_changed = True

    # Whichever of the two changed (or both), this account's current login
    # token — on whichever device it is signed in on, manager or
    # receptionist tablet alike — stops being accepted immediately. This is
    # the one shared mechanism behind "force logout on login change", so it
    # works the same whichever app is asking.
    if login_actually_changed:
        user_record.token_version += 1
        if mirror_user:
            mirror_user.token_version = user_record.token_version

    response_payload = {"status": "Login updated.", "username": user_record.username}
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    new_records_to_track = []
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track, restore_snapshots=[(user_record, previous_values)])
    # A new password or name starts with a clean count and no wait.
    _forget_login_failures(payload.target_username, payload.new_username or "")
    return response_payload


@app.post("/management/employees/", status_code=status.HTTP_201_CREATED)
def onboard_new_guesthouse_employee(
    payload: EmployeeOnboardSubmission,
    request: Request,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Administrative Staff Onboarding Gate.
    Validates inputs, verifies managerial hardware layer permissions,
    and performs concurrent dual-writes to primary and backup systems.
    """
    # Enforce strict workstation IP hardware security policies
    enforce_managerial_hardware_gate(request)
    
    # Extract concurrent twin-engine connection handles from the generator
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    # A Receptionist also gets a login here, so onboarding and account
    # creation happen together rather than as two separate manager steps.
    new_login_user = None
    mirror_login_user = None
    if payload.role.strip() == "Receptionist":
        if not payload.username or not payload.password:
            raise HTTPException(status_code=400, detail="A username and password are required for a receptionist.")
        cleaned_username = payload.username.strip()
        if not is_valid_username(cleaned_username):
            raise HTTPException(status_code=400, detail="Usernames use 3 to 30 letters, numbers, dots, dashes or underscores.")
        if db.query(models.User).filter(models.User.username == cleaned_username).first():
            raise HTTPException(status_code=400, detail="That username is already in use.")
        password_hash = clean_new_password(payload.password)
        new_login_user = models.User(username=cleaned_username, password_hash=password_hash, role="Receptionist", is_active=True)
        mirror_login_user = models.User(username=cleaned_username, password_hash=password_hash, role="Receptionist", is_active=True)
        db.add(new_login_user)
        mirror_db.add(mirror_login_user)

    # 1. Prepare database logging entry block for primary workspace ledger.
    # start_date marks the first day this salary row counts for payroll;
    # person_id is filled in below once this row's own id is known, so this
    # first row for a person points at itself.
    new_employee = models.Payroll(
        employee_name=payload.employee_name.strip(),
        role=payload.role.strip(),
        monthly_salary=payload.monthly_salary,
        start_date=datetime.datetime.utcnow(),
    )
    db.add(new_employee)
    
    # 2. Prepare identical layout mirror profile for structural disk resiliency
    mirror_employee = models.Payroll(
        employee_name=payload.employee_name.strip(),
        role=payload.role.strip(),
        monthly_salary=payload.monthly_salary,
        start_date=new_employee.start_date,
    )
    mirror_db.add(mirror_employee)

    response_payload = {"status": "Staff record successfully written to active database repositories."}
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    new_records_to_track = [new_employee]
    if new_login_user:
        new_records_to_track.append(new_login_user)
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    # 3. Synchronized commit across both storage sectors, linked as one action
    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track)

    # The employee's real database ID is only known after the commit above
    # succeeds. This row is its own first salary row, so person_id points at
    # itself; user_id links it to the login just created, if any. This is a
    # second, small commit rather than folding these into the first, since
    # both ids only exist once the rows above are actually saved.
    new_employee.person_id = new_employee.id
    if new_login_user:
        new_employee.user_id = new_login_user.id
    mirror_employee.person_id = mirror_employee.id
    if mirror_login_user:
        mirror_employee.user_id = mirror_login_user.id
    commit_dual_write(db, mirror_db)

    # This ID is what the front end then uses to upload a passport photo
    # for this employee.
    response_payload["id"] = new_employee.id
    return response_payload


@app.get("/management/employees/")
def list_active_employees(db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(verify_admin_roles)):
    """
    Returns every currently active employee. An employee who has been
    marked inactive (see the deletion endpoint below) no longer appears
    here, even though their historical record still exists on disk.
    """
    db = db_tuple[0]
    active_staff = db.query(models.Payroll).filter(models.Payroll.is_active == True).order_by(models.Payroll.employee_name).all()
    return {
        "employees": [
            {
                "id": staff.id,
                "employee_name": staff.employee_name,
                "role": staff.role,
                "monthly_salary": float(staff.monthly_salary),
                "photo_url": staff.photo_url,
            }
            for staff in active_staff
        ]
    }


def _money_brought_in_for_logins(db, display_name, linked_user_ids, window_start, window_end):
    """
    The one body behind every "Money Brought In" chip: the bookings,
    extensions and shop sales recorded by the given login ids over the
    chosen window, with cancelled bookings and extensions left out. Used
    by each receptionist's chip and by the Buffer chip, so all of them
    always add up the same way.
    """
    if not linked_user_ids:
        return {"employee_name": display_name, "bookings": [], "extensions": [], "shop_sales": [], "total": 0.0}

    bookings = db.query(models.Booking).filter(
        models.Booking.recorded_by.in_(linked_user_ids),
        models.Booking.check_in_time >= window_start,
        models.Booking.check_in_time < window_end,
        models.Booking.is_cancelled == False,
    ).order_by(models.Booking.check_in_time.desc()).all()

    extensions = db.query(models.BookingExtension).filter(
        models.BookingExtension.recorded_by.in_(linked_user_ids),
        models.BookingExtension.timestamp >= window_start,
        models.BookingExtension.timestamp < window_end,
        models.BookingExtension.is_cancelled == False,
    ).order_by(models.BookingExtension.timestamp.desc()).all()

    shop_sales = db.query(models.AncillarySale).filter(
        models.AncillarySale.recorded_by.in_(linked_user_ids),
        models.AncillarySale.timestamp >= window_start,
        models.AncillarySale.timestamp < window_end,
    ).order_by(models.AncillarySale.timestamp.desc()).all()

    # An extension is listed with the room it extended, so it reads like any
    # other booking.
    room_by_booking = {}
    if extensions:
        extended_booking_ids = list({e.booking_id for e in extensions})
        room_by_booking = {
            booking_id: room_number
            for booking_id, room_number in db.query(models.Booking.id, models.Booking.room_number).filter(
                models.Booking.id.in_(extended_booking_ids)
            ).all()
        }

    bookings_total = sum((b.total_paid for b in bookings), Decimal("0.00"))
    extensions_total = sum((e.price for e in extensions), Decimal("0.00"))
    sales_total = sum((s.total_cost for s in shop_sales), Decimal("0.00"))

    return {
        "employee_name": display_name,
        # The guest's name is deliberately left out of this line, per
        # Wim's request — room, duration, price and time are enough here.
        "bookings": [
            {
                "room_number": b.room_number, "duration_hours": b.duration_hours, "amount": float(b.total_paid),
                "timestamp": b.check_in_time.isoformat(),
                "payment": _payment_summary(b.payment_mode, b.total_paid, b.cash_tendered, b.usd_received, b.momo_number, b.bank_sender_account),
            }
            for b in bookings
        ],
        "extensions": [
            {
                "room_number": room_by_booking.get(e.booking_id, ""), "additional_hours": e.additional_hours, "amount": float(e.price),
                "timestamp": e.timestamp.isoformat(),
                "payment": _payment_summary(e.payment_mode, e.price, e.cash_tendered, e.usd_received, e.momo_number, e.bank_sender_account),
            }
            for e in extensions
        ],
        "shop_sales": [
            {
                "item_name": canonical_name(s.item_name), "quantity": s.quantity, "amount": float(s.total_cost),
                "timestamp": s.timestamp.isoformat(),
                "payment": _payment_summary(s.payment_mode, s.total_cost, s.cash_tendered, s.usd_received, s.momo_number, s.bank_sender_account),
            }
            for s in shop_sales
        ],
        "total": float(bookings_total + extensions_total + sales_total),
    }


# The Buffer chip. The shared "buffer" login is deliberately not an
# employee (it never appears in Employee Management or Payroll), so it has
# no employee id to ask for. This route is declared BEFORE the
# employee-id route below so that the word "buffer" is never mistaken for
# an id. Anything booked or sold while the shared Buffer login was in use
# is credited here.
@app.get("/management/buffer/money-brought-in/")
def get_buffer_money_brought_in(
    period: str = None,
    days_back: int = None,
    start_date: str = None,
    end_date: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    db = db_tuple[0]
    window_start, window_end = _resolve_period_window(days_back, start_date, end_date, period)
    buffer_ids = [row.id for row in db.query(models.User).filter(models.User.role == "Buffer").all()]
    return _money_brought_in_for_logins(db, "Buffer", buffer_ids, window_start, window_end)


@app.get("/management/employees/{employee_id}/money-brought-in/")
def get_employee_money_brought_in(
    employee_id: int,
    period: str = None,
    days_back: int = None,
    start_date: str = None,
    end_date: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Staff Earnings for one receptionist: bookings, extensions and shop
    sales they personally recorded, over the chosen period, with the same
    kind of drill-down Business Summary uses. Either days_back or a
    start_date/end_date pair works, exactly as it does for Business
    Summary and the Guest Log.

    Every payroll row sharing this employee's person_id is checked for a
    linked login, since a salary change starts a new payroll row for the
    same person — this must still show one person's full history, not just
    whichever row happens to be the current one.
    """
    db = db_tuple[0]

    target_staff = db.query(models.Payroll).filter(models.Payroll.id == employee_id).first()
    if not target_staff:
        raise HTTPException(status_code=404, detail="Target employee profile not found.")

    window_start, window_end = _resolve_period_window(days_back, start_date, end_date, period)

    person_id = target_staff.person_id or target_staff.id
    linked_user_ids = [
        row.user_id for row in db.query(models.Payroll).filter(models.Payroll.person_id == person_id).all()
        if row.user_id
    ]
    return _money_brought_in_for_logins(db, target_staff.employee_name, linked_user_ids, window_start, window_end)


@app.patch("/management/employees/{employee_id}")
def edit_existing_employee(
    employee_id: int,
    payload: EmployeeEditSubmission,
    request: Request,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Updates an existing employee's role and salary. The employee's name is
    never changed here; see EmployeeEditSubmission for why.

    A role change that crosses in or out of "Receptionist" also opens or
    closes that person's front-desk login, in the same step:
      - Moving AWAY from Receptionist closes their login for good: it is
        deactivated, forces out any device it is currently signed in on,
        and its password is overwritten with an unrecoverable random value
        that nobody — including a manager — can ever read back or use
        again. The row itself is kept, not deleted, purely so this
        person's past bookings still show a real "checked in/out by" name
        in the Guest Log; it can never be signed into or reactivated
        again, by design.
      - Moving TO Receptionist (from any other role, including someone
        moving back after an earlier demotion) requires a username and
        password right here, the same as onboarding a brand-new
        receptionist. If this same person already has a retired login from
        an earlier demotion, that same row is reactivated with a plain
        overwrite of its username and password (no old password needed) —
        rather than a fresh row being created every time, which would
        otherwise leave a small pile of dead accounts behind with each
        role cycle. Only someone who never had a login before gets a
        brand-new row.
    """
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    target_staff = db.query(models.Payroll).filter(models.Payroll.id == employee_id).first()
    if not target_staff:
        raise HTTPException(status_code=404, detail="Target employee profile not found.")

    old_role = target_staff.role
    new_role = payload.role.strip()
    role_leaving_receptionist = old_role == "Receptionist" and new_role != "Receptionist"
    role_becoming_receptionist = new_role == "Receptionist" and old_role != "Receptionist"

    new_records_to_track = []
    restore_snapshots = []

    # Carried onto whichever payroll row ends up representing this person
    # going forward (the existing row if only the role changed, or the
    # brand-new row if the salary also changed). Defaults to whatever this
    # person's login link already was, unmodified.
    resolved_user_id = target_staff.user_id
    brand_new_login_user = None  # filled in below only if a fresh login row is created here

    if role_leaving_receptionist and target_staff.user_id:
        login_user = db.query(models.User).filter(models.User.id == target_staff.user_id).first()
        if login_user and login_user.is_active:
            # A random, never-recorded password permanently locks this
            # login out — not merely "deactivated", but left with no
            # working password at all, so it can never quietly be turned
            # back on. The username is left as it was, so this person's
            # earlier bookings keep showing their real name in the Guest
            # Log rather than a scrambled placeholder.
            unrecoverable_password_hash = clean_new_password(secrets.token_urlsafe(32))
            restore_snapshots.append((login_user, {
                "password_hash": login_user.password_hash,
                "is_active": login_user.is_active,
                "token_version": login_user.token_version,
            }))
            login_user.password_hash = unrecoverable_password_hash
            login_user.is_active = False
            login_user.token_version += 1
            mirror_login_user = mirror_db.query(models.User).filter(models.User.id == target_staff.user_id).first()
            if mirror_login_user:
                mirror_login_user.password_hash = unrecoverable_password_hash
                mirror_login_user.is_active = False
                mirror_login_user.token_version = login_user.token_version
        # resolved_user_id is deliberately left pointing at this retired
        # login rather than cleared to None: that link is exactly what
        # lets a later promotion back to Receptionist find this same row
        # and reactivate it, instead of it becoming an orphaned account
        # that a fresh login's username would then collide with.

    if role_becoming_receptionist:
        if not payload.username or not payload.password:
            raise HTTPException(status_code=400, detail="A username and password are required to make this person a receptionist.")
        cleaned_username = payload.username.strip()
        if not is_valid_username(cleaned_username):
            raise HTTPException(status_code=400, detail="Usernames use 3 to 30 letters, numbers, dots, dashes or underscores.")

        # If this same person already has a login from an earlier
        # demotion, that one row is reused for good — reactivated with a
        # plain overwrite of its username and password (no old password
        # needed, the same as a manager resetting anyone's login) — rather
        # than a fresh row being created every time someone cycles roles,
        # which would otherwise leave a small pile of dead, permanently
        # unusable accounts behind with each cycle.
        existing_login = db.query(models.User).filter(models.User.id == target_staff.user_id).first() if target_staff.user_id else None
        username_collision_query = db.query(models.User).filter(models.User.username == cleaned_username)
        if existing_login:
            username_collision_query = username_collision_query.filter(models.User.id != existing_login.id)
        if username_collision_query.first():
            raise HTTPException(status_code=400, detail="That username is already in use.")

        new_password_hash = clean_new_password(payload.password)
        if existing_login:
            restore_snapshots.append((existing_login, {
                "username": existing_login.username, "password_hash": existing_login.password_hash,
                "is_active": existing_login.is_active, "token_version": existing_login.token_version,
            }))
            existing_login.username = cleaned_username
            existing_login.password_hash = new_password_hash
            existing_login.is_active = True
            existing_login.token_version += 1
            mirror_existing_login = mirror_db.query(models.User).filter(models.User.id == existing_login.id).first()
            if mirror_existing_login:
                mirror_existing_login.username = cleaned_username
                mirror_existing_login.password_hash = new_password_hash
                mirror_existing_login.is_active = True
                mirror_existing_login.token_version = existing_login.token_version
            resolved_user_id = existing_login.id
        else:
            brand_new_login_user = models.User(username=cleaned_username, password_hash=new_password_hash, role="Receptionist", is_active=True)
            mirror_brand_new_login_user = models.User(username=cleaned_username, password_hash=new_password_hash, role="Receptionist", is_active=True)
            db.add(brand_new_login_user)
            mirror_db.add(mirror_brand_new_login_user)
            new_records_to_track.append(brand_new_login_user)
            # resolved_user_id is filled in below, after the commit gives
            # this brand-new login row its real database id.

    salary_is_changing = target_staff.monthly_salary != payload.monthly_salary

    if salary_is_changing:
        # A salary change never overwrites what was already paid: today
        # ends the old row, and a brand-new row starts from today at the
        # new salary. Both rows share the same person_id, so this is still
        # one employee across payroll history.
        now = datetime.datetime.utcnow()
        previous_values = {"end_date": target_staff.end_date, "is_active": target_staff.is_active}
        target_staff.end_date = now
        target_staff.is_active = False
        restore_snapshots.append((target_staff, previous_values))

        mirror_old_staff = mirror_db.query(models.Payroll).filter(models.Payroll.id == employee_id).first()
        if mirror_old_staff:
            mirror_old_staff.end_date = now
            mirror_old_staff.is_active = False

        new_staff_row = models.Payroll(
            employee_name=target_staff.employee_name, role=new_role,
            monthly_salary=payload.monthly_salary, is_active=True, start_date=now,
            person_id=target_staff.person_id or target_staff.id,
            user_id=resolved_user_id, photo_url=target_staff.photo_url,
        )
        mirror_new_staff_row = models.Payroll(
            employee_name=target_staff.employee_name, role=new_role,
            monthly_salary=payload.monthly_salary, is_active=True, start_date=now,
            person_id=target_staff.person_id or target_staff.id,
            user_id=resolved_user_id, photo_url=target_staff.photo_url,
        )
        db.add(new_staff_row)
        mirror_db.add(mirror_new_staff_row)
        new_records_to_track.append(new_staff_row)
        response_employee_id = None  # filled in after commit, below
        row_needing_new_login_id = new_staff_row
        mirror_row_needing_new_login_id = mirror_new_staff_row
    else:
        # Only the role (and/or login) changed: no new payroll row is needed.
        previous_values = {"role": target_staff.role, "user_id": target_staff.user_id}
        target_staff.role = new_role
        target_staff.user_id = resolved_user_id
        restore_snapshots.append((target_staff, previous_values))

        mirror_staff = mirror_db.query(models.Payroll).filter(models.Payroll.id == employee_id).first()
        if mirror_staff:
            mirror_staff.role = new_role
            mirror_staff.user_id = resolved_user_id
        response_employee_id = employee_id
        row_needing_new_login_id = target_staff if brand_new_login_user else None
        mirror_row_needing_new_login_id = mirror_staff if brand_new_login_user else None

    response_payload = {"status": "Employee updated."}
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track, restore_snapshots=restore_snapshots)

    # A brand-new login's real id only exists once the commit above has
    # actually happened. Link it onto whichever payroll row now represents
    # this person, in a second small commit — the same two-phase pattern
    # onboarding itself uses for the same reason.
    if brand_new_login_user and row_needing_new_login_id is not None:
        row_needing_new_login_id.user_id = brand_new_login_user.id
        if mirror_row_needing_new_login_id is not None:
            mirror_row_needing_new_login_id.user_id = brand_new_login_user.id
        commit_dual_write(db, mirror_db)

    response_payload["id"] = response_employee_id if response_employee_id else new_staff_row.id
    return response_payload


@app.post("/management/employees/{employee_id}/photo/")
def upload_employee_passport_photo(
    employee_id: int,
    request: Request,
    photo: UploadFile = File(...),
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Saves an employee's passport photo to local disk storage and records
    its web path on the employee's profile. The employee's profile points
    to the newest upload.
    """
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    target_staff = db.query(models.Payroll).filter(models.Payroll.id == employee_id).first()
    if not target_staff:
        raise HTTPException(status_code=404, detail="Target employee profile not found.")

    # The upload is read with a hard size ceiling, opened as a real picture
    # and redrawn from its pixels as a fresh passport-size JPEG. Whatever
    # the sender called the file, whatever type it claimed, and anything
    # hidden inside it is discarded: only the redrawn picture is stored,
    # under a name the server chooses.
    raw_upload = photo.file.read(MAX_EMPLOYEE_PHOTO_BYTES + 1)
    if len(raw_upload) > MAX_EMPLOYEE_PHOTO_BYTES:
        raise HTTPException(status_code=413, detail="The picture is too large. Please use one under 2 MB.")

    try:
        with Image.open(io.BytesIO(raw_upload)) as probe:
            if probe.format not in ALLOWED_EMPLOYEE_PHOTO_FORMATS:
                raise ValueError("Unsupported picture format.")
            if probe.width * probe.height > MAX_EMPLOYEE_PHOTO_PIXELS:
                raise ValueError("Picture dimensions are too large.")
            probe.verify()

        with Image.open(io.BytesIO(raw_upload)) as picture:
            picture.load()
            redrawn = ImageOps.exif_transpose(picture).convert("RGB")
            redrawn.thumbnail((EMPLOYEE_PHOTO_OUTPUT_PIXELS, EMPLOYEE_PHOTO_OUTPUT_PIXELS))
            clean_jpeg = io.BytesIO()
            redrawn.save(clean_jpeg, format="JPEG", quality=85)
    except Exception:
        raise HTTPException(status_code=400, detail="That file is not a valid JPG, PNG or WEBP picture.")

    stored_file_name = f"employee_{employee_id}_{uuid.uuid4().hex}.jpg"
    stored_file_path = os.path.join(EMPLOYEE_PHOTO_STORAGE_DIRECTORY, stored_file_name)

    with open(stored_file_path, "wb") as destination_file:
        destination_file.write(clean_jpeg.getvalue())

    public_photo_url = f"/employee-photos/{stored_file_name}"

    # A photo belongs to the person, not to one payroll row: a salary change
    # starts a new row for the same person, so every row of this person
    # points to the new picture.
    person_key = target_staff.person_id or target_staff.id
    person_rows = db.query(models.Payroll).filter(
        or_(models.Payroll.person_id == person_key, models.Payroll.id == target_staff.id)
    ).all()
    replaced_photo_urls = {row.photo_url for row in person_rows if row.photo_url}

    photo_snapshots = []
    for row in person_rows:
        photo_snapshots.append((row, {"photo_url": row.photo_url}))
        row.photo_url = public_photo_url
        mirror_row = mirror_db.query(models.Payroll).filter(models.Payroll.id == row.id).first()
        if mirror_row:
            mirror_row.photo_url = public_photo_url

    response_payload = {"status": "Photo uploaded.", "photo_url": public_photo_url}
    try:
        commit_dual_write(db, mirror_db, restore_snapshots=photo_snapshots)
    except HTTPException:
        # The picture was never attached to anyone, so it is not kept.
        _delete_employee_photo_file(stored_file_name)
        raise

    # A replaced picture is deleted once no employee record refers to it.
    # The photos of employees who were removed are never touched, because
    # nothing replaces them.
    for old_photo_url in replaced_photo_urls:
        still_in_use = db.query(models.Payroll).filter(models.Payroll.photo_url == old_photo_url).first()
        if not still_in_use:
            _delete_employee_photo_file(os.path.basename(old_photo_url))
    return response_payload


@app.delete("/management/employees/{employee_id}")
def deactivate_employee_record(
    employee_id: int,
    request: Request,
    client_action_id: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Marks an employee as inactive rather than deleting their record
    outright, so their historical payroll totals survive intact for
    year-end reporting even after they leave or their salary later changes.
    An inactive employee no longer appears in the active staff list or
    counts toward the ongoing payroll overhead calculation.
    """
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, client_action_id)
    if cached_response:
        return cached_response

    target_staff = db.query(models.Payroll).filter(models.Payroll.id == employee_id).first()
    if not target_staff:
        return {"status": "Employee removed."}

    restore_snapshots = [(target_staff, {"is_active": target_staff.is_active})]
    target_staff.is_active = False

    mirror_staff = mirror_db.query(models.Payroll).filter(models.Payroll.id == employee_id).first()
    if mirror_staff:
        mirror_staff.is_active = False

    # Also stops this person's login from working, if they had one — a
    # removed receptionist can no longer log in from that moment on, even
    # though their past bookings and sales still show under their name.
    if target_staff.user_id:
        login_user = db.query(models.User).filter(models.User.id == target_staff.user_id).first()
        if login_user:
            restore_snapshots.append((login_user, {"is_active": login_user.is_active}))
            login_user.is_active = False
        mirror_login_user = mirror_db.query(models.User).filter(models.User.id == target_staff.user_id).first()
        if mirror_login_user:
            mirror_login_user.is_active = False

    response_payload = {"status": "Employee removed."}
    tag_record, mirror_tag_record = build_processed_action_records(client_action_id, response_payload)
    new_records_to_track = []
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track, restore_snapshots=restore_snapshots)
    return response_payload


@app.post("/management/rooms/", status_code=status.HTTP_201_CREATED)
def construct_and_provision_new_room_asset(
    payload: RoomAssetSubmission,
    request: Request,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Administrative Property Asset Configuration Gate.
    Validates physical boundaries, verifies secure terminal hardware whitelists,
    and runs simultaneous dual-write commits across distinct database cores.
    """
    # Verify the incoming socket packet comes directly from an approved manager workstation
    enforce_managerial_hardware_gate(request)
    
    # Extract the paired twin-engine tracking session references from our context dependency container
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    # Clean up input string text identifiers to ensure neat layout sorting
    cleaned_room_id = payload.room_name.strip()

    # Integrity Guardrail: Intercept duplicate asset definitions to prevent layout collisions
    collision_check = db.query(models.RoomAsset).filter(models.RoomAsset.id == cleaned_room_id).first()
    if collision_check:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, 
            detail="Asset Allocation Error: A room using this identifier already exists in the registry."
        )

    # 1. Prepare asset row configuration properties for the primary live engine storage registry
    new_room = models.RoomAsset(
        id=cleaned_room_id,
        room_name=cleaned_room_id,
        description=payload.description.strip(),
        current_status="AVAILABLE" # Automatically initializes fresh rooms as clean and ready for immediate check-ins
    )
    db.add(new_room)
    
    # 2. Replicate matching blueprint parameters for tracking continuity on the secondary disk mirror file
    mirror_room = models.RoomAsset(
        id=cleaned_room_id,
        room_name=cleaned_room_id,
        description=payload.description.strip(),
        current_status="AVAILABLE"
    )
    mirror_db.add(mirror_room)

    # A room sharing an existing description is meant to be priced exactly
    # like the others of that type. Setting a price "by description" only
    # ever reaches the rooms that exist at that moment, so without this a
    # new room would silently start with no approved prices at all, even
    # though the manager's screen makes it look like it already belongs to
    # a fully-priced group. Copying an existing sibling's price list here,
    # at creation time, closes that gap.
    inherited_pricing_rows = []
    sibling_room = db.query(models.RoomAsset).filter(
        models.RoomAsset.description == payload.description.strip(),
        models.RoomAsset.id != cleaned_room_id
    ).first()
    if sibling_room:
        sibling_pricing = db.query(models.RoomPricingOption).filter(
            models.RoomPricingOption.room_id == sibling_room.id
        ).all()
        for option in sibling_pricing:
            new_price_row = models.RoomPricingOption(
                room_id=cleaned_room_id, duration_hours=option.duration_hours, price=option.price
            )
            mirror_price_row = models.RoomPricingOption(
                room_id=cleaned_room_id, duration_hours=option.duration_hours, price=option.price
            )
            db.add(new_price_row)
            mirror_db.add(mirror_price_row)
            inherited_pricing_rows.append(new_price_row)

    response_payload = {"status": "Physical room asset successfully bound to live database registry."}
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    new_records_to_track = [new_room] + inherited_pricing_rows
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    # 3. Commit to both storage locations, linked as one action
    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track)

    return response_payload


@app.get("/management/rooms/")
def list_all_room_assets(db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(verify_admin_roles)):
    """
    Returns every room currently configured in the system, so the Room
    Management screen always reflects what is actually stored on the
    server rather than a fixed local list.
    """
    db = db_tuple[0]
    all_rooms = db.query(models.RoomAsset).order_by(models.RoomAsset.room_name).all()
    return {
        "rooms": [
            {"id": room.id, "room_name": room.room_name, "description": room.description}
            for room in all_rooms
        ]
    }


@app.patch("/management/rooms/{room_id}")
def edit_existing_room_asset(
    room_id: str,
    payload: RoomEditSubmission,
    request: Request,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Updates an existing room's description. The room's name is never
    changed here; see RoomEditSubmission for why.
    """
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    target_room = db.query(models.RoomAsset).filter(models.RoomAsset.id == room_id.strip()).first()
    if not target_room:
        raise HTTPException(status_code=404, detail="Target room asset not found.")

    new_description = payload.description.strip()
    previous_values = {"description": target_room.description}
    description_is_changing = new_description != target_room.description

    target_room.description = new_description

    mirror_room = mirror_db.query(models.RoomAsset).filter(models.RoomAsset.id == room_id.strip()).first()
    if mirror_room:
        mirror_room.description = new_description

    # A room's approved prices belong to its room type. When the type
    # changes, the room takes on the price list of its new type, by the same
    # rule used when a room is created:
    #   - another room already has this type: this room gets a copy of that
    #     room's price list, replacing whatever prices it had before;
    #   - no other room has this type (a brand-new type): the room's prices
    #     are cleared, and the manager sets new ones before it can be booked.
    new_price_rows = []
    removed_price_details = []
    price_list_cleared = False
    if description_is_changing:
        old_price_rows = db.query(models.RoomPricingOption).filter(
            models.RoomPricingOption.room_id == target_room.id
        ).all()
        removed_price_details = [
            {"room_id": row.room_id, "duration_hours": row.duration_hours, "price": row.price}
            for row in old_price_rows
        ]
        for row in old_price_rows:
            db.delete(row)
        for mirror_row in mirror_db.query(models.RoomPricingOption).filter(
            models.RoomPricingOption.room_id == target_room.id
        ).all():
            mirror_db.delete(mirror_row)

        sibling_room = db.query(models.RoomAsset).filter(
            models.RoomAsset.description == new_description,
            models.RoomAsset.id != target_room.id,
        ).first()
        if sibling_room:
            for option in db.query(models.RoomPricingOption).filter(models.RoomPricingOption.room_id == sibling_room.id).all():
                copied_row = models.RoomPricingOption(room_id=target_room.id, duration_hours=option.duration_hours, price=option.price)
                db.add(copied_row)
                mirror_db.add(models.RoomPricingOption(room_id=target_room.id, duration_hours=option.duration_hours, price=option.price))
                new_price_rows.append(copied_row)
        else:
            price_list_cleared = True

    if not description_is_changing:
        status_text = "Room updated."
    elif price_list_cleared:
        status_text = "Room updated. This is a new room type, so its prices were cleared. Set new prices before it can be booked."
    else:
        status_text = "Room updated. It now uses the prices of its new room type."
    response_payload = {"status": status_text, "id": room_id.strip()}
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    new_records_to_track = list(new_price_rows)
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(
        db, mirror_db, new_db_records=new_records_to_track,
        restore_snapshots=[(target_room, previous_values)],
        deleted_records=[(models.RoomPricingOption, details) for details in removed_price_details],
    )
    return response_payload


@app.delete("/management/rooms/{room_id}")
def purge_and_decommission_room_asset(
    room_id: str,
    request: Request,
    client_action_id: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Drops a target room inventory definition permanently out of database configurations.
    """
    # Enforce strict regional hardware network perimeters to prevent front desk clerks from dropping room files
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, client_action_id)
    if cached_response:
        return cached_response

    # Locate the target asset primary keys inside both discrete tracking environments
    target_room = db.query(models.RoomAsset).filter(models.RoomAsset.id == room_id.strip()).first()
    mirror_room = mirror_db.query(models.RoomAsset).filter(models.RoomAsset.id == room_id.strip()).first()

    if not target_room:
        return {"status": "Physical asset row completely removed from database configurations."}

    # Save the record's details before deleting it, in case the backup
    # delete fails and this room needs to be recreated.
    saved_details = {
        "id": target_room.id,
        "room_name": target_room.room_name,
        "description": target_room.description,
        "current_status": target_room.current_status,
    }

    # A deleted room must not leave orphaned entries behind in its price
    # list, so those are removed together with the room as one action.
    orphaned_prices = db.query(models.RoomPricingOption).filter(models.RoomPricingOption.room_id == room_id.strip()).all()
    mirror_orphaned_prices = mirror_db.query(models.RoomPricingOption).filter(models.RoomPricingOption.room_id == room_id.strip()).all()

    saved_price_details = [
        {"room_id": p.room_id, "duration_hours": p.duration_hours, "price": p.price}
        for p in orphaned_prices
    ]

    db.delete(target_room)
    if mirror_room:
        mirror_db.delete(mirror_room)

    for price_entry in orphaned_prices:
        db.delete(price_entry)
    for mirror_price_entry in mirror_orphaned_prices:
        mirror_db.delete(mirror_price_entry)

    response_payload = {"status": "Physical asset row completely removed from database configurations."}
    tag_record, mirror_tag_record = build_processed_action_records(client_action_id, response_payload)
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)

    deleted_record_list = [(models.RoomAsset, saved_details)]
    deleted_record_list.extend((models.RoomPricingOption, details) for details in saved_price_details)

    commit_dual_write(db, mirror_db, new_db_records=[tag_record] if tag_record else None, deleted_records=deleted_record_list)

    return response_payload


# --- ROOM PRICING TABLE MANAGEMENT ---

@app.post("/management/room-pricing/")
def add_room_pricing_option(
    payload: RoomPricingSubmission,
    request: Request,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Adds a manager-approved duration and price combination for a room.
    Bookings are only accepted automatically if they match an entry here.
    """
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    target_room = db.query(models.RoomAsset).filter(models.RoomAsset.id == payload.room_id.strip()).first()
    if not target_room:
        raise HTTPException(status_code=404, detail="Target room asset not found.")

    existing_entry = db.query(models.RoomPricingOption).filter(
        models.RoomPricingOption.room_id == payload.room_id.strip(),
        models.RoomPricingOption.duration_hours == payload.duration_hours
    ).first()
    if existing_entry:
        raise HTTPException(status_code=400, detail="A price is already set for this room and duration.")

    new_price = models.RoomPricingOption(room_id=payload.room_id.strip(), duration_hours=payload.duration_hours, price=payload.price)
    mirror_price = models.RoomPricingOption(room_id=payload.room_id.strip(), duration_hours=payload.duration_hours, price=payload.price)
    db.add(new_price)
    mirror_db.add(mirror_price)

    response_payload = {"status": "Room price entry added.", "room_id": payload.room_id.strip(), "duration_hours": payload.duration_hours, "price": float(payload.price)}
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    new_records_to_track = [new_price]
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track)
    return response_payload


@app.post("/management/room-pricing/by-description/")
def set_room_pricing_for_description_group(
    payload: DescriptionPricingSubmission,
    request: Request,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Sets a duration and price for every room sharing the given
    description, in one action. If a room in the group already has a
    price set for this duration, that price is updated; otherwise a new
    entry is created for it. This is the normal way pricing is now
    managed, since a guesthouse prices a group of matching rooms
    identically rather than one room at a time.
    """
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    cleaned_description = payload.description.strip()
    matching_rooms = db.query(models.RoomAsset).filter(models.RoomAsset.description == cleaned_description).all()
    if not matching_rooms:
        raise HTTPException(status_code=404, detail="No rooms found with this description.")

    new_records_to_track = []
    restore_snapshots = []

    for room in matching_rooms:
        existing_entry = db.query(models.RoomPricingOption).filter(
            models.RoomPricingOption.room_id == room.id,
            models.RoomPricingOption.duration_hours == payload.duration_hours
        ).first()
        if existing_entry:
            restore_snapshots.append((existing_entry, {"price": existing_entry.price}))
            existing_entry.price = payload.price
        else:
            new_entry = models.RoomPricingOption(room_id=room.id, duration_hours=payload.duration_hours, price=payload.price)
            db.add(new_entry)
            new_records_to_track.append(new_entry)

    # The mirror database is queried and updated independently, following
    # the same matching logic, so both copies end up identical.
    mirror_matching_rooms = mirror_db.query(models.RoomAsset).filter(models.RoomAsset.description == cleaned_description).all()
    for room in mirror_matching_rooms:
        existing_entry = mirror_db.query(models.RoomPricingOption).filter(
            models.RoomPricingOption.room_id == room.id,
            models.RoomPricingOption.duration_hours == payload.duration_hours
        ).first()
        if existing_entry:
            existing_entry.price = payload.price
        else:
            mirror_db.add(models.RoomPricingOption(room_id=room.id, duration_hours=payload.duration_hours, price=payload.price))

    response_payload = {
        "status": f"Price applied to {len(matching_rooms)} room(s) sharing this description.",
        "rooms_updated": [room.id for room in matching_rooms],
        "duration_hours": payload.duration_hours,
        "price": float(payload.price),
    }
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track, restore_snapshots=restore_snapshots)
    return response_payload


@app.delete("/management/room-pricing/by-description/")
def remove_room_pricing_for_description_group(
    description: str,
    duration_hours: int,
    request: Request,
    client_action_id: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Removes a duration and price combination from every room sharing the
    given description, in one action.
    """
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, client_action_id)
    if cached_response:
        return cached_response

    cleaned_description = canonical_name(description)
    matching_room_ids = [
        room.id for room in db.query(models.RoomAsset).filter(models.RoomAsset.description == cleaned_description).all()
    ]
    targets = db.query(models.RoomPricingOption).filter(
        models.RoomPricingOption.room_id.in_(matching_room_ids),
        models.RoomPricingOption.duration_hours == duration_hours
    ).all()

    saved_details = [
        {"room_id": target.room_id, "duration_hours": target.duration_hours, "price": target.price}
        for target in targets
    ]
    for target in targets:
        db.delete(target)

    mirror_matching_room_ids = [
        room.id for room in mirror_db.query(models.RoomAsset).filter(models.RoomAsset.description == cleaned_description).all()
    ]
    mirror_targets = mirror_db.query(models.RoomPricingOption).filter(
        models.RoomPricingOption.room_id.in_(mirror_matching_room_ids),
        models.RoomPricingOption.duration_hours == duration_hours
    ).all()
    for mirror_target in mirror_targets:
        mirror_db.delete(mirror_target)

    response_payload = {"status": "Price removed for all rooms sharing this description."}
    tag_record, mirror_tag_record = build_processed_action_records(client_action_id, response_payload)
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)

    deleted_record_list = [(models.RoomPricingOption, details) for details in saved_details]
    commit_dual_write(db, mirror_db, new_db_records=[tag_record] if tag_record else None, deleted_records=deleted_record_list)
    return response_payload


@app.delete("/management/room-pricing/{pricing_id}")
def remove_room_pricing_option(
    pricing_id: int,
    request: Request,
    client_action_id: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Removes a duration and price combination from a room's approved price list.
    """
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, client_action_id)
    if cached_response:
        return cached_response

    target_price = db.query(models.RoomPricingOption).filter(models.RoomPricingOption.id == pricing_id).first()
    mirror_price = mirror_db.query(models.RoomPricingOption).filter(models.RoomPricingOption.id == pricing_id).first()

    if not target_price:
        return {"status": "Room price entry removed."}

    saved_details = {
        "room_id": target_price.room_id,
        "duration_hours": target_price.duration_hours,
        "price": target_price.price,
    }

    db.delete(target_price)
    if mirror_price:
        mirror_db.delete(mirror_price)

    response_payload = {"status": "Room price entry removed."}
    tag_record, mirror_tag_record = build_processed_action_records(client_action_id, response_payload)
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)

    commit_dual_write(db, mirror_db, new_db_records=[tag_record] if tag_record else None, deleted_records=[(models.RoomPricingOption, saved_details)])
    return response_payload


@app.get("/rooms/pricing/")
def list_room_pricing_options(db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    """
    Returns every room's current approved duration and price combinations.
    Used by the booking screen to only offer valid, manager-approved options.
    """
    db = db_tuple[0]
    all_entries = db.query(models.RoomPricingOption).order_by(models.RoomPricingOption.room_id, models.RoomPricingOption.duration_hours).all()
    return {
        "pricing": [
            {"id": entry.id, "room_id": entry.room_id, "duration_hours": entry.duration_hours, "price": float(entry.price)}
            for entry in all_entries
        ]
    }


# --- MANAGER BOOKING OVERRIDE (CANCEL AND RESTORE FROM RECORDS) ---

@app.post("/management/bookings/{booking_id}/manager-cancel/")
def manager_cancel_booking(
    booking_id: int,
    request: Request,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Lets the manager cancel any booking from the Records screen, with no
    time limit. The booking is never deleted: it stays in the Guest Log
    marked as cancelled by the manager, and its money (and the money of its
    extensions) leaves every total.

    If the booking is the one currently in its room, the room goes to
    DIRTY exactly as an ordinary cancel does. A booking that is already
    over leaves its room's state alone.

    What the booking looked like beforehand is saved in the
    manager_override_records table, so Restore can put it back.
    """
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    booking = db.query(models.Booking).filter(models.Booking.id == booking_id).first()
    if not booking:
        raise HTTPException(status_code=404, detail="Booking not found.")
    if booking.is_cancelled:
        raise HTTPException(status_code=400, detail="This booking is already cancelled.")

    now = datetime.datetime.utcnow()
    latest_in_room = db.query(models.Booking).filter(
        models.Booking.room_number == booking.room_number
    ).order_by(models.Booking.id.desc()).first()
    is_latest_in_room = bool(latest_in_room and latest_in_room.id == booking.id)

    previous_values = {
        "is_cancelled": booking.is_cancelled,
        "cancelled_by": booking.cancelled_by,
        "room_status": booking.room_status,
        "actual_checkout_time": booking.actual_checkout_time,
    }
    standing_extensions = db.query(models.BookingExtension).filter(
        models.BookingExtension.booking_id == booking.id,
        models.BookingExtension.is_cancelled == False,
    ).all()
    extension_snapshots = [
        (extension, {"is_cancelled": False, "cancelled_by": None, "cancelled_at": None})
        for extension in standing_extensions
    ]

    booking.is_cancelled = True
    booking.cancelled_by = current_user.id
    booking.actual_checkout_time = now
    if is_latest_in_room and booking.room_status == "OCCUPIED":
        booking.room_status = "DIRTY"
    # Each standing extension is cancelled by the same person at the same
    # moment as its booking, so Records can show who cancelled it and when.
    for extension in standing_extensions:
        extension.is_cancelled = True
        extension.cancelled_by = current_user.id
        extension.cancelled_at = now

    mirror_booking = mirror_db.query(models.Booking).filter(models.Booking.id == booking_id).first()
    if mirror_booking:
        mirror_booking.is_cancelled = True
        mirror_booking.cancelled_by = current_user.id
        mirror_booking.actual_checkout_time = now
        mirror_booking.room_status = booking.room_status
    for extension in standing_extensions:
        mirror_extension = mirror_db.query(models.BookingExtension).filter(models.BookingExtension.id == extension.id).first()
        if mirror_extension:
            mirror_extension.is_cancelled = True
            mirror_extension.cancelled_by = current_user.id
            mirror_extension.cancelled_at = now

    extension_ids_text = ",".join(str(extension.id) for extension in standing_extensions) or None
    override_row = models.ManagerOverrideRecord(
        booking_id=booking_id, action="CANCEL", performed_by=current_user.id,
        previous_room_status=previous_values["room_status"],
        previous_actual_checkout_time=previous_values["actual_checkout_time"],
        cancelled_extension_ids=extension_ids_text, performed_at=now,
    )
    mirror_override_row = models.ManagerOverrideRecord(
        booking_id=booking_id, action="CANCEL", performed_by=current_user.id,
        previous_room_status=previous_values["room_status"],
        previous_actual_checkout_time=previous_values["actual_checkout_time"],
        cancelled_extension_ids=extension_ids_text, performed_at=now,
    )
    db.add(override_row)
    mirror_db.add(mirror_override_row)

    commit_dual_write(
        db, mirror_db, new_db_records=[override_row],
        restore_snapshots=[(booking, previous_values)] + extension_snapshots,
    )
    return {"action_taken": "MANAGER_CANCELLED", "booking_id": booking_id, "room": booking.room_number}


@app.post("/management/bookings/{booking_id}/manager-restore/")
def manager_restore_booking(
    booking_id: int,
    request: Request,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Reverses a manager cancellation: the booking and the extensions that
    were standing when it was cancelled count again in every total.

    Only the booking and its money come back. The room is left exactly as
    it is: a restore never turns a room back to Occupied, so it can never
    disturb a countdown or a guest who has since taken the room.

    The actual-checkout time follows what was true before the cancellation.
    A guest who had already been checked out keeps the checkout time
    recorded then. A guest who was still in the room when the booking was
    cancelled keeps the cancellation time as the time the stay ended.

    Only a booking the manager cancelled can be restored here.
    """
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    booking = db.query(models.Booking).filter(models.Booking.id == booking_id).first()
    if not booking:
        raise HTTPException(status_code=404, detail="Booking not found.")

    last_override = db.query(models.ManagerOverrideRecord).filter(
        models.ManagerOverrideRecord.booking_id == booking_id,
        models.ManagerOverrideRecord.action.in_(["CANCEL", "RESTORE"]),
    ).order_by(models.ManagerOverrideRecord.id.desc()).first()
    if not booking.is_cancelled or not last_override or last_override.action != "CANCEL":
        raise HTTPException(status_code=400, detail="Only a booking the manager cancelled can be restored.")

    now = datetime.datetime.utcnow()
    previous_values = {
        "is_cancelled": booking.is_cancelled,
        "cancelled_by": booking.cancelled_by,
        "room_status": booking.room_status,
        "actual_checkout_time": booking.actual_checkout_time,
    }
    booking.is_cancelled = False
    booking.cancelled_by = None

    mirror_booking = mirror_db.query(models.Booking).filter(models.Booking.id == booking_id).first()
    if mirror_booking:
        mirror_booking.is_cancelled = False
        mirror_booking.cancelled_by = None

    # The cancellation overwrote the checkout time of a guest who had
    # already left, so the time saved at that moment is put back.
    if last_override.previous_actual_checkout_time is not None:
        booking.actual_checkout_time = last_override.previous_actual_checkout_time
        if mirror_booking:
            mirror_booking.actual_checkout_time = last_override.previous_actual_checkout_time

    extension_snapshots = []
    for extension_id_text in (last_override.cancelled_extension_ids or "").split(","):
        if not extension_id_text.strip():
            continue
        extension = db.query(models.BookingExtension).filter(models.BookingExtension.id == int(extension_id_text)).first()
        if extension:
            extension_snapshots.append((extension, {
                "is_cancelled": extension.is_cancelled,
                "cancelled_by": extension.cancelled_by,
                "cancelled_at": extension.cancelled_at,
            }))
            extension.is_cancelled = False
            extension.cancelled_by = None
            extension.cancelled_at = None
        mirror_extension = mirror_db.query(models.BookingExtension).filter(models.BookingExtension.id == int(extension_id_text)).first()
        if mirror_extension:
            mirror_extension.is_cancelled = False
            mirror_extension.cancelled_by = None
            mirror_extension.cancelled_at = None

    override_row = models.ManagerOverrideRecord(
        booking_id=booking_id, action="RESTORE", performed_by=current_user.id, performed_at=now,
    )
    mirror_override_row = models.ManagerOverrideRecord(
        booking_id=booking_id, action="RESTORE", performed_by=current_user.id, performed_at=now,
    )
    db.add(override_row)
    mirror_db.add(mirror_override_row)

    commit_dual_write(
        db, mirror_db, new_db_records=[override_row],
        restore_snapshots=[(booking, previous_values)] + extension_snapshots,
    )
    return {"action_taken": "MANAGER_RESTORED", "booking_id": booking_id, "room": booking.room_number}


@app.post("/management/extensions/{extension_id}/manager-cancel/")
def manager_cancel_extension(
    extension_id: int,
    request: Request,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Lets the manager cancel one extension from the Records screen, with no
    time limit, exactly as a whole booking can be cancelled. The extension
    is never deleted: it stays in Records marked as cancelled by the
    manager, and its money leaves every total. The booking it belongs to
    is left as it is, and so is the room.
    """
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    extension = db.query(models.BookingExtension).filter(models.BookingExtension.id == extension_id).first()
    if not extension:
        raise HTTPException(status_code=404, detail="Extension not found.")
    if extension.is_cancelled:
        raise HTTPException(status_code=400, detail="This extension is already cancelled.")

    now = datetime.datetime.utcnow()
    extension.is_cancelled = True
    extension.cancelled_by = current_user.id
    extension.cancelled_at = now
    mirror_extension = mirror_db.query(models.BookingExtension).filter(models.BookingExtension.id == extension_id).first()
    if mirror_extension:
        mirror_extension.is_cancelled = True
        mirror_extension.cancelled_by = current_user.id
        mirror_extension.cancelled_at = now

    override_row = models.ManagerOverrideRecord(
        booking_id=extension.booking_id, action="CANCEL_EXTENSION", performed_by=current_user.id,
        cancelled_extension_ids=str(extension.id), performed_at=now,
    )
    mirror_override_row = models.ManagerOverrideRecord(
        booking_id=extension.booking_id, action="CANCEL_EXTENSION", performed_by=current_user.id,
        cancelled_extension_ids=str(extension.id), performed_at=now,
    )
    db.add(override_row)
    mirror_db.add(mirror_override_row)

    commit_dual_write(
        db, mirror_db, new_db_records=[override_row],
        restore_snapshots=[(extension, {"is_cancelled": False, "cancelled_by": None, "cancelled_at": None})],
    )
    return {"action_taken": "MANAGER_CANCELLED_EXTENSION", "extension_id": extension_id}


@app.post("/management/extensions/{extension_id}/manager-restore/")
def manager_restore_extension(
    extension_id: int,
    request: Request,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Reverses a manager cancellation of one extension, so its money counts
    again. Only an extension the manager cancelled can be restored here.
    The room is never touched.
    """
    enforce_managerial_hardware_gate(request)
    db, mirror_db = db_tuple

    extension = db.query(models.BookingExtension).filter(models.BookingExtension.id == extension_id).first()
    if not extension:
        raise HTTPException(status_code=404, detail="Extension not found.")

    last_override = db.query(models.ManagerOverrideRecord).filter(
        models.ManagerOverrideRecord.booking_id == extension.booking_id,
        models.ManagerOverrideRecord.action.in_(["CANCEL_EXTENSION", "RESTORE_EXTENSION"]),
        models.ManagerOverrideRecord.cancelled_extension_ids == str(extension.id),
    ).order_by(models.ManagerOverrideRecord.id.desc()).first()
    if not extension.is_cancelled or not last_override or last_override.action != "CANCEL_EXTENSION":
        raise HTTPException(status_code=400, detail="Only an extension the manager cancelled can be restored.")

    booking = db.query(models.Booking).filter(models.Booking.id == extension.booking_id).first()
    if booking and booking.is_cancelled:
        raise HTTPException(status_code=400, detail="The booking is cancelled. Restore the booking instead.")

    now = datetime.datetime.utcnow()
    cancelled_by_before, cancelled_at_before = extension.cancelled_by, extension.cancelled_at
    extension.is_cancelled = False
    extension.cancelled_by = None
    extension.cancelled_at = None
    mirror_extension = mirror_db.query(models.BookingExtension).filter(models.BookingExtension.id == extension_id).first()
    if mirror_extension:
        mirror_extension.is_cancelled = False
        mirror_extension.cancelled_by = None
        mirror_extension.cancelled_at = None

    override_row = models.ManagerOverrideRecord(
        booking_id=extension.booking_id, action="RESTORE_EXTENSION", performed_by=current_user.id,
        cancelled_extension_ids=str(extension.id), performed_at=now,
    )
    mirror_override_row = models.ManagerOverrideRecord(
        booking_id=extension.booking_id, action="RESTORE_EXTENSION", performed_by=current_user.id,
        cancelled_extension_ids=str(extension.id), performed_at=now,
    )
    db.add(override_row)
    mirror_db.add(mirror_override_row)

    commit_dual_write(
        db, mirror_db, new_db_records=[override_row],
        restore_snapshots=[(extension, {"is_cancelled": True, "cancelled_by": cancelled_by_before, "cancelled_at": cancelled_at_before})],
    )
    return {"action_taken": "MANAGER_RESTORED_EXTENSION", "extension_id": extension_id}


# --- LOGIN RECORD (MANAGER READS WHO LOGGED IN, AND WHEN) ---

@app.get("/management/login-records/")
def get_login_records(
    request: Request,
    period: str = None,
    days_back: int = None,
    start_date: str = None,
    end_date: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    The Login Record sub-view of the Records tab: every login attempt in
    the chosen period, newest first. Failed attempts and logins from an
    unexpected kind of device carry a plain note; nothing here blocks
    anyone. For a successful login, first_today says whether it was that
    person's first successful login of its GMT day, which is the moment
    they started work.
    """
    enforce_managerial_hardware_gate(request)
    db = db_tuple[0]
    window_start, window_end = _resolve_period_window(days_back, start_date, end_date, period)

    rows = db.query(models.LoginRecord).filter(
        models.LoginRecord.attempted_at >= window_start,
        models.LoginRecord.attempted_at < window_end,
    ).order_by(models.LoginRecord.attempted_at.desc(), models.LoginRecord.id.desc()).limit(2000).all()

    # Real names for known logins, the same names used everywhere else.
    display_names_by_id = _staff_display_names(db)
    name_by_username = {
        user.username: display_names_by_id.get(user.id, user.username)
        for user in db.query(models.User).all()
    }

    # The first successful login of each person on each day (oldest row of
    # that day), worked out over the rows being returned.
    first_success_ids = set()
    seen_person_days = set()
    for row in sorted(rows, key=lambda r: (r.attempted_at, r.id)):
        if row.outcome != "SUCCESS":
            continue
        person_day = (row.username_tried, row.attempted_at.date())
        if person_day not in seen_person_days:
            seen_person_days.add(person_day)
            first_success_ids.add(row.id)

    return {
        "records": [
            {
                "id": row.id,
                "name": name_by_username.get(row.username_tried, row.username_tried),
                "username_tried": row.username_tried,
                "outcome": row.outcome,
                "role": row.role,
                "client_ip": row.client_ip,
                "flag_note": row.flag_note,
                "attempted_at": row.attempted_at.isoformat(),
                "first_today": row.id in first_success_ids,
            }
            for row in rows
        ]
    }


# --- DAILY EXPENSE MANAGEMENT ---

@app.get("/expenses/")
def list_daily_expenses(db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(verify_admin_roles)):
    """
    Returns every Utilities and Expendables entry logged during the
    currently open session, so a closed shift's entries stop showing up
    once a new one has started.
    """
    db = db_tuple[0]
    active_session = db.query(models.SessionLog).filter(models.SessionLog.is_closed == False).first()
    if not active_session:
        return {"expenses": []}

    all_expenses = db.query(models.DailyExpense).filter(
        models.DailyExpense.session_id == active_session.id
    ).order_by(models.DailyExpense.timestamp.desc()).all()
    return {
        "expenses": [
            {
                "id": expense.id,
                "item_or_reason": canonical_name(expense.item_or_reason),
                "amount_spent": float(expense.amount_spent),
                "category": expense.category,
            }
            for expense in all_expenses
        ]
    }


@app.post("/expenses/", status_code=status.HTTP_201_CREATED)
def log_daily_expense(
    payload: DailyExpenseSubmission,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Logs a new Utilities or Expendables entry against the currently active shift.
    """
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    active_session = db.query(models.SessionLog).filter(models.SessionLog.is_closed == False).first()
    if not active_session:
        raise HTTPException(status_code=400, detail="No active runtime session footprint.")

    new_expense = models.DailyExpense(
        session_id=active_session.id,
        item_or_reason=payload.item_or_reason.strip(),
        amount_spent=payload.amount_spent,
        category=payload.category,
    )
    mirror_expense = models.DailyExpense(
        session_id=active_session.id,
        item_or_reason=payload.item_or_reason.strip(),
        amount_spent=payload.amount_spent,
        category=payload.category,
    )
    db.add(new_expense)
    mirror_db.add(mirror_expense)

    response_payload = {"status": "Expense logged."}
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    new_records_to_track = [new_expense]
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track)
    response_payload["id"] = new_expense.id
    return response_payload


@app.patch("/expenses/{expense_id}")
def edit_daily_expense(
    expense_id: int,
    payload: DailyExpenseEditSubmission,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Updates the item description and amount of an existing expense entry.
    The category is not changed here; a re-categorized entry should be
    removed and logged again under the correct category instead.
    """
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, payload.client_action_id)
    if cached_response:
        return cached_response

    target_expense = db.query(models.DailyExpense).filter(models.DailyExpense.id == expense_id).first()
    if not target_expense:
        raise HTTPException(status_code=404, detail="Target expense entry not found.")

    previous_values = {"item_or_reason": target_expense.item_or_reason, "amount_spent": target_expense.amount_spent}
    target_expense.item_or_reason = payload.item_or_reason.strip()
    target_expense.amount_spent = payload.amount_spent

    mirror_expense = mirror_db.query(models.DailyExpense).filter(models.DailyExpense.id == expense_id).first()
    if mirror_expense:
        mirror_expense.item_or_reason = payload.item_or_reason.strip()
        mirror_expense.amount_spent = payload.amount_spent

    response_payload = {"status": "Expense updated."}
    tag_record, mirror_tag_record = build_processed_action_records(payload.client_action_id, response_payload)
    new_records_to_track = []
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)
        new_records_to_track.append(tag_record)

    commit_dual_write(db, mirror_db, new_db_records=new_records_to_track, restore_snapshots=[(target_expense, previous_values)])
    return response_payload


@app.delete("/expenses/{expense_id}")
def delete_daily_expense(
    expense_id: int,
    client_action_id: str = None,
    db_tuple: tuple = Depends(get_db),
    current_user: models.User = Depends(verify_admin_roles)
):
    """
    Permanently removes a logged expense entry.
    """
    db, mirror_db = db_tuple

    cached_response = find_previously_processed_action(db, client_action_id)
    if cached_response:
        return cached_response

    target_expense = db.query(models.DailyExpense).filter(models.DailyExpense.id == expense_id).first()
    mirror_expense = mirror_db.query(models.DailyExpense).filter(models.DailyExpense.id == expense_id).first()

    if not target_expense:
        return {"status": "Expense removed."}

    saved_details = {
        "session_id": target_expense.session_id,
        "item_or_reason": target_expense.item_or_reason,
        "amount_spent": target_expense.amount_spent,
        "category": target_expense.category,
    }

    db.delete(target_expense)
    if mirror_expense:
        mirror_db.delete(mirror_expense)

    response_payload = {"status": "Expense removed."}
    tag_record, mirror_tag_record = build_processed_action_records(client_action_id, response_payload)
    if tag_record:
        db.add(tag_record)
        mirror_db.add(mirror_tag_record)

    commit_dual_write(db, mirror_db, new_db_records=[tag_record] if tag_record else None, deleted_records=[(models.DailyExpense, saved_details)])
    return response_payload


# --- LIVE ROOM STATUS FEED ---

@app.get("/shift/activity-summary/")
def get_shift_activity_summary(db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    """
    The "what has happened so far this shift" lists for the receptionist's
    screen, so whoever is at the front desk is never in the dark about what
    is going on (they cannot open the manager's screens).

    Covers the WHOLE shift (the session that is open right now), whoever
    made each entry. An extension counts as a booking here, exactly as it
    does everywhere else. Each line says only WHAT happened and for how
    much: the room, the number of hours and the price for a booking or an
    extension; the item, the quantity and the total price for a shop sale.
    Nobody's name is ever included, so one person at the front desk cannot
    see what another has brought in. Cancelled bookings and cancelled
    extensions are left out.
    """
    db = db_tuple[0]
    empty_answer = {"bookings_total": 0, "bookings": [], "sales_total": 0, "sales_amount": 0.0, "sales": []}
    active_session = db.query(models.SessionLog).filter(models.SessionLog.is_closed == False).order_by(models.SessionLog.id.desc()).first()
    if not active_session:
        return empty_answer

    booking_rows = db.query(models.Booking).filter(
        models.Booking.session_id == active_session.id,
        models.Booking.is_cancelled == False,
    ).all()

    extension_rows = db.query(models.BookingExtension, models.Booking.room_number).join(
        models.Booking, models.BookingExtension.booking_id == models.Booking.id
    ).filter(
        models.BookingExtension.timestamp >= active_session.start_time,
        models.BookingExtension.is_cancelled == False,
    ).all()

    sale_rows = db.query(models.AncillarySale).filter(
        models.AncillarySale.session_id == active_session.id,
    ).all()

    booking_lines = [
        {"kind": "booking", "room": booking.room_number, "hours": int(booking.duration_hours),
         "price": float(booking.total_paid), "at": booking.timestamp.isoformat()}
        for booking in booking_rows
    ]
    booking_lines += [
        {"kind": "extension", "room": room_number, "hours": int(extension.additional_hours),
         "price": float(extension.price), "at": extension.timestamp.isoformat()}
        for extension, room_number in extension_rows
    ]
    booking_lines.sort(key=lambda line: line["at"], reverse=True)

    sale_lines = [
        {"item": canonical_name(sale.item_name), "quantity": int(sale.quantity),
         "total": float(sale.total_cost), "at": sale.timestamp.isoformat()}
        for sale in sale_rows
    ]
    sale_lines.sort(key=lambda line: line["at"], reverse=True)

    return {
        "bookings_total": len(booking_lines),
        "bookings": booking_lines,
        "sales_total": len(sale_lines),
        "sales_amount": round(sum(line["total"] for line in sale_lines), 2),
        "sales": sale_lines,
    }


@app.get("/rooms/live-status/")
def get_live_room_status_feed(db_tuple: tuple = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    """
    Returns the current state of every room, plus a live countdown of time
    remaining for any room that is occupied. Shared by the receptionist's
    interactive room grid and the manager's read-only overview screen.

    Status values: AVAILABLE, OCCUPIED, TIME_UP, DIRTY.
    A room shows OCCUPIED until its expected checkout time passes, after
    which it shows TIME_UP until the receptionist actually checks it out.

    Also includes each room's description, and, for an occupied or
    time-expired room, the guest's name, the guest's phone number, the
    booking's own ID, the check-in time, and the room's expected checkout
    deadline, so the front end can display who is in the room, how to
    reach them, and offer actions such as cancellation and extension
    against the correct booking.
    """
    db = db_tuple[0]
    now = datetime.datetime.utcnow()

    all_rooms = db.query(models.RoomAsset).order_by(models.RoomAsset.room_name).all()
    room_feed = []

    for room in all_rooms:
        # The most recent booking for this room decides its current physical
        # state. Cancellation status is a financial/reporting flag and must
        # not be used to filter this out: a cancelled booking still
        # correctly marks the room DIRTY, and skipping it would show a
        # stale status from an older, unrelated booking instead.
        latest_booking = db.query(models.Booking).filter(
            models.Booking.room_number == room.room_name
        ).order_by(models.Booking.id.desc()).first()

        remaining_seconds = None
        guest_name = None
        guest_phone = None
        booking_id = None
        check_in_time = None
        expected_checkout_time = None

        if latest_booking is None or latest_booking.room_status == "AVAILABLE":
            display_status = "AVAILABLE"
        elif latest_booking.room_status == "DIRTY":
            display_status = "DIRTY"
        elif latest_booking.room_status == "OCCUPIED":
            guest_name = canonical_name(latest_booking.guest_name, False)
            guest_phone = latest_booking.guest_phone
            booking_id = latest_booking.id
            check_in_time = latest_booking.check_in_time.isoformat()
            expected_checkout_time = latest_booking.expected_checkout_time.isoformat()
            if latest_booking.expected_checkout_time <= now:
                display_status = "TIME_UP"
                remaining_seconds = 0
            else:
                display_status = "OCCUPIED"
                remaining_seconds = int((latest_booking.expected_checkout_time - now).total_seconds())
        else:
            display_status = latest_booking.room_status

        room_feed.append({
            "room_id": room.id,
            "room_name": room.room_name,
            "description": room.description,
            "status": display_status,
            "remaining_seconds": remaining_seconds,
            "guest_name": guest_name,
            "guest_phone": guest_phone,
            "booking_id": booking_id,
            "check_in_time": check_in_time,
            "expected_checkout_time": expected_checkout_time,
        })

    # A live, running count of what has happened so far during the
    # currently active shift, so a manager can see the day's operational
    # picture as it unfolds rather than waiting for the shift to close.
    # This is intentionally a plain count only, not a financial figure;
    # revenue totals and detailed breakdowns stay in Business Summary.
    active_session = db.query(models.SessionLog).filter(models.SessionLog.is_closed == False).first()
    bookings_this_shift = 0
    cancelled_this_shift = 0
    if active_session:
        bookings_this_shift = db.query(models.Booking).filter(
            models.Booking.session_id == active_session.id,
            models.Booking.is_cancelled == False
        ).count()
        cancelled_this_shift = db.query(models.Booking).filter(
            models.Booking.session_id == active_session.id,
            models.Booking.is_cancelled == True
        ).count()

    # CANCELLATIONS FOR TODAY'S DATE, AS A LIST.
    # Every booking cancelled since midnight today (Ghana time is GMT, the
    # same clock the server keeps), whichever shift it fell in. The list
    # simply starts empty again after midnight. Only the manager's account
    # receives it: the receptionist's grid has no use for it, and it names
    # who cancelled what.
    cancelled_today = []
    if current_user.role in ("Owner", "Manager"):
        start_of_today = now.replace(hour=0, minute=0, second=0, microsecond=0)
        cancelled_rows = db.query(models.Booking).filter(
            models.Booking.is_cancelled == True,
            models.Booking.actual_checkout_time != None,
            models.Booking.actual_checkout_time >= start_of_today,
        ).order_by(models.Booking.actual_checkout_time.desc()).all()
        who = _staff_display_names(db)
        for booking in cancelled_rows:
            cancelled_today.append({
                "booking_id": booking.id,
                "room_name": booking.room_number,
                "guest_name": canonical_name(booking.guest_name, False),
                "cancelled_by": who.get(booking.cancelled_by, "Unknown"),
                "cancelled_at": booking.actual_checkout_time.isoformat(),
            })

    return {
        "rooms": room_feed,
        "server_time": now.isoformat(),
        "bookings_this_shift": bookings_this_shift,
        "cancelled_this_shift": cancelled_this_shift,
        "cancelled_today": cancelled_today,
        "cancelled_today_count": len(cancelled_today),
        # True while an official shift is open, False during the automatic
        # buffer period between shifts. Lets the receptionist's tablet show
        # a plain "Buffer period" banner (with who is logged in) without
        # needing any manager-only endpoint.
        "official_shift_active": bool(active_session and active_session.closure_type != "Buffer_Shift"),
    }
