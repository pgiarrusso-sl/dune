Install links wait for their targets when first built. Existing links are
withdrawn while their targets are rebuilt, even if only the producer is
requested. The gated producer depends on universe because its synchronization
side effects must run every time.

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
  >    (run test %{env:FAIL_PRODUCER=0} = 0)
  >    (copy input.txt %{target}))))
  > (install (section share) (files payload.txt))
  > EOF
  $ wait_started() {
  >   "$timeout" 15 dune_cmd wait-for-file-to-appear "$GATE_DIR/started" || {
  >     cat "$1"; return 1;
  >   }
  > }
  $ trap 'touch "$GATE_DIR/release"' EXIT
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

Incremental rebuild: withdraw the installed link before removing its target.

  $ rm gate/release gate/started
  $ echo version-two > case/input.txt
  $ (cd case &&
  >  dune build _build/install/default/share/link-test/payload.txt \
  >    --display=quiet) > rebuild.log 2>&1 & build_pid=$!
  $ wait_started rebuild.log
  $ if test -L "$installed"; then echo old-link-present;
  > else echo old-link-absent; fi
  old-link-absent
  $ if test -e "$target"; then echo rebuilding-target-present;
  > else echo rebuilding-target-absent; fi
  rebuilding-target-absent
  $ if test -e "$installed"; then echo old-link-resolves;
  > else echo old-link-unavailable; fi
  old-link-unavailable
  $ touch gate/release
  $ wait "$build_pid"
  $ cat "$installed"
  version-two

Rebuilding only the producer also withdraws and restores the installed link.

  $ rm gate/release gate/started
  $ echo version-three > case/input.txt
  $ (cd case && dune build payload.txt --display=quiet) \
  >   > producer-only.log 2>&1 & build_pid=$!
  $ wait_started producer-only.log
  $ if test -L "$installed"; then echo unrequested-link-present;
  > else echo unrequested-link-absent; fi
  unrequested-link-absent
  $ if test -e "$target"; then echo producer-target-present;
  > else echo producer-target-absent; fi
  producer-target-absent
  $ if test -e "$installed"; then echo unrequested-link-resolves;
  > else echo unrequested-link-unavailable; fi
  unrequested-link-unavailable
  $ touch gate/release
  $ wait "$build_pid"
  $ cat "$installed"
  version-three
  $ test ! -e case/_build/.target-symlinks

A failed producer leaves its link withdrawn. A later producer-only build
recovers it from the saved link, without requesting the install rule.

  $ rm gate/release gate/started
  $ echo version-four > case/input.txt
  $ (cd case && FAIL_PRODUCER=1 dune build payload.txt --display=quiet) \
  >   > failed.log 2>&1 & build_pid=$!
  $ wait_started failed.log
  $ test ! -L "$installed"
  $ touch gate/release
  $ wait "$build_pid"
  [1]
  $ test ! -e "$target"
  $ test ! -L "$installed"
  $ saved_dir=case/_build/.target-symlinks/install/default/share/link-test
  $ saved=$saved_dir/payload.txt
  $ test -L "$saved"
  $ rm gate/release gate/started
  $ (cd case && dune build payload.txt --display=quiet) \
  >   > recover.log 2>&1 & build_pid=$!
  $ wait_started recover.log
  $ test ! -L "$installed"
  $ touch gate/release
  $ wait "$build_pid"
  $ cat "$installed"
  version-four
  $ test ! -e case/_build/.target-symlinks

An interrupted build can leave a withdrawn link even though its producer's
output is up to date. Simulate that interruption, then request only the cached
producer. The saved symlink must be recovered without rerunning the action.

  $ cat >> case/dune <<'EOF'
  > (rule
  >  (target stable.txt)
  >  (deps input.txt)
  >  (action
  >   (progn
  >    (run echo stable-producer-executed)
  >    (copy input.txt %{target}))))
  > (install (section share) (files stable.txt))
  > EOF
  $ (cd case && dune build \
  >   _build/install/default/share/link-test/stable.txt --display=quiet)
  stable-producer-executed
  $ stable=case/_build/install/default/share/link-test/stable.txt
  $ stable_saved=$saved_dir/stable.txt
  $ mkdir -p "$(dirname "$stable_saved")"
  $ mv "$stable" "$stable_saved"
  $ test ! -L "$stable"
  $ (cd case && dune build stable.txt --display=short)
  $ cat "$stable"
  version-four
  $ test ! -e case/_build/.target-symlinks

Withdrawn links obey ordinary stale-artifact cleanup. Removing an install
entry must not allow a later producer-only build to resurrect its saved link.

  $ mkdir -p "$(dirname "$stable_saved")"
  $ mv "$stable" "$stable_saved"
  $ sed '/(install (section share) (files stable.txt))/d' case/dune \
  >   > case/dune.new
  $ mv case/dune.new case/dune
  $ (cd case && dune build \
  >   _build/install/default/share/link-test/payload.txt --display=quiet)
  $ (cd case && dune build stable.txt --display=short)
  $ test ! -L "$stable"
  $ test ! -e case/_build/.target-symlinks

A saved child link from an old layout must not be restored through a new
directory symlink, which would write into another rule's source directory.
Loading the new directory's install rule discards the obsolete saved child.

  $ cat >> case/dune <<'EOF'
  > (rule
  >  (target (dir real-dir))
  >  (deps input.txt (sandbox always))
  >  (action
  >   (progn
  >    (run mkdir %{target})
  >    (run cp input.txt %{target}/kept.txt))))
  > (install (section share) (dirs (real-dir as renamed)))
  > EOF
  $ renamed=case/_build/install/default/share/link-test/renamed
  $ (cd case && dune build \
  >   _build/install/default/share/link-test/renamed --display=quiet)
  $ stale_dir=$saved_dir/renamed
  $ mkdir -p "$stale_dir"
  $ ln -s ../../../../../default/stable.txt "$stale_dir/obsolete.txt"
  $ (cd case && dune build stable.txt --display=short)
  $ test ! -L "$renamed/obsolete.txt"
  $ test ! -L case/_build/default/real-dir/obsolete.txt
  $ (cd case && dune build \
  >   _build/install/default/share/link-test/renamed --display=quiet)
  $ test ! -e case/_build/.target-symlinks

An installed file can itself be a symlink. Withdraw its installed link while
the underlying producer runs, even though the intervening symlink is unchanged.

  $ cat >> case/dune <<'EOF'
  > (rule
  >  (target alias.txt)
  >  (deps payload.txt)
  >  (action (run ln -s payload.txt %{target})))
  > (install (section share) (files alias.txt))
  > (rule
  >  (target alias2.txt)
  >  (deps alias.txt)
  >  (action (run ln -s alias.txt %{target})))
  > (install (section share) (files alias2.txt))
  > EOF
  $ (cd case && dune build \
  >   _build/install/default/share/link-test/alias2.txt --display=quiet)
  $ alias=case/_build/install/default/share/link-test/alias.txt
  $ alias2=case/_build/install/default/share/link-test/alias2.txt
  $ (cd case && dune build \
  >   _build/install/default/share/link-test/alias.txt --display=quiet)
  $ test -L case/_build/default/alias.txt
  $ share=case/_build/install/default/share/link-test
  $ ln -s ../../../../../../../../../../missing "$share/Unused"
  $ ln -s . "$share/Loop"
  $ rm gate/release gate/started
  $ echo version-five > case/input.txt
  $ (cd case && dune build payload.txt --display=quiet) \
  >   > indirect.log 2>&1 & build_pid=$!
  $ wait_started indirect.log
  $ test ! -L "$alias"
  $ test ! -L "$alias2"
  $ test ! -L "$installed"
  $ touch gate/release
  $ wait "$build_pid"
  $ cat "$alias"
  version-five
  $ cat "$alias2"
  version-five
  $ test -L "$share/Unused"
  $ test -L "$share/Loop"
  $ test ! -e case/_build/.target-symlinks

Directory targets can have both a directory symlink and links to individual
files inside them. Withdraw both kinds before deleting the directory.

  $ mkdir dir-case dir-gate
  $ export GATE_DIR=$PWD/dir-gate
  $ cat > dir-case/dune-project <<EOF
  > (lang dune 3.24)
  > (name dir-test)
  > (package (name dir-test))
  > EOF
  $ cat > dir-case/dune <<'EOF'
  > (rule
  >  (target (dir payload-dir))
  >  (deps input.txt (universe) (sandbox always))
  >  (action
  >   (progn
  >    (run touch %{env:GATE_DIR=missing-gate}/started)
  >    (run dune_cmd wait-for-file-to-appear
  >     %{env:GATE_DIR=missing-gate}/release)
  >    (run mkdir %{target})
  >    (run cp input.txt %{target}/keep.txt)
  >    (run sh -c "if [ \"$1\" = 0 ]; then cp \"$2\" \"$3\"; fi"
  >     -- %{env:DROP_CHILD=0} input.txt %{target}/optional.txt))))
  > (rule
  >  (target (dir alias-dir))
  >  (deps payload-dir (sandbox always))
  >  (action (run ln -s payload-dir %{target})))
  > (install
  >  (section share)
  >  (dirs payload-dir)
  >  (files
  >   (payload-dir/optional.txt as optional.txt)
  >   (alias-dir/keep.txt as indirect.txt)))
  > EOF
  $ echo directory-one > dir-case/input.txt
  $ touch dir-gate/release
  $ (cd dir-case && dune build \
  >   _build/install/default/share/dir-test/payload-dir \
  >   _build/install/default/share/dir-test/optional.txt \
  >   _build/install/default/share/dir-test/indirect.txt --display=quiet)
  $ dir_installed=dir-case/_build/install/default/share/dir-test/payload-dir
  $ child_installed=dir-case/_build/install/default/share/dir-test/optional.txt
  $ indirect=dir-case/_build/install/default/share/dir-test/indirect.txt
  $ rm dir-gate/release dir-gate/started
  $ echo directory-two > dir-case/input.txt
  $ (cd dir-case && DROP_CHILD=1 dune build payload-dir --display=quiet) \
  >   > dir-rebuild.log 2>&1 & build_pid=$!
  $ wait_started dir-rebuild.log
  $ test ! -L "$dir_installed"
  $ test ! -L "$child_installed"
  $ test ! -L "$indirect"
  $ touch dir-gate/release
  $ wait "$build_pid"
  $ cat "$dir_installed/keep.txt"
  directory-two
  $ cat "$indirect"
  directory-two

The link to a file omitted by the new producer must remain withdrawn. A later
producer-only rebuild that includes that file restores it.

  $ test ! -L "$child_installed"
  $ rm dir-gate/release dir-gate/started
  $ echo directory-three > dir-case/input.txt
  $ (cd dir-case && dune build payload-dir --display=quiet) \
  >   > dir-recover.log 2>&1 & build_pid=$!
  $ wait_started dir-recover.log
  $ test ! -L "$dir_installed"
  $ test ! -L "$child_installed"
  $ touch dir-gate/release
  $ wait "$build_pid"
  $ cat "$child_installed"
  directory-three
  $ cat "$dir_installed/keep.txt"
  directory-three
  $ cat "$indirect"
  directory-three
  $ test ! -e dir-case/_build/.target-symlinks

Parallel producers share backup directories. Exercise their creation and
cleanup with background filesystem operations and repeated input changes.

  $ mkdir parallel-case
  $ cat > parallel-case/dune-project <<EOF
  > (lang dune 3.24)
  > (name parallel-test)
  > (package (name parallel-test))
  > EOF
  $ for i in 1 2 3 4 5 6 7 8; do
  >   cat >> parallel-case/dune <<EOF
  > (rule
  >  (target file$i.txt)
  >  (deps input.txt)
  >  (action (copy input.txt %{target})))
  > (install (section share) (files file$i.txt))
  > EOF
  > done
  $ echo parallel-zero > parallel-case/input.txt
  $ (cd parallel-case && dune build @install --display=quiet)
  $ parallel_install=parallel-case/_build/install/default/share/parallel-test
  $ for version in one two three four; do
  >   echo parallel-$version > parallel-case/input.txt
  >   (cd parallel-case &&
  >  DUNE_CONFIG__BACKGROUND_FILE_SYSTEM_OPERATIONS_IN_RULE_EXECUTION=enabled \
  >      dune build file{1,2,3,4,5,6,7,8}.txt -j 8 --display=quiet) || exit 1
  >   for i in 1 2 3 4 5 6 7 8; do
  >     test -L "$parallel_install/file$i.txt" || exit 1
  >     test "$(cat "$parallel_install/file$i.txt")" = parallel-$version || \
  >       exit 1
  >   done
  > done
  $ cat "$parallel_install/file1.txt"
  parallel-four
  $ test ! -e parallel-case/_build/.target-symlinks
