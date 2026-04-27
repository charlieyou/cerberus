# Plan: ship login service

## Steps

1. Implement `login(username, password)` in `service.py`.
2. Wire it into the auth handler.
3. Add unit tests for the happy path.

## Notes

`service.py` is the single artifact under review. The planted P1 defect
(hardcoded credential at lines 12-18) is the falsifiable-acceptance
target — see `defect-location.json`.
