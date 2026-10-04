open Import

type t

(** Maintain an index of existing symlinks for one build. The index is only
    scanned if a target needs rebuilding or a previous build left links
    withdrawn. Directory symlinks are not traversed. *)
val with_ : dirs:Path.Build.t list -> (unit -> 'a Fiber.t) -> 'a Fiber.t

(** Move links whose referents will be removed into private build metadata.
    They remain there if the producer fails or the build is interrupted. *)
val remove : Targets.Validated.t -> t Fiber.t

(** Restore withdrawn links to validated outputs, including links that were
    not requested by this build. Links to missing outputs stay withdrawn. *)
val restore : t -> Digest.t Targets.Produced.t -> unit Fiber.t

(** Recover links left withdrawn by an interrupted build whose producer's
    outputs are still up to date in the workspace-local cache. *)
val restore_pending : Targets.Validated.t -> Digest.t Targets.Produced.t -> unit Fiber.t

(** Apply the same stale-artifact cleanup to withdrawn links as to visible
    outputs. Directory targets own their entire subtree. *)
val prune_stale
  :  dir:Path.Build.t
  -> is_target:(Path.Build.t -> bool)
  -> subdirs_to_keep:Subdir_set.t
  -> unit Fiber.t
