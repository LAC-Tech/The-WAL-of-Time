open Local_io
open Wp

type 'e t = {
  by_fd : ReplicaID.t FD.Map.t;
  by_rid : FD.t ReplicaID.Map.t;
  vv : VV.t;
  req_buf : 'e Local_io.req list;
}

let empty =
  {
    by_fd = FD.Map.empty;
    by_rid = ReplicaID.Map.empty;
    vv = VV.empty;
    req_buf = [];
  }

let create aofs =
  let add sm (rid, fd, offset) =
    {
      sm with
      vv = sm.vv |> VV.update rid offset;
      by_fd = sm.by_fd |> FD.Map.add fd rid;
      by_rid = sm.by_rid |> ReplicaID.Map.add rid fd;
    }
  in
  aofs |> Seq.fold_left add empty

let io_reqs { req_buf; _ } = req_buf |> List.to_seq

let transition io_res sm =
  let get_fd rid = ReplicaID.Map.find rid sm.by_rid in
  let get_rid fd = FD.Map.find fd sm.by_fd in
  let recv = function
    | Append { rid; events } -> [ Local_io.Append { fd = get_fd rid; events } ]
    | ClientRead vv ->
        let f (rid, offset) = Local_io.Read { fd = get_fd rid; offset } in
        vv |> VV.to_list |> List.map f
  in
  match io_res with
  | Write { fd; size } -> { sm with vv = VV.update (get_rid fd) size sm.vv }
  | Recv msg -> { sm with req_buf = recv msg }
