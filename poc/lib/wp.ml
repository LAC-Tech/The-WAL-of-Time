(** Wire Protocol **)

module ReplicaID : sig
  type t

  module Map : Map.S with type key = t
end = struct
  type t = int

  module Map = Map.Make (Int)
end

(* Maps ReplicaIDs to the size of the file *)
module VV : sig
  type t

  val empty : t
  val update : ReplicaID.t -> int -> t -> t
  val to_list : t -> (ReplicaID.t * int) list
end = struct
  type t = int ReplicaID.Map.t

  let empty = ReplicaID.Map.empty

  let update (id : ReplicaID.t) (new_offset : int) vv =
    let f = function
      | Some old_offset ->
          assert (new_offset > old_offset);
          Some new_offset
      | None -> Some new_offset
    in
    ReplicaID.Map.update id f vv

  let to_list = ReplicaID.Map.to_list
end

type incoming =
  | Append of { rid : ReplicaID.t; events : Bytes.t list }
  | ClientRead of VV.t

type outgoing = Current of VV.t | RemoteDelta of Bytes.t ReplicaID.Map.t
