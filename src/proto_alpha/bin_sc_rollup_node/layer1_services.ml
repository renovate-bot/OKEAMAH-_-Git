(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

open Protocol
open Alpha_context
open Apply_results
open Protocol_client_context.Alpha_block_services

type 'accu operation_processor = {
  apply :
    'kind.
    'accu ->
    source:public_key_hash ->
    'kind manager_operation ->
    'kind Apply_results.successful_manager_operation_result ->
    'accu;
  apply_internal :
    'kind.
    'accu ->
    source:public_key_hash ->
    'kind Apply_internal_results.internal_manager_operation ->
    'kind Apply_internal_results.successful_internal_manager_operation_result ->
    'accu;
}

let process_applied_manager_operations operations accu f =
  let rec on_applied_operation_and_result :
      type kind. _ -> kind Apply_results.contents_and_result_list -> _ =
   fun accu -> function
    | Single_and_result
        ( Manager_operation {operation; source; _},
          Manager_operation_result
            {
              operation_result = Applied operation_result;
              internal_operation_results;
              _;
            } ) ->
        let accu = f.apply accu ~source operation operation_result in
        on_applied_internal_operations accu source internal_operation_results
    | Single_and_result (_, _) -> accu
    | Cons_and_result
        ( Manager_operation {operation; source; _},
          Manager_operation_result
            {
              operation_result = Applied operation_result;
              internal_operation_results;
              _;
            },
          rest ) ->
        let accu = f.apply accu ~source operation operation_result in
        let accu =
          on_applied_internal_operations accu source internal_operation_results
        in
        on_applied_operation_and_result accu rest
    | Cons_and_result (_, _, rest) -> on_applied_operation_and_result accu rest
  and on_applied_internal_operations accu source internal_operation_results =
    let open Apply_internal_results in
    List.fold_left
      (fun accu (Internal_manager_operation_result ({operation; _}, result)) ->
        match result with
        | Applied result -> f.apply_internal accu ~source operation result
        | _ -> accu)
      accu
      internal_operation_results
  in
  let process_contents accu
      ({protocol_data = Operation_data {contents; _}; receipt; _} : operation) =
    match receipt with
    | Empty | Too_large | Receipt No_operation_metadata ->
        (* This should case should not happen between [operations] is supposed
           to be retrieved with `force_metadata:true` and assuming that the
           tezos node is running in archive mode. *)
        assert false
    | Receipt (Operation_metadata {contents = results; _}) -> (
        match Apply_results.kind_equal_list contents results with
        | Some Eq ->
            on_applied_operation_and_result accu
            @@ Apply_results.pack_contents_list contents results
        | None ->
            (* Should not happen *)
            assert false)
  in
  let process_operations = List.fold_left process_contents in
  List.fold_left process_operations operations accu
