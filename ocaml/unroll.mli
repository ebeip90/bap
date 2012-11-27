(** Loop unrolling *)

(** The type signature of a loop unrolling function. Count specifies
    the number of times to unroll loops. *)
type unrollf = ?count:int -> Cfg.AST.G.t -> Cfg.AST.G.t

(** Unroll loops identified by structural analysis. The current
    structural analysis implementation is incomplete and may fail
    (raise an exception). *)
val unroll_loops_sa: unrollf

(** Unroll loops using the default loop identification algorithm,
    which is unspecifed and may change. *)
val unroll_loops: unrollf