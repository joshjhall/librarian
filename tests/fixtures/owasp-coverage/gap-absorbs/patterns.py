# Fixture scanner stub: simulates slice B (#707) shipping an `ssrf` detector
# while the map still tags `ssrf` as owner: gap.
emit(path, idx, "hardcoded-secret", "x")
emit(path, idx, "injection-risk", "x")
emit(path, idx, "command-injection", "x")
