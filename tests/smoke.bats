load test_helper

setup() {
  setup_yazi tailscale
  # a `tailscale` that is a script: it says which devices there are, and writes down what it is asked to
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB/bin"
  export STUB
  cat >"$STUB/status.json" <<'JSON'
{"Peer": {
  "a": {"DNSName": "laptop.tail.ts.net.", "OS": "macOS", "Online": true, "TailscaleIPs": ["100.64.0.2", "fd7a::2"]},
  "b": {"DNSName": "phone.tail.ts.net.", "OS": "iOS", "Online": true, "TailscaleIPs": ["100.64.0.3"]},
  "c": {"DNSName": "old.tail.ts.net.", "OS": "linux", "Online": false, "TailscaleIPs": ["100.64.0.4"]}
}}
JSON
  cat >"$STUB/bin/tailscale" <<'SH'
#!/bin/sh
case "$1 $2" in
  "status --json") cat "$STUB/status.json" ;;
  "file cp") echo "cp $3 $4" >>"$STUB/calls.log" ;;
  "file get")
    for last; do :; done
    echo hello >"$last/received.txt"
    echo "get $*" >>"$STUB/calls.log"
    ;;
esac
SH
  chmod +x "$STUB/bin/tailscale"
  export PATH="$STUB/bin:$PATH"

  cat >"$YAZI_CONFIG_HOME/keymap.toml" <<'KEYS'
[mgr]
prepend_keymap = [
  { on = ["T", "s"], run = "plugin tailscale send", desc = "Send with Taildrop" },
  { on = ["T", "r"], run = "plugin tailscale receive", desc = "Receive with Taildrop" },
  { on = ["T", "x"], run = "plugin tailscale oops", desc = "A wrong argument" },
]
KEYS
  echo hello >"$WORK/aaa.txt"
  echo hello >"$WORK/bbb.txt"
  mkdir -p "$WORK/folder"
  echo hello >"$WORK/folder/inside.txt"
}

teardown() { stop_yazi; }

calls() { cat "$STUB/calls.log" 2>/dev/null || true; }

@test "the menu lists the devices that are online, and not the others" {
  start_yazi
  send_keys T
  send_keys s
  assert_healthy
  assert_screen "laptop (macOS)"
  assert_screen "phone (iOS)"
  refute_screen "old (linux)"
}

@test "the hovered file is sent to the device that is chosen" {
  start_yazi
  # the folder is the first entry, the file is the second
  send_keys j
  send_keys T
  send_keys s
  send_keys 2
  assert_healthy
  calls | grep -q "cp $WORK/aaa.txt 100.64.0.3:"
}

@test "the selected files are sent, all of them" {
  start_yazi
  send_keys j
  send_keys Space
  send_keys Space
  send_keys T
  send_keys s
  send_keys 1
  assert_healthy
  calls | grep -q "cp $WORK/aaa.txt 100.64.0.2:"
  calls | grep -q "cp $WORK/bbb.txt 100.64.0.2:"
}

@test "a folder is sent as a zip" {
  start_yazi
  # the folder is the first entry
  send_keys T
  send_keys s
  send_keys 1
  assert_healthy
  calls | grep -q "folder.zip 100.64.0.2:"
}

@test "nothing is sent when the menu is cancelled" {
  start_yazi
  send_keys T
  send_keys s
  send_keys Escape
  assert_healthy
  [ -z "$(calls)" ]
}

@test "no device online is a message that says so" {
  sed -i.bak 's/"Online": true/"Online": false/g' "$STUB/status.json"
  start_yazi
  send_keys T
  send_keys s
  assert_screen "No device is online"
  [ -z "$(calls)" ]
}

@test "receive takes the files into the folder of Yazi" {
  start_yazi
  send_keys T
  send_keys r
  assert_healthy
  assert_screen "received.txt"
  calls | grep -q "^get file get --conflict=rename $WORK"
}

@test "a wrong argument is an error that says what to use" {
  start_yazi
  send_keys T
  send_keys x
  assert_screen "plugin tailscale send"
}
