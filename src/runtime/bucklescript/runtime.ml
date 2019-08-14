(* This file is part of Bisect_ppx, released under the MIT license. See
   LICENSE.md for details, or visit
   https://github.com/aantron/bisect_ppx/blob/master/LICENSE.md. *)



let register_file =
  Bisect_common.register_file

let get_coverage_data =
  Bisect_common.runtime_data_to_string