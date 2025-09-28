type t = int

let of_int = Fun.id

let update new_offset old_offset =
  assert (new_offset > old_offset);
  new_offset
