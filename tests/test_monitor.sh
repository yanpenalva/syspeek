#!/usr/bin/env bash
#
# syspeek test suite. Fixtures/mocks for /proc, sensors, df, ps and package
# managers so results do not depend only on the host running the tests.
#
# Run: ./tests/test_monitor.sh  (or: bash tests/test_monitor.sh)

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/monitor.sh"

PASS=0
FAIL=0
SKIP=0

TMPBASE="$(mktemp -d /tmp/syspeek-tests.XXXXXX)"
trap 'rm -rf "$TMPBASE"' EXIT

pass() { PASS=$((PASS+1)); printf 'ok %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL %s\n  %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); printf 'skip %s (%s)\n' "$1" "$2"; }

assert_eq() { # name expected actual
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}

assert_contains() { # name haystack needle
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "missing [$3] in output"; fi
}

assert_not_contains() { # name haystack needle
    if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "should not contain [$3]"; fi
}

have_python_json() { command -v python3 >/dev/null 2>&1; }

json_get() { # file python-expr  -> prints value
    python3 -c "import json,sys; d=json.load(open('$1')); print($2)" 2>/dev/null || echo "__ERR__"
}

# ---------------------------------------------------------------- fixtures ---

make_proc_basic() { # dir -> minimal /proc replacement
    local d="$1"
    mkdir -p "$d/net"
    cat >"$d/stat" <<'EOF'
cpu  100 0 100 800 0 0 0 0 0 0
btime 1700000000
EOF
    printf '0.50 0.30 0.20 1/100 1234\n' >"$d/loadavg"
    printf '12345.67 54321.21\n' >"$d/uptime"
    cat >"$d/meminfo" <<'EOF'
MemTotal:        8000000 kB
MemAvailable:    4000000 kB
MemFree:         3500000 kB
SwapTotal:       2000000 kB
SwapFree:        1500000 kB
EOF
    printf 'processor\t: 0\nprocessor\t: 1\n' >"$d/cpuinfo"
    cat >"$d/net/dev" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo frame compressed multicast
    lo: 1000    10    0    0    0     0          0         0     1000    10    0    0    0     0       0          0
enp0s3: 2000    20    0    0    0     0          0         0     3000    30    0    0    0     0       0          0
wlp2s0: 4000    40    0    0    0     0          0         0     5000    50    0    0    0     0       0          0
EOF
}

make_mockbin() { # dir [sensors-body-file]
    local d="$1"
    mkdir -p "$d"
    # Symlink essentials so PATH-mocked runs still work.
    for c in awk grep sed ps df sleep date uname nproc getconf cat head cut tr sort python3 bash sh; do
        if command -v "$c" >/dev/null 2>&1; then
            ln -sf "$(command -v "$c")" "$d/$c" 2>/dev/null || true
        fi
    done
}

make_sensors_mock() { # dir body-text
    local d="$1" body="$2"
    cat >"$d/sensors" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$body"
EOF
    chmod +x "$d/sensors"
}

# ===========================================================================
echo "== syspeek tests =="

# 1. bash syntax
if bash -n "$SCRIPT"; then pass "bash -n monitor.sh"; else fail "bash -n monitor.sh" "syntax error"; fi

# 2. shellcheck (optional)
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning "$SCRIPT"; then pass "shellcheck"; else fail "shellcheck" "warnings/errors"; fi
else
    skip "shellcheck" "not installed"
fi

# 3. no tput/bc invocation (mentions in comments are fine)
if grep -qE '\$\(tput|`tput|command -v tput' "$SCRIPT"; then fail "no tput invocation" "script invokes tput"; else pass "no tput invocation"; fi
if grep -q "command -v bc\| | bc\||bc" "$SCRIPT"; then fail "no bc dependency" "script references bc"; else pass "no bc dependency"; fi

# 4. --help / --version / exit codes
out=$("$SCRIPT" --help 2>&1); rc=$?
assert_eq "--help exit 0" "0" "$rc"
assert_contains "--help mentions --json" "$out" "--json"
assert_contains "--help mentions --install" "$out" "--install"

out=$("$SCRIPT" --version 2>&1); rc=$?
assert_eq "--version exit 0" "0" "$rc"
assert_contains "--version prints syspeek" "$out" "syspeek"

"$SCRIPT" --bogus >/dev/null 2>&1; rc=$?
assert_eq "unknown option exit 2" "2" "$rc"

"$SCRIPT" --top 0 >/dev/null 2>&1; rc=$?
assert_eq "--top 0 exit 2" "2" "$rc"

"$SCRIPT" --top abc >/dev/null 2>&1; rc=$?
assert_eq "--top abc exit 2" "2" "$rc"

"$SCRIPT" --top >/dev/null 2>&1; rc=$?
assert_eq "--top missing value exit 2" "2" "$rc"

"$SCRIPT" --interface >/dev/null 2>&1; rc=$?
assert_eq "--interface missing value exit 2" "2" "$rc"

"$SCRIPT" --interface= >/dev/null 2>&1; rc=$?
assert_eq "--interface empty exit 2" "2" "$rc"

"$SCRIPT" extra-arg >/dev/null 2>&1; rc=$?
assert_eq "positional arg exit 2" "2" "$rc"

# 5. default run never calls a package manager
pm_dir="$TMPBASE/pm"; mkdir -p "$pm_dir"
pm_marker="$TMPBASE/pm-called"
for mgr in apt dnf pacman dpkg rpm sudo; do
    cat >"$pm_dir/$mgr" <<EOF
#!/usr/bin/env bash
echo "$mgr called" >>"$pm_marker"
exit 0
EOF
    chmod +x "$pm_dir/$mgr"
done
if PATH="$pm_dir:$PATH" "$SCRIPT" --no-color >/dev/null 2>&1; then
    if [[ -f "$pm_marker" ]]; then fail "default run never calls package manager" "$(cat "$pm_marker")"
    else pass "default run never calls package manager"; fi
else fail "default run never calls package manager" "script exited non-zero"; fi

# 6. no ANSI with --no-color / non-TTY / NO_COLOR
out=$("$SCRIPT" --no-color 2>&1)
if printf '%s' "$out" | grep -qP '\x1b\[' 2>/dev/null || printf '%s' "$out" | grep -q $'\033\['; then
    fail "--no-color has no ANSI" "escape sequence found"
else pass "--no-color has no ANSI"; fi

out=$("$SCRIPT" 2>&1)  # piped => non-TTY
if printf '%s' "$out" | grep -q $'\033\['; then
    fail "non-TTY has no ANSI" "escape sequence found"
else pass "non-TTY has no ANSI"; fi

out=$(NO_COLOR=1 "$SCRIPT" 2>&1)
if printf '%s' "$out" | grep -q $'\033\['; then
    fail "NO_COLOR env has no ANSI" "escape sequence found"
else pass "NO_COLOR env has no ANSI"; fi

out=$("$SCRIPT" --json 2>&1)
if printf '%s' "$out" | grep -q $'\033\['; then
    fail "JSON has no ANSI" "escape sequence found"
else pass "JSON has no ANSI"; fi

# 7. JSON validity and sections
if have_python_json; then
    jf="$TMPBASE/report.json"
    "$SCRIPT" --json --no-color >"$jf" 2>/dev/null; rc=$?
    assert_eq "JSON run exit 0" "0" "$rc"
    if python3 -m json.tool "$jf" >/dev/null 2>&1; then pass "JSON is valid"; else fail "JSON is valid" "python json.tool failed"; fi
    for key in schema_version system cpu memory swap disk network processes temperatures warnings; do
        if python3 -c "import json; d=json.load(open('$jf')); assert '$key' in d" 2>/dev/null; then
            pass "JSON has .$key"
        else fail "JSON has .$key" "missing key"; fi
    done
    # numeric stays numeric
    if python3 -c "import json; d=json.load(open('$jf')); assert isinstance(d['cpu']['logical_cpus'], int)" 2>/dev/null; then
        pass "JSON logical_cpus numeric"
    else fail "JSON logical_cpus numeric" "not an int"; fi
else skip "JSON checks" "python3 missing"; fi

# 8. --top respected
if have_python_json; then
    jf="$TMPBASE/top2.json"
    SYSPEEK_PROCROOT="" "$SCRIPT" --json --top 2 >"$jf" 2>/dev/null || true
    # use fixture proc to be deterministic about ps? ps still host; just check upper bound
    n_cpu=$(python3 -c "import json; print(len(json.load(open('$jf'))['processes']['top_cpu']))")
    n_mem=$(python3 -c "import json; print(len(json.load(open('$jf'))['processes']['top_mem']))")
    if [[ "$n_cpu" -le 2 && "$n_mem" -le 2 ]]; then pass "--top 2 respected ($n_cpu/$n_mem)"; else fail "--top 2 respected" "got $n_cpu/$n_mem"; fi
else skip "--top respected" "python3 missing"; fi

# 9. fixture /proc: modern names listed, lo excluded by default
if have_python_json; then
    fd="$TMPBASE/proc1"; make_proc_basic "$fd"
    mb="$TMPBASE/bin1"; make_mockbin "$mb"
    make_sensors_mock "$mb" "Package id 0:  +55.0°C"
    jf="$TMPBASE/fix1.json"
    PATH="$mb:$PATH" SYSPEEK_PROCROOT="$fd" "$SCRIPT" --json --no-color >"$jf" 2>/dev/null; rc=$?
    assert_eq "fixture run exit 0" "0" "$rc"
    ifaces=$(python3 -c "import json; print(' '.join(x['interface'] for x in json.load(open('$jf'))['network']))")
    assert_contains "fixture lists enp0s3" "$ifaces" "enp0s3"
    assert_contains "fixture lists wlp2s0" "$ifaces" "wlp2s0"
    assert_not_contains "fixture excludes lo by default" "$ifaces" "lo"
    # exact match: prefix must NOT match
    PATH="$mb:$PATH" SYSPEEK_PROCROOT="$fd" "$SCRIPT" --json --interface enp >"$TMPBASE/fix-prefix.json" 2>/dev/null
    w=$(python3 -c "import json; print(' '.join(json.load(open('$TMPBASE/fix-prefix.json'))['warnings']))")
    assert_contains "interface prefix does not match" "$w" "not found"
    # exact match works, including lo when explicitly requested
    PATH="$mb:$PATH" SYSPEEK_PROCROOT="$fd" "$SCRIPT" --json --interface wlp2s0 >"$TMPBASE/fix-exact.json" 2>/dev/null
    ifaces2=$(python3 -c "import json; print(' '.join(x['interface'] for x in json.load(open('$TMPBASE/fix-exact.json'))['network']))")
    assert_eq "interface exact match" "wlp2s0" "$ifaces2"
    PATH="$mb:$PATH" SYSPEEK_PROCROOT="$fd" "$SCRIPT" --json --interface lo >"$TMPBASE/fix-lo.json" 2>/dev/null
    ifaces3=$(python3 -c "import json; print(' '.join(x['interface'] for x in json.load(open('$TMPBASE/fix-lo.json'))['network']))")
    assert_eq "explicit lo filter works" "lo" "$ifaces3"
else skip "fixture /proc tests" "python3 missing"; fi

# 10. missing sensors => warning + empty temps, still exit 0
mb2="$TMPBASE/bin-nosensors"; make_mockbin "$mb2"
cat >"$mb2/sensors" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$mb2/sensors"
fd2="$TMPBASE/proc2"; make_proc_basic "$fd2"
out=$(PATH="$mb2:$PATH" SYSPEEK_PROCROOT="$fd2" "$SCRIPT" --no-color 2>&1); rc=$?
assert_eq "sensors-failure exit 0" "0" "$rc"
assert_contains "sensors-failure warns" "$out" "emperature"
if have_python_json; then
    PATH="$mb2:$PATH" SYSPEEK_PROCROOT="$fd2" "$SCRIPT" --json >"$TMPBASE/nosens.json" 2>/dev/null
    n=$(python3 -c "import json; print(len(json.load(open('$TMPBASE/nosens.json'))['temperatures']))")
    assert_eq "sensors-failure temps empty" "0" "$n"
fi

# 11. sensor format + locale variants
if have_python_json; then
    mb3="$TMPBASE/bin-sensors"; make_mockbin "$mb3"
    body='coretemp-isa-0000
Core 0:         +45.0°C  (high = +80.0°C)
Package id 0:   +55.0°C
Tctl:           +60.0°C
Composite:      +33.9°C
Sensor 2:       +68.8°C  (crit = +110.0°C)
temp1:          +42.0°C
k10temp-pci-00c3
Tdie:           +44,5°C'
    make_sensors_mock "$mb3" "$body"
    fd3="$TMPBASE/proc3"; make_proc_basic "$fd3"
    PATH="$mb3:$PATH" SYSPEEK_PROCROOT="$fd3" "$SCRIPT" --json >"$TMPBASE/sens.json" 2>/dev/null
    n=$(python3 -c "import json; print(len(json.load(open('$TMPBASE/sens.json'))['temperatures']))")
    if [[ "$n" -ge 6 ]]; then pass "sensor variants parsed ($n)"; else fail "sensor variants parsed" "only $n entries"; fi
    labels=$(python3 -c "import json; print(' '.join(x['label'] for x in json.load(open('$TMPBASE/sens.json'))['temperatures']))")
    for want in "Core 0" "Package id 0" "Tctl" "Composite" "Sensor 2" "temp1" "Tdie"; do
        assert_contains "sensor label $want" "$labels" "$want"
    done
else skip "sensor variants" "python3 missing"; fi

# 12. missing swap lines => null + warning, still exit 0
if have_python_json; then
    fd4="$TMPBASE/proc-noswap"; make_proc_basic "$fd4"
    grep -v '^Swap' "$fd4/meminfo" >"$fd4/meminfo.tmp" && mv "$fd4/meminfo.tmp" "$fd4/meminfo"
    mb4="$TMPBASE/bin4"; make_mockbin "$mb4"; make_sensors_mock "$mb4" "temp1: +40.0°C"
    PATH="$mb4:$PATH" SYSPEEK_PROCROOT="$fd4" "$SCRIPT" --json >"$TMPBASE/noswap.json" 2>/dev/null; rc=$?
    assert_eq "no-swap exit 0" "0" "$rc"
    st=$(python3 -c "import json; print(json.load(open('$TMPBASE/noswap.json'))['swap']['total_mb'])")
    assert_eq "no-swap total null" "None" "$st"
    w=$(python3 -c "import json; print(' '.join(json.load(open('$TMPBASE/noswap.json'))['warnings']))")
    assert_contains "no-swap warns" "$w" "Swap"
else skip "swap-missing" "python3 missing"; fi

# 13. missing /proc => nulls + warnings, exit 0
if have_python_json; then
    mb5="$TMPBASE/bin5"; make_mockbin "$mb5"; make_sensors_mock "$mb5" "temp1: +40.0°C"
    PATH="$mb5:$PATH" SYSPEEK_PROCROOT="$TMPBASE/does-not-exist" "$SCRIPT" --json >"$TMPBASE/noproc.json" 2>/dev/null; rc=$?
    assert_eq "no-proc exit 0" "0" "$rc"
    cpu=$(python3 -c "import json; print(json.load(open('$TMPBASE/noproc.json'))['cpu']['usage_percent'])")
    assert_eq "no-proc cpu null" "None" "$cpu"
    w=$(python3 -c "import json; print(len(json.load(open('$TMPBASE/noproc.json'))['warnings']))")
    if [[ "$w" -ge 1 ]]; then pass "no-proc warnings ($w)"; else fail "no-proc warnings" "empty"; fi
else skip "no-proc" "python3 missing"; fi

# 14. multiple mounts via mocked df
if have_python_json; then
    mb6="$TMPBASE/bin-df"; make_mockbin "$mb6"
    rm -f "$mb6/df"
    cat >"$mb6/df" <<'EOF'
#!/usr/bin/env bash
# Mock: list mode (-T, possibly combined as -PT) returns / and /home;
# per-mount queries return canned bytes. Parse combined short flags.
list_mode=0; inode_mode=0
for a in "$@"; do
    [[ "$a" == -*T* ]] && list_mode=1
    [[ "$a" == -*i* ]] && inode_mode=1
done
if ((list_mode == 1)); then
    printf 'Filesystem Type 1B-blocks Used Available Use%% Mounted on\n'
    printf '/dev/sda1 ext4 1000000000 300000000 700000000 30%% /\n'
    printf '/dev/sda2 ext4 2000000000 500000000 1500000000 25%% /home\n'
    printf 'tmpfs tmpfs 1000000 0 1000000 0%% /run\n'
    exit 0
fi
if ((inode_mode == 1)); then
    printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n'
    printf '/dev/x 1000 100 900 10%% %s\n' "${@: -1}"
    exit 0
fi
printf 'Filesystem 1B-blocks Used Available Use%% Mounted on\n'
printf '/dev/x 1000000000 300000000 700000000 30%% %s\n' "${@: -1}"
exit 0
EOF
    chmod +x "$mb6/df"
    make_sensors_mock "$mb6" "temp1: +40.0°C"
    fd6="$TMPBASE/proc6"; make_proc_basic "$fd6"
    PATH="$mb6:$PATH" SYSPEEK_PROCROOT="$fd6" "$SCRIPT" --json --all-mounts >"$TMPBASE/multi.json" 2>/dev/null
    mounts=$(python3 -c "import json; print(' '.join(x['mount'] for x in json.load(open('$TMPBASE/multi.json'))['disk']))")
    assert_contains "all-mounts has /home" "$mounts" "/home"
    assert_not_contains "all-mounts skips tmpfs /run" "$mounts" "/run"
    # default (no flag) on same mock: only /
    PATH="$mb6:$PATH" SYSPEEK_PROCROOT="$fd6" "$SCRIPT" --json >"$TMPBASE/single.json" 2>/dev/null
    mounts1=$(python3 -c "import json; print(' '.join(x['mount'] for x in json.load(open('$TMPBASE/single.json'))['disk']))")
    assert_eq "default mount only /" "/" "$mounts1"
else skip "multi-mount" "python3 missing"; fi

# 15. JSON escaping: ps command with quotes/backslash stays valid JSON
if have_python_json; then
    mb7="$TMPBASE/bin-ps"; make_mockbin "$mb7"
    rm -f "$mb7/ps"
    cat >"$mb7/ps" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *stat=* ]]; then printf 'S\nR\n'; exit 0; fi
printf 'USER                               PID %%CPU %%MEM COMMAND\n'
printf 'tester                             1   9.9  1.1  my "quoted" \\ command\n'
printf 'tester                             2   0.1  0.2  plain-cmd --flag\n'
exit 0
EOF
    chmod +x "$mb7/ps"
    make_sensors_mock "$mb7" "temp1: +40.0°C"
    fd7="$TMPBASE/proc7"; make_proc_basic "$fd7"
    PATH="$mb7:$PATH" SYSPEEK_PROCROOT="$fd7" "$SCRIPT" --json --top 5 >"$TMPBASE/esc.json" 2>/dev/null; rc=$?
    assert_eq "escape run exit 0" "0" "$rc"
    if python3 -m json.tool "$TMPBASE/esc.json" >/dev/null 2>&1; then pass "escaped JSON valid"
    else fail "escaped JSON valid" "json.tool failed"; fi
    cmd=$(python3 -c "import json; print(json.load(open('$TMPBASE/esc.json'))['processes']['top_cpu'][0]['command'])")
    assert_contains "escaped command round-trips" "$cmd" '"quoted"'
else skip "json escaping" "python3 missing"; fi

# 16. --install mapping + explicitness
if grep -q 'lm_sensors' "$SCRIPT" && grep -q 'lm-sensors' "$SCRIPT"; then
    pass "--install maps apt/dnf vs pacman names"
else fail "--install maps apt/dnf vs pacman names" "mapping strings missing"; fi
if grep -q 'DO_INSTALL' "$SCRIPT"; then pass "--install is explicit (gated)"; else fail "--install is explicit (gated)" "no gate found"; fi
# mocked --install calls the right manager binary with the right package.
# Isolated PATH (no real sensors/sudo/apt) so the install path is exercised.
mb8="$TMPBASE/bin-install"; make_mockbin "$mb8"
for mgr in apt dnf pacman sensors sudo; do rm -f "$mb8/$mgr"; done
cat >"$mb8/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$mb8/sudo"
cat >"$mb8/apt" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMPBASE/install-calls"
exit 0
EOF
chmod +x "$mb8/apt"
fd8="$TMPBASE/proc8"; make_proc_basic "$fd8"
PATH="$mb8" SYSPEEK_PROCROOT="$fd8" "$SCRIPT" --install --no-color >/dev/null 2>&1 || true
if grep -q "lm-sensors" "$TMPBASE/install-calls" 2>/dev/null; then pass "--install uses apt lm-sensors"
else fail "--install uses apt lm-sensors" "no call logged"; fi

echo "----------------------------------------"
printf 'pass=%s fail=%s skip=%s\n' "$PASS" "$FAIL" "$SKIP"
if ((FAIL > 0)); then exit 1; else exit 0; fi
