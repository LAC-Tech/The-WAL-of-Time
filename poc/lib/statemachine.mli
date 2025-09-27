type t

val create : (Wp.ReplicaID.t * Local_io.FD.t * int) Seq.t -> t
val transition : Local_io.res -> t -> t
val io_reqs : t -> Local_io.req Seq.t
