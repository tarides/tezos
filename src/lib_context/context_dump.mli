(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018-2020 Nomadic Labs <contact@nomadic-labs.com>           *)
(* Copyright (c) 2018-2020 Tarides <contact@tarides.com>                     *)
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

type error += System_write_error of string

type error += Bad_hash of string * Bytes.t * Bytes.t

type error += Context_not_found of Bytes.t

type error += System_read_error of string

type error += Inconsistent_snapshot_file

type error += Inconsistent_snapshot_data

type error += Missing_snapshot_data

type error += Invalid_snapshot_version of string * string

type error += Restore_context_failure

module type Dump_interface = sig
  type index

  type context

  type tree

  type hash

  type step = string

  type key = step list

  type commit_info

  type batch

  val batch : index -> (batch -> 'a Lwt.t) -> 'a Lwt.t

  val commit_info_encoding : commit_info Data_encoding.t

  val hash_encoding : hash Data_encoding.t

  module Block_header : sig
    type t = Block_header.t

    val to_bytes : t -> Bytes.t

    val of_bytes : Bytes.t -> t option

    val equal : t -> t -> bool

    val encoding : t Data_encoding.t
  end

  module Pruned_block : sig
    type t

    val to_bytes : t -> Bytes.t

    val of_bytes : Bytes.t -> t option

    val header : t -> Block_header.t

    val encoding : t Data_encoding.t
  end

  module Block_data : sig
    type t

    val to_bytes : t -> Bytes.t

    val of_bytes : Bytes.t -> t option

    val header : t -> Block_header.t

    val operations : t -> Operation.t list list

    val predecessor_header : t -> Block_header.t

    val encoding : t Data_encoding.t
  end

  module Protocol_data : sig
    type t

    val to_bytes : t -> Bytes.t

    val of_bytes : Bytes.t -> t option

    val encoding : t Data_encoding.t
  end

  module Commit_hash : sig
    type t

    val to_bytes : t -> Bytes.t

    val of_bytes : Bytes.t -> t tzresult

    val encoding : t Data_encoding.t
  end

  (* commit manipulation (for parents) *)
  val context_parents : context -> Commit_hash.t list

  (* Commit info *)
  val context_info : context -> commit_info

  (* block header manipulation *)
  val get_context : index -> Block_header.t -> context option Lwt.t

  val set_context :
    info:commit_info ->
    parents:Commit_hash.t list ->
    context ->
    Block_header.t ->
    bool Lwt.t

  (* for dumping *)
  val context_tree : context -> tree

  val tree_hash : tree -> hash

  val sub_tree : tree -> key -> tree option Lwt.t

  val tree_list : tree -> (step * [`Contents | `Node]) list Lwt.t

  val tree_content : tree -> string option Lwt.t

  (* for restoring *)
  val make_context : index -> context

  val update_context : context -> tree -> context

  val add_string : batch -> string -> tree Lwt.t

  val add_dir : batch -> (step * hash) list -> tree option Lwt.t
end

module type S = sig
  type index

  type context

  type block_header

  type block_data

  type pruned_block

  type protocol_data

  (*Dump a context and returns the number of elements written*)
  val dump_context_fd :
    index -> block_data -> context_fd:Lwt_unix.file_descr -> int tzresult Lwt.t

  val restore_context_fd :
    index ->
    ?expected_block:Block_hash.t ->
    fd:Lwt_unix.file_descr ->
    target_block:Block_hash.t ->
    nb_context_elements:int ->
    block_data tzresult Lwt.t
end

module Make (I : Dump_interface) :
  S
    with type index := I.index
     and type context := I.context
     and type block_header := I.Block_header.t
     and type block_data := I.Block_data.t
     and type pruned_block := I.Pruned_block.t
     and type protocol_data := I.Protocol_data.t

module type S_legacy = sig
  type index

  type context

  type block_header

  type block_data

  type pruned_block

  type protocol_data

  (** {b Warning} Used only to create legacy snapshots (testing purposes) *)
  val dump_contexts_fd :
    index ->
    block_header
    * block_data
    * History_mode.Legacy.t
    * (block_header ->
      (pruned_block option * protocol_data option) tzresult Lwt.t) ->
    fd:Lwt_unix.file_descr ->
    unit tzresult Lwt.t

  val restore_context_fd :
    index ->
    fd:Lwt_unix.file_descr ->
    ?expected_block:string ->
    handle_block:(History_mode.Legacy.t ->
                 Block_hash.t * pruned_block ->
                 unit tzresult Lwt.t) ->
    handle_protocol_data:(protocol_data -> unit tzresult Lwt.t) ->
    block_validation:(block_header option ->
                     Block_hash.t ->
                     pruned_block ->
                     unit tzresult Lwt.t) ->
    (block_header * block_data * Block_header.t option * History_mode.Legacy.t)
    tzresult
    Lwt.t
end

module Make_legacy (I : Dump_interface) :
  S_legacy
    with type index := I.index
     and type context := I.context
     and type block_header := I.Block_header.t
     and type block_data := I.Block_data.t
     and type pruned_block := I.Pruned_block.t
     and type protocol_data := I.Protocol_data.t