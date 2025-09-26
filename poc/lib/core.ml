module ReplicaID = struct
  type t = int

  module Map = Map.Make (Int)
end

module FD = struct
  type t = int

  module Map = Map.Make (Int)
end

module Event = struct
  type t = Bytes.t
end

(* Maps ReplicaIDs to the size of the file *)
module VersionVector : sig
  type t

  val empty : t
  val update : ReplicaID.t -> int -> t -> t
  val to_seq : t -> (ReplicaID.t * int) Seq.t
end = struct
  type t = int ReplicaID.Map.t

  let empty = ReplicaID.Map.empty

  let update id new_offset vv =
    let f = function
      | Some old_offset ->
          assert (new_offset > old_offset);
          Some new_offset
      | None -> Some new_offset
    in
    ReplicaID.Map.update id f vv

  let to_seq = ReplicaID.Map.to_seq
end

module Msg = struct
  type incoming =
    | Append of { rid : ReplicaID.t; events : Event.t list }
    | ClientRead of VersionVector.t

  type outgoing =
    | Current of VersionVector.t
    | RemoteDelta of Bytes.t ReplicaID.Map.t
end

module AOF : sig
  type t

  val append : t -> Event.t list -> t
end = struct
  type t = Event.t Containers_pvec.t

  let append = Containers_pvec.add_list
end

(** These should all be equivalent to syscalls *)
module LocalIo = struct
  (* ie, SQE *)
  type req =
    | Send of Msg.outgoing
    | Append of { fd : FD.t; events : Event.t list }
    | Read of { fd : FD.t; offset : int }

  (* ie, CQE *)
  type res = Write of { fd : FD.t; size : int } | Recv of Msg.incoming
end

module Logs : sig
  type t

  val empty : t
  val get_fd : ReplicaID.t -> t -> FD.t
  val get_rid : FD.t -> t -> ReplicaID.t
end = struct
  type t = {
    fd_to_rid : ReplicaID.t FD.Map.t;
    rid_to_fd : FD.t ReplicaID.Map.t;
  }

  let empty = { fd_to_rid = FD.Map.empty; rid_to_fd = ReplicaID.Map.empty }
  let get_fd rid ls = ReplicaID.Map.find rid ls.rid_to_fd
  let get_rid fd ls = FD.Map.find fd ls.fd_to_rid
end

module StateMachine : sig
  type t

  val empty : t
  val transition : LocalIo.res -> t -> t
end = struct
  type t = { logs : Logs.t; vv : VersionVector.t; req_buf : LocalIo.req list }

  let empty = { logs = Logs.empty; vv = VersionVector.empty; req_buf = [] }

  let transition io_res sm =
    let recv = function
      | Msg.Append { rid; events } ->
          let fd = Logs.get_fd rid sm.logs in
          [ LocalIo.Append { fd; events } ]
      | Msg.ClientRead vv ->
          vv |> VersionVector.to_seq
          |> Seq.map (fun (rid, offset) ->
                 let fd = Logs.get_fd rid sm.logs in
                 LocalIo.Read { fd; offset })
          |> List.of_seq
    in
    match io_res with
    | LocalIo.Write { fd; size } ->
        let rid = Logs.get_rid fd sm.logs in
        let new_vv = VersionVector.update rid size sm.vv in
        { sm with vv = new_vv }
    | LocalIo.Recv msg -> { sm with req_buf = recv msg }
end
