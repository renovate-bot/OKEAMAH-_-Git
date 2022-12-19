(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
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

open Sc_rollup_errors
module Store = Storage.Sc_rollup
module Commitment_storage = Sc_rollup_commitment_storage
module Commitment = Sc_rollup_commitment_repr
module Commitment_hash = Commitment.Hash

(** As the set encoded with a list are proportional to the number of
    stakers on the rollup, we admit that it will be a small set. We
    also admit that a small list respecting the set properties is more
    efficient than using a real {!Set.S}. *)
module Set_out_of_list (S : sig
  type t = Raw_context.t * Sc_rollup_repr.t

  type key

  type value

  val equal_value : value -> value -> bool

  val find : t -> key -> (Raw_context.t * value list option) tzresult Lwt.t

  val init : t -> key -> value list -> (Raw_context.t * int) tzresult Lwt.t

  val add :
    t -> key -> value list -> (Raw_context.t * int * bool) tzresult Lwt.t

  val remove : t -> key -> (Raw_context.t * int) tzresult Lwt.t
end) =
struct
  let add_or_init ctxt rollup key value =
    let open Lwt_result_syntax in
    let* ctxt, values_opt = S.find (ctxt, rollup) key in
    match values_opt with
    | None ->
        (* Initialize the list of values. *)
        let values = [value] in
        let* ctxt, size = S.init (ctxt, rollup) key values in
        return (ctxt, size, values)
    | Some existing_values ->
        (* Adds [value] to [existing_values] if the values does not
           already exist. *)
        let exists = List.mem ~equal:S.equal_value value existing_values in
        if exists then return (ctxt, 0, existing_values)
        else
          let values = value :: existing_values in
          let* ctxt, diff_size, _existed = S.add (ctxt, rollup) key values in
          return (ctxt, diff_size, values)

  let find ctxt rollup key = S.find (ctxt, rollup) key

  let get ctxt rollup key =
    let open Lwt_result_syntax in
    let* ctxt, values_opt = find ctxt rollup key in
    return (ctxt, Option.value ~default:[] values_opt)

  let remove ctxt rollup key = S.remove (ctxt, rollup) key
end

module Commitments_per_inbox_level = Set_out_of_list (struct
  type t = Raw_context.t * Sc_rollup_repr.t

  type key = Raw_level_repr.t

  type value = Commitment_hash.t

  let equal_value = Commitment_hash.equal

  let find = Store.Commitments_per_inbox_level.find

  let init = Store.Commitments_per_inbox_level.init

  let add = Store.Commitments_per_inbox_level.add

  let remove = Store.Commitments_per_inbox_level.remove_existing
end)

module Commitment_stakers = Set_out_of_list (struct
  type t = Raw_context.t * Sc_rollup_repr.t

  type key = Commitment_hash.t

  type value = Sc_rollup_staker_index_repr.t

  let equal_value (x : value) (y : value) = Z.equal (x :> Z.t) (y :> Z.t)

  let find = Store.Commitment_stakers.find

  let init = Store.Commitment_stakers.init

  let add = Store.Commitment_stakers.add

  let remove = Store.Commitment_stakers.remove_existing
end)

let is_staker ctxt rollup staker =
  let open Lwt_result_syntax in
  let* ctxt, res =
    Sc_rollup_staker_index_storage.find_staker_index_unsafe ctxt rollup staker
  in
  return (Option.is_some res, ctxt)

let find_staker ctxt rollup staker =
  let open Lwt_result_syntax in
  let* ctxt, staker_index =
    Sc_rollup_staker_index_storage.get_staker_index_unsafe ctxt rollup staker
  in
  let* ctxt, level = Store.Stakers.get (ctxt, rollup) staker_index in
  let* ctxt, commitments_opt =
    Commitments_per_inbox_level.find ctxt rollup level
  in
  match commitments_opt with
  | None ->
      (* The staked commitment is no longer active (i.e. cemented). *)
      return (ctxt, None)
  | Some commitments ->
      (* Looks for the commitment [staker] stakes on, in the list of commitments
         posted for this level. *)
      let rec find_staker_in_commitments = function
        | [] -> tzfail Sc_rollup_not_staked
        | commitment_hash :: rst ->
            let* ctxt, stakers =
              Commitment_stakers.get ctxt rollup commitment_hash
            in
            if
              List.mem
                ~equal:Z.equal
                (staker_index :> Z.t)
                (stakers :> Z.t list)
            then return (ctxt, Some commitment_hash)
            else find_staker_in_commitments rst
      in
      find_staker_in_commitments commitments

let stakers_commitments_uncarbonated ctxt rollup =
  let open Lwt_result_syntax in
  let*! stakers =
    Sc_rollup_staker_index_storage.list_stakers_uncarbonated ctxt rollup
  in
  List.map_es
    (fun staker ->
      let* _ctxt, commitment_opt = find_staker ctxt rollup staker in
      return (staker, commitment_opt))
    stakers

let get_contract_and_stake ctxt staker =
  let staker_contract = Contract_repr.Implicit staker in
  let stake = Constants_storage.sc_rollup_stake_amount ctxt in
  (staker_contract, stake)

let check_staked_on_lcc_or_ancestor ctxt rollup ~staker_index lcc_inbox_level =
  let open Lwt_result_syntax in
  (* [staker] needs to stake on a commitment older than [lcc] (or on
     LCC) to withdraw. *)
  let* ctxt, last_staked_level =
    Store.Stakers.get (ctxt, rollup) staker_index
  in
  let* () =
    fail_unless
      Raw_level_repr.(last_staked_level <= lcc_inbox_level)
      Sc_rollup_not_staked_on_lcc_or_ancestor
  in
  return ctxt

let deposit_stake ctxt rollup staker =
  let open Lwt_result_syntax in
  (* Freeze the stake of [staker]. *)
  let staker_contract, stake = get_contract_and_stake ctxt staker in
  let* ctxt, staker_balance =
    Contract_storage.get_balance_carbonated ctxt staker_contract
  in
  let* () =
    fail_when
      Tez_repr.(staker_balance < stake)
      (Sc_rollup_staker_funds_too_low
         {
           staker;
           sc_rollup = rollup;
           staker_balance;
           min_expected_balance = stake;
         })
  in
  let bond_id = Bond_id_repr.Sc_rollup_bond_id rollup in
  let* ctxt, balance_updates =
    Token.transfer
      ctxt
      (`Contract staker_contract)
      (`Frozen_bonds (staker_contract, bond_id))
      stake
  in
  (* Initialize the index of [staker]. *)
  let* ctxt, staker_index =
    Sc_rollup_staker_index_storage.fresh_staker_index ctxt rollup staker
  in
  return (ctxt, balance_updates, staker_index)

let clean_staker_metadata ctxt rollup staker =
  Sc_rollup_staker_index_storage.remove_staker ctxt rollup staker

let withdraw_stake ctxt rollup staker =
  let open Lwt_result_syntax in
  let* _lcc, lcc_inbox_level, ctxt =
    Commitment_storage.last_cemented_commitment_hash_with_level ctxt rollup
  in
  let* ctxt, staker_index =
    Sc_rollup_staker_index_storage.get_staker_index_unsafe ctxt rollup staker
  in
  let* ctxt =
    check_staked_on_lcc_or_ancestor ctxt rollup ~staker_index lcc_inbox_level
  in
  let staker_contract, stake = get_contract_and_stake ctxt staker in
  let bond_id = Bond_id_repr.Sc_rollup_bond_id rollup in
  let* ctxt, balance_updates =
    Token.transfer
      ctxt
      (`Frozen_bonds (staker_contract, bond_id))
      (`Contract staker_contract)
      stake
  in
  let* ctxt = clean_staker_metadata ctxt rollup staker in
  return (ctxt, balance_updates)

let assert_commitment_not_too_far_ahead ctxt rollup lcc commitment =
  let open Lwt_result_syntax in
  let* lcc, ctxt = Commitment_storage.get_commitment_unsafe ctxt rollup lcc in
  let min_level = Commitment.(lcc.inbox_level) in
  let max_level = Commitment.(commitment.inbox_level) in
  let* () =
    fail_when
      (let sc_rollup_max_lookahead =
         Constants_storage.sc_rollup_max_lookahead_in_blocks ctxt
       in
       Compare.Int32.(
         sc_rollup_max_lookahead < Raw_level_repr.diff max_level min_level))
      Sc_rollup_too_far_ahead
  in
  return ctxt

(** Enfore that a commitment's inbox level increases by an exact fixed amount over its predecessor.
    This property is used in several places - not obeying it causes severe breakage.
*)
let assert_commitment_period ctxt rollup commitment =
  let open Lwt_result_syntax in
  let pred_hash = Commitment.(commitment.predecessor) in
  let* pred, ctxt =
    Commitment_storage.get_commitment_unsafe ctxt rollup pred_hash
  in
  let pred_level = Commitment.(pred.inbox_level) in
  (* We want to check the following inequalities on [commitment.inbox_level],
     [commitment.predecessor.inbox_level] and the constant [sc_rollup_commitment_period].

     - Greater-than-or-equal (>=), to ensure inbox_levels are monotonically
     increasing along each branch of commitments. Together with
     [assert_commitment_not_too_far_ahead] this is sufficient to limit the
     depth of the commitment tree, which is also the number of commitments stored
     per staker. This constraint must be enforced at submission time.

     - Equality (=), so that L2 blocks are produced at a regular rate.  This
     ensures that there is only ever one branch of correct commitments,
     simplifying refutation logic. This could also be enforced at refutation time
     rather than submission time, but doing it here works too.

     Because [a >= b && a = b] is equivalent to [a = b], we can just keep the latter as
     an optimization.
  *)
  let sc_rollup_commitment_period =
    Constants_storage.sc_rollup_commitment_period_in_blocks ctxt
  in
  let* () =
    fail_unless
      Raw_level_repr.(
        commitment.inbox_level = add pred_level sc_rollup_commitment_period)
      Sc_rollup_bad_inbox_level
  in
  return ctxt

(** [assert_commitment_is_not_past_curfew ctxt rollup inbox_level] will look in the
    storage [Commitment_first_publication_level] for the level of the oldest commit for
    [inbox_level] and if it is more than [sc_rollup_challenge_window_in_blocks]
    ago it fails with [Sc_rollup_commitment_past_curfew]. Otherwise it adds the
    respective storage (if it is not set) and returns the context. *)
let assert_commitment_is_not_past_curfew ctxt rollup inbox_level =
  let open Lwt_result_syntax in
  let refutation_deadline_blocks =
    Int32.of_int @@ Constants_storage.sc_rollup_challenge_window_in_blocks ctxt
  in
  let current_level = (Raw_context.current_level ctxt).level in
  let* ctxt, oldest_commit =
    Store.Commitment_first_publication_level.find (ctxt, rollup) inbox_level
  in
  match oldest_commit with
  | Some oldest_commit ->
      if
        Compare.Int32.(
          Raw_level_repr.diff current_level oldest_commit
          > refutation_deadline_blocks)
      then tzfail Sc_rollup_commitment_past_curfew
      else return ctxt
  | None ->
      (* The storage cost is covered by the stake. *)
      let* ctxt, _diff, _existed =
        Store.Commitment_first_publication_level.add
          (ctxt, rollup)
          inbox_level
          current_level
      in
      return ctxt

(** Check invariants on [inbox_level], enforcing overallocation of storage,
    regularity of block production and curfew.

    The constants used by [assert_refine_conditions_met] must be chosen such
    that the maximum cost of storage allocated by each staker is at most the size
    of their deposit.
 *)
let assert_refine_conditions_met ctxt rollup lcc commitment =
  let open Lwt_result_syntax in
  let* ctxt = assert_commitment_not_too_far_ahead ctxt rollup lcc commitment in
  let* ctxt = assert_commitment_period ctxt rollup commitment in
  let* ctxt =
    assert_commitment_is_not_past_curfew
      ctxt
      rollup
      Commitment.(commitment.inbox_level)
  in
  let current_level = (Raw_context.current_level ctxt).level in
  let* () =
    fail_unless
      Raw_level_repr.(commitment.Commitment.inbox_level < current_level)
      (Sc_rollup_commitment_from_future
         {current_level; inbox_level = commitment.inbox_level})
  in
  return ctxt

let is_staker_index_staked_on ctxt rollup
    (staker_index : Sc_rollup_staker_index_repr.t) commitment_hash =
  let open Lwt_result_syntax in
  let* ctxt, stakers = Commitment_stakers.get ctxt rollup commitment_hash in
  let exists =
    List.mem ~equal:Compare.Z.equal (staker_index :> Z.t) (stakers :> Z.t list)
  in
  return (ctxt, exists)

let is_staked_on ctxt rollup staker commitment_hash =
  let open Lwt_result_syntax in
  let* ctxt, staker_index_opt =
    Sc_rollup_staker_index_storage.find_staker_index_unsafe ctxt rollup staker
  in
  match staker_index_opt with
  | None -> return (ctxt, false)
  | Some staker_index ->
      is_staker_index_staked_on ctxt rollup staker_index commitment_hash

let deallocate_commitment ctxt rollup node =
  let open Lwt_result_syntax in
  let* ctxt, _size_freed =
    Store.Commitments.remove_existing (ctxt, rollup) node
  in
  return ctxt

let deallocate_commitment_metadata ctxt rollup commitment_hash =
  let open Lwt_result_syntax in
  let* ctxt, _size_freed =
    Store.Commitment_added.remove_existing (ctxt, rollup) commitment_hash
  in
  return ctxt

let deallocate ctxt rollup commitment_hash =
  let open Lwt_result_syntax in
  let* ctxt = deallocate_commitment_metadata ctxt rollup commitment_hash in
  deallocate_commitment ctxt rollup commitment_hash

let find_commitment_to_deallocate ctxt rollup commitment_hash
    ~num_commitments_to_keep =
  let open Lwt_result_syntax in
  (* The recursion is safe as long as [num_commitments_to_keep] remains
     a small value. *)
  let rec aux ctxt commitment_hash n =
    if Compare.Int.(n = 0) then return (Some commitment_hash, ctxt)
    else
      let* pred_hash, ctxt =
        Commitment_storage.get_predecessor_opt_unsafe
          ctxt
          rollup
          commitment_hash
      in
      match pred_hash with
      | None -> return (None, ctxt)
      | Some pred_hash -> (aux [@ocaml.tailcall]) ctxt pred_hash (n - 1)
  in
  aux ctxt commitment_hash num_commitments_to_keep

(* This commitment storage size in bytes will be re-computed at the end
   of the merge request. *)
let commitment_storage_size_in_bytes = 0

(** [set_staker_commitment ctxt rollup staker_index inbox_level commitment_hash]
    updates the **newest** commitment [staker_index] stakes on.
    Adds [staker_index] to the set of stakers staking on [commitment_hash]. *)
let set_staker_commitment ctxt rollup staker_index inbox_level commitment_hash =
  let open Lwt_result_syntax in
  (* Update the newest commitment [staker_index] stakes on. *)
  let* ctxt, size_diff_stakers =
    let* ctxt, last_level = Store.Stakers.get (ctxt, rollup) staker_index in
    if Raw_level_repr.(last_level < inbox_level) then
      Store.Stakers.update (ctxt, rollup) staker_index inbox_level
    else return (ctxt, 0)
  in
  (* Adds [staker_index] to the set of stakers staking on [commitment_hash]. *)
  let* ctxt, size_diff_commitment_stakers, _stakers =
    Commitment_stakers.add_or_init ctxt rollup commitment_hash staker_index
  in
  return (ctxt, size_diff_stakers + size_diff_commitment_stakers)

(** [assert_staker_dont_backtrack ctxt rollup staker_index commitments]
    asserts that [staker_index] do not stake on multiple commitments in
    [commitments]. *)
let assert_staker_dont_backtrack ctxt rollup staker_index commitments =
  let open Lwt_result_syntax in
  (* Compute the list of commitments [staker_index] stakes on. *)
  let* ctxt, staked_on_commitments =
    List.fold_left_es
      (fun (ctxt, staked_on_commitments) commitment ->
        let* ctxt, is_staked_on =
          is_staker_index_staked_on ctxt rollup staker_index commitment
        in
        if is_staked_on then return (ctxt, commitment :: staked_on_commitments)
        else return (ctxt, staked_on_commitments))
      (ctxt, [])
      commitments
  in
  let* () =
    fail_when
      Compare.List_length_with.(staked_on_commitments > 1)
      Sc_rollup_errors.Sc_rollup_staker_backtracked
  in
  return ctxt

(* TODO: https://gitlab.com/tezos/tezos/-/issues/2559
   Add a test checking that L2 nodes can catch up after going offline. *)
let refine_stake ctxt rollup commitment ~staker_index ~lcc =
  let open Lwt_result_syntax in
  (* Checks the commitment validity, see {!assert_refine_conditions_met}. *)
  let* ctxt = assert_refine_conditions_met ctxt rollup lcc commitment in
  let*? ctxt, commitment_hash =
    Sc_rollup_commitment_storage.hash ctxt commitment
  in
  (* Adds the commitment to the storage. *)
  let* ctxt, _commitment_size_diff, _commit_existed =
    Store.Commitments.add (ctxt, rollup) commitment_hash commitment
  in
  (* Initializes or fetch the level at which the commitment was first
     published. *)
  let publication_level = (Raw_context.current_level ctxt).level in
  let* _commitment_added_size_diff, commitment_added_level, ctxt =
    Commitment_storage.set_commitment_added
      ctxt
      rollup
      commitment_hash
      publication_level
  in
  (* Updates the [staker_index]'s metadata. *)
  let* ctxt, _size_diff =
    set_staker_commitment
      ctxt
      rollup
      staker_index
      commitment.inbox_level
      commitment_hash
  in
  (* Adds the [commitment] to the set of commitments for this inbox level. *)
  let* ctxt, _commitments_per_inbox_level_size_diff, commitments =
    Commitments_per_inbox_level.add_or_init
      ctxt
      rollup
      commitment.inbox_level
      commitment_hash
  in
  (* Checks that the staker is not backtracking, done at the end to avoid
     the double get to the list of commitments. *)
  let* ctxt =
    assert_staker_dont_backtrack ctxt rollup staker_index commitments
  in
  return (commitment_hash, commitment_added_level, ctxt)

let publish_commitment ctxt rollup staker commitment =
  let open Lwt_result_syntax in
  let* lcc, ctxt = Commitment_storage.last_cemented_commitment ctxt rollup in
  let* () =
    fail_when
      Sc_rollup_repr.Number_of_ticks.(
        commitment.Commitment.number_of_ticks = zero)
      Sc_rollup_zero_tick_commitment
  in
  let* ctxt, staker_index_opt =
    Sc_rollup_staker_index_storage.find_staker_index_unsafe ctxt rollup staker
  in
  (* If [staker] is an active staker, it has an index. *)
  let* ctxt, balances_updates, staker_index =
    match staker_index_opt with
    | None -> deposit_stake ctxt rollup staker
    | Some staker_index -> return (ctxt, [], staker_index)
  in
  let* commitment_hash, publication_level, ctxt =
    refine_stake ctxt rollup ~staker_index commitment ~lcc
  in
  return (commitment_hash, publication_level, ctxt, balances_updates)

let is_active_commitment ctxt rollup lcc commitment_hash =
  let open Lwt_result_syntax in
  let* commitment, ctxt =
    Commitment_storage.get_commitment_unsafe ctxt rollup commitment_hash
  in
  if Commitment_hash.equal commitment.predecessor lcc then
    let* ctxt, stakers_on_commitment =
      Commitment_stakers.get ctxt rollup commitment_hash
    in
    let* ctxt, active_stakers =
      (* Filter the list of active stakers on this commitment. *)
      List.fold_left_es
        (fun (ctxt, active_stakers) staker ->
          let* ctxt, is_staker_active =
            Sc_rollup_staker_index_storage.is_active ctxt rollup staker
          in
          if is_staker_active then return (ctxt, staker :: active_stakers)
          else return (ctxt, active_stakers))
        (ctxt, [])
        stakers_on_commitment
    in
    (* The commitment is active if its predecessor is the LCC and
       at least one active steaker has staked on it. *)
    return (ctxt, Compare.List_length_with.(active_stakers > 0))
  else (* Dangling commitment. *)
    return (ctxt, false)

let active_commitments_of_inbox_level ctxt rollup lcc inbox_level =
  let open Lwt_result_syntax in
  let* ctxt, commitments =
    Commitments_per_inbox_level.get ctxt rollup inbox_level
  in
  List.fold_left_es
    (fun (ctxt, active_commitments, dangling_commitments) commitment ->
      let* ctxt, is_active = is_active_commitment ctxt rollup lcc commitment in
      if is_active then
        return (ctxt, commitment :: active_commitments, dangling_commitments)
      else return (ctxt, active_commitments, commitment :: dangling_commitments))
    (ctxt, [], [])
    commitments

(** [assert_cement_commitments_met ctxt rollup ~old_lcc new_lcc] asserts that
    the following list of properties are respected:

    {ol
      {li The [new_lcc]'s predecessor is the LCC.}
      {li The challenge window period is over.}
      {li [new_lcc] is the only active commitment.}
    }
*)
let assert_cement_commitments_met ctxt rollup ~old_lcc ~new_lcc =
  let open Lwt_result_syntax in
  (* Checks that the commitment's predecessor is the LCC. *)
  let* new_lcc_commitment, ctxt =
    Commitment_storage.get_commitment_unsafe ctxt rollup new_lcc
  in
  let* () =
    fail_unless
      Commitment_hash.(new_lcc_commitment.predecessor = old_lcc)
      Sc_rollup_parent_not_lcc
  in
  (* Checks that the commitment is past the challenge window. *)
  let* ctxt, new_lcc_added =
    Store.Commitment_added.get (ctxt, rollup) new_lcc
  in
  let* () =
    let challenge_windows_in_blocks =
      Constants_storage.sc_rollup_challenge_window_in_blocks ctxt
    in
    let current_level = (Raw_context.current_level ctxt).level in
    let min_level =
      Raw_level_repr.add new_lcc_added challenge_windows_in_blocks
    in
    fail_when
      Raw_level_repr.(current_level < min_level)
      (Sc_rollup_commitment_too_recent {current_level; min_level})
  in
  (* Checks that the commitment is the only active commitment. *)
  let* ctxt, active_commitments, dangling_commitments =
    active_commitments_of_inbox_level
      ctxt
      rollup
      old_lcc
      new_lcc_commitment.inbox_level
  in
  match active_commitments with
  (* A commitment can be cemented if there is only one valid
     commitment, and it matches the commitment provided. The
     commitment provided is then not strictly required. *)
  | [active_commitment] ->
      if Commitment_hash.equal active_commitment new_lcc then
        return (ctxt, new_lcc_commitment, dangling_commitments)
      else tzfail (Sc_rollup_invalid_commitment_to_cement new_lcc)
  | _ -> tzfail Sc_rollup_disputed

let deallocate_inbox_level ctxt rollup (new_lcc_commitment, new_lcc_hash)
    dangling_commitments =
  let open Lwt_result_syntax in
  let inbox_level = new_lcc_commitment.Commitment.inbox_level in
  let* ctxt, _size_diff =
    Commitments_per_inbox_level.remove ctxt rollup inbox_level
  in
  let* ctxt =
    List.fold_left_es
      (fun ctxt commitment -> deallocate ctxt rollup commitment)
      ctxt
      dangling_commitments
  in
  let* ctxt =
    List.fold_left_es
      (fun ctxt commitment ->
        let* ctxt, _freed_size =
          Commitment_stakers.remove ctxt rollup commitment
        in
        return ctxt)
      ctxt
      (new_lcc_hash :: dangling_commitments)
  in
  let* ctxt = deallocate_commitment_metadata ctxt rollup new_lcc_hash in
  let* ctxt, _size_freed =
    Store.Commitment_first_publication_level.remove_existing
      (ctxt, rollup)
      inbox_level
  in
  return ctxt

let update_saved_cemented_commitments ctxt rollup old_lcc =
  let open Lwt_result_syntax in
  (* We must not remove the commitment itself as we need it to allow
     executing outbox messages for a limited period. The maximum number of
     active cemented commitments available for execution is specified in
     [ctxt.sc_rollup.max_number_of_stored_cemented_commitments].
     Instead, we remove the oldest cemented commitment that would exceed
     [max_number_of_cemented_commitments], if such exist.

     Decrease max_number_of_stored_cemented_commitments by one because
     we start counting commitments from old_lcc, rather than from new_lcc.
  *)
  let num_commitments_to_keep =
    (Raw_context.constants ctxt).sc_rollup
      .max_number_of_stored_cemented_commitments - 1
  in
  let* commitment_to_deallocate, ctxt =
    find_commitment_to_deallocate ~num_commitments_to_keep ctxt rollup old_lcc
  in
  match commitment_to_deallocate with
  | None -> return ctxt
  | Some old_lcc ->
      if Commitment_hash.(equal old_lcc zero) then return ctxt
      else deallocate_commitment ctxt rollup old_lcc

let cement_commitment ctxt rollup new_lcc =
  let open Lwt_result_syntax in
  let* old_lcc, ctxt =
    Commitment_storage.last_cemented_commitment ctxt rollup
  in
  (* Assert conditions to cement are met. *)
  let* ctxt, new_lcc_commitment, dangling_commitments =
    assert_cement_commitments_met ctxt rollup ~old_lcc ~new_lcc
  in
  (* Update the LCC. *)
  let* ctxt, _size_diff =
    Store.Last_cemented_commitment.update ctxt rollup new_lcc
  in
  (* Clean the storage. *)
  let* ctxt =
    deallocate_inbox_level
      ctxt
      rollup
      (new_lcc_commitment, new_lcc)
      dangling_commitments
  in
  (* Update the saved cemented commitments. *)
  let* ctxt = update_saved_cemented_commitments ctxt rollup old_lcc in
  return (ctxt, new_lcc_commitment)

let remove_staker ctxt rollup staker =
  let open Lwt_result_syntax in
  let staker_contract, stake = get_contract_and_stake ctxt staker in
  let bond_id = Bond_id_repr.Sc_rollup_bond_id rollup in
  let* ctxt, balance_updates =
    Token.transfer
      ctxt
      (`Frozen_bonds (staker_contract, bond_id))
      `Sc_rollup_refutation_punishments
      stake
  in
  let* ctxt = clean_staker_metadata ctxt rollup staker in
  return (ctxt, balance_updates)

let commitments_of_inbox_level = Commitments_per_inbox_level.get

let stakers_of_commitment = Commitment_stakers.get

module Internal_for_tests = struct
  let deposit_stake = deposit_stake

  let refine_stake ?lcc ctxt rollup staker commitment =
    let open Lwt_result_syntax in
    let* lcc =
      match lcc with
      | None ->
          let* lcc, _ctxt =
            Commitment_storage.last_cemented_commitment ctxt rollup
          in
          return lcc
      | Some lcc -> return lcc
    in
    let* _ctxt, staker_index =
      Sc_rollup_staker_index_storage.get_staker_index_unsafe ctxt rollup staker
    in
    refine_stake ctxt rollup commitment ~staker_index ~lcc

  let commitment_storage_size_in_bytes = commitment_storage_size_in_bytes
end
