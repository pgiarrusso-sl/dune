Withdraw and restore installed links on successive watch-mode builds that
request only the producer. Each build must inspect the current installed tree.

  $ export DUNE_CACHE=enabled
  $ make_dune_project_with_package 3.24 watch-test
  $ export GATE_DIR=$(mktemp -d)
  $ cleanup() {
  >   touch "$GATE_DIR/release"
  >   dune shutdown >/dev/null 2>&1
  >   rm -r "$GATE_DIR"
  > }
  $ trap cleanup EXIT
  $ cat > dune <<'EOF'
  > (rule
  >  (target payload.txt)
  >  (deps input.txt (universe))
  >  (action
  >   (progn
  >    (run touch %{env:GATE_DIR=missing-gate}/started)
  >    (run dune_cmd wait-for-file-to-appear
  >     %{env:GATE_DIR=missing-gate}/release)
  >    (copy input.txt %{target}))))
  > (install (section share) (files payload.txt))
  > EOF
  $ installed=_build/install/default/share/watch-test/payload.txt
  $ echo watch-one > input.txt
  $ touch "$GATE_DIR/release"
  $ dune build "$installed" --display=quiet
  $ cat "$installed"
  watch-one
  $ start_dune --display=quiet

  $ for version in two three; do
  >   rm "$GATE_DIR/release" "$GATE_DIR/started"
  >   echo watch-$version > input.txt
  >   dune rpc build --wait payload.txt > .#rpc-output 2>&1 & request_pid=$!
  >   "$timeout" 15 dune_cmd wait-for-file-to-appear "$GATE_DIR/started" || {
  >     cat .#rpc-output .#dune-output; exit 1;
  >   }
  >   test ! -L "$installed" || exit 1
  >   touch "$GATE_DIR/release"
  >   wait "$request_pid" || { cat .#rpc-output; exit 1; }
  >   test "$(cat "$installed")" = watch-$version || exit 1
  > done
  $ cat "$installed"
  watch-three
  $ test ! -e _build/.target-symlinks
  $ stop_dune_quiet
