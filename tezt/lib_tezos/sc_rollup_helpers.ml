(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2023 Nomadic Labs <contact@nomadic-labs.com>                *)
(* Copyright (c) 2022-2023 TriliTech <contact@trili.tech>                    *)
(* Copyright (c) 2023 Marigold <contact@marigold.dev>                        *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

(** Helpers built upon the Sc_rollup_node and Sc_rollup_client *)

(*
  SC tests may contain arbitrary/generated bytes in external messages,
  and captured deposits/withdrawals contain byte sequences that change
  for both proofs and contract addresses.
 *)
let replace_variables string =
  string
  |> replace_string ~all:true (rex "0x01\\w{40}00") ~by:"[MICHELINE_KT1_BYTES]"
  |> replace_string ~all:true (rex "0x.*") ~by:"[SMART_ROLLUP_BYTES]"
  |> replace_string
       ~all:true
       (rex "hex\\:\\[\".*?\"\\]")
       ~by:"[SMART_ROLLUP_EXTERNAL_MESSAGES]"
  |> Tezos_regression.replace_variables

let hooks = Tezos_regression.hooks_custom ~replace_variables ()

let hex_encode (input : string) : string =
  match Hex.of_string input with `Hex s -> s

let load_kernel_file
    ?(base = "src/proto_alpha/lib_protocol/test/integration/wasm_kernel") name :
    string =
  let open Tezt.Base in
  let kernel_file = project_root // base // name in
  read_file kernel_file

(* [read_kernel filename] reads binary encoded WebAssembly module (e.g. `foo.wasm`)
   and returns a hex-encoded Wasm PVM boot sector, suitable for passing to
   [originate_sc_rollup].
*)
let read_kernel ?base name : string =
  hex_encode (load_kernel_file ?base (name ^ ".wasm"))

module Installer_kernel_config = struct
  type move_args = {from : string; to_ : string}

  type reveal_args = {hash : string; to_ : string}

  type set_args = {value : string; to_ : string}

  type instr = Move of move_args | Reveal of reveal_args | Set of set_args

  type t = instr list

  let instr_to_yaml = function
    | Move {from; to_} -> sf {|  - move:
      from: %s
      to: %s
|} from to_
    | Reveal {hash; to_} -> sf {|  - reveal: %s
    to: %s
|} hash to_
    | Set {value; to_} ->
        sf {|  - set:
      value: %s
      to: %s
|} value to_

  let to_yaml t =
    "instructions:\n" ^ String.concat "" (List.map instr_to_yaml t)

  let check_dump ~config dump =
    let dump = Base.read_file dump in
    let check kind value destination =
      let regexp =
        Format.asprintf "- set:\n    %s: %s\n    to: %s" kind value destination
      in
      let error_msg =
        Format.asprintf
          "key-value pair not found in dump (%s: %s, to: %s)"
          kind
          value
          destination
      in
      Check.is_true ~error_msg Base.(dump =~ rex regexp)
    in
    (* Check that the config is included in the dump (the PVM did not alter
       the key-value pairs defined in the config) *)
    List.iter
      (function
        | Move {from; to_} -> check "from" from to_
        | Reveal {hash; to_} -> check "hash" hash to_
        | Set {value; to_} -> check "value" value to_)
      config
end

(* Testing the installation of a larger kernel, with e2e messages.

   When a kernel is too large to be originated directly, we can install
   it by using the 'reveal_installer' kernel. This leverages the reveal
   preimage+DAC mechanism to install the tx kernel.
*)
let prepare_installer_kernel_gen ?runner
    ?(base_installee =
      "src/proto_alpha/lib_protocol/test/integration/wasm_kernel")
    ~preimages_dir ?(display_root_hash = false) ?config installee =
  let open Tezt.Base in
  let open Lwt.Syntax in
  let installer = installee ^ "-installer.hex" in
  let output = Temp.file installer in
  let installee = (project_root // base_installee // installee) ^ ".wasm" in
  let setup_file_args =
    match config with
    | Some config ->
        let setup_file =
          match config with
          | `Config config ->
              let setup_file = Temp.file "setup-config.yaml" in
              Base.write_file
                setup_file
                ~contents:(Installer_kernel_config.to_yaml config) ;
              setup_file
          | `Path path -> path
          | `Both (config, path) ->
              let setup_file = Temp.file "setup-config.yaml" in
              let base_config = Base.read_file path in
              let new_contents =
                String.concat
                  ""
                  (List.map Installer_kernel_config.instr_to_yaml config)
              in
              Base.write_file setup_file ~contents:(base_config ^ new_contents) ;
              setup_file
        in
        ["--setup-file"; setup_file]
    | None -> []
  in
  let display_root_hash_arg =
    if display_root_hash then ["--display-root-hash"] else []
  in
  let process =
    Process.spawn
      ?runner
      ~name:installer
      (project_root // "smart-rollup-installer")
      ([
         "get-reveal-installer";
         "--upgrade-to";
         installee;
         "--output";
         output;
         "--preimages-dir";
         preimages_dir;
       ]
      @ display_root_hash_arg @ setup_file_args)
  in
  let+ installer_output =
    Runnable.run
    @@ Runnable.{value = process; run = Process.check_and_read_stdout}
  in
  let root_hash =
    if display_root_hash then installer_output =~* rex "ROOT_HASH: ?(\\w*)"
    else None
  in
  (read_file output, root_hash)

let prepare_installer_kernel ?runner ?base_installee ~preimages_dir ?config
    installee =
  let open Lwt.Syntax in
  let+ output, _ =
    prepare_installer_kernel_gen
      ?runner
      ?base_installee
      ~preimages_dir
      ?config
      installee
  in
  output

let default_boot_sector_of ~kind =
  match kind with
  | "arith" -> ""
  | "wasm_2_0_0" -> Constant.wasm_echo_kernel_boot_sector
  | kind -> raise (Invalid_argument kind)

let make_parameter name = function
  | None -> []
  | Some value -> [([name], `Int value)]

let make_bool_parameter name = function
  | None -> []
  | Some value -> [([name], `Bool value)]

let setup_l1 ?bootstrap_smart_rollups ?bootstrap_contracts ?commitment_period
    ?challenge_window ?timeout ?whitelist_enable protocol =
  let parameters =
    make_parameter "smart_rollup_commitment_period_in_blocks" commitment_period
    @ make_parameter "smart_rollup_challenge_window_in_blocks" challenge_window
    @ make_parameter "smart_rollup_timeout_period_in_blocks" timeout
    @ (if Protocol.number protocol >= 19 then
       make_bool_parameter "smart_rollup_private_enable" whitelist_enable
      else [])
    @ [(["smart_rollup_arith_pvm_enable"], `Bool true)]
  in
  let base = Either.right (protocol, None) in
  let* parameter_file =
    Protocol.write_parameter_file
      ?bootstrap_smart_rollups
      ?bootstrap_contracts
      ~base
      parameters
  in
  let nodes_args =
    Node.[Synchronisation_threshold 0; History_mode Archive; No_bootstrap_peers]
  in
  Client.init_with_protocol ~parameter_file `Client ~protocol ~nodes_args ()

(** This helper injects an SC rollup origination via octez-client. Then it
    bakes to include the origination in a block. It returns the address of the
    originated rollup *)
let originate_sc_rollup ?hooks ?(burn_cap = Tez.(of_int 9999999)) ?whitelist
    ?(alias = "rollup") ?(src = Constant.bootstrap1.alias) ~kind
    ?(parameters_ty = "string") ?(boot_sector = default_boot_sector_of ~kind)
    client =
  let* sc_rollup =
    Client.Sc_rollup.(
      originate
        ?hooks
        ~burn_cap
        ?whitelist
        ~alias
        ~src
        ~kind
        ~parameters_ty
        ~boot_sector
        client)
  in
  let* () = Client.bake_for_and_wait client in
  return sc_rollup

(* Configuration of a rollup node
   ------------------------------

   A rollup node has a configuration file that must be initialized.
*)
let setup_rollup ~protocol ~kind ?hooks ?alias ?(mode = Sc_rollup_node.Operator)
    ?boot_sector ?(parameters_ty = "string")
    ?(operator = Constant.bootstrap1.alias) ?data_dir ?rollup_node_name
    ?whitelist tezos_node tezos_client =
  let* sc_rollup =
    originate_sc_rollup
      ?hooks
      ~kind
      ?boot_sector
      ~parameters_ty
      ?alias
      ?whitelist
      ~src:operator
      tezos_client
  in
  let sc_rollup_node =
    Sc_rollup_node.create
      mode
      tezos_node
      ?data_dir
      ~base_dir:(Client.base_dir tezos_client)
      ~default_operator:operator
      ?name:rollup_node_name
  in
  let rollup_client = Sc_rollup_client.create ~protocol sc_rollup_node in
  return (sc_rollup_node, rollup_client, sc_rollup)

let originate_forward_smart_contract ?(src = Constant.bootstrap1.alias) client
    protocol =
  (* Originate forwarder contract to send internal messages to rollup *)
  let* alias, contract_id =
    Client.originate_contract_at
      ~amount:Tez.zero
      ~src
      ~init:"Unit"
      ~burn_cap:Tez.(of_int 1)
      client
      ["mini_scenarios"; "sc_rollup_forward"]
      protocol
  in
  let* () = Client.bake_for_and_wait client in
  Log.info
    "The forwarder %s (%s) contract was successfully originated"
    alias
    contract_id ;
  return contract_id

let last_cemented_commitment_hash_with_level ~sc_rollup client =
  let* json =
    Client.RPC.call client
    @@ RPC
       .get_chain_block_context_smart_rollups_smart_rollup_last_cemented_commitment_hash_with_level
         sc_rollup
  in
  let hash = JSON.(json |-> "hash" |> as_string) in
  let level = JSON.(json |-> "level" |> as_int) in
  return (hash, level)

let genesis_commitment ~sc_rollup tezos_client =
  let* genesis_info =
    Client.RPC.call ~hooks tezos_client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_genesis_info
         sc_rollup
  in
  let genesis_commitment_hash =
    JSON.(genesis_info |-> "commitment_hash" |> as_string)
  in
  let* json =
    Client.RPC.call ~hooks tezos_client
    @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_commitment
         ~sc_rollup
         ~hash:genesis_commitment_hash
         ()
  in
  match Sc_rollup_client.commitment_from_json json with
  | None -> failwith "genesis commitment have been removed"
  | Some commitment -> return commitment

let call_rpc ~smart_rollup_node ~service =
  let open Runnable.Syntax in
  let url =
    Printf.sprintf "%s/%s" (Sc_rollup_node.endpoint smart_rollup_node) service
  in
  let*! response = Curl.get url in
  return response

type bootstrap_smart_rollup_setup = {
  bootstrap_smart_rollup : Protocol.bootstrap_smart_rollup;
  smart_rollup_node_data_dir : string;
  smart_rollup_node_extra_args : string list;
}

let setup_bootstrap_smart_rollup ?(name = "smart-rollup") ~address
    ?(parameters_ty = "string") ?whitelist ?base_installee ~installee ?config ()
    =
  (* Create a temporary directory to store the preimages. *)
  let smart_rollup_node_data_dir = Temp.dir (name ^ "-data-dir") in

  (* Create the installer boot sector. *)
  let* boot_sector =
    prepare_installer_kernel
      ?base_installee
      ~preimages_dir:(Filename.concat smart_rollup_node_data_dir "wasm_2_0_0")
      ?config
      installee
  in

  (* Create a temporary file with the boot sector, which needs to
     be given to the smart rollup node when the rollup is a bootstrap
     smart rollup. *)
  let boot_sector_file = Filename.temp_file "boot-sector" ".hex" in
  let () = write_file boot_sector_file ~contents:boot_sector in

  (* Convert the parameters ty to a JSON representation. *)
  let* parameters_ty =
    let client = Client.create_with_mode Client.Mockup in
    Client.convert_data_to_json ~data:parameters_ty client
  in

  let bootstrap_smart_rollup : Protocol.bootstrap_smart_rollup =
    {address; pvm_kind = "wasm_2_0_0"; boot_sector; parameters_ty; whitelist}
  in

  return
    {
      bootstrap_smart_rollup;
      smart_rollup_node_data_dir;
      smart_rollup_node_extra_args = ["--boot-sector-file"; boot_sector_file];
    }

(* Refutation game scenarios
   -------------------------
*)

type refutation_scenario_parameters = {
  loser_modes : string list;
  inputs : string list list;
  final_level : int;
  empty_levels : int list;
  stop_loser_at : int list;
  reset_honest_on : (string * int * Sc_rollup_node.mode option) list;
  bad_reveal_at : int list;
  priority : [`Priority_honest | `Priority_loser | `No_priority];
  allow_degraded : bool;
}

let refutation_scenario_parameters ?(loser_modes = []) ~final_level
    ?(empty_levels = []) ?(stop_loser_at = []) ?(reset_honest_on = [])
    ?(bad_reveal_at = []) ?(priority = `No_priority) ?(allow_degraded = false)
    inputs =
  {
    loser_modes;
    inputs;
    final_level;
    empty_levels;
    stop_loser_at;
    reset_honest_on;
    bad_reveal_at;
    priority;
    allow_degraded;
  }

type test = {variant : string option; tags : string list; description : string}

let format_title_scenario kind {variant; tags = _; description} =
  Printf.sprintf
    "%s - %s%s"
    kind
    description
    (match variant with Some variant -> " (" ^ variant ^ ")" | None -> "")

(* Pushing message in the inbox
   ----------------------------

   A message can be pushed to a smart-contract rollup inbox through
   the Tezos node. Then we can observe that the messages are included in the
   inbox.
*)
let send_message_client ?hooks ?(src = Constant.bootstrap2.alias) client msg =
  let* () = Client.Sc_rollup.send_message ?hooks ~src ~msg client in
  Client.bake_for_and_wait client

let send_messages_client ?hooks ?src ?batch_size n client =
  let messages =
    List.map
      (fun i ->
        let batch_size = match batch_size with None -> i | Some v -> v in
        let json =
          `A (List.map (fun _ -> `String "CAFEBABE") (range 1 batch_size))
        in
        "text:" ^ Ezjsonm.to_string json)
      (range 1 n)
  in
  Lwt_list.iter_s
    (fun msg -> send_message_client ?hooks ?src client msg)
    messages

let send_message = send_message_client

let send_messages = send_messages_client

type sc_rollup_constants = {
  origination_size : int;
  challenge_window_in_blocks : int;
  stake_amount : Tez.t;
  commitment_period_in_blocks : int;
  max_lookahead_in_blocks : int32;
  max_active_outbox_levels : int32;
  max_outbox_messages_per_level : int;
  number_of_sections_in_dissection : int;
  timeout_period_in_blocks : int;
}

let get_sc_rollup_constants client =
  let* json =
    Client.RPC.call client @@ RPC.get_chain_block_context_constants ()
  in
  let open JSON in
  let origination_size = json |-> "smart_rollup_origination_size" |> as_int in
  let challenge_window_in_blocks =
    json |-> "smart_rollup_challenge_window_in_blocks" |> as_int
  in
  let stake_amount =
    json |-> "smart_rollup_stake_amount" |> as_string |> Int64.of_string
    |> Tez.of_mutez_int64
  in
  let commitment_period_in_blocks =
    json |-> "smart_rollup_commitment_period_in_blocks" |> as_int
  in
  let max_lookahead_in_blocks =
    json |-> "smart_rollup_max_lookahead_in_blocks" |> as_int32
  in
  let max_active_outbox_levels =
    json |-> "smart_rollup_max_active_outbox_levels" |> as_int32
  in
  let max_outbox_messages_per_level =
    json |-> "smart_rollup_max_outbox_messages_per_level" |> as_int
  in
  let number_of_sections_in_dissection =
    json |-> "smart_rollup_number_of_sections_in_dissection" |> as_int
  in
  let timeout_period_in_blocks =
    json |-> "smart_rollup_timeout_period_in_blocks" |> as_int
  in
  return
    {
      origination_size;
      challenge_window_in_blocks;
      stake_amount;
      commitment_period_in_blocks;
      max_lookahead_in_blocks;
      max_active_outbox_levels;
      max_outbox_messages_per_level;
      number_of_sections_in_dissection;
      timeout_period_in_blocks;
    }

let forged_commitment ?(compressed_state = Constant.sc_rollup_compressed_state)
    ?(number_of_ticks = 1) ~inbox_level ~predecessor () :
    Sc_rollup_client.commitment =
  {compressed_state; inbox_level; predecessor; number_of_ticks}

let publish_commitment ?(src = Constant.bootstrap1.public_key_hash) ~commitment
    client sc_rollup =
  let ({compressed_state; inbox_level; predecessor; number_of_ticks}
        : Sc_rollup_client.commitment) =
    commitment
  in
  Client.Sc_rollup.publish_commitment
    ~hooks
    ~src
    ~sc_rollup
    ~compressed_state
    ~inbox_level
    ~predecessor
    ~number_of_ticks
    client

let forge_and_publish_commitment_return_runnable ?compressed_state
    ?number_of_ticks ~inbox_level ~predecessor ~sc_rollup ~src client =
  let commitment =
    forged_commitment
      ?compressed_state
      ?number_of_ticks
      ~inbox_level
      ~predecessor
      ()
  in
  (commitment, publish_commitment ~src ~commitment client sc_rollup)

let get_staked_on_commitment ~sc_rollup ~staker client =
  let* json =
    Client.RPC.call client
    @@ RPC
       .get_chain_block_context_smart_rollups_smart_rollup_staker_staked_on_commitment
         ~sc_rollup
         staker
  in
  match JSON.(json |-> "hash" |> as_string_opt) with
  | Some hash -> return hash
  | None -> failwith (Format.sprintf "hash is missing %s" __LOC__)

let forge_and_publish_commitment ?compressed_state ?number_of_ticks ~inbox_level
    ~predecessor ~sc_rollup ~src client =
  let open Runnable in
  let open Syntax in
  let commitment, runnable =
    forge_and_publish_commitment_return_runnable
      ?compressed_state
      ?number_of_ticks
      ~inbox_level
      ~predecessor
      ~sc_rollup
      ~src
      client
  in
  let*! () = runnable in
  let* () = Client.bake_for_and_wait client in
  let* hash = get_staked_on_commitment ~sc_rollup ~staker:src client in
  return (commitment, hash)

let bake_period_then_publish_commitment ?compressed_state ?number_of_ticks
    ~sc_rollup ~src client =
  let* {commitment_period_in_blocks = commitment_period; _} =
    get_sc_rollup_constants client
  in
  let* predecessor, last_inbox_level =
    last_cemented_commitment_hash_with_level ~sc_rollup client
  in
  let inbox_level = last_inbox_level + commitment_period in
  let* current_level = Client.level client in
  let missing_blocks_to_commit =
    last_inbox_level + commitment_period - current_level + 1
  in
  let* () =
    repeat missing_blocks_to_commit (fun () -> Client.bake_for_and_wait client)
  in
  forge_and_publish_commitment
    ?compressed_state
    ?number_of_ticks
    ~inbox_level
    ~predecessor
    ~sc_rollup
    ~src
    client

let cement_commitment protocol ?(src = Constant.bootstrap1.alias) ?fail
    ~sc_rollup ~hash client =
  let open Runnable in
  let open Syntax in
  let p =
    Client.Sc_rollup.cement_commitment
      protocol
      ~hooks
      ~dst:sc_rollup
      ~src
      ~hash
      client
  in
  match fail with
  | None ->
      let*! () = p in
      Client.bake_for_and_wait client
  | Some failure ->
      let*? process = p in
      Process.check_error ~msg:(rex failure) process

(** Helper to check that the operation whose hash is given is successfully
    included (applied) in the current head block. *)
let check_op_included ~__LOC__ =
  let get_op_status op =
    JSON.(op |-> "metadata" |-> "operation_result" |-> "status" |> as_string)
  in
  fun ~oph client ->
    let* head = Client.RPC.call client @@ RPC.get_chain_block () in
    (* Operations in a block are encoded as a list of lists of operations
       [ consensus; votes; anonymous; manager ]. Manager operations are
       at index 3 in the list. *)
    let ops = JSON.(head |-> "operations" |=> 3 |> as_list) in
    let op_contents =
      match
        List.find_opt (fun op -> oph = JSON.(op |-> "hash" |> as_string)) ops
      with
      | None -> []
      | Some op -> JSON.(op |-> "contents" |> as_list)
    in
    match op_contents with
    | [op] ->
        let status = get_op_status op in
        if String.equal status "applied" then unit
        else
          Test.fail
            ~__LOC__
            "Unexpected operation %s status: got %S instead of 'applied'."
            oph
            status
    | _ ->
        Test.fail
          "Expected to have one operation with hash %s, but got %d"
          oph
          (List.length op_contents)

(** Helper function that allows to inject the given operation in a node, bake a
    block, and check that the operation is successfully applied in the baked
    block. *)
let bake_operation_via_rpc ~__LOC__ client op =
  let* (`OpHash oph) = Operation.Manager.inject [op] client in
  let* () = Client.bake_for_and_wait client in
  check_op_included ~__LOC__ ~oph client

let start_refute client ~source ~opponent ~sc_rollup ~player_commitment_hash
    ~opponent_commitment_hash =
  let module M = Operation.Manager in
  let refutation = M.Start {player_commitment_hash; opponent_commitment_hash} in
  bake_operation_via_rpc ~__LOC__ client
  @@ M.make ~source
  @@ M.sc_rollup_refute ~sc_rollup ~opponent ~refutation ()

(** [move_refute_with_unique_state_hash
    ?number_of_sections_in_dissection client ~source ~opponent
    ~sc_rollup ~state_hash] submits a dissection refutation
    operation. The dissection is always composed of the same
    state_hash and should only be used for test. *)
let move_refute_with_unique_state_hash ?number_of_sections_in_dissection client
    ~source ~opponent ~sc_rollup ~state_hash =
  let module M = Operation.Manager in
  let* number_of_sections_in_dissection =
    match number_of_sections_in_dissection with
    | Some n -> return n
    | None ->
        let* {number_of_sections_in_dissection; _} =
          get_sc_rollup_constants client
        in
        return number_of_sections_in_dissection
  in
  (* Construct a valid dissection with valid initial hash of size
     [sc_rollup.number_of_sections_in_dissection]. The state hash
     given is the state hash of the parent commitment of the refuted
     one and the one used for all tick. *)
  let rec aux i acc =
    if i = number_of_sections_in_dissection - 1 then
      List.rev (M.{state_hash = None; tick = i} :: acc)
    else aux (i + 1) (M.{state_hash = Some state_hash; tick = i} :: acc)
  in
  let refutation =
    M.Move {choice_tick = 0; refutation_step = Dissection (aux 0 [])}
  in
  bake_operation_via_rpc ~__LOC__ client
  @@ M.make ~source
  @@ M.sc_rollup_refute ~sc_rollup ~opponent ~refutation ()

let timeout ?expect_failure ~sc_rollup ~staker1 ~staker2 ?(src = staker1) client
    =
  let open Runnable in
  let open Syntax in
  let*! () =
    Client.Sc_rollup.timeout
      ~hooks
      ~dst:sc_rollup
      ~src
      ~staker1
      ~staker2
      client
      ?expect_failure
  in
  Client.bake_for_and_wait client

(** Wait for the rollup node to detect a conflict *)
let wait_for_conflict_detected sc_node =
  Sc_rollup_node.wait_for sc_node "smart_rollup_node_conflict_detected.v0"
  @@ fun json ->
  let our_hash = JSON.(json |-> "our_commitment_hash" |> as_string) in
  Some (our_hash, json)

(** Wait for the [sc_rollup_node_publish_commitment] event from the
    rollup node. *)
let wait_for_publish_commitment node =
  Sc_rollup_node.wait_for
    node
    "smart_rollup_node_commitment_publish_commitment.v0"
  @@ fun json ->
  let hash = JSON.(json |-> "hash" |> as_string) in
  let level = JSON.(json |-> "level" |> as_int) in
  Some (hash, level)

(** Wait for the rollup node to detect a timeout *)
let wait_for_timeout_detected sc_node =
  Sc_rollup_node.wait_for sc_node "smart_rollup_node_timeout_detected.v0"
  @@ fun json ->
  let other = JSON.(json |> as_string) in
  Some other

(** Wait for the rollup node to compute a dissection *)
let wait_for_computed_dissection sc_node =
  Sc_rollup_node.wait_for sc_node "smart_rollup_node_computed_dissection.v0"
  @@ fun json ->
  let opponent = JSON.(json |-> "opponent" |> as_string) in
  Some (opponent, json)

let remove_state_from_dissection dissection =
  JSON.update
    "dissection"
    (fun d ->
      let d =
        JSON.as_list d
        |> List.map (fun s ->
               JSON.filter_object s (fun key _ -> not (key = "state"))
               |> JSON.unannotate)
      in
      JSON.annotate ~origin:"trimmed_dissection" (`A d))
    dissection

let to_text_messages_arg msgs =
  let json = Ezjsonm.list Ezjsonm.string msgs in
  "text:" ^ Ezjsonm.to_string ~minify:true json

let to_hex_messages_arg msgs =
  let json = Ezjsonm.list Ezjsonm.string msgs in
  "hex:" ^ Ezjsonm.to_string ~minify:true json

(** Configure the rollup node to pay more fees for its refute operations. *)
let prioritize_refute_operations sc_rollup_node =
  Log.info
    "Prioritize refutation operations for rollup node %s"
    (Sc_rollup_node.name sc_rollup_node) ;
  Sc_rollup_node.Config_file.update sc_rollup_node @@ fun config ->
  let open JSON in
  update
    "fee-parameters"
    (update "refute"
    @@ put
         ( "minimal-nanotez-per-gas-unit",
           JSON.annotate
             ~origin:"higher-priority"
             (`A [`String "200"; `String "1"]) ))
    config

let send_text_messages ?(format = `Raw) ?hooks ?src client msgs =
  match format with
  | `Raw -> send_message ?hooks ?src client (to_text_messages_arg msgs)
  | `Hex -> send_message ?hooks ?src client (to_hex_messages_arg msgs)

let reveal_hash_hex data =
  let hash =
    Tezos_crypto.Blake2B.(hash_string [data] |> to_string) |> hex_encode
  in
  "00" ^ hash

type reveal_hash = {message : string; filename : string}

let reveal_hash ~protocol:_ ~kind data =
  let hex_hash = reveal_hash_hex data in
  match kind with
  | "arith" -> {message = "hash:" ^ hex_hash; filename = hex_hash}
  | _ ->
      (* Not used for wasm yet. *)
      assert false

let bake_until ?hook cond n client =
  assert (0 <= n) ;
  let rec go i =
    if 0 < i then
      let* cond = cond client in
      if cond then
        let* () = match hook with None -> unit | Some hook -> hook (n - i) in
        let* () = Client.bake_for_and_wait client in
        go (i - 1)
      else return ()
    else return ()
  in
  go n

(*

   To check the refutation game logic, we evaluate a scenario with one
   honest rollup node and one dishonest rollup node configured as with
   a given [loser_mode].

   For a given sequence of [inputs], distributed amongst several
   levels, with some possible [empty_levels]. We check that at some
   [final_level], the crime does not pay: the dishonest node has losen
   its deposit while the honest one has not.

*)
let test_refutation_scenario_aux ~(mode : Sc_rollup_node.mode) ~kind
    {
      loser_modes;
      inputs;
      final_level;
      empty_levels;
      stop_loser_at;
      reset_honest_on;
      bad_reveal_at;
      priority;
      allow_degraded;
    } protocol sc_rollup_node _sc_client1 sc_rollup_address node client =
  let bootstrap1_key = Constant.bootstrap1.public_key_hash in
  let loser_keys =
    List.mapi
      (fun i _ -> Account.Bootstrap.keys.(i + 1).public_key_hash)
      loser_modes
  in

  let game_started = ref false in
  let conflict_detected = ref false in
  let detected_conflicts = ref [] in
  let published_commitments = ref [] in
  let detected_timeouts = Hashtbl.create 5 in
  let dissections = Hashtbl.create 17 in

  let run_honest_node sc_rollup_node =
    let gather_conflicts_promise =
      let rec gather_conflicts () =
        let* conflict = wait_for_conflict_detected sc_rollup_node in
        conflict_detected := true ;
        detected_conflicts := conflict :: !detected_conflicts ;
        gather_conflicts ()
      in
      gather_conflicts ()
    in
    let gather_commitments_promise =
      let rec gather_commitments () =
        let* c = wait_for_publish_commitment sc_rollup_node in
        published_commitments := c :: !published_commitments ;
        gather_commitments ()
      in
      gather_commitments ()
    in
    let gather_timeouts_promise =
      let rec gather_timeouts () =
        let* other = wait_for_timeout_detected sc_rollup_node in
        Hashtbl.replace
          detected_timeouts
          other
          (Option.value ~default:0 (Hashtbl.find_opt detected_timeouts other)
          + 1) ;
        gather_timeouts ()
      in
      gather_timeouts ()
    in
    let gather_dissections_promise =
      let rec gather_dissections () =
        let* opponent, dissection =
          wait_for_computed_dissection sc_rollup_node
        in
        let dissection =
          match kind with
          | "arith" -> dissection
          | _ (* wasm *) ->
              (* Remove state hashes from WASM dissections as they depend on
                 timestamps *)
              remove_state_from_dissection dissection
        in
        (* Use buckets of table to store multiple dissections for same
           opponent. *)
        Hashtbl.add dissections opponent dissection ;
        gather_dissections ()
      in
      gather_dissections ()
    in
    (* Write configuration to be able to change it *)
    let* _ =
      Sc_rollup_node.config_init ~force:true sc_rollup_node sc_rollup_address
    in
    if priority = `Priority_honest then
      prioritize_refute_operations sc_rollup_node ;
    let* () =
      Sc_rollup_node.run
        ~event_level:`Debug
        ~allow_degraded
        sc_rollup_node
        sc_rollup_address
        []
    in
    return
      [
        gather_conflicts_promise;
        gather_commitments_promise;
        gather_timeouts_promise;
        gather_dissections_promise;
      ]
  in

  let loser_sc_rollup_nodes =
    let i = ref 0 in
    List.map2
      (fun default_operator _ ->
        incr i ;
        let rollup_node_name = "loser" ^ string_of_int !i in
        Sc_rollup_node.create
          Operator
          node
          ~base_dir:(Client.base_dir client)
          ~default_operator
          ~name:rollup_node_name)
      loser_keys
      loser_modes
  in
  let* gather_promises = run_honest_node sc_rollup_node
  and* () =
    Lwt_list.iter_p (fun (loser_mode, loser_sc_rollup_node) ->
        let* _ =
          Sc_rollup_node.config_init
            ~loser_mode
            loser_sc_rollup_node
            sc_rollup_address
        in
        if priority = `Priority_loser then
          prioritize_refute_operations loser_sc_rollup_node ;
        Sc_rollup_node.run
          loser_sc_rollup_node
          ~loser_mode
          ~allow_degraded
          sc_rollup_address
          [])
    @@ List.combine loser_modes loser_sc_rollup_nodes
  in

  let restart_promise =
    (* Reset node when detecting certain events *)
    Lwt_list.iter_p
      (fun (event, delay, restart_mode) ->
        let* () =
          Sc_rollup_node.wait_for sc_rollup_node event @@ fun _json -> Some ()
        in
        let* current_level = Node.get_level node in
        let* _ =
          Sc_rollup_node.wait_for_level
            ~timeout:3.0
            sc_rollup_node
            (current_level + delay)
        in
        let* () = Sc_rollup_node.terminate sc_rollup_node in
        let sc_rollup_node =
          match restart_mode with
          | Some mode -> Sc_rollup_node.change_node_mode sc_rollup_node mode
          | None -> sc_rollup_node
        in
        let* _ = run_honest_node sc_rollup_node in
        unit)
      reset_honest_on
  in

  let stop_losers level =
    if List.mem level stop_loser_at then
      Lwt_list.iter_p
        (fun loser_sc_rollup_node ->
          Sc_rollup_node.terminate loser_sc_rollup_node)
        loser_sc_rollup_nodes
    else unit
  in
  (* Calls that can fail because the node is down due to the ongoing migration
     need to be retried. *)
  let retry f =
    let f _ =
      let* () = Node.wait_for_ready node in
      f ()
    in
    Lwt.catch f f
  in
  let rec consume_inputs = function
    | [] -> unit
    | inputs :: next_batches as all ->
        let level = Node.get_last_seen_level node in
        let* () = stop_losers level in
        if List.mem level empty_levels then
          let* () = retry @@ fun () -> Client.bake_for_and_wait client in
          consume_inputs all
        else
          let* () =
            retry @@ fun () ->
            send_text_messages ~src:Constant.bootstrap3.alias client inputs
          in
          consume_inputs next_batches
  in
  let* () = consume_inputs inputs in
  let after_inputs_level = Node.get_last_seen_level node in

  let hook i =
    let level = after_inputs_level + i in
    let* () =
      if List.mem level bad_reveal_at then
        let hash = reveal_hash ~protocol ~kind "Missing data" in
        retry @@ fun () ->
        send_text_messages ~src:Constant.bootstrap3.alias client [hash.message]
      else unit
    in
    stop_losers level
  in
  let keep_going client =
    let* games =
      retry @@ fun () ->
      Client.RPC.call client
      @@ RPC.get_chain_block_context_smart_rollups_smart_rollup_staker_games
           ~staker:bootstrap1_key
           sc_rollup_address
           ()
    in
    let has_games = JSON.as_list games <> [] in
    if !game_started then return has_games
    else (
      game_started := has_games ;
      return true)
  in

  let* () =
    bake_until ~hook keep_going (final_level - List.length inputs) client
  in

  if not !conflict_detected then
    Test.fail "Honest node did not detect the conflict" ;

  let multiple_timeouts_for_opponent =
    Hashtbl.fold
      (fun _other timeouts no -> no || timeouts > 1)
      detected_timeouts
      false
  in

  if multiple_timeouts_for_opponent then
    Test.fail "Attempted to timeout an opponent more than once" ;

  if mode = Accuser then (
    assert (!detected_conflicts <> []) ;
    List.iter
      (fun (commitment_hash, level) ->
        if not (List.mem_assoc commitment_hash !detected_conflicts) then
          Test.fail
            "Accuser published the commitment %s at level %d which never \
             appeared in a conflict"
            commitment_hash
            level)
      !published_commitments) ;

  let* {stake_amount; _} = get_sc_rollup_constants client in
  let* honest_deposit_json =
    retry @@ fun () ->
    Client.RPC.call client
    @@ RPC.get_chain_block_context_contract_frozen_bonds ~id:bootstrap1_key ()
  in
  let* loser_deposits_json =
    Lwt_list.map_p
      (fun id ->
        retry @@ fun () ->
        Client.RPC.call client
        @@ RPC.get_chain_block_context_contract_frozen_bonds ~id ())
      loser_keys
  in

  Check.(
    (honest_deposit_json = stake_amount)
      Tez.typ
      ~error_msg:"expecting deposit for honest participant = %R, got %L") ;
  List.iter
    (fun loser_deposit_json ->
      Check.(
        (loser_deposit_json = Tez.zero)
          Tez.typ
          ~error_msg:"expecting loss for dishonest participant = %R, got %L"))
    loser_deposits_json ;
  Log.info "Checking that we can still retrieve state from rollup node" ;
  (* This is a way to make sure the rollup node did not crash *)
  let* _value =
    Sc_rollup_node.RPC.call sc_rollup_node
    @@ Sc_rollup_rpc.get_global_block_state_hash ()
  in
  List.iter Lwt.cancel (restart_promise :: gather_promises) ;
  (* Capture dissections *)
  Hashtbl.to_seq_values dissections
  |> List.of_seq |> List.rev
  |> List.iter (fun dissection ->
         Regression.capture "\n" ;
         Regression.capture @@ JSON.encode dissection) ;
  unit

let rec swap i l =
  if i <= 0 then l
  else match l with [_] | [] -> l | x :: y :: l -> y :: swap (i - 1) (x :: l)

let inputs_for n =
  List.concat @@ List.init n
  @@ fun i -> [swap i ["3 3 +"; "1"; "1 1 x"; "3 7 8 + * y"; "2 2 out"]]

(** Wait for the [injecting_pending] event from the injector. *)
let wait_for_injecting_event ?(tags = []) ?count node =
  Sc_rollup_node.wait_for node "injecting_pending.v0" @@ fun json ->
  let event_tags = JSON.(json |-> "tags" |> as_list |> List.map as_string) in
  let event_count = JSON.(json |-> "count" |> as_int) in
  match count with
  | Some c when c <> event_count -> None
  | _ ->
      if List.for_all (fun t -> List.mem t event_tags) tags then
        Some event_count
      else None

let injecting_refute_event _tezos_node rollup_node =
  let* _injected = wait_for_injecting_event ~tags:["refute"] rollup_node in
  unit

let total_ticks ?(block = "head") sc_rollup_node =
  let service = "global/block/" ^ block ^ "/total_ticks" in
  let* json = call_rpc ~smart_rollup_node:sc_rollup_node ~service in
  return (JSON.as_int json)

let state_current_level ?(block = "head") sc_rollup_node =
  let service = "global/block/" ^ block ^ "/state_current_level" in
  let* json = call_rpc ~smart_rollup_node:sc_rollup_node ~service in
  return (JSON.as_int json)

let status ?(block = "head") sc_rollup_node =
  let service = "global/block/" ^ block ^ "/status" in
  let* json = call_rpc ~smart_rollup_node:sc_rollup_node ~service in
  return (JSON.as_string json)

let outbox ?(block = "cemented") ~outbox_level sc_rollup_node =
  let service =
    "global/block/" ^ block ^ "/outbox/" ^ string_of_int outbox_level
    ^ "/messages"
  in
  call_rpc ~smart_rollup_node:sc_rollup_node ~service
