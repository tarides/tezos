(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

type error +=
  | Incompatible_history_mode of {
      requested : History_mode.t;
      stored : History_mode.t;
    }
  | Invalid_export_block of {
      block : Block_hash.t option;
      reason :
        [ `Pruned
        | `Pruned_pred
        | `Unknown
        | `Caboose
        | `Genesis
        | `Not_enough_pred ];
    }
  | (* TODO *)
      Snapshot_import_failure of string
  | Wrong_protocol_hash of Protocol_hash.t
  | Inconsistent_operation_hashes of
      (Operation_list_list_hash.t * Operation_list_list_hash.t)
  | Invalid_block_specification of string
  | Cannot_find_protocol_sources of Protocol_hash.t
  | Protocol_hash_and_protocol_sources_mismatch of {
      provided_protocol_hash : Protocol_hash.t;
      computed_protocol_hash : Protocol_hash.t;
    }
  | Provided_protocol_sources_and_embedded_protocol_sources_mismatch of {
      protocol_hash : Protocol_hash.t;
      computed_protocol_hash : Protocol_hash.t;
      computed_protocol_hash_from_embedded_sources : Protocol_hash.t;
    }

val export :
  ?rolling:bool ->
  ?block:string ->
  store_dir:string ->
  context_dir:string ->
  chain_name:Distributed_db_version.Name.t ->
  snapshot_dir:string ->
  Genesis.t ->
  unit tzresult Lwt.t

val import :
  ?patch_context:(Context.t -> Context.t tzresult Lwt.t) ->
  ?block:string ->
  snapshot_dir:string ->
  dst_store_dir:string ->
  dst_context_dir:string ->
  user_activated_upgrades:User_activated.upgrades ->
  user_activated_protocol_overrides:User_activated.protocol_overrides ->
  Genesis.t ->
  unit tzresult Lwt.t

val snapshot_info : snapshot_dir:string -> unit Lwt.t

val import_legacy :
  ?patch_context:(Context.t -> Context.t tzresult Lwt.t) ->
  ?block:string ->
  dst_store_dir:string ->
  dst_context_dir:string ->
  chain_name:Distributed_db_version.Name.t ->
  user_activated_upgrades:User_activated.upgrades ->
  user_activated_protocol_overrides:User_activated.protocol_overrides ->
  snapshot_file:string ->
  Genesis.t ->
  unit tzresult Lwt.t