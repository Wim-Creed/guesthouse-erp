"""
Graceland Guesthouse security test suite.

Run this against a real running server to check that the core security
rules actually hold: a receptionist token cannot read manager reports, bad
input is rejected cleanly, a MoMo number must be exactly 10 digits, and a
manager-only action is refused from off manager hardware. There are no
built-in passwords anywhere in this file, in keeping with the rest of the
system: it asks for real credentials at the terminal every time it runs,
the same way a real person would have to.

Usage:
    python pen_test.py

The script asks for the server address first. Pressing Enter uses
http://127.0.0.1:8000, which works when the script runs on the server
computer itself, because the loopback addresses are always allowed.
"""

import getpass
import requests

# The address used when nothing is typed at the first question.
DEFAULT_SERVER_ADDRESS = "http://127.0.0.1:8000"

print("==================================================================")
print("           GRACELAND GUESTHOUSE SECURITY TEST SUITE               ")
print("==================================================================\n")

typed_server_address = input(f"Server address (press Enter for {DEFAULT_SERVER_ADDRESS}): ").strip()
if typed_server_address and "://" not in typed_server_address:
    typed_server_address = "http://" + typed_server_address
BASE_URL = (typed_server_address or DEFAULT_SERVER_ADDRESS).rstrip("/")

receptionist_username = input("Receptionist username to test with: ").strip()
receptionist_password = getpass.getpass("Receptionist password (hidden): ")
admin_username = input("Administrator username to test with: ").strip()
admin_password = getpass.getpass("Administrator password (hidden): ")


def log_in(username, password):
    response = requests.post(f"{BASE_URL}/auth/login/", data={"username": username, "password": password}, timeout=5)
    response.raise_for_status()
    return response.json()["access_token"]


# ---------------------------------------------------------------------
# TEST 1: A receptionist token must not be able to read manager reports
# ---------------------------------------------------------------------
print("\nTEST 1: Checking that a receptionist token cannot read Business Summary...")
try:
    receptionist_token = log_in(receptionist_username, receptionist_password)
    headers = {"Authorization": f"Bearer {receptionist_token}"}
    response = requests.get(f"{BASE_URL}/analytics/financials/?period=monthly", headers=headers, timeout=5)
    if response.status_code == 403:
        print("    PASSED: the server refused the request.")
    else:
        print(f"    FAILED: expected 403, got {response.status_code}.")
except requests.RequestException as error:
    print(f"    Could not run this test: {error}")


# ---------------------------------------------------------------------
# TEST 2: An out-of-range stay duration must be rejected
# ---------------------------------------------------------------------
print("\nTEST 2: Checking that an unreasonable stay duration is rejected...")
try:
    payload = {
        "room_number": "Room 102", "guest_name": "Test Guest", "guest_phone": "0240000000",
        "duration_hours": 99999999, "payment_mode": "CASH", "currency_used": "GHS",
        "cash_tendered": 100.00, "change_returned": 0,
    }
    response = requests.post(f"{BASE_URL}/bookings/", json=payload, headers=headers, timeout=5)
    if response.status_code == 422:
        print("    PASSED: the server rejected the out-of-range value.")
    else:
        print(f"    FAILED: expected 422, got {response.status_code}.")
except requests.RequestException as error:
    print(f"    Could not run this test: {error}")


# ---------------------------------------------------------------------
# TEST 3: A mobile money number must be exactly 10 digits
# ---------------------------------------------------------------------
print("\nTEST 3: Checking that a malformed mobile money number is rejected...")
try:
    payload = {
        "room_number": "Room 102", "guest_name": "Test Guest", "guest_phone": "0240000000",
        "duration_hours": 6, "payment_mode": "MOMO", "currency_used": "GHS",
        "cash_tendered": 100.00, "change_returned": 0, "momo_number": "024000000012",
    }
    response = requests.post(f"{BASE_URL}/bookings/", json=payload, headers=headers, timeout=5)
    if response.status_code == 400:
        print("    PASSED: the server rejected the malformed number.")
    else:
        print(f"    FAILED: expected 400, got {response.status_code}.")
except requests.RequestException as error:
    print(f"    Could not run this test: {error}")


# ---------------------------------------------------------------------
# TEST 4: A manager-only action must be refused from off manager hardware
# ---------------------------------------------------------------------
print("\nTEST 4: Checking that a manager-only action is refused off manager hardware...")
print("    (This only proves something if this script is run from a receptionist")
print("     tablet's own network address. Running it from the server or a manager")
print("     device will correctly show it passing through instead.)")
try:
    admin_token = log_in(admin_username, admin_password)
    admin_headers = {"Authorization": f"Bearer {admin_token}"}
    payload = {"target_username": receptionist_username, "manager_password": admin_password, "new_password": "ATestPassword123!"}
    response = requests.post(f"{BASE_URL}/management/change-login/", json=payload, headers=admin_headers, timeout=5)
    if response.status_code == 403:
        print("    PASSED: the server refused the request from this hardware.")
    elif response.status_code == 200:
        print("    NOTE: the server allowed this — expected if run from manager hardware.")
        print("    Reverting the test password change now...")
        revert_payload = {"target_username": receptionist_username, "manager_password": admin_password, "new_password": receptionist_password}
        requests.post(f"{BASE_URL}/management/change-login/", json=revert_payload, headers=admin_headers, timeout=5)
    else:
        print(f"    FAILED: unexpected status code {response.status_code}.")
except requests.RequestException as error:
    print(f"    Could not run this test: {error}")

print("\n==================================================================")
