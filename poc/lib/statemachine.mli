type 'event t
(** Parameterised by event type pure to simplify simulations We can test various
    scenarios without whatever data we want without serde *)

type log = { rid : Wp.ReplicaID.t; fd : Local_io.FD.t; count : Counter.t }

val create : log -> log Seq.t -> 'e t
val transition : 'e Local_io.res -> 'e t -> 'e t
val io_reqs : 'e t -> 'e Local_io.req Seq.t
