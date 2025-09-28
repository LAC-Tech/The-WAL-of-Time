open Local_io
open Wp

type local = { rid : ReplicaID.t; fd : FD.t }
type remotes = { by_fd : ReplicaID.t FD.Map.t; by_rid : FD.t ReplicaID.Map.t }

type 'e t = {
  local : local;
  remotes : remotes;
  vv : VV.t;
  req_buf : 'e Local_io.req list;
}

type log = { rid : ReplicaID.t; fd : FD.t; count : Counter.t }

let create (local : log) =
  let add sm { rid; fd; count } =
    {
      sm with
      vv = sm.vv |> VV.update rid count;
      remotes =
        {
          by_fd = sm.remotes.by_fd |> FD.Map.add fd rid;
          by_rid = sm.remotes.by_rid |> ReplicaID.Map.add rid fd;
        };
    }
  in

  let empty =
    {
      local = { rid = local.rid; fd = local.fd };
      remotes = { by_fd = FD.Map.empty; by_rid = ReplicaID.Map.empty };
      vv = VV.create local.rid local.count;
      req_buf = [];
    }
  in
  Seq.fold_left add empty

let io_reqs sm = List.to_seq sm.req_buf

let transition io_res sm =
  let get_fd rid = ReplicaID.Map.find rid sm.remotes.by_rid in
  let get_rid fd = FD.Map.find fd sm.remotes.by_fd in
  let recv = function
    | Append { rid; events } -> [ Local_io.Append { fd = get_fd rid; events } ]
    | ClientRead vv ->
        let f (rid, count) = Local_io.Read { fd = get_fd rid; count } in
        vv |> VV.to_list |> List.map f
  in
  match io_res with
  | Write { fd; count } -> { sm with vv = VV.update (get_rid fd) count sm.vv }
  | Recv msg -> { sm with req_buf = recv msg }
