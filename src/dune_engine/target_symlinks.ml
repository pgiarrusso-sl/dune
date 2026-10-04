open Import
open Fiber.O

type link =
  { src : Path.Build.t
  ; referents : Path.Build.Set.t
  ; dst : Path.Build.t
  ; target : string
  }

type t = link list

let backup_dir = Path.Build.relative Path.Build.root ".target-symlinks"
let backup_path dst = Path.Build.append_local backup_dir (Path.Build.local dst)

let maybe_async f =
  match Config.(get background_file_system_operations_in_rule_execution) with
  | `Enabled -> Scheduler.async_exn f
  | `Disabled -> Fiber.return (f ())
;;

let mutations = Fiber.Mutex.create ()

let with_mutations f =
  (* Pruning an empty backup directory must not race with another producer
     creating a backup there, including with background filesystem operations. *)
  Fiber.Mutex.with_lock mutations ~f:(fun () -> maybe_async f)
;;

let readlink path =
  match Unix.readlink (Path.Build.to_string path) with
  | target -> Some target
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR | Unix.EINVAL), _, _) -> None
;;

let source ~dst target =
  let target =
    if Filename.is_relative target
    then Filename.concat (Path.Build.to_string (Path.Build.parent_exn dst)) target
    else target
  in
  Path.of_string_allow_outside_workspace target |> Path.as_in_build_dir
;;

let scan ~dirs =
  let readlinks = Path.Build.Table.create 128 in
  let readlink_cached path = Path.Build.Table.find_or_add readlinks path ~f:readlink in
  let referents src =
    let rec find_symlink path =
      if Path.Build.is_root path
      then None
      else (
        match readlink_cached path with
        | Some target -> Some (path, target)
        | None -> find_symlink (Path.Build.parent_exn path))
    in
    let rec loop remaining src seen =
      if remaining = 0 || Path.Build.Set.mem seen src
      then seen
      else (
        let seen = Path.Build.Set.add seen src in
        match find_symlink src with
        | None -> seen
        | Some (dst, target) ->
          (match source ~dst target with
           | None -> seen
           | Some resolved ->
             let suffix =
               Path.drop_prefix_exn (Path.build src) ~prefix:(Path.build dst)
             in
             loop (remaining - 1) (Path.Build.append_local resolved suffix) seen))
    in
    loop 40 src Path.Build.Set.empty
  in
  let add dst target links =
    match source ~dst target with
    | None -> links
    | Some src ->
      Path.Build.Map.set links dst { src; referents = referents src; dst; target }
  in
  let scan root ~dst links =
    Fpath.traverse
      ~dir:(Path.Build.to_string root)
      ~init:links
      ~on_other:`Ignore
      ~on_symlink:
        (`Call
            (fun ~dir fname links ->
              let path = Path.Build.relative_fname (Path.Build.relative root dir) fname in
              let links =
                match readlink path with
                | None -> links
                | Some target ->
                  let dst = dst path in
                  if
                    List.exists dirs ~f:(fun dir -> Path.Build.is_descendant dst ~of_:dir)
                  then add dst target links
                  else links
              in
              links, None))
      ~on_error:
        (`Call
            (fun ~dir:_ error links ->
              match error with
              | Unix.ENOENT, _, _ -> links
              | _ -> Unix_error.Detailed.raise error))
      ()
  in
  let links =
    scan backup_dir Path.Build.Map.empty ~dst:(fun path ->
      Path.drop_prefix_exn (Path.build path) ~prefix:(Path.build backup_dir)
      |> Path.Build.append_local Path.Build.root)
  in
  let links =
    List.fold_left dirs ~init:links ~f:(fun links root -> scan root links ~dst:Fun.id)
  in
  (* Index ancestors too: removing a directory also removes the referents of
     links pointing to files inside that directory. *)
  Path.Build.Map.fold links ~init:Path.Build.Map.empty ~f:(fun link index ->
    let rec loop src keys =
      let keys = Path.Build.Set.add keys src in
      match Path.Build.parent src with
      | None -> keys
      | Some src -> loop src keys
    in
    let keys = Path.Build.Set.fold link.referents ~init:Path.Build.Set.empty ~f:loop in
    Path.Build.Set.fold keys ~init:index ~f:(fun src index ->
      Path.Build.Map.add_multi index src link))
;;

type build =
  { index : t Path.Build.Map.t Fiber.Lazy.t
  ; has_pending : bool Fiber.Lazy.t
  }

let current = Fiber.Var.create None

let with_ ~dirs f =
  let build =
    { index = Fiber.Lazy.create (fun () -> with_mutations (fun () -> scan ~dirs))
    ; has_pending =
        Fiber.Lazy.create (fun () ->
          maybe_async (fun () -> Fpath.exists (Path.Build.to_string backup_dir)))
    }
  in
  Fiber.Var.set current (Some build) f
;;

let affected targets =
  let* build = Fiber.Var.get_exn current in
  let+ index = Fiber.Lazy.force build.index in
  let find path links =
    List.fold_left
      (Path.Build.Map.Multi.find index path)
      ~init:links
      ~f:(fun links link -> Path.Build.Map.set links link.dst link)
  in
  Targets.Validated.fold targets ~init:Path.Build.Map.empty ~file:find ~dir:find
  |> Path.Build.Map.values
;;

let prune_backup_dirs dir =
  let rec loop dir =
    if Path.Build.is_descendant dir ~of_:backup_dir
    then (
      match Unix.rmdir (Path.Build.to_string dir) with
      | () -> Path.Build.parent dir |> Option.iter ~f:loop
      | exception Unix.Unix_error ((Unix.ENOTEMPTY | Unix.EEXIST | Unix.ENOENT), _, _) ->
        ())
  in
  loop dir
;;

let is_protected path =
  List.exists (Build_config.get ()).target_symlink_dirs ~f:(fun dir ->
    Path.Build.is_descendant path ~of_:dir)
;;

let directory_can_contain_links dir =
  let rec loop dir =
    if Path.Build.is_root dir
    then true
    else (
      match Unix.lstat (Path.Build.to_string dir) with
      | { Unix.st_kind = Unix.S_DIR; _ } -> loop (Path.Build.parent_exn dir)
      | _ -> false
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> loop (Path.Build.parent_exn dir)
      | exception Unix.Unix_error (Unix.ENOTDIR, _, _) -> false)
  in
  loop dir
;;

let parent_can_contain_link dst = directory_can_contain_links (Path.Build.parent_exn dst)

let discard_backup path =
  let backup = backup_path path in
  if parent_can_contain_link backup
  then (
    Path.rm_rf (Path.build backup);
    prune_backup_dirs (Path.Build.parent_exn backup))
;;

let prune_stale ~dir ~is_target ~subdirs_to_keep =
  if not (is_protected dir)
  then Fiber.return ()
  else
    with_mutations (fun () ->
      let backup = backup_path dir in
      if not (directory_can_contain_links backup)
      then ()
      else (
        match Path.Untracked.readdir_unsorted_with_kinds (Path.build backup) with
        | Error (Unix.ENOENT, _, _) -> ()
        | Error error -> Unix_error.Detailed.raise error
        | Ok entries ->
          List.iter entries ~f:(fun (name, kind) ->
            let path = Path.Build.relative_fname dir name in
            let keep =
              match kind with
              | Unix.S_DIR -> Subdir_set.mem subdirs_to_keep name && not (is_target path)
              | _ -> is_target path
            in
            if not keep then discard_backup path)))
;;

let rec mkdir_backup_dir dir =
  if not (Path.Build.equal dir backup_dir)
  then mkdir_backup_dir (Path.Build.parent_exn dir);
  (* A saved directory link is a metadata entry, not a directory for children.
     Visible children supersede a previously withdrawn link at their parent. *)
  match Unix.lstat (Path.Build.to_string dir) with
  | { Unix.st_kind = Unix.S_LNK; _ } ->
    Fpath.unlink_exn (Path.Build.to_string dir);
    Path.mkdir_p (Path.build dir)
  | { Unix.st_kind = Unix.S_DIR; _ } -> ()
  | _ -> Unix.mkdir (Path.Build.to_string dir) 0o777
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Path.mkdir_p (Path.build dir)
;;

let remove targets =
  let* links = affected targets in
  let protected_targets =
    Targets.Validated.fold
      targets
      ~init:[]
      ~file:(fun path acc -> if is_protected path then path :: acc else acc)
      ~dir:(fun path acc -> if is_protected path then path :: acc else acc)
  in
  if List.is_empty links && List.is_empty protected_targets
  then Fiber.return links
  else
    let+ () =
      with_mutations (fun () ->
        List.iter protected_targets ~f:discard_backup;
        List.iter links ~f:(fun { src = _; referents = _; dst; target } ->
          match readlink dst with
          | Some current when String.equal current target && parent_can_contain_link dst
            ->
            let backup = backup_path dst in
            mkdir_backup_dir (Path.Build.parent_exn backup);
            Rule_cache.Workspace_local.remove_target dst;
            Rule_cache.Workspace_local.remove_subtree dst;
            Unix.rename (Path.Build.to_string dst) (Path.Build.to_string backup)
          | None | Some _ -> ()))
    in
    links
;;

let restore links produced =
  if List.is_empty links
  then Fiber.return ()
  else
    with_mutations (fun () ->
      List.iter links ~f:(fun { src; referents; dst; target } ->
        let src_exists () =
          match Path.Untracked.stat (Path.build src) with
          | Ok _ -> true
          | Error _ -> false
        in
        if
          Path.Build.Set.exists referents ~f:(Targets.Produced.mem_any produced)
          && src_exists ()
          && parent_can_contain_link dst
          && parent_can_contain_link (backup_path dst)
        then (
          let backup = backup_path dst in
          match readlink backup with
          | Some current when String.equal current target ->
            let destination_exists =
              match Unix.lstat (Path.Build.to_string dst) with
              | _ -> true
              | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false
            in
            if destination_exists
            then Fpath.unlink_exn (Path.Build.to_string backup)
            else (
              Rule_cache.Workspace_local.remove_target dst;
              Rule_cache.Workspace_local.remove_subtree dst;
              Path.mkdir_p (Path.build (Path.Build.parent_exn dst));
              Unix.rename (Path.Build.to_string backup) (Path.Build.to_string dst));
            prune_backup_dirs (Path.Build.parent_exn backup)
          | None | Some _ -> ())))
;;

let restore_pending targets produced =
  let* build = Fiber.Var.get_exn current in
  let* has_pending = Fiber.Lazy.force build.has_pending in
  if not has_pending
  then Fiber.return ()
  else
    let* links = affected targets in
    restore links produced
;;
