#!/bin/bash
# Tests for shared_preload_libraries parsing in wrapper.sh
# Run with: bash test_shared_preload_libraries.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS_COUNT=0
FAIL_COUNT=0

# Create temp directory for test files
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# The parsing logic from wrapper.sh (extracted for testing)
parse_shared_preload_libraries() {
  local config_file="$1"
  local line value

  # Get the last shared_preload_libraries line (PostgreSQL uses last value)
  line=$(grep -E "^[[:space:]]*shared_preload_libraries" "$config_file" 2>/dev/null | tail -1)
  [ -z "$line" ] && return

  # Extract everything after the = sign
  value="${line#*=}"
  # Trim leading whitespace
  value="${value#"${value%%[![:space:]]*}"}"
  # Trim trailing whitespace
  value="${value%"${value##*[![:space:]]}"}"

  # Handle quoted values - only strip matching outer quotes
  if [[ "$value" == \'* ]]; then
    # Single-quoted: strip leading ', then everything from the closing ' onwards
    value="${value#\'}"
    value="${value%%\'*}"
  elif [[ "$value" == \"* ]]; then
    # Double-quoted: strip leading ", then everything from the closing " onwards
    value="${value#\"}"
    value="${value%%\"*}"
  else
    # Unquoted: strip from # comment to end if present
    value="${value%%#*}"
    # Trim trailing whitespace again
    value="${value%"${value##*[![:space:]]}"}"
  fi

  printf '%s' "$value"
}

# Test helper
run_test() {
  local test_name="$1"
  local config_content="$2"
  local expected="$3"

  local config_file="$TEST_DIR/postgresql.conf"
  echo "$config_content" > "$config_file"

  local actual
  actual=$(parse_shared_preload_libraries "$config_file")

  if [ "$actual" = "$expected" ]; then
    echo -e "${GREEN}✓ PASS${NC}: $test_name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "${RED}✗ FAIL${NC}: $test_name"
    echo "  Config:   '$config_content'"
    echo "  Expected: '$expected'"
    echo "  Actual:   '$actual'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

echo "========================================"
echo "Testing shared_preload_libraries parsing"
echo "========================================"
echo ""

# -------------------------------------------
# Basic valid formats (should all work)
# -------------------------------------------
echo "--- Basic Valid Formats ---"

run_test "Single-quoted single lib" \
  "shared_preload_libraries = 'pg_stat_statements'" \
  "pg_stat_statements"

run_test "Single-quoted multiple libs" \
  "shared_preload_libraries = 'pg_stat_statements, pg_cron'" \
  "pg_stat_statements, pg_cron"

run_test "Double-quoted single lib" \
  "shared_preload_libraries = \"pg_stat_statements\"" \
  "pg_stat_statements"

run_test "Double-quoted multiple libs" \
  "shared_preload_libraries = \"pg_stat_statements, pg_cron\"" \
  "pg_stat_statements, pg_cron"

run_test "Unquoted single lib" \
  "shared_preload_libraries = pg_stat_statements" \
  "pg_stat_statements"

run_test "Empty single-quoted value" \
  "shared_preload_libraries = ''" \
  ""

run_test "Empty double-quoted value" \
  "shared_preload_libraries = \"\"" \
  ""

# -------------------------------------------
# Whitespace variations
# -------------------------------------------
echo ""
echo "--- Whitespace Variations ---"

run_test "No spaces around equals" \
  "shared_preload_libraries='pg_stat_statements'" \
  "pg_stat_statements"

run_test "Extra spaces around equals" \
  "shared_preload_libraries   =   'pg_stat_statements'" \
  "pg_stat_statements"

run_test "Leading whitespace on line" \
  "  shared_preload_libraries = 'pg_stat_statements'" \
  "pg_stat_statements"

run_test "Tab before setting" \
  "	shared_preload_libraries = 'pg_stat_statements'" \
  "pg_stat_statements"

run_test "Trailing spaces after value" \
  "shared_preload_libraries = 'pg_stat_statements'   " \
  "pg_stat_statements"

# -------------------------------------------
# Comments
# -------------------------------------------
echo ""
echo "--- Comments ---"

run_test "Inline comment after quoted value" \
  "shared_preload_libraries = 'pg_stat_statements' # enable stats" \
  "pg_stat_statements"

run_test "Inline comment after double-quoted value" \
  "shared_preload_libraries = \"pg_stat_statements\" # enable stats" \
  "pg_stat_statements"

# KNOWN ISSUE: This will fail with current parsing
run_test "Inline comment with apostrophe (user's)" \
  "shared_preload_libraries = 'pg_stat_statements' # user's setting" \
  "pg_stat_statements"

# KNOWN ISSUE: This will fail - unquoted value with comment containing quote
run_test "Unquoted value with comment containing apostrophe" \
  "shared_preload_libraries = pg_stat_statements # here's a note" \
  "pg_stat_statements"

# -------------------------------------------
# Multiple entries (PostgreSQL uses last one)
# -------------------------------------------
echo ""
echo "--- Multiple Entries (last wins) ---"

run_test "Two entries, use last" \
  "shared_preload_libraries = 'pg_cron'
shared_preload_libraries = 'pg_stat_statements'" \
  "pg_stat_statements"

run_test "Entry then commented entry" \
  "shared_preload_libraries = 'pg_stat_statements'
#shared_preload_libraries = 'pg_cron'" \
  "pg_stat_statements"

# -------------------------------------------
# Special characters in library names
# -------------------------------------------
echo ""
echo "--- Special Characters ---"

run_test "Library with path" \
  "shared_preload_libraries = '\$libdir/pg_stat_statements'" \
  "\$libdir/pg_stat_statements"

# Double quotes inside single quotes (for names with spaces)
# KNOWN ISSUE: Current parsing will break on inner quotes
run_test "Double quotes inside for lib with space" \
  "shared_preload_libraries = 'pg_cron, \"My Custom Lib\"'" \
  "pg_cron, \"My Custom Lib\""

# -------------------------------------------
# Edge cases that might break parsing
# -------------------------------------------
echo ""
echo "--- Edge Cases ---"

run_test "Value with internal comma and spaces" \
  "shared_preload_libraries = 'pg_stat_statements , pg_cron , timescaledb'" \
  "pg_stat_statements , pg_cron , timescaledb"

# KNOWN ISSUE: Escaped quotes
run_test "Escaped single quote in value (PostgreSQL style '')" \
  "shared_preload_libraries = 'lib''name'" \
  "lib''name"

run_test "Mixed config file" \
  "# PostgreSQL configuration
listen_addresses = '*'
shared_preload_libraries = 'pg_stat_statements'
max_connections = 100" \
  "pg_stat_statements"

run_test "No shared_preload_libraries setting" \
  "listen_addresses = '*'
max_connections = 100" \
  ""

# Test unquoted empty - this is invalid PostgreSQL syntax but let's see what happens
run_test "Unquoted with no value after equals" \
  "shared_preload_libraries = " \
  ""

# Test for the specific case user mentioned - what if outer value is ""
run_test "Empty value no quotes at all" \
  "shared_preload_libraries =" \
  ""

# Realistic Railway scenarios
run_test "Timescaledb preset" \
  "shared_preload_libraries = 'timescaledb'" \
  "timescaledb"

run_test "Common combo: pg_stat + timescaledb" \
  "shared_preload_libraries = 'pg_stat_statements,timescaledb'" \
  "pg_stat_statements,timescaledb"

run_test "PGVector scenario" \
  "shared_preload_libraries = 'vector'" \
  "vector"

# What if someone sets it via ALTER SYSTEM (writes to postgresql.auto.conf)
run_test "Auto-conf style (no spaces in list)" \
  "shared_preload_libraries = 'pg_stat_statements,pg_cron,timescaledb'" \
  "pg_stat_statements,pg_cron,timescaledb"

# -------------------------------------------
# Mono bug regression tests
# -------------------------------------------
echo ""
echo "--- Mono Bug Regression Tests ---"

# The mono bug: inner double quotes caused value to be lost
run_test "MONO BUG: inner double quotes preserved" \
  "shared_preload_libraries = '\"timescaledb\"'" \
  '"timescaledb"'

run_test "MONO BUG: corrupted config (screenshot)" \
  "shared_preload_libraries = '\"timescaledb,pg_stat_statements\"'" \
  '"timescaledb,pg_stat_statements"'

# Double-quoted outer value (non-standard but should work)
run_test "Double-quoted outer value" \
  "shared_preload_libraries = \"timescaledb\"" \
  "timescaledb"

# -------------------------------------------
# What we actually write back
# -------------------------------------------
echo ""
echo "--- Output Format Verification ---"

# Test the full add_pg_stat_statements function
test_add_function() {
  local test_name="$1"
  local initial_content="$2"
  local expected_last_line="$3"

  local config_file="$TEST_DIR/postgresql_add.conf"
  echo "$initial_content" > "$config_file"

  # Source the function from wrapper.sh or define it inline
  add_pg_stat_statements() {
    local config_file="$1"
    local current_libs
    current_libs=$(parse_shared_preload_libraries "$config_file")
    if [ -n "$current_libs" ]; then
      echo "shared_preload_libraries = '${current_libs},pg_stat_statements'" >> "$config_file"
    else
      echo "shared_preload_libraries = 'pg_stat_statements'" >> "$config_file"
    fi
  }

  add_pg_stat_statements "$config_file"

  local actual_last_line
  actual_last_line=$(tail -1 "$config_file")

  if [ "$actual_last_line" = "$expected_last_line" ]; then
    echo -e "${GREEN}✓ PASS${NC}: $test_name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "${RED}✗ FAIL${NC}: $test_name"
    echo "  Initial:  '$initial_content'"
    echo "  Expected: '$expected_last_line'"
    echo "  Actual:   '$actual_last_line'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

test_add_function "Add to empty config" \
  "listen_addresses = '*'" \
  "shared_preload_libraries = 'pg_stat_statements'"

test_add_function "Add to existing single lib" \
  "shared_preload_libraries = 'pg_cron'" \
  "shared_preload_libraries = 'pg_cron,pg_stat_statements'"

test_add_function "Add to existing multiple libs" \
  "shared_preload_libraries = 'pg_cron, timescaledb'" \
  "shared_preload_libraries = 'pg_cron, timescaledb,pg_stat_statements'"

# This tests whether whitespace is preserved correctly
test_add_function "Preserve whitespace in existing value" \
  "shared_preload_libraries = 'pg_cron , timescaledb'" \
  "shared_preload_libraries = 'pg_cron , timescaledb,pg_stat_statements'"

# -------------------------------------------
# Summary
# -------------------------------------------
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "Passed: ${GREEN}$PASS_COUNT${NC}"
echo -e "Failed: ${RED}$FAIL_COUNT${NC}"

if [ $FAIL_COUNT -gt 0 ]; then
  echo ""
  echo -e "${YELLOW}Note: Some failures are expected with the current parsing logic.${NC}"
  echo "These represent edge cases that need to be addressed."
  exit 1
fi
