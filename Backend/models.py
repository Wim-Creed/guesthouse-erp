import datetime
from sqlalchemy import Column, String, Integer, Boolean, DateTime, ForeignKey, Numeric
from sqlalchemy.orm import declarative_base, relationship

# ====================================================================
# CENTRAL RELATIONAL DEFINITION BASE ARCHITECTURE
# ====================================================================
# Instantiates the core SQLAlchemy declarative mapper engine framework.
# This binds table configurations securely on startup execution loops.
Base = declarative_base()


class User(Base):
    """
    [TABLE: user_accounts]
    Logs core front-desk credential layers, authorization states, and responsibilities.
    Fulfills the precise database tracking lookups required by main.py auth systems.
    """
    __tablename__ = "user_accounts"

    # Unique transactional internal key identifying individual employees
    id = Column(Integer, primary_key=True, autoincrement=True)
    
    # Text-string username column locked with an exclusive lookup index constraint
    username = Column(String, unique=True, nullable=False, index=True)
    
    # Store variable for salted and encrypted bcrypt hashes passed down network streams
    password_hash = Column(String, nullable=False) 
    
    # Strict privilege flag mapping roles directly ('Owner', 'Manager', 'Receptionist')
    role = Column(String, nullable=False)          

    # Marks whether this login may still be used. A removed receptionist is
    # switched off here rather than deleted, so every booking and sale they
    # recorded keeps pointing at a real account and stays visible in reports.
    is_active = Column(Boolean, default=True, nullable=False)

    # Set when a manager resets a receptionist's password to a temporary
    # one. The person must then choose their own password at next login.
    must_change_password = Column(Boolean, default=False, nullable=False)

    # Hash of the one-time recovery code shown when the administrator
    # account is first created. Only used for the administrator's own
    # "Forgot password?" path, which works without any internet.
    recovery_code_hash = Column(String, nullable=True)

    # Bumped by one every time this account's username or password
    # changes. The number in effect at the moment someone logged in is
    # stamped into their login token; if it no longer matches this column,
    # the token is treated as ended immediately, on every device, even
    # though it has not technically expired yet. This is what makes a
    # login change force an immediate logout everywhere, not only on the
    # device where the change was made.
    token_version = Column(Integer, default=1, nullable=False)


class RoomAsset(Base):
    """
    [TABLE: room_assets]
    Houses static property structures mapped cleanly out to clerk tracking grids.
    Maintains baseline properties defining individual rental facilities on location.
    """
    __tablename__ = "room_assets"

    # Direct room key matching your front-facing layout grid tracking maps
    id = Column(String, primary_key=True, index=True)
    
    # Descriptive identifier label displaying room numbers uniquely across interfaces
    room_name = Column(String, unique=True, nullable=False)
    
    # Physical property information string tracking bed capacities or spatial configurations
    description = Column(String, nullable=False)
    
    # Operational stage string engine checking asset availability ('AVAILABLE', 'OCCUPIED', 'DIRTY')
    current_status = Column(String, default="AVAILABLE", nullable=False)

    # Links each room to its manager-approved list of duration/price combinations
    pricing_options = relationship("RoomPricingOption", back_populates="room")
# ====================================================================
# FASTAPI BACKEND SYSTEM CORE ENGINE - PART 2: TRANSACTIONAL LEDGERS
# ====================================================================
# (Ensure this block shares or imports the 'Base' instance initialized in Part 1)

class Booking(Base):
    """
    [TABLE: room_bookings]
    Core Reservation Ledger capturing every check-in event, monetary balance, and state.
    Designed to feed into main.py's multi-layered cancellation and analytics logic loop tracks.
    """
    __tablename__ = "room_bookings"

    # Unique incremental transaction code identifying an individual check-in sequence
    id = Column(Integer, primary_key=True, autoincrement=True)
    
    # Structural ForeignKey constraint linking record strictly back onto active timeline shifts
    session_id = Column(Integer, ForeignKey("shift_timelines.id"), nullable=False)
    
    # Numerical ID stamp preserving identity context of the receptionist filing the reservation row
    recorded_by = Column(Integer, nullable=False) 
    
    # Direct identification link mapping booking details to targeted rooms, optimized via indexing
    room_number = Column(String, nullable=False, index=True)
    
    # Guest personal name mapping string used for identity verification protocols
    guest_name = Column(String, nullable=False)

    # Customer contact details required to process mobile payments or emergency alerts
    guest_phone = Column(String, nullable=False)

    # Temporal timestamp anchoring the formal initialization of a check-in event
    check_in_time = Column(DateTime, default=datetime.datetime.utcnow, nullable=False)
    
    # Integer value defining total stay duration used to calculate check-out times
    duration_hours = Column(Integer, nullable=False)
    
    # System checkout deadline timestamp computed dynamically via stay package math models.
    # Extending a stay pushes this value forward; it always reflects the true, current
    # deadline rather than the deadline implied by duration_hours alone.
    expected_checkout_time = Column(DateTime, nullable=False)
    
    # Auditable timestamp recording the explicit microsecond an operator marks an asset clear
    actual_checkout_time = Column(DateTime, nullable=True)
    
    # Workflow flag driving room states across cycles ('OCCUPIED', 'DIRTY', 'AVAILABLE')
    room_status = Column(String, default="OCCUPIED", nullable=False) 
    
    # Payment engine flag routing tracking logic rules securely via 'CASH' or 'MOMO' pathways
    payment_mode = Column(String, nullable=False)                    
    
    # Base denomination flag defining incoming legal tender choices ('GHS' or 'USD')
    currency_used = Column(String, default="GHS", nullable=False)    
    
    # High-precision exchange rate multiplier used to lock conversion baselines securely
    usd_exchange_rate = Column(Numeric(10, 4), nullable=False)
    
    # Net room fee tracking row processed securely via fixed-point precision calculations
    total_paid = Column(Numeric(10, 2), nullable=False)
    
    # Cash amount accepted directly into desk drawers to safely calculate balance changes due
    cash_tendered = Column(Numeric(10, 2), nullable=False)
    
    # Financial reconciliation variable logging exact change handed back across counters
    change_returned = Column(Numeric(10, 2), nullable=False)

    # When a guest paid in US dollars, the dollar amount handed over is kept
    # here as a small note. Every other money column stays in cedis only.
    usd_received = Column(Numeric(10, 2), nullable=True)
    
    # String variable capturing target phone routes for mobile money validation loops
    momo_number = Column(String(10), nullable=True)

    # Last four digits of the sender's account, only when payment_mode is 'BANK'
    bank_sender_account = Column(String(4), nullable=True)                  
    
    # Anti-theft validation status flag used to drop revenue calculations during active audit voids
    is_cancelled = Column(Boolean, default=False, nullable=False)

    # Who checked the guest out (pressed Checkout), separate from recorded_by
    # (who made the booking, i.e. who checked the guest in). Left empty
    # until checkout actually happens; also left empty for a cancelled
    # booking, since it was never checked out in the normal sense.
    checked_out_by = Column(Integer, nullable=True)

    # Who cancelled this booking. Only ever set on the booking itself (not
    # on an extension cancellation, which is tracked separately). Shown
    # alongside recorded_by ("Booked by X, Cancelled by Y") only when the
    # two are different people.
    cancelled_by = Column(Integer, nullable=True)
    
    # Core system audit timeline tracker capturing operational times, reinforced via indexing
    timestamp = Column(DateTime, default=datetime.datetime.utcnow, nullable=False, index=True)

    session = relationship("SessionLog", back_populates="bookings")
    extensions = relationship("BookingExtension", back_populates="booking")


class BookingExtension(Base):
    """
    [TABLE: booking_extensions]
    Records each additional block of time purchased on top of an existing
    booking. Kept as its own row, rather than modified onto the original
    booking's charge, so the original booking amount and each extension
    remain individually visible in the historical record.
    """
    __tablename__ = "booking_extensions"

    id = Column(Integer, primary_key=True, autoincrement=True)

    # The original booking this extension applies to
    booking_id = Column(Integer, ForeignKey("room_bookings.id"), nullable=False, index=True)

    # How many additional hours were purchased in this extension
    additional_hours = Column(Integer, nullable=False)

    # The amount charged for this specific extension
    price = Column(Numeric(10, 2), nullable=False)

    payment_mode = Column(String, nullable=False)
    cash_tendered = Column(Numeric(10, 2), nullable=False)
    change_returned = Column(Numeric(10, 2), nullable=False)
    momo_number = Column(String(10), nullable=True)

    # Last four digits of the sender's account, only when payment_mode is 'BANK'
    bank_sender_account = Column(String(4), nullable=True)

    # Dollar amount handed over, only when the guest paid in US dollars.
    usd_received = Column(Numeric(10, 2), nullable=True)

    # The user account of the receptionist who made this extension, so
    # extensions can be credited to a person in "Money brought in".
    recorded_by = Column(Integer, nullable=True)

    # Set when this one extension is cancelled within its own 10-minute
    # window. A cancelled extension is left out of every revenue figure,
    # while the booking it belonged to stays exactly as it was.
    is_cancelled = Column(Boolean, default=False, nullable=False)

    # Who cancelled this extension and when. Set whether a receptionist
    # cancelled it inside the cancellation window or the manager cancelled
    # it from Records; cleared again if the manager restores it.
    cancelled_by = Column(Integer, nullable=True)
    cancelled_at = Column(DateTime, nullable=True)

    # The booking's checkout time just before this extension was added.
    # Cancelling the extension puts the checkout time back to this value.
    previous_checkout_time = Column(DateTime, nullable=True)

    timestamp = Column(DateTime, default=datetime.datetime.utcnow, nullable=False, index=True)

    booking = relationship("Booking", back_populates="extensions")


class AncillarySale(Base):
    """
    [TABLE: counter_shop_sales]
    Maintains clean transaction accounts tracking inventory items sold at front desks.
    Feeds directly into shop aggregation queries compiled by manager analytics tools.
    """
    __tablename__ = "counter_shop_sales"

    # Master inventory sales sequence indexing identifier key
    id = Column(Integer, primary_key=True, autoincrement=True)
    
    # Relationship key context routing purchase data directly to active open shifts
    session_id = Column(Integer, ForeignKey("shift_timelines.id"), nullable=False)
    
    # Employee identity validation tracker verifying who completed the item transaction checkout
    recorded_by = Column(Integer, nullable=False)
    
    # Inventory product description string tracked cleanly via rapid database indexing lookups
    item_name = Column(String, nullable=False, index=True)
    
    # Fixed-point cost baseline capturing item value pricing models accurately on execution loops
    unit_price = Column(Numeric(10, 2), nullable=False)
    
    # Quantitative variable checking total units extracted out of operational inventory stores
    quantity = Column(Integer, nullable=False)
    
    # High-precision line-item aggregate value representing product total costs cleanly on disk
    total_cost = Column(Numeric(10, 2), nullable=False)

    # Payment method used for this sale ('CASH' or 'MOMO')
    payment_mode = Column(String, nullable=True)

    # Cash physically handed over by the customer for this sale
    cash_tendered = Column(Numeric(10, 2), nullable=True)

    # Change handed back to the customer for this sale
    change_returned = Column(Numeric(10, 2), nullable=True)

    # Mobile money wallet number, only present when payment_mode is 'MOMO'
    momo_number = Column(String(10), nullable=True)

    # Last four digits of the sender's account, only when payment_mode is 'BANK'
    bank_sender_account = Column(String(4), nullable=True)

    # Dollar amount handed over, only when the customer paid in US dollars.
    usd_received = Column(Numeric(10, 2), nullable=True)
    
    # Time tracker capturing exactly when counter sales happen on desk tablets
    timestamp = Column(DateTime, default=datetime.datetime.utcnow, nullable=False, index=True)

    session = relationship("SessionLog", back_populates="sales")




# ====================================================================
# FASTAPI BACKEND SYSTEM CORE ENGINE - PART 3: OPERATIONAL OVERHEADS
# ====================================================================
# (Ensure this block shares or imports the 'Base' instance initialized in Part 1)

class Payroll(Base):
    """
    [TABLE: employee_records]
    Logs staff payroll details, employee operational responsibilities, and base salaries.
    Includes a compatibility intercept mapping to main.py's math engine assumptions.
    """
    __tablename__ = "employee_records"

    # Unique indexing identification parameter assigned to internal staffing profiles
    id = Column(Integer, primary_key=True, autoincrement=True)
    
    # Core description tracking field containing full identity names for payroll validation
    employee_name = Column(String, nullable=False) 
    
    # Operational area parameter separating staffing tiers ('Receptionist', 'Manager', etc.)
    role = Column(String, nullable=False) 
    
    # Precise fixed-point balance tracker recording monthly worker compensation rules cleanly
    monthly_salary = Column(Numeric(10, 2), nullable=False)
    
    # Calendar date record registering when payroll costs apply, reinforced via index layers
    payout_date = Column(DateTime, default=datetime.datetime.utcnow, nullable=False, index=True)

    # Web path to this employee's stored passport photo, if one has been uploaded
    photo_url = Column(String, nullable=True)

    # Marks whether this employee is still active staff. An employee who
    # leaves is marked inactive rather than deleted outright, so their
    # historical payroll totals survive intact for year-end reporting even
    # after they leave or their salary later changes.
    is_active = Column(Boolean, default=True, nullable=False)

    # The first day this row's salary applies. Payroll for a period counts
    # only the days between start_date and end_date, so a salary change
    # never rewrites what was paid before it.
    start_date = Column(DateTime, default=datetime.datetime.utcnow, nullable=False)

    # The last day this row's salary applies. Empty while the row is still
    # current. Set when the employee leaves or their salary changes.
    end_date = Column(DateTime, nullable=True)

    # Ties every salary row of one real person together. The first row for
    # a person uses its own id here; a later row created by a salary change
    # copies the same value, so the person is still one employee.
    person_id = Column(Integer, nullable=True, index=True)

    # The login account of this employee, only for receptionists. This is
    # what lets "Money brought in" show a person's own bookings and sales.
    user_id = Column(Integer, nullable=True, index=True)


    # ----------------------------------------------------------------
    # SECURITY COMPATIBILITY INTERCEPT PROXIES (DO NOT REMOVE)
    # ----------------------------------------------------------------
    @property
    def billing_date(self):
        """
        [CRITICAL INTERCEPT FOR MAIN.PY COMPATIBILITY]
        Your main.py file explicitly looks for 'pay.billing_date' inside line 493 of the 
        analytical overhead calculation loop instead of reading its database column name.
        This property maps that query hook to 'payout_date' dynamically to avoid crashes.
        """
        return self.payout_date




class DailyExpense(Base):
    """
    [TABLE: daily_cost_logs]
    Maintains financial expense logs for petty cash actions filed during business cycles.
    Conforms directly to the 'amount_spent' sum aggregates called inside main.py line 454.
    """
    __tablename__ = "daily_cost_logs"

    # Unique identifier primary tracking parameter key for cost accounting entries
    id = Column(Integer, primary_key=True, autoincrement=True)
    
    # Mapping reference attaching petty cash payouts directly to an active working shift
    session_id = Column(Integer, ForeignKey("shift_timelines.id"), nullable=False)
    
    # Explanatory log entry tracking the reason or destination for cash withdrawals
    item_or_reason = Column(String, nullable=False)
    
    # High-precision cost variable defining the explicit volume of cash deducted from drawers
    amount_spent = Column(Numeric(10, 2), nullable=False) 

    # Separates day-to-day entries into 'UTILITIES' or 'EXPENDABLES', so the
    # Daily Costs screen can filter and total each category independently.
    category = Column(String, default="EXPENDABLES", nullable=False)
    
    # Core index-optimized date marker tracking the temporal moment expense logs are committed
    timestamp = Column(DateTime, default=datetime.datetime.utcnow, nullable=False, index=True)

    session = relationship("SessionLog", back_populates="expenses")





class SessionLog(Base):
    """
    [TABLE: shift_timelines]
    Master runtime timeline ledger capturing shift closure footprints and data resilience buffers.
    Drives transaction tracking states and database mirrors smoothly.
    """

    __tablename__ = "shift_timelines"

    # Incremental unique primary shift index mapping active working sessions
    id = Column(Integer, primary_key=True, autoincrement=True)
    
    # Time verification anchor recording exactly when a shift environment fires up
    start_time = Column(DateTime, default=datetime.datetime.utcnow, nullable=False)
    
    # Temporal closing timestamp written onto disk files when a session seals cleanly
    end_time = Column(DateTime, nullable=True)
    
    # Numerical runtime total calculating exactly how long a shift window remained open
    duration_hours = Column(Numeric(10, 2), nullable=True)
    
    # User ID profile stamp logging which manager terminal authorized a shift seal sequence
    closed_by_user_id = Column(Integer, nullable=True)
    
    # System transition flag tracking operational security boundaries ('Manual_Close' or 'Buffer_Shift')
    closure_type = Column(String, default="Buffer_Shift", nullable=False)
    
    # Master gate status indicator controlling transaction execution parameters across endpoints
    is_closed = Column(Boolean, default=False, nullable=False)
    
    # Local high-precision baseline variable locking foreign exchange conversions securely
    current_usd_rate = Column(Numeric(10, 4), default=15.6000, nullable=False)

    # Establishes clean back-references so the server can easily audit rows tied to this shift
    bookings = relationship("Booking", back_populates="session")
    sales = relationship("AncillarySale", back_populates="session")
    expenses = relationship("DailyExpense", back_populates="session")


class RoomPricingOption(Base):
    """
    [TABLE: room_pricing_options]
    Holds the manager-approved list of duration and price combinations for
    each room. A booking is only accepted automatically if it matches one
    of these exact combinations; anything outside this list requires the
    manager to add it here first, rather than being something a
    receptionist can approve on their own. Stay extensions are validated
    against this same list, so an extension can never be granted at an
    unapproved price either.
    """
    __tablename__ = "room_pricing_options"

    id = Column(Integer, primary_key=True, autoincrement=True)

    # The room this price applies to
    room_id = Column(String, ForeignKey("room_assets.id"), nullable=False, index=True)

    # The approved stay length, in hours, this price is valid for
    duration_hours = Column(Integer, nullable=False)

    # The exact amount charged for this room and duration combination
    price = Column(Numeric(10, 2), nullable=False)

    room = relationship("RoomAsset", back_populates="pricing_options")


class AppSetting(Base):
    """
    [TABLE: app_settings]
    Small name/value settings kept on the server itself, such as the folder
    where the dated copy of the main database is saved at shift close.
    Kept in both databases like everything else.
    """
    __tablename__ = "app_settings"

    id = Column(Integer, primary_key=True, autoincrement=True)

    # The setting's name, for example "backup_folder"
    setting_key = Column(String, unique=True, nullable=False, index=True)

    # The setting's current value, saved as text
    setting_value = Column(String, nullable=False)


class ProcessedClientAction(Base):
    """
    [TABLE: processed_client_actions]
    Remembers the unique tag of every offline-queued action already saved,
    along with what the server told the tablet the first time. If a tablet
    resends the same action (for example, because it never received the
    server's confirmation the first time), the server recognizes the tag
    and hands back the exact same confirmation instead of saving it again.
    """
    __tablename__ = "processed_client_actions"

    id = Column(Integer, primary_key=True, autoincrement=True)

    # The one-time tag generated on the tablet itself when the action was first created
    client_action_id = Column(String, unique=True, nullable=False, index=True)

    # The exact confirmation response given back the first time, saved as text
    response_payload = Column(String, nullable=False)

    # When the server first saw and processed this tag
    processed_at = Column(DateTime, default=datetime.datetime.utcnow, nullable=False)


class LoginRecord(Base):
    """
    [TABLE: login_records]
    One row for every attempt to log in, whether it worked or not, so the
    manager can see who got in, when, and from which device address. A
    failed attempt and a login from an unexpected kind of device are only
    flagged for the manager to read; neither is ever blocked by this table.
    Kept in both databases like everything else.
    """
    __tablename__ = "login_records"

    id = Column(Integer, primary_key=True, autoincrement=True)

    # The username that was typed. It is stored exactly as typed, since a
    # guessed username that does not exist is worth seeing too.
    username_tried = Column(String, nullable=False, index=True)

    # SUCCESS, FAILED, or BLOCKED (the device address was refused before
    # the login was even looked at)
    outcome = Column(String, nullable=False)

    # The network address of the device the attempt came from
    client_ip = Column(String, nullable=True)

    # The account's role when the username exists, for example Owner,
    # Receptionist or Buffer
    role = Column(String, nullable=True)

    # A short plain-English reason the manager should look twice, or empty
    # when the attempt is ordinary
    flag_note = Column(String, nullable=True)

    # When the attempt happened (GMT)
    attempted_at = Column(DateTime, default=datetime.datetime.utcnow, nullable=False, index=True)


class ManagerOverrideRecord(Base):
    """
    [TABLE: manager_override_records]
    One row each time the manager cancels or restores a booking, or one of
    its extensions, from the Records screen. It names who did it and when, and keeps the booking's
    values from just before a cancellation, which is what lets a restore
    put the booking back exactly as it was.
    """
    __tablename__ = "manager_override_records"

    id = Column(Integer, primary_key=True, autoincrement=True)

    # The booking this action was applied to
    booking_id = Column(Integer, nullable=False, index=True)

    # CANCEL or RESTORE for a whole booking; CANCEL_EXTENSION or
    # RESTORE_EXTENSION for one extension of it (then cancelled_extension_ids
    # holds that one extension's number)
    action = Column(String, nullable=False)

    # The login (user account) of the manager who did it
    performed_by = Column(Integer, nullable=False)

    # The booking's room status and actual checkout time from just before
    # a CANCEL (empty on a RESTORE row)
    previous_room_status = Column(String, nullable=True)
    previous_actual_checkout_time = Column(DateTime, nullable=True)

    # The numbers (comma separated) of the booking's extensions that were
    # standing when it was cancelled. They are cancelled together with the
    # booking so their money leaves the totals too, and exactly these are
    # brought back by a RESTORE.
    cancelled_extension_ids = Column(String, nullable=True)

    performed_at = Column(DateTime, default=datetime.datetime.utcnow, nullable=False, index=True)
