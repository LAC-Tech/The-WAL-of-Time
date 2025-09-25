module ReplicaID = struct
  type t = int [@@deriving ord]
end

module ReplicaIDMap = Map.Make (ReplicaID)

module Event = struct
  type t = Bytes.t
end

(* Maps ReplicaIDs to the size of the file *)
module VersionVector : sig
  type t

  val update : t -> ReplicaID.t -> int -> t
end = struct
  type t = int ReplicaIDMap.t

  let update vv id new_offset =
    let f = function
      | Some old_offset ->
          assert (new_offset > old_offset);
          Some new_offset
      | None -> Some new_offset
    in
    ReplicaIDMap.update id f vv
end

module Msg = struct
  type incoming =
    | Append of { rid : ReplicaID.t; events : Event.t list }
    | ClientRead of VersionVector.t

  type outgoing =
    | Current of VersionVector.t
    | RemoteDelta of Bytes.t ReplicaIDMap.t
end

module AOF : sig
  type t

  val append : t -> Event.t list -> t
end = struct
  type t = Event.t Containers_pvec.t

  let append = Containers_pvec.add_list
end

module FD = struct
  type t = int [@@deriving ord]
end

module FDMap = Map.Make (FD)

(** These should all be equivalent to syscalls *)
module LocalIo = struct
  (* ie, SQE *)
  type req =
    | Send of Msg.outgoing
    | Append of { fd : FD.t; events : Event.t list }

  (* ie, CQE *)
  type res = Write of { fd : FD.t; size : int } | Recv of Msg.incoming
end

module StateMachine : sig
  type t

  val transition : t -> LocalIo.res -> t
end = struct
  type t = {
    fd_to_rid : ReplicaID.t FDMap.t;
    rid_to_fd : FD.t ReplicaIDMap.t;
    vv : VersionVector.t;
    req_buf : LocalIo.req list;
  }

  let transition sm = function
    | LocalIo.Write { fd; size } ->
        let rid = FDMap.find fd sm.fd_to_rid in
        { sm with vv = VersionVector.update sm.vv rid size }
    | LocalIo.Recv msg -> (
        match msg with
        | Append { rid; events } ->
            let fd = ReplicaIDMap.find rid sm.rid_to_fd in
            { sm with req_buf = [ LocalIo.Append { fd; events } ] }
        | ClientRead vv -> failwith "TODO")
end
