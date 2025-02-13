open Core
open Instr_freq

let start = Time.now ()

(* Credits to
   https://github.com/janestreet/jenga/blob/c10d05423320e0a8c113b9a09674d8bc69bfbc2c/bench/run.ml#L5*)
let eprintf_progress fmt =
  ksprintf
    (fun str ->
      let from_start = Time.diff (Time.now ()) start in
      let decimals =
        match Time.Span.to_unit_of_time from_start with
        | Nanosecond | Microsecond | Millisecond -> 0
        | Second -> 1
        | Minute | Hour | Day -> 2
      in
      Out_channel.printf "[%5s] %s%!"
        (Time.Span.to_string_hum from_start ~decimals)
        str)
    fmt
;;

let load_whole_block_predicate_by_name ~pattern_name =
  let m =
    List.Assoc.find_exn Import_patterns.all ~equal:String.equal pattern_name
  in
  let module Whole_block_predicate = ( val m
                                         : Index.Matcher
                                           .Whole_block_predicate
                                           .S )
  in
  Whole_block_predicate.f
;;

let build_index files ~(index_file : Filename.t) ~context_length =
  let total_number_of_files = List.length files in
  printf "Building the index...\n%!";
  let index = Index.empty () in
  let functions_per_file = ref [] in
  let blocks_per_function = ref [] in
  let instructions_per_block = ref [] in
  List.iteri files ~f:(fun ifile file ->
      if ifile % 5000 = 0 then Gc.compact ();
      let functions = Loop_free_block.read_file ~file ~context_length in
      functions_per_file := List.length functions :: !functions_per_file;

      List.iter functions ~f:(fun (_fun_decl, blocks) ->
          blocks_per_function := Array.length blocks :: !blocks_per_function;
          Array.iter blocks ~f:(fun block ->
              Index.update ~source_file:file index block;
              instructions_per_block :=
                (Loop_free_block.to_list block |> List.length)
                :: !instructions_per_block));
      let { Index.n_symbolic_blocks;
            n_basic_instructions;
            n_terminator_instructions
          } =
        Index.hashtbl_load_statistics index
      in
      eprintf_progress
        "Processing file %d/%d; Index load: Symbolic_blocks: %d; \
         Instructions: (basic: %d) (terminator: %d) \r"
        ifile total_number_of_files n_symbolic_blocks n_basic_instructions
        n_terminator_instructions);
  let () = Index.to_file index ~filename:index_file in
  let sum nums = List.sum (module Int) nums ~f:Fn.id in
  let mean nums =
    Float.of_int (sum nums) /. Float.of_int (List.length nums)
  in
  let max nums =
    List.max_elt nums ~compare:Int.compare |> Option.value_exn
  in
  let blocks = !blocks_per_function in
  let functions = !functions_per_file in
  let instructions = !instructions_per_block in
  printf "\nSaved index to %s\n%!" index_file;

  Out_channel.with_file (index_file ^ ".log") ~f:(fun f ->
      fprintf f "Processed:\n";
      fprintf f "\tfiles: %d\n" (List.length files);
      fprintf f "\tfunctions: total %d; mean/file %f; max/file %d \n"
        (sum functions) (mean functions) (max functions);
      fprintf f "\tblocks: total %d; mean/function %f; max/function %d \n"
        (sum blocks) (mean blocks) (max blocks);
      fprintf f "\tinstructions: total %d; mean/block %f; max/block %d\n"
        (sum instructions) (mean instructions) (max instructions);
      let index_stats = Index.hashtbl_load_statistics index in
      fprintf f
        "Index statistics: Symbolic_blocks: %d; Basic_instructions: %d; \
         Terminator instructions: %d\n"
        index_stats.n_symbolic_blocks index_stats.n_basic_instructions
        index_stats.n_terminator_instructions);
  index
;;

let main
    files
    ~index_file
    ~n_real_blocks_to_print
    ~n_most_frequent_equivalences
    ~block_print_mode
    ~min_block_size
    ~matcher_of_index
    ~context_length =
  let index =
    if Sys.file_exists_exn index_file then (
      printf "Loading cached index from %s... %!" index_file;
      let index = Index.of_file ~filename:index_file in
      printf "loaded!\n%!";
      index )
    else build_index files ~index_file ~context_length
  in
  let matcher = Option.map matcher_of_index ~f:(fun f -> f ~index) in
  (* XCR gyorsh for : this is a nice way to add different patterns; consider
     separating it out a bit more and explosing a type for functions that
     return a pair of on_block and on_finish_iterations. What are the
     restrictions? e.g., does order they are listed in matter / do they have
     to preserve index? *)
  let { Stats.on_block; on_finish_iteration; hint_files } =
    let statistics = ref [] in
    let add_stat stat = statistics := stat :: !statistics in
    add_stat (Stats.count_blocks_matching index ~min_block_size ~matcher);

    if n_real_blocks_to_print > 0 then
      add_stat
        (Stats.print_most_popular_classes index ~n_real_blocks_to_print
           ~n_most_frequent_equivalences ~block_print_mode ~min_block_size
           ~matcher);

    Stats.combine !statistics
  in
  let files = String.Set.diff (String.Set.of_list files) hint_files in
  let on_file file =
    List.iter (Loop_free_block.read_file ~file ~context_length)
      ~f:(fun (fundecl, blocks) ->
        Array.iter blocks ~f:(fun block ->
            let equivalence = Index.equivalence_exn index block in
            let frequency = Index.frequency_exn index equivalence in
            match on_block block ~file ~equivalence ~frequency ~fundecl with
            | `Continue -> ()
            | `Stop -> raise Utils.Stop_iteration))
  in
  ( try
      Set.iter hint_files ~f:on_file;
      Set.iter files ~f:on_file
    with Utils.Stop_iteration -> () );
  on_finish_iteration ()
;;

let block_print_mode_arg =
  Command.Arg_type.create (fun mode ->
      match String.lowercase mode with
      | "asm" -> Loop_free_block.As_assembly
      | "cfg" -> Loop_free_block.As_cfg
      | "both" -> Loop_free_block.Both
      | _ -> failwithf "Invalid block_print_mode argument: %s" mode ())
;;

let main_command =
  Command.basic ~summary:"Count frequency of basic blocks."
    ~readme:(fun () ->
      "Group contents of basic blocks based on equivalence classes, and \
       print the most common classes.")
    [%map_open.Command.Let_syntax
      let anon_files = anon (sequence ("input" %: Filename.arg_type))
      and n_real_blocks_to_print =
        flag "-print-n-real-blocks"
          (optional_with_default 1 int)
          ~doc:
            "n Print [n] actual blocks from the codebase for each \
             equivalence class. For n=1, the index caches which files to \
             look at, so the program should be very quick. For n >= 2, we \
             have to look through all given files, and it might take a lot \
             longer."
      and n_most_frequent_equivalences =
        flag "-n-most-frequent-equivalences"
          (optional_with_default 10 int)
          ~doc:"n Print most frequent equivalence classes. Defaults to 10."
      and block_print_mode =
        flag "-block-print-mode"
          (optional_with_default Loop_free_block.Both block_print_mode_arg)
          ~doc:
            "repr Which representatin to print blocks in. Must be one of \
             [asm | cfg | both]"
      and min_block_size =
        flag "-min-block-size"
          (optional_with_default 5 int)
          ~doc:
            "n Only report equivalence classes, for which the \
             representative block has at least [n] instructions (including \
             the terminator). Defaults to 5."
      and index_file =
        flag "-index-file"
          (required Filename.arg_type)
          ~doc:
            "filepath Location of index file. Will be built if it does not \
             exist. If it exists, it is reused across multiple runs."
      and from_file =
        flag "-from-file"
          (optional Filename.arg_type)
          ~doc:
            "list-file Treat each line of [list-file] as a file to process."
      and subsequence_matcher =
        flag "-use-subsequence-matcher"
          (optional Filename.arg_type)
          ~doc:
            "sexp_matcher_file Print only symbolic blocks which match the \
             given subsequence matcher."
      and whole_block_matcher =
        flag "-use-whole-block-matcher"
          (optional Filename.arg_type)
          ~doc:
            "patterns_name Print only symbolic blocks which match the \
             given whole-block matcher. The given argument should be the \
             name of a pattern, with a matching file \
             patterns/pattern_${patterns_name}"
      and context_length =
        flag "-context-length"
          (optional_with_default 0 int)
          ~doc:
            "context How much context to include when building the index. \
             From the CFG graph,we will take chains of length [context] \
             and treat them as single blocks.This options permits us to \
             look at more instructions and gain better insight, however \
             the worst-case running time is exponential in this \
             parameter.If you change this option, then you *must* rebuild \
             the index. Defaults to 0."
      in
      let matcher_of_index =
        match (subsequence_matcher, whole_block_matcher) with
        | None, None -> None
        | Some _, Some _ ->
            failwith
              "Please specify at most one of-use-subsequence-matcher and \
               -use-whole-block-matcher!"
        | Some sexp_matcher_file, None ->
            printf "Loading matcher from %s\n%!" sexp_matcher_file;
            let instructions =
              Sexp.load_sexps_conv_exn sexp_matcher_file
                [%of_sexp:
                  Index.Matcher.desc Index.With_register_information.t]
              |> Array.of_list
            in
            Index.Matcher.create_for_subsequence ~instructions |> Some
        | None, Some pattern_name ->
            Index.Matcher.create_for_whole_block
              ~f:(load_whole_block_predicate_by_name ~pattern_name)
            |> Some
      in
      let files =
        anon_files
        @
        match from_file with
        | None -> []
        | Some file -> In_channel.read_lines file
      in
      fun () ->
        main files ~index_file ~n_real_blocks_to_print
          ~n_most_frequent_equivalences ~block_print_mode ~min_block_size
          ~matcher_of_index ~context_length]
;;

let () = Command.run main_command
