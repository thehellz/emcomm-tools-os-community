#!/usr/bin/env bash
# Run every shell test in EmComm Tools OS Community's tests directory.
set -u

SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/tests" ]]; then
    TEST_DIR="$SCRIPT_DIR/tests"
elif [[ -d "$SCRIPT_DIR/../tests" ]]; then
    TEST_DIR="$(cd "$SCRIPT_DIR/../tests" && pwd)"
else
    echo "ERROR: Cannot find tests directory. Put this script in the repo root or scripts/ directory." >&2
    exit 2
fi

mapfile -d '' tests < <(find "$TEST_DIR" -maxdepth 1 -type f -name '*.sh' ! -samefile "$SCRIPT_PATH" -print0 | sort -z)
if (( ${#tests[@]} == 0 )); then
    echo "ERROR: No .sh tests found in $TEST_DIR" >&2
    exit 2
fi

log_file="$(mktemp)"
trap 'rm -f -- "$log_file"' EXIT

passed=0
failed=0
failures=()
echo "Running ${#tests[@]} tests from $TEST_DIR"
echo
for test_path in "${tests[@]}"; do
    test_name="$(basename -- "$test_path")"
    printf '==> %-40s ' "$test_name"
    # Running each test in its own shell avoids one exit stopping the suite.
    if (cd "$TEST_DIR" && bash "./$test_name") > "$log_file" 2>&1; then
        echo 'PASS'
        ((passed+=1))
    else
        result=$?
        echo "FAIL (exit $result)"
        sed 's/^/    /' "$log_file"
        failures+=("$test_name")
        ((failed+=1))
    fi
done
printf '\nRESULTS: %d passed, %d failed, %d total\n' "$passed" "$failed" "${#tests[@]}"
if (( failed > 0 )); then
    printf 'Failed tests:\n'
    printf '  %s\n' "${failures[@]}"
    exit 1
fi
