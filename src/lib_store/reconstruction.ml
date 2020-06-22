(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2019 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

type status =
  | Reconstruct_start_default of (Block_hash.t * Int32.t)
  | Reconstruct_enum
  | Reconstruct_success

let status_pp ppf = function
  | Reconstruct_start_default (h, l) ->
      Format.fprintf
        ppf
        "Starting reconstruct from genesis toward block %a (level %ld)"
        Block_hash.pp
        h
        l
  | Reconstruct_enum ->
      Format.fprintf ppf "Enumerating all blocks to reconstruct"
  | Reconstruct_success ->
      Format.fprintf ppf "The storage was successfully reconstructed."

module Definition = struct
  let name = "reconstruction"

  type t = status Time.System.stamped

  let encoding =
    let open Data_encoding in
    Time.System.stamped_encoding
    @@ union
         [ case
             (Tag 0)
             ~title:"Reconstruct_start_default"
             (obj2
                (req "block_heash" Block_hash.encoding)
                (req "block_level" int32))
             (function
               | Reconstruct_start_default (h, l) -> Some (h, l) | _ -> None)
             (fun (h, l) -> Reconstruct_start_default (h, l));
           case
             (Tag 1)
             ~title:"Reconstruct_enum"
             empty
             (function Reconstruct_enum -> Some () | _ -> None)
             (fun () -> Reconstruct_enum);
           case
             (Tag 2)
             ~title:"Reconstruct_success"
             empty
             (function Reconstruct_success -> Some () | _ -> None)
             (fun () -> Reconstruct_success) ]

  let pp ~short:_ ppf (status : t) =
    Format.fprintf ppf "%a" status_pp status.data

  let doc = "Reconstruction status."

  let level (status : t) =
    match status.data with
    | Reconstruct_start_default _ | Reconstruct_enum | Reconstruct_success ->
        Internal_event.Notice
end

module Event_reconstruction = Internal_event.Make (Definition)

let lwt_emit (status : status) =
  let time = Systime_os.now () in
  Event_reconstruction.emit
    ~section:(Internal_event.Section.make_sanitized [Definition.name])
    (fun () -> Time.System.stamp ~time status)
  >>= function
  | Ok () ->
      Lwt.return_unit
  | Error el ->
      Format.kasprintf
        Lwt.fail_with
        "Reconstruction_event.emit: %a"
        pp_print_error
        el

open Reconstruction_errors

(* The status of a metadata. It is:
   - Complete: all the metadata of the corresponding cycle are stored
   - Partial level: the metadata before level are missing
   - Not_stored: no metada are stored *)
type metadata_status = Complete | Partial of Int32.t | Not_stored

(* We assume that :
   - a cemented metadata cycle is partial if, at least, the first
     metadata of the cycle (start_level) is missing.
   - there only exists a contiguous set of empty metadata *)
let cemented_metadata_status cemented_store = function
  | {Cemented_block_store.start_level; end_level; _} ->
      let end_metadata_opt =
        Cemented_block_store.read_block_metadata cemented_store end_level
      in
      if end_metadata_opt = None then Not_stored
      else
        let start_metadata_opt =
          Cemented_block_store.read_block_metadata cemented_store end_level
        in
        if start_metadata_opt <> None then Complete
        else
          (* TODO dicho search *)
          let rec search level =
            if level >= end_level then assert false
            else
              Cemented_block_store.read_block_metadata cemented_store level
              |> function
              | None -> search (Int32.succ level) | Some _ -> Partial level
          in
          search start_level

let check_context_hash_consistency block_validation_result block_header =
  let expected = block_header.Block_header.shell.context in
  let got = block_validation_result.Block_validation.context_hash in
  fail_unless
    (Context_hash.equal expected got)
    (Reconstruction_failure
       (Context_hash_mismatch (block_header, expected, got)))

let apply_context chain_store context_index chain_id ~user_activated_upgrades
    ~user_activated_protocol_overrides block =
  let block_header = Store.Block.header block in
  let operations = Store.Block.operations block in
  Store.Block.read_predecessor chain_store block
  >>=? fun pred_block ->
  let predecessor_block_header = Store.Block.header pred_block in
  Context.checkout_exn context_index predecessor_block_header.shell.context
  >>= fun predecessor_context ->
  Block_validation.apply
    chain_id
    ~user_activated_upgrades
    ~user_activated_protocol_overrides
    ~max_operations_ttl:(Int32.to_int (Store.Block.level pred_block))
    ~predecessor_block_header
    ~predecessor_context
    ~block_header
    operations
  >>=? fun ({validation_store; block_metadata; ops_metadata; _} :
             Block_validation.result) ->
  check_context_hash_consistency validation_store block_header
  >>=? fun () ->
  return
    {
      Store.Block.message = validation_store.message;
      max_operations_ttl = validation_store.max_operations_ttl;
      last_allowed_fork_level = validation_store.last_allowed_fork_level;
      block_metadata;
      operations_metadata = ops_metadata;
    }

let store_chunk cemented_store raw_chunk =
  Lwt_list.map_s
    (fun (block, metadata) ->
      Lwt.return ({block with metadata = Some metadata} : Block_repr.t))
    raw_chunk
  >>= fun chunk ->
  Cemented_block_store.cement_blocks_metadata cemented_store chunk

let reconstruct_complete_chunk chain_store context_index
    ~user_activated_upgrades ~user_activated_protocol_overrides ~start_level
    ~end_level =
  let block_store = Store.Unsafe.get_block_store chain_store in
  let chain_id = Store.Chain.chain_id chain_store in
  let cemented_block_store = Block_store.cemented_block_store block_store in
  let rec aux level acc =
    if level > end_level then
      store_chunk cemented_block_store (List.rev acc)
      >>=? fun () -> return_unit
    else
      Store.Block.read_block_by_level_opt chain_store level
      >>= (function
            | None ->
                failwith
                  "Cannot read block in cemented store. The storage is \
                   corrupted."
            | Some b ->
                return b)
      >>=? fun block ->
      ( if Store.Block.is_genesis chain_store (Store.Block.hash block) then
        Store.Chain.genesis_block chain_store
        >>= fun genesis_block ->
        Store.Block.get_block_metadata chain_store genesis_block
      else
        apply_context
          chain_store
          context_index
          chain_id
          ~user_activated_upgrades
          ~user_activated_protocol_overrides
          block )
      >>=? fun metadata ->
      aux
        (Int32.succ level)
        (Store.Unsafe.(repr_of_block block, metadata) :: acc)
  in
  aux start_level []

let gather_available_metadata chain_store ~start_level ~end_level =
  let rec aux level acc =
    if level > end_level then return acc
    else
      Store.Block.read_block_by_level chain_store level
      >>=? fun block ->
      Store.Block.get_block_metadata chain_store block
      >>=? fun metadata ->
      aux
        (Int32.succ level)
        ((Store.Unsafe.repr_of_block block, metadata) :: acc)
  in
  aux start_level []

let reconstruct_partial_chunk chain_store context_index
    ~user_activated_upgrades ~user_activated_protocol_overrides ~start_level
    ~end_level =
  let chain_id = Store.Chain.chain_id chain_store in
  let rec aux level acc =
    if level > end_level then return List.(rev acc)
    else
      Store.Block.read_block_by_level chain_store level
      >>=? fun block ->
      ( if Store.Block.is_genesis chain_store (Store.Block.hash block) then
        Store.Chain.genesis_block chain_store
        >>= fun genesis_block ->
        Store.Block.get_block_metadata chain_store genesis_block
      else
        apply_context
          chain_store
          context_index
          chain_id
          ~user_activated_upgrades
          ~user_activated_protocol_overrides
          block )
      >>=? fun metadata ->
      aux
        (Int32.succ level)
        ((Store.Unsafe.repr_of_block block, metadata) :: acc)
  in
  aux start_level []

let reconstruct_chunks chain_store context_index ~user_activated_upgrades
    ~user_activated_protocol_overrides =
  let block_store = Store.Unsafe.get_block_store chain_store in
  let cemented_block_store = Block_store.cemented_block_store block_store in
  let chain_dir = Store.Chain.chain_dir chain_store in
  let cemented_blocks_dir = Naming.(chain_dir // cemented_blocks_directory) in
  Cemented_block_store.load_table ~cemented_blocks_dir
  >>|? Array.to_list
  >>=? fun cemented_cycles ->
  Lwt_utils_unix.display_progress
    ~pp_print_step:(fun ppf i ->
      Format.fprintf ppf "Reconstructing cemented blocks: %i cycles rebuilt" i)
    (fun notify ->
      let rec aux = function
        | [] ->
            (* Should not happen *)
            return_unit
        | ({Cemented_block_store.start_level; end_level; _} as file) :: tl -> (
          match cemented_metadata_status cemented_block_store file with
          | Complete ->
              (* Should not happen: we should have stopped or not started *)
              return_unit
          | Partial limit ->
              (* Reconstruct it partially and the stop *)
              (* As the block at level = limit contains metadata the sub chunk
             stops before. Then, we gather the stored metadata at limit (incl.) *)
              reconstruct_partial_chunk
                chain_store
                context_index
                ~user_activated_upgrades
                ~user_activated_protocol_overrides
                ~start_level:1l
                ~end_level:Int32.(pred limit)
              >>=? fun chunk ->
              gather_available_metadata
                chain_store
                ~start_level:limit
                ~end_level
              >>=? fun read ->
              store_chunk cemented_block_store (List.append chunk read)
              >>=? fun () -> notify () >>= fun () -> return_unit
          | Not_stored ->
              (* Reconstruct it and continue *)
              reconstruct_complete_chunk
                chain_store
                context_index
                ~user_activated_upgrades
                ~user_activated_protocol_overrides
                ~start_level
                ~end_level
              >>=? fun () -> notify () >>= fun () -> aux tl )
      in
      aux cemented_cycles)

(* Reconstruct the storage without checking if the context is already
   populated. We assume that commiting an exsisting context is a
   nop. *)
let reconstruct_cemented chain_store context_index ~user_activated_upgrades
    ~user_activated_protocol_overrides =
  reconstruct_chunks
    chain_store
    context_index
    ~user_activated_upgrades
    ~user_activated_protocol_overrides

let reconstruct_floating chain_store context_index ~user_activated_upgrades
    ~user_activated_protocol_overrides =
  let chain_id = Store.Chain.chain_id chain_store in
  let chain_dir = Store.Chain.chain_dir chain_store in
  let block_store = Store.Unsafe.get_block_store chain_store in
  Floating_block_store.init ~chain_dir ~readonly:false RO_TMP
  >>= fun new_ro_store ->
  let floating_stores = Block_store.floating_block_stores block_store in
  Lwt_utils_unix.display_progress
    ~pp_print_step:(fun ppf i ->
      Format.fprintf ppf "Reconstructing floating blocks: %i" i)
    (fun notify ->
      Error_monad.iter_s
        (fun fs ->
          Floating_block_store.iter_seq
            (fun (block, predecessors) ->
              let level = Block_repr.level block in
              (* If the block is genesis then just retrieve its metadata. *)
              ( if Store.Block.is_genesis chain_store (Block_repr.hash block)
              then
                Store.Chain.genesis_block chain_store
                >>= fun genesis_block ->
                Store.Block.get_block_metadata chain_store genesis_block
              else
                (* It is needed to read the metadata using the
                   cemented_block_store to avoid the cache mechanism which
                   stores blocks without metadata *)
                let metadata_opt =
                  Cemented_block_store.read_block_metadata
                    (Block_store.cemented_block_store block_store)
                    level
                in
                match metadata_opt with
                | None ->
                    (* When the metadata is not available in the
                       cemented_block_store, it means that the block
                       (in floating) was not cemented yet. It is thus needed to
                       recompute its metadata + context *)
                    apply_context
                      chain_store
                      context_index
                      chain_id
                      ~user_activated_upgrades
                      ~user_activated_protocol_overrides
                      (Store.Unsafe.block_of_repr block)
                | Some m ->
                    return m )
              >>=? fun metadata ->
              Floating_block_store.append_block
                new_ro_store
                predecessors
                {block with metadata = Some metadata}
              >>= fun () -> notify () >>= fun () -> return_unit)
            fs
          >>=? fun () -> return_unit)
        floating_stores)
  >>=? fun () ->
  Block_store.swap_floating_store
    block_store
    ~src:new_ro_store
    ~dst_kind:Floating_block_store.RO
  >>=? fun () ->
  (* Reset the RW to an empty floating_block_store *)
  Floating_block_store.init ~chain_dir ~readonly:false RW_TMP
  >>= fun empty_rw ->
  Block_store.swap_floating_store
    block_store
    ~src:empty_rw
    ~dst_kind:Floating_block_store.RW
  >>=? fun () -> return_unit

(* Only Full modes with any offset can be reconstructed *)
let check_history_mode_compatibility chain_store =
  match Store.Chain.history_mode chain_store with
  | History_mode.(Full _) ->
      return_unit
  | _ as history_mode ->
      fail (Cannot_reconstruct history_mode)

let restore_constants chain_store genesis_block =
  Store.Unsafe.set_history_mode chain_store History_mode.Archive
  >>=? fun () ->
  let genesis = Store.Block.descriptor genesis_block in
  Store.Unsafe.set_savepoint chain_store genesis
  >>=? fun () -> Store.Unsafe.set_caboose chain_store genesis

let reconstruct ?patch_context ~store_dir ~context_dir genesis
    ~user_activated_upgrades ~user_activated_protocol_overrides =
  Store.init
    ?patch_context
    ~store_dir
    ~context_dir
    ~allow_testchains:false
    genesis
  >>=? fun store ->
  protect
    ~on_error:(fun err ->
      Store.close_store store >>= fun () -> Lwt.return (Error err))
    (fun () ->
      let context_index = Store.context_index store in
      let chain_store = Store.main_chain_store store in
      Store.Chain.genesis_block chain_store
      >>= fun genesis_block ->
      check_history_mode_compatibility chain_store
      >>=? fun () ->
      Store.Chain.savepoint chain_store
      >>= fun savepoint ->
      fail_when
        (snd savepoint = Store.Block.level genesis_block)
        (Reconstruction_failure Nothing_to_reconstruct)
      >>=? fun () ->
      lwt_emit (Reconstruct_start_default savepoint)
      >>= fun () ->
      lwt_emit Reconstruct_enum
      >>= fun () ->
      reconstruct_cemented
        chain_store
        context_index
        ~user_activated_upgrades
        ~user_activated_protocol_overrides
      >>=? fun () ->
      let chain_store = Store.main_chain_store store in
      reconstruct_floating
        chain_store
        context_index
        ~user_activated_upgrades
        ~user_activated_protocol_overrides
      >>=? fun () ->
      restore_constants chain_store genesis_block
      >>=? fun () ->
      (* TODO? add a global check *)
      lwt_emit Reconstruct_success
      >>= fun () -> Store.close_store store >>= return)