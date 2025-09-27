type 'event t
(** Parameterised by event type pure to simplify simulations We can test various
    scenarios without whatever data we want without serde *)

val create : (Wp.ReplicaID.t * Local_io.FD.t * int) Seq.t -> 'e t
val transition : 'e Local_io.res -> 'e t -> 'e t
val io_reqs : 'e t -> 'e Local_io.req Seq.t
