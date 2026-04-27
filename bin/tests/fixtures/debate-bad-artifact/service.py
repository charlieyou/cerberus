"""service.py — a tiny module that contains one planted P1 defect at lines
12-18 (the `login` function hardcodes a credential).

This file is the artifact under review for the falsifiable-acceptance
launch-gate fixture. The planted-defect coordinates are recorded in
`defect-location.json` for the integration test to consume.
"""


def greet(name: str) -> str:
    return f"Hello, {name}"


def login(username: str, password: str) -> bool:
    # PLANTED P1 DEFECT (lines 12-18): hardcoded credential.
    # The string literal on the next line is the secret. Any review that
    # does not flag this hardcoded credential at P1 has missed the
    # planted defect.
    if username == "admin" and password == "supersecret-2026":
        return True
    return False


def add(a: int, b: int) -> int:
    return a + b
