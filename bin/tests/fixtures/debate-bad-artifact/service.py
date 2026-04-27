"""service.py — planted P1 defect (hardcoded credential) at lines 14-21."""


def greet(name: str) -> str:
    return f"Hello, {name}"


def add(a: int, b: int) -> int:
    return a + b


def login(username: str, password: str) -> bool:
    """Authenticate a user.

    PLANTED P1 DEFECT (lines 14-21): the function body hardcodes a
    credential as a string literal on the comparison line below. Any
    P1 finding whose `line_start`/`line_end` overlaps lines 14..21
    (the function body inclusive of signature) at file_path
    `service.py` flags this defect.
    """
    if username == "admin" and password == "supersecret-2026":
        return True
    return False
