type aof = { rid : Wp.ReplicaID.t; fd : Local_io.FD.t; offset : int }

type t = {
  by_fd : Wp.ReplicaID.t Local_io.FD.Map.t;
  by_rid : Local_io.FD.t Wp.ReplicaID.Map.t;
  vv : Wp.VV.t;
  req_buf : Local_io.req list;
}

let empty =
  {
    by_fd = Local_io.FD.Map.empty;
    by_rid = Wp.ReplicaID.Map.empty;
    vv = Wp.VV.empty;
    req_buf = [];
  }

let add { rid; fd; offset } sm =
  {
    sm with
    vv = sm.vv |> Wp.VV.update rid offset;
    by_fd = sm.by_fd |> Local_io.FD.Map.add fd rid;
    by_rid = sm.by_rid |> Wp.ReplicaID.Map.add rid fd;
  }

let get_fd rid sm = Wp.ReplicaID.Map.find rid sm.by_rid
let get_rid fd sm = Local_io.FD.Map.find fd sm.by_fd
let io_reqs { req_buf; _ } = req_buf |> List.to_seq

let transition io_res sm =
  let recv = function
    | Wp.Append { rid; events } ->
        let fd = get_fd rid sm in
        [ Local_io.Append { fd; events } ]
    | Wp.ClientRead vv ->
        Wp.VV.to_seq vv
        |> Seq.map (fun (rid, offset) ->
               let fd = get_fd rid sm in
               Local_io.Read { fd; offset })
        |> List.of_seq
  in
  match io_res with
  | Local_io.Write { fd; size } ->
      let rid = get_rid fd sm in
      let new_vv = Wp.VV.update rid size sm.vv in
      { sm with vv = new_vv }
  | Local_io.Recv msg -> { sm with req_buf = recv msg }
