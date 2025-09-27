(** These should all be equivalent to syscalls *)

module FD : sig
  type t

  module Map : Map.S with type key = t
end = struct
  type t = int

  module Map = Map.Make (Int)
end

(* ie, SQE *)
type 'event req =
  | Send of 'event Wp.outgoing
  | Append of { fd : FD.t; events : 'event list }
  | Read of { fd : FD.t; offset : int }

(* ie, CQE *)
type 'event res =
  | Write of { fd : FD.t; size : int }
  | Recv of 'event Wp.incoming
