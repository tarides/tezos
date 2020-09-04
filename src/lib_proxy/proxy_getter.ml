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

module Events = struct
  include Internal_event.Simple

  let section = ["proxy_getter"]

  let cache_hit =
    declare_1
      ~section
      ~name:"cache_hit"
      ~msg:"Cache hit: ({key})"
      ~level:Debug
      ("key", Data_encoding.string)

  let cache_miss =
    declare_1
      ~section
      ~name:"cache_miss"
      ~msg:"Cache miss: ({key})"
      ~level:Debug
      ("key", Data_encoding.string)

  let cache_node_miss =
    declare_1
      ~section
      ~name:"cache_node_miss"
      ~msg:"Cache node miss: ({key})"
      ~level:Debug
      ("key", Data_encoding.string)

  let cache_node_hit =
    declare_1
      ~section
      ~name:"cache_node_hit"
      ~msg:"Cache node hit: ({key})"
      ~level:Debug
      ("key", Data_encoding.string)
end

let rec raw_context_to_tree
    (raw : Tezos_shell_services.Block_services.raw_context) :
    Proxy_context.M.tree option =
  match raw with
  | Key (bytes : Bytes.t) ->
      Some (Proxy_context.M.Key bytes)
  | Cut ->
      None
  | Dir pairs ->
      let f string_map (string, raw_context) =
        let nested = raw_context_to_tree raw_context in
        match nested with
        | None ->
            string_map
        | Some u ->
            TzString.Map.add string u string_map
      in
      let dir = List.fold_left f TzString.Map.empty pairs in
      if TzString.Map.is_empty dir then None else Some (Dir dir)

type proxy_getter_input = {
  rpc_context : RPC_context.simple;
  chain : Tezos_shell_services.Block_services.chain;
  block : Tezos_shell_services.Block_services.block;
}

module type PROTO_RPC = sig
  val split_key :
    Proxy_context.M.key -> (Proxy_context.M.key * Proxy_context.M.key) option

  val do_rpc :
    proxy_getter_input ->
    Proxy_context.M.key ->
    Proxy_context.M.tree option tzresult Lwt.t
end

module type M = sig
  val proxy_dir_mem :
    proxy_getter_input -> Proxy_context.M.key -> bool tzresult Lwt.t

  val proxy_get :
    proxy_getter_input ->
    Proxy_context.M.key ->
    Proxy_context.M.tree option tzresult Lwt.t

  val proxy_mem :
    proxy_getter_input -> Proxy_context.M.key -> bool tzresult Lwt.t
end

module StringMap = TzString.Map

module Tree = struct
  let empty = Proxy_context.M.empty

  let rec raw_get m k =
    match (k, m) with
    | ([], m) ->
        Some m
    | (n :: k, Proxy_context.M.Dir m) -> (
      match StringMap.find_opt n m with
      | Some res ->
          raw_get res k
      | None ->
          None )
    | (_ :: _, Proxy_context.M.Key _) ->
        None

  let rec comb (k : StringMap.key list) (v : Proxy_context.M.tree) :
      Proxy_context.M.tree =
    match k with
    | [] ->
        v
    | k_hd :: k_tail ->
        Proxy_context.M.Dir (StringMap.singleton k_hd (comb k_tail v))

  let rec set_leaf (m : Proxy_context.M.tree) (k : StringMap.key list)
      (v : Proxy_context.M.tree) =
    match k with
    | [] ->
        v
    | k_hd :: k_tail -> (
      match m with
      | Key _ ->
          assert false
      | Dir map ->
          let k_m =
            match StringMap.find_opt k_hd map with
            | None ->
                comb k_tail v
            | Some k_hd_tree ->
                set_leaf k_hd_tree k_tail v
          in
          Proxy_context.M.Dir (StringMap.add k_hd k_m map) )
end

module RequestsTree = struct
  (** The point of this data structure is as follows:

      Suppose [Make.cache] is like this, because key A has been
      requested already and the tree at A has two nodes B and C:

      A-B
       \
        C

      If proxy_getter receives a request for A-D, there's no point doing
      a request, even if it's not there; because as A has been requested
      already; if A-D was available, it would be there already.
  
      This is a crucial optimisation that reduces the number of .../raw/bytes
      RPC requests by 90% when executing baking_rights&?all=true locally,
      after the chain starts having more than a few cycles.
      More specifically, in baking_rights, the client keeps looking for
      (missing) keys of the form rolls;owner;snapshot;10;1;74;5;1354
      while the parent key rolls;owner;snapshot;10;1 has been obtained before.

      This structure has the invariant that all leafs are [All] nodes.
      If requests A;B and A;C have been one the tree is as follows:

      A[Few] -> B[All]
         \
          \---> C[All]

      If then request A is done, the tree becomes:

      A[All]
    *)

  type tree =
    | Partial of tree StringMap.t
        (** Some longer requests have been done.
            A subset of this key's data is available *)
    | All
        (** This exact request has been done.
            All data of this key is avaiable *)

  let empty = Partial StringMap.empty

  let rec add (t : tree) (k : string list) : tree =
    match (t, k) with
    | (_, []) | (All, _) ->
        All
    | (Partial map, k_hd :: k_tail) -> (
        let sub_t_opt = StringMap.find_opt k_hd map in
        match sub_t_opt with
        | None ->
            Partial (StringMap.add k_hd (add empty k_tail) map)
        | Some (Partial _ as sub_t) ->
            Partial (StringMap.add k_hd (add sub_t k_tail) map)
        | Some All ->
            t )

  let rec find_opt (t : tree) (k : string list) : tree option =
    match (t, k) with
    | (All, _) ->
        Some All
    | (Partial _, []) ->
        None
    | (Partial map, k_hd :: k_tail) -> (
        let sub_t_opt = StringMap.find_opt k_hd map in
        match sub_t_opt with
        | None ->
            None
        | Some All ->
            Some All
        | Some (Partial _ as sub_t) -> (
          match k_tail with [] -> Some sub_t | _ -> find_opt sub_t k_tail ) )
end

module StringSet = TzString.Set

module Make (X : PROTO_RPC) : M = struct
  let cache = ref Tree.empty

  let requests = ref RequestsTree.empty

  let pp_key k = String.concat ";" k

  let is_all k =
    match RequestsTree.find_opt !requests k with
    | Some All ->
        true
    | _ ->
        false

  type kind = Get | Mem

  (** Handles the application of [X.split_key]. Performs
      the RPC call and updates [cache] accordingly. *)
  let do_rpc (pgi : proxy_getter_input) (kind : kind)
      (key : Proxy_context.M.key) : unit tzresult Lwt.t =
    let (key, split) =
      match kind with
      | Mem ->
          (* If the value is not going to be used, don't request a parent *)
          (key, false)
      | Get -> (
        match X.split_key key with
        | None ->
            (* There's no splitting for this key *)
            (key, false)
        | Some (prefix, _) ->
            (* Splitting triggers: a parent key will be requested *)
            (prefix, true) )
    in
    (* is_all has been checked (by the caller: generic_call)
       for the key received as parameter. Hence it only makes sense
       to check it if a parent key is being retrieved ('split' = true
       and hence 'key' here differs from the key received as parameter) *)
    if split && is_all key then return_unit
    else
      X.do_rpc pgi key
      >>=? fun tree_opt ->
      let pped_key = pp_key key in
      (* Remember request was done: map key to [All] in !requests
         (see [REQUESTS_TREE]'s mli for further details) *)
      requests := RequestsTree.add !requests key ;
      match tree_opt with
      | None ->
          (* This is not an error, the caller may be requesting with
             Proxy_context.mem whether some key is mapped *)
          Events.(emit cache_node_miss pped_key) >>= fun () -> return_unit
      | Some tree ->
          Events.(emit cache_node_hit pped_key)
          >>= fun () ->
          cache := Tree.set_leaf !cache key tree ;
          return_unit

  (* [generic_call] and [do_rpc] above go hand in hand. do_rpc takes
     care of performing the RPC call and updating [cache].
     generic_call calls [do_rpc] to make sure the cache is filled, and
     then queries the cache to return the desired value.
     Having them separate allows to avoid mixing the logic of
     [X.split_key] (confined to do_rpc) and the logic of getting
     the key's value. *)

  let generic_call :
      kind ->
      proxy_getter_input ->
      Proxy_context.M.key ->
      Proxy_context.M.tree option tzresult Lwt.t =
   fun (kind : kind) (pgi : proxy_getter_input) (key : Proxy_context.M.key) ->
    let pped_key = pp_key key in
    ( if is_all key then
      (* This exact request was done already.
         So data was obtained already. Note that this does not imply
         that this function will return Some (maybe the node doesn't
         map this key). *)
      Events.(emit cache_hit pped_key) >>= fun () -> return_unit
    else
      (* This exact request was NOT done already (either a longer request
         was done or no related request was done at all).
         An RPC MUST be done. *)
      Events.(emit cache_miss pped_key) >>= fun () -> do_rpc pgi kind key )
    >>=? fun () -> return @@ Tree.raw_get !cache key

  let proxy_get = generic_call Get

  let proxy_dir_mem pgi key =
    generic_call Mem pgi key
    >>=? fun tree_opt ->
    match tree_opt with
    | None ->
        return_false
    | Some (Proxy_context.M.Key _) ->
        return_false
    | Some (Proxy_context.M.Dir _) ->
        return_true

  let proxy_mem pgi key =
    generic_call Mem pgi key
    >>=? fun tree_opt ->
    match tree_opt with
    | None ->
        return_false
    | Some (Proxy_context.M.Key _) ->
        return_true
    | Some (Proxy_context.M.Dir _) ->
        return_false
end