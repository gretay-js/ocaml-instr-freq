open Core

let main ~files ~output =
  Out_channel.with_file output ~f:(fun oc ->
      let print fmt = fprintf oc fmt in
      print "open Instr_freq\n";
      print "open Patterns\n";
      print "(* This file is automatically generated *)\n";
      print "let all = [\n";
      List.iter files ~f:(fun file ->
          let module_name =
            Filename.basename file |> Filename.chop_extension
          in
          if
            Filename.check_suffix module_name ".pp"
            (* Ignore pretty printed files *)
          then ()
          else
            Scanf.sscanf module_name "pattern_%s" (fun pattern_name ->
                print
                  "\t\"%s\", (module %s : \
                   Index.Matcher.Whole_block_predicate.S);\n"
                  pattern_name
                  (String.capitalize module_name)));
      print "]\n;;\n")
;;

let main_command =
  Command.basic ~summary:"Generate patterns file."
    ~readme:(fun () ->
      "To be used for automatic generation of patterns meta-file.")
    [%map_open.Command.Let_syntax
      let files =
        anon (sequence ("ml-files-with-patterns" %: Filename.arg_type))
      and output =
        flag "-o" (required Filename.arg_type) ~doc:"Output file"
      in
      fun () -> main ~files ~output]
;;

let () = Command.run main_command
