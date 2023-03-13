open Libsrs

type curve = G1 | G2

let extract curve source input_file output_file =
  match curve with
  | G1 ->
      let g1_elements = Powers_of_tau.to_g1s input_file in
      let output_file =
        Option.value
          ~default:
            (Format.sprintf
               "srs_%s_g1_%i"
               source
               (Libsrs.exact_log2
                  (Bls12_381_polynomial.G1_carray.length g1_elements)))
          output_file
      in
      Srs.gs1_to_file g1_elements output_file
  | G2 ->
      let g2_elements = Powers_of_tau.to_g2s input_file in
      let output_file =
        Option.value
          ~default:
            (Format.sprintf
               "srs_%s_g2_%i"
               source
               (Libsrs.exact_log2
                  (Bls12_381_polynomial.G2_carray.length g2_elements)))
          output_file
      in
      Srs.gs2_to_file g2_elements output_file

let check g1s_input_file g2s_input_file =
  let bigstring_of_file filename =
    let fd = Unix.openfile filename [Unix.O_RDONLY] 0o440 in
    Bigarray.array1_of_genarray
    @@ Unix.map_file
         fd
         Bigarray.char
         Bigarray.c_layout
         false
         [|(* [-1] means read the whole file *) -1|]
  in
  let open Bls12_381_polynomial in
  let g1s =
    Srs.Srs_g1.of_bigstring (bigstring_of_file g1s_input_file) |> Result.get_ok
  in
  let g2s =
    Srs.Srs_g2.of_bigstring (bigstring_of_file g2s_input_file) |> Result.get_ok
  in
  Srs.check (g1s, g2s)

let extract_cmd =
  let open Cmdliner in
  let source =
    let doc = "Source of the powers of tau file: filecoin or zcash." in
    Arg.(
      required
      & pos 0 (some (enum [("zcash", "zcash"); ("filecoin", "filecoin")])) None
      & info [] ~docv:"source" ~doc)
  in
  let curve =
    let doc = "Which curve points to output: G1 or G2" in
    Arg.(
      required
      & pos
          1
          (some (enum [("g1", G1); ("G1", G1); ("g2", G2); ("G2", G2)]))
          None
      & info [] ~docv:"curve" ~doc)
  in
  let input_file =
    let doc = "Powers of tau file e.g. phase1radix2m5." in
    Arg.(required & pos 2 (some file) None & info [] ~docv:"input" ~doc)
  in
  let output_file =
    let doc = "Output file." in
    Arg.(
      value & opt (some string) None & info ["o"; "outdir"] ~docv:"output" ~doc)
  in
  let term = Term.(const extract $ curve $ source $ input_file $ output_file) in
  Cmd.(v (info "extract") term)

let check_cmd =
  let open Cmdliner in
  let g1s_input_file =
    let doc = "Srs file of G1." in
    Arg.(required & pos 0 (some file) None & info [] ~docv:"input" ~doc)
  in
  let g2s_input_file =
    let doc = "Srs file of G2." in
    Arg.(required & pos 1 (some file) None & info [] ~docv:"input" ~doc)
  in
  let term = Term.(const check $ g1s_input_file $ g2s_input_file) in
  Cmd.(v (info "check") term)

let _ =
  let open Cmdliner in
  let doc =
    "Extracts SRS for G1 and G2 from powers-of-tau generated by the ZCash and\n\
     Filecoin MPC ceremonies:\n\
     - https://download.z.cash/downloads/powersoftau (max 2^21)\n\
     - https://trusted-setup.filecoin.io/phase1 (max 2^27)\n\n\
     To truncate the result use:\n\
     head -c $(( 48 * nb_elements )) g1_input > g1_output\n\
     head -c $(( 96 * nb_elements )) g2_input > g2_output"
  in
  let info = Cmd.info "extract-srs" ~doc in
  let default = Term.(ret (const (`Help (`Pager, None)))) in
  exit @@ Cmd.eval @@ Cmd.group info ~default [extract_cmd; check_cmd]
