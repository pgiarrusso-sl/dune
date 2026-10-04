Install links wait for their targets when first built, but existing links
survive while their targets are rebuilt. The gated producer depends on
universe because its synchronization side effects must run every time.

  $ export DUNE_CACHE=enabled
  $ mkdir case gate
  $ export GATE_DIR=$PWD/gate
  $ cat > case/dune-project <<EOF
  > (lang dune 3.24)
  > (name link-test)
  > (package (name link-test))
  > EOF
  $ cat > case/dune <<'EOF'
  > (rule
  >  (target payload.txt)
  >  (deps input.txt (env_var GATE_DIR) (universe))
  >  (action
  >   (progn
  >    (run touch %{env:GATE_DIR=missing-gate}/started)
  >    (run dune_cmd wait-for-file-to-appear
  >     %{env:GATE_DIR=missing-gate}/release)
  >    (copy input.txt %{target}))))
  > (install (section share) (files payload.txt))
  > EOF
  $ wait_started() {
  >   "$timeout" 15 dune_cmd wait-for-file-to-appear gate/started || {
  >     cat "$1"; return 1;
  >   }
  > }
  $ trap 'touch gate/release' EXIT
  $ installed=case/_build/install/default/share/link-test/payload.txt
  $ target=case/_build/default/payload.txt

Fresh build: the symlink action waits for the producer to finish.

  $ echo version-one > case/input.txt
  $ (cd case &&
  >  dune build _build/install/default/share/link-test/payload.txt \
  >    --display=quiet) > fresh.log 2>&1 & build_pid=$!
  $ wait_started fresh.log
  $ if test -L "$installed"; then echo fresh-link-present;
  > else echo fresh-link-absent; fi
  fresh-link-absent
  $ if test -e "$target"; then echo fresh-target-present;
  > else echo fresh-target-absent; fi
  fresh-target-absent
  $ touch gate/release
  $ wait "$build_pid"
  $ cat "$installed"
  version-one

Incremental rebuild: the old installed link outlives its removed target.

  $ rm gate/release gate/started
  $ echo version-two > case/input.txt
  $ (cd case &&
  >  dune build _build/install/default/share/link-test/payload.txt \
  >    --display=quiet) > rebuild.log 2>&1 & build_pid=$!
  $ wait_started rebuild.log
  $ if test -L "$installed"; then echo old-link-present;
  > else echo old-link-absent; fi
  old-link-present
  $ if test -e "$target"; then echo rebuilding-target-present;
  > else echo rebuilding-target-absent; fi
  rebuilding-target-absent
  $ if test -e "$installed"; then echo old-link-resolves;
  > else echo old-link-dangling; fi
  old-link-dangling
  $ touch gate/release
  $ wait "$build_pid"
  $ cat "$installed"
  version-two

Rebuilding only the producer also leaves the old installed link dangling.

  $ rm gate/release gate/started
  $ echo version-three > case/input.txt
  $ (cd case && dune build payload.txt --display=quiet) \
  >   > producer-only.log 2>&1 & build_pid=$!
  $ wait_started producer-only.log
  $ if test -L "$installed"; then echo unrequested-link-present;
  > else echo unrequested-link-absent; fi
  unrequested-link-present
  $ if test -e "$target"; then echo producer-target-present;
  > else echo producer-target-absent; fi
  producer-target-absent
  $ if test -e "$installed"; then echo unrequested-link-resolves;
  > else echo unrequested-link-dangling; fi
  unrequested-link-dangling
  $ touch gate/release
  $ wait "$build_pid"
  $ cat "$installed"
  version-three
