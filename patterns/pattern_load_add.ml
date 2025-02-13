open Instr_freq
open! Core

let f ~(block : Index.Matcher.Whole_block_predicate.block) =
  Lib.single_use_lookahead ~block ~lookahead_length:2 ~f:(function
    | [ { Index.With_register_information.desc =
            Index.Matcher.Basic (Op (Load _));
          arg = [| _ |];
          res = [| load_destination |]
        };
        { Index.With_register_information.desc =
            Index.Matcher.Basic (Op (Intop _));
          arg = [| intop_input1; intop_input2 |];
          res = [| intop_output |]
        }
      ]
      when load_destination = intop_input2 && intop_input1 = intop_output ->
        true
    | _ -> false)
;;
