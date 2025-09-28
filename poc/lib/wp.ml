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

  val create : ReplicaID.t -> Counter.t -> t
  val update : ReplicaID.t -> Counter.t -> t -> t
  val to_list : t -> (ReplicaID.t * Counter.t) list
end = struct
  type t = Counter.t ReplicaID.Map.t

  let create rid offset = ReplicaID.Map.of_list [ (rid, offset) ]

  let update id new_offset =
    let f = function
      | Some old_offset -> Some (Counter.update new_offset old_offset)
      | None -> Some new_offset
    in
    ReplicaID.Map.update id f

  let to_list = ReplicaID.Map.to_list
end

(** Server to server msg *)
type 'event s2s_msg =
  | Append of { rid : ReplicaID.t; events : 'event list }
  | Current of VV.t
