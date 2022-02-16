(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(** [Gas_input_size] includes the definitions for the different sizes used
    in the gas models of the protocol. They do not always represent memory
    sizes, but rather they can be seen as an information size. They are
    tailored to the models that use them, and should not be used for anything
    other than gas computation.
 *)

type t = int

type micheline_size = {traversal : t; int_bytes : t; string_bytes : t}

(* ------------------------------------------------------------------------- *)
(* encoding *)

val encoding : t Data_encoding.encoding

val micheline_size_encoding : micheline_size Data_encoding.encoding

(* ------------------------------------------------------------------------- *)

val zero : t

val add : t -> t -> t

val pp : Format.formatter -> t -> unit

val pp_micheline_size : Format.formatter -> micheline_size -> unit

val to_int : t -> int

val of_int : int -> t

val integer : 'a Alpha_context.Script_int.num -> t

val string : string -> t

val script_string : Alpha_context.Script_string.t -> t

val bytes : Bytes.t -> t

val mutez : Alpha_context.Tez.tez -> t

val list : 'a Script_typed_ir.boxed_list -> t

val set : 'a Script_typed_ir.set -> t

val map : ('a, 'b) Script_typed_ir.map -> t

val timestamp : Alpha_context.Script_timestamp.t -> t

val size_of_comparable_value : 'a Script_typed_ir.comparable_ty -> 'a -> t

(* ------------------------------------------------------------------------- *)
(* Micheline/Michelson-related *)

val of_micheline : ('a, 'b) Micheline.node -> micheline_size

(* ------------------------------------------------------------------------- *)
(* Sapling-related *)

val sapling_transaction_inputs : Alpha_context.Sapling.transaction -> t

val sapling_transaction_outputs : Alpha_context.Sapling.transaction -> t
