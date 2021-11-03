(* This file is part of Bisect_ppx, released under the MIT license. See
   LICENSE.md for details, or visit
   https://github.com/aantron/bisect_ppx/blob/master/LICENSE.md. *)



(* Searching for .coverage files. *)

(* Recursively finds all files in [directory] that match [filename_filter]. *)
let list_recursively filename_filter directory =
  let rec list_recursively directory file_accumulator =
    Sys.readdir directory
    |> Array.fold_left begin fun file_accumulator entry ->
      let entry_path = Filename.concat directory entry in
      match Sys.is_directory entry_path with
      | true ->
        list_recursively entry_path file_accumulator
      | false ->
        if filename_filter entry then
          entry_path::file_accumulator
        else
          file_accumulator
      | exception Sys_error _ ->
        file_accumulator
    end
      file_accumulator
  in
  list_recursively directory []

(* Non-recursively lists all files in [directory] that match
   [filename_filter]. This is used when searching the current directory, assumed
   to be the project root, for [.coverage] files. It is better not to search
   recursively in this case, to avoid listing [_opam] or [node_modules]. *)
let list_non_recursively filename_filter directory =
  Sys.readdir directory
  |> Array.to_list
  |> List.filter filename_filter

let is_coverage_file filename =
  Filename.check_suffix filename ".coverage"

let list_coverage_files files_on_command_line coverage_search_paths =
  (* If there are files on the command line, or coverage search directories
     specified, use those. Otherwise, search for files in ./, ./_build, and/or
     the esy sandbox. During the search, we look for files with extension
     .coverage. *)
  let individual_files, coverage_search_paths =
    match files_on_command_line, coverage_search_paths with
    | [], [] ->
      let files =
        list_non_recursively is_coverage_file Filename.current_dir_name in
      let paths =
        match Sys.getenv "cur__target_dir" with
        | exception Not_found -> ["_build"]
        | directory -> [directory; "_build"]
      in
      files, paths

    | _ ->
      files_on_command_line, coverage_search_paths
  in

  let all_coverage_files =
    coverage_search_paths
    |> List.filter Sys.file_exists
    |> List.filter Sys.is_directory
    |> List.map (fun directory -> list_recursively is_coverage_file directory)
    |> List.flatten
    |> (@) individual_files
  in

  (* Display feedback about where coverage files were found. *)
  begin
    match files_on_command_line, coverage_search_paths with
  | [], [] | _, _::_ ->
    all_coverage_files
    |> List.map Filename.dirname
    |> List.sort_uniq String.compare
    |> List.map (fun directory -> directory ^ Filename.dir_sep)
    |> List.iter (Util.info "found coverage files in '%s'")
  | _ ->
    ()
  end;

  if all_coverage_files = [] then
    Util.error "no coverage files given on command line or found"
  else
    all_coverage_files



(* Sanity checking with --expect and --do-not-expect. *)

let strip_extensions filename =
  let dirname, basename = Filename.(dirname filename, basename filename) in
  let basename =
    (* Use [String.index] rather than [String.rindex] in case some of the files
       have extensions like .pp.ml. *)
    match String.index basename '.' with
    | index -> String.sub basename 0 index
    | exception Not_found -> basename
  in
  Filename.concat dirname basename

let is_source_file filename =
  List.exists (fun extension -> Filename.check_suffix filename extension)
    [".ml"; ".re"; ".mll"; ".mly"]

let list_expected_files paths =
  paths
  |> List.map (fun path ->
    if Filename.(check_suffix path dir_sep) then
      list_recursively is_source_file path
    else
      [path])
  |> List.flatten
  |> List.sort_uniq String.compare

let filtered_expected_files expect do_not_expect =
  let expected_files = list_expected_files expect in
  let excluded_files = list_expected_files do_not_expect in
  expected_files
  |> List.filter (fun path -> not (List.mem path excluded_files))
  (* Not the fastest way to subtract the files. *)

let assert_expected_sources_are_present present_files expect do_not_expect =
  let present_files = List.map strip_extensions present_files in
  filtered_expected_files expect do_not_expect
  |> List.iter (fun file ->
    if not (List.mem (strip_extensions file) present_files) then
      Util.error "expected file '%s' is not included in the report" file)



(* Reading a single .coverage file. *)

(* ReScript emits ASTs with absolute paths to source files, and these absolute
   paths end up in [.coverage] files. Try to convert absolute paths to relative
   paths by stripping off a prefix that matches the current directory. *)
let get_relative_path file =
  if Filename.is_relative file then
    file
  else
    let cwd = Sys.getcwd () in
    let cwd_end = String.length cwd in
    let sep_length = String.length Filename.dir_sep in
    let sep_end = sep_length + cwd_end in
    try
      if String.sub file 0 cwd_end = cwd &&
          String.sub file cwd_end sep_length = Filename.dir_sep then
        String.sub file sep_end (String.length file - sep_end)
      else
        file
    with Invalid_argument _ ->
      file

(* filename + reason *)
exception Invalid_file of string * string

let junk channel =
  try ignore (input_char channel)
  with End_of_file -> ()

let read_int buffer channel =
  Buffer.clear buffer;
  let rec loop () =
    match input_char channel with
    | exception End_of_file -> ()
    | ' ' -> ()
    | c -> Buffer.add_char buffer c; loop ()
  in
  loop ();
  int_of_string (Buffer.contents buffer)

let read_string buffer channel =
  let length = read_int buffer channel in
  let string = really_input_string channel length in
  junk channel;
  string

let read_array read_element buffer channel =
  let length = read_int buffer channel in
  Array.init length (fun _index -> read_element buffer channel)

let read_list read_element buffer channel =
  read_array read_element buffer channel |> Array.to_list

let read_instrumented_file buffer channel =
  let filename = read_string buffer channel |> get_relative_path in
  let points = read_list read_int buffer channel in
  let counts = read_array read_int buffer channel in
  Bisect_common.{filename; points; counts}

let read_coverage buffer channel =
  read_list read_instrumented_file buffer channel

let read ~filename =
  let channel = open_in_bin filename in
  try
    let magic_number_in_file =
      try
        really_input_string
          channel (String.length Bisect_common.coverage_file_identifier)
      with End_of_file ->
        raise
          (Invalid_file
            (filename, "unexpected end of file while reading magic number"))
    in
    if magic_number_in_file <> Bisect_common.coverage_file_identifier then
      raise (Invalid_file (filename, "bad magic number"));

    junk channel;

    let buffer = Buffer.create 4096 in
    let result =
      try read_coverage buffer channel
      with e ->
        raise
          (Invalid_file
            (filename, "exception reading data: " ^ Printexc.to_string e));
    in
    close_in_noerr channel;
    result

  with exn ->
    close_in_noerr channel;
    raise exn



(* Finding all the .coverage files, reading them, and accumulating visit
   counts. *)

let saturating_add x y =
  if ((x > 0) && (y > 0) && (x > max_int - y)) then
    max_int
  else if ((x < 0) && (y < 0) && (x < min_int - y)) then
    min_int
  else
    x + y

let elementwise_saturating_add xs ys =
  let longer, shorter =
    if Array.length xs >= Array.length ys then
      xs, ys
    else
      ys, xs
  in
  let result = Array.copy longer in
  shorter |> Array.iteri (fun index v ->
    result.(index) <- saturating_add v result.(index));
  result

(* Iterate over all the [.coverage] files specified on the command line or
   found. Load each one. Then iterate over all the source files for which
   coverage data is found. Accumulate visit counts when the same source file is
   mentioned in multiple [.coverage] files. Store one copy of the point offset
   data for each source file. *)
let load_coverage ~coverage_files ~coverage_paths ~expect ~do_not_expect =
  let points, counts =
    let all_points = Hashtbl.create 17 in
    let total_counts = Hashtbl.create 17 in

    list_coverage_files coverage_files coverage_paths
    |> List.iter begin fun filename ->
      let coverage_per_source_file = read ~filename in
      coverage_per_source_file
      |> List.iter begin fun Bisect_common.{filename; points; counts} ->
        let counts =
          match Hashtbl.find total_counts filename with
          | counts_so_far -> elementwise_saturating_add counts counts_so_far
          | exception Not_found -> counts
        in
        Hashtbl.replace all_points filename points;
        Hashtbl.replace total_counts filename counts
      end
    end;

    all_points, total_counts
  in

  (* Check that all source files specified with [--expect] are present in the
     resulting accumulated data. *)
  let present_files =
    Hashtbl.fold (fun filename _ acc -> filename::acc) counts [] in
  assert_expected_sources_are_present present_files expect do_not_expect;

  points, counts