(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
module L = Logging
open PulseBasicInterface
module BaseDomain = PulseBaseDomain
module DecompilerExpr = PulseDecompilerExpr
module Decompiler = PulseDecompiler
module PathContext = PulsePathContext
module UninitBlocklist = PulseUninitBlocklist

(** {2 Unsafe part of the module implementation wrt normalization} *)

(** signature common to [PostDomain], representing the post at the current program point, and the
    inverted [PreDomain], representing the inferred pre-condition*)
module type BaseDomainSig = sig
  (* private because the lattice is not the same for preconditions and postconditions so we don't
     want to confuse them *)
  type t = private BaseDomain.t [@@deriving compare, equal, yojson_of]
end

(* defined in two parts to avoid exporting internal APIs to the .mli *)
module type BaseDomainSig_ = sig
  include BaseDomainSig

  val empty : t

  val update :
       ?stack:PulseBaseStack.t
    -> ?heap:PulseBaseMemory.t
    -> ?attrs:PulseBaseAddressAttributes.t
    -> t
    -> t

  val subst_var : for_summary:bool -> AbstractValue.t * AbstractValue.t -> t -> t SatUnsat.t

  val pp : F.formatter -> t -> unit
end

(* just to expose record field names without having to type
   [BaseDomain.heap] *)
type base_domain = BaseDomain.t =
  {heap: PulseBaseMemory.t; stack: PulseBaseStack.t; attrs: PulseBaseAddressAttributes.t}

(** represents the post abstract state at each program point *)
module PostDomain : BaseDomainSig_ = struct
  include BaseDomain

  let update ?stack ?heap ?attrs foot =
    let new_stack, new_heap, new_attrs =
      ( Option.value ~default:foot.stack stack
      , Option.value ~default:foot.heap heap
      , Option.value ~default:foot.attrs attrs )
    in
    if
      phys_equal new_stack foot.stack && phys_equal new_heap foot.heap
      && phys_equal new_attrs foot.attrs
    then foot
    else {stack= new_stack; heap= new_heap; attrs= new_attrs}
end

(* NOTE: [PreDomain] and [Domain] theoretically differ in that [PreDomain] should be the inverted lattice of [Domain], but since we never actually join states or check implication the two collapse into one (though we still want to be careful not to mix them up so give them different types). *)

(** represents the inferred pre-condition at each program point, biabduction style *)
module PreDomain : BaseDomainSig_ = PostDomain

(* see documentation in this file's .mli *)
type t =
  { post: PostDomain.t
  ; pre: PreDomain.t
  ; path_condition: Formula.t
  ; decompiler: (Decompiler.t[@yojson.opaque] [@equal.ignore] [@compare.ignore])
  ; topl: (PulseTopl.state[@yojson.opaque])
  ; need_closure_specialization: bool
  ; need_dynamic_type_specialization: (AbstractValue.Set.t[@yojson.opaque])
  ; skipped_calls: SkippedCalls.t }
[@@deriving compare, equal, yojson_of]

let pp f
    { post
    ; pre
    ; path_condition
    ; decompiler
    ; need_closure_specialization
    ; need_dynamic_type_specialization
    ; topl
    ; skipped_calls } =
  let pp_decompiler f =
    if Config.debug_level_analysis >= 3 then F.fprintf f "decompiler=%a;@;" Decompiler.pp decompiler
  in
  F.fprintf f
    "@[<v>%a@;\
     %a@;\
     PRE=[%a]@;\
     %tneed_closure_specialization=%b@;\
     need_dynamic_type_specialization=%a@;\
     skipped_calls=%a@;\
     Topl=%a@]"
    Formula.pp path_condition PostDomain.pp post PreDomain.pp pre pp_decompiler
    need_closure_specialization AbstractValue.Set.pp need_dynamic_type_specialization
    SkippedCalls.pp skipped_calls PulseTopl.pp_state topl


let leq ~lhs ~rhs =
  phys_equal lhs rhs
  || SkippedCalls.leq ~lhs:lhs.skipped_calls ~rhs:rhs.skipped_calls
     && Formula.equal lhs.path_condition rhs.path_condition
     &&
     match
       BaseDomain.isograph_map BaseDomain.empty_mapping
         ~lhs:(lhs.pre :> BaseDomain.t)
         ~rhs:(rhs.pre :> BaseDomain.t)
     with
     | NotIsomorphic ->
         false
     | IsomorphicUpTo foot_mapping ->
         BaseDomain.is_isograph foot_mapping
           ~lhs:(lhs.post :> BaseDomain.t)
           ~rhs:(rhs.post :> BaseDomain.t)


let set_path_condition path_condition astate = {astate with path_condition}

let set_need_closure_specialization astate = {astate with need_closure_specialization= true}

let unset_need_closure_specialization astate = {astate with need_closure_specialization= false}

let map_decompiler astate ~f = {astate with decompiler= f astate.decompiler}

let canon astate v = Formula.get_var_repr astate.path_condition v

(** The internals define here are safe (wrt normalization) to use but expose the
    canonical/non-canonical (sub-)types of abstract values inherited from [PulseCanonValue]. We want
    to hide these in the external API of this file and pretend everything is just an
    [AbstractValue.t] for ease of use (and because historically this was written with just
    [AbstractValue.t] so feel free to change at some point) so we confine the trickier exposed bits
    to this [Internal] module. *)
module Internal = struct
  (** Versions of the stack/heap/attributes that are safe wrt value normalization; see the
      documentation for [PulseCanonValue] *)
  module CanonValue = PulseCanonValue.Make (struct
    type astate = t

    let canon = canon
  end)

  module RawStack = PulseBaseStack
  module RawMemory = PulseBaseMemory
  module BaseStack = CanonValue.Stack
  module BaseMemory = CanonValue.Memory
  module BaseAddressAttributes = CanonValue.Attributes

  let downcast (x : CanonValue.t) : AbstractValue.t = (x :> AbstractValue.t) [@@inline always]

  let downcast_fst pair = (pair : CanonValue.t * _ :> AbstractValue.t * _) [@@inline always]

  let downcast_snd_fst pair_pair = (pair_pair : _ * (CanonValue.t * _) :> _ * (AbstractValue.t * _))
    [@@inline always]


  let downcast_access access = (access : BaseMemory.Access.t :> RawMemory.Access.t)
    [@@inline always]


  module SafeBaseMemory = struct
    module Edges = struct
      let fold astate edges ~init ~f =
        BaseMemory.Edges.fold edges ~init ~f:(fun acc access_addr_hist ->
            f acc (CanonValue.canon_snd_fst astate access_addr_hist) )


      let mapi astate edges ~f =
        BaseMemory.Edges.mapi edges ~f:(fun access addr_hist ->
            f access (CanonValue.canon_fst astate addr_hist) )
    end

    let fold_edges astate v heap ~init ~f =
      match BaseMemory.find_opt v heap with
      | None ->
          init
      | Some edges ->
          Edges.fold astate edges ~init ~f
  end

  module SafeStack = struct
    let is_abducible astate var =
      (* HACK: formals are pre-registered in the initial state *)
      BaseStack.mem var (astate.pre :> base_domain).stack || Var.is_global var


    (** [astate] with [astate.post.stack = f astate.post.stack] *)
    let map_post_stack ~f astate =
      let new_post = PostDomain.update astate.post ~stack:(f (astate.post :> base_domain).stack) in
      if phys_equal new_post astate.post then astate else {astate with post= new_post}


    let eval origin var astate =
      let astate, addr_hist =
        match BaseStack.find_opt var (astate.post :> base_domain).stack with
        | Some addr_hist ->
            (astate, addr_hist) |> CanonValue.canon_snd_fst astate
        | None ->
            let addr = CanonValue.mk_fresh () in
            let addr_hist = (addr, origin) in
            let post_stack =
              BaseStack.add var (addr_hist |> downcast_fst) (astate.post :> base_domain).stack
            in
            let post_heap = (astate.post :> base_domain).heap in
            let post_attrs = (astate.post :> base_domain).attrs in
            let pre =
              (* do not overwrite values of variables already in the pre *)
              if
                (not (BaseStack.mem var (astate.pre :> base_domain).stack))
                && is_abducible astate var
              then
                (* HACK: do not record the history of values in the pre as they are unused *)
                let foot_stack =
                  BaseStack.add var
                    (downcast addr, ValueHistory.epoch)
                    (astate.pre :> base_domain).stack
                in
                let foot_heap = BaseMemory.register_address addr (astate.pre :> base_domain).heap in
                PreDomain.update ~stack:foot_stack ~heap:foot_heap astate.pre
              else astate.pre
            in
            let post =
              PostDomain.update astate.post ~stack:post_stack ~heap:post_heap ~attrs:post_attrs
            in
            ({astate with post; pre}, addr_hist)
      in
      let astate =
        map_decompiler astate ~f:(fun decompiler ->
            Decompiler.add_var_source (fst addr_hist |> downcast) var decompiler )
      in
      (astate, addr_hist)


    let add var addr_hist astate =
      map_post_stack astate ~f:(fun stack -> BaseStack.add var addr_hist stack)


    let remove_vars vars astate =
      let vars_to_remove =
        let is_in_pre var astate = BaseStack.mem var (astate.pre :> base_domain).stack in
        List.filter vars ~f:(fun var -> not (is_in_pre var astate))
      in
      map_post_stack astate ~f:(fun stack ->
          BaseStack.filter (fun var _ -> not (List.mem ~equal:Var.equal vars_to_remove var)) stack )


    let fold_keys f astate accum =
      BaseStack.fold (fun v _ acc -> f v acc) (astate.post :> base_domain).stack accum


    let fold f astate accum =
      BaseStack.fold
        (fun var addr_hist acc -> f var (CanonValue.canon_fst astate addr_hist) acc)
        (astate.post :> base_domain).stack accum


    let find_opt var astate =
      BaseStack.find_opt var (astate.post :> base_domain).stack |> CanonValue.canon_opt_fst astate


    let mem var astate = BaseStack.mem var (astate.post :> base_domain).stack

    let map_var_address_pre proc_name astate ~f ~default pvar =
      match
        BaseStack.find_opt (Var.of_pvar pvar) (astate.pre :> base_domain).stack
        |> CanonValue.canon_opt_fst astate
      with
      | None ->
          L.d_printfln "Misnamed %a. Not found in initial_stack of %a" Pvar.pp_value pvar
            Procname.pp proc_name ;
          ( match Pvar.get_declaring_function pvar with
          | None ->
              ()
          | Some pname ->
              L.d_printfln "%a belongs to %a" Pvar.pp_value pvar Procname.pp pname ) ;
          default
      | Some addr ->
          f addr


    let exists f astate =
      BaseStack.exists
        (fun var addr_hist -> f var (CanonValue.canon_fst astate addr_hist))
        (astate.post :> base_domain).stack


    let keys astate = fold_keys List.cons astate []
  end

  module SafeAttributes = struct
    open IResult.Let_syntax

    (** if [address] is in [pre] then add the attribute [attr] *)
    let abduce_attribute (address : CanonValue.t) attribute astate =
      let is_must_be_initialized_on_written =
        match (attribute : Attribute.t) with
        | MustBeInitialized _ ->
            BaseAddressAttributes.find_opt address (astate.post :> base_domain).attrs
            |> Option.exists ~f:(fun attrs -> Attributes.get_written_to attrs |> Option.is_some)
        | _ ->
            false
      in
      let new_pre =
        if is_must_be_initialized_on_written then (
          L.d_printfln "No abducing %a:%a, the address has been written" CanonValue.pp address
            Attribute.pp attribute ;
          astate.pre )
        else (
          L.d_printfln "Abducing %a:%a" CanonValue.pp address Attribute.pp attribute ;
          if BaseMemory.mem address (astate.pre :> base_domain).heap then
            PreDomain.update astate.pre
              ~attrs:
                (BaseAddressAttributes.add_one address attribute (astate.pre :> base_domain).attrs)
          else astate.pre )
      in
      if phys_equal new_pre astate.pre then astate else {astate with pre= new_pre}


    (** [astate] with [astate.post.attrs = f astate.post.attrs] *)
    let map_post_attrs ~f astate =
      let new_post = PostDomain.update astate.post ~attrs:(f (astate.post :> base_domain).attrs) in
      if phys_equal new_post astate.post then astate else {astate with post= new_post}


    let initialize address astate =
      map_post_attrs astate ~f:(fun attrs -> BaseAddressAttributes.initialize address attrs)


    let add_one address attributes astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.add_one address attributes)


    let abduce_and_add value attrs astate =
      Attributes.fold attrs ~init:astate ~f:(fun astate attr ->
          let astate =
            if Attribute.is_suitable_for_pre attr then abduce_attribute value attr astate
            else astate
          in
          let astate =
            if Attribute.is_suitable_for_post attr then add_one value attr astate else astate
          in
          match attr with Attribute.WrittenTo _ -> initialize value astate | _ -> astate )


    let find_opt address astate =
      BaseAddressAttributes.find_opt address (astate.post :> base_domain).attrs


    let check_valid path ?must_be_valid_reason access_trace addr astate =
      let+ () = BaseAddressAttributes.check_valid addr (astate.post :> base_domain).attrs in
      (* if [address] is in [pre] and it should be valid then that fact goes in the precondition *)
      abduce_and_add addr
        (Attributes.singleton
           (MustBeValid (path.PathContext.timestamp, access_trace, must_be_valid_reason)) )
        astate


    let check_initialized path access_trace addr astate =
      let attrs = (astate.post :> base_domain).attrs in
      let+ () = BaseAddressAttributes.check_initialized addr attrs in
      let is_written_to =
        Option.exists (BaseAddressAttributes.find_opt addr attrs) ~f:(fun attrs ->
            Attribute.Attributes.get_written_to attrs |> Option.is_some )
      in
      if is_written_to then astate
      else
        abduce_attribute addr (MustBeInitialized (path.PathContext.timestamp, access_trace)) astate


    let add_taint_sink path sink trace addr astate =
      let taint_sink = Attribute.TaintSink.{time= path.PathContext.timestamp; sink; trace} in
      abduce_attribute addr (MustNotBeTainted (Attribute.TaintSinkSet.singleton taint_sink)) astate


    let get_taint_sources_and_sanitizers addr astate =
      let attrs = (astate.post :> base_domain).attrs in
      match BaseAddressAttributes.find_opt addr attrs with
      | None ->
          (Attribute.TaintedSet.empty, Attribute.TaintSanitizedSet.empty)
      | Some addr_attrs ->
          ( Attribute.Attributes.get_tainted addr_attrs
          , Attribute.Attributes.get_taint_sanitized addr_attrs )


    let get_propagate_taint_from addr astate =
      let attrs = (astate.post :> base_domain).attrs in
      let open IOption.Let_syntax in
      let* addr_attrs = BaseAddressAttributes.find_opt addr attrs in
      Attribute.Attributes.get_propagate_taint_from addr_attrs


    (** [astate] with [astate.pre.attrs = f astate.pre.attrs] *)
    let map_pre_attrs ~f astate =
      let new_pre = PreDomain.update astate.pre ~attrs:(f (astate.pre :> base_domain).attrs) in
      if phys_equal new_pre astate.pre then astate else {astate with pre= new_pre}


    let add_edge_on_src timestamp src location stack =
      match src with
      | `LocalDecl (pvar, addr_opt) -> (
        match addr_opt with
        | None ->
            let addr = CanonValue.mk_fresh () in
            let history = ValueHistory.singleton (VariableDeclared (pvar, location, timestamp)) in
            (BaseStack.add (Var.of_pvar pvar) (downcast addr, history) stack, addr)
        | Some addr ->
            (stack, addr) )
      | `Malloc addr ->
          (stack, addr)


    let rec set_uninitialized_post tenv timestamp src typ location ?(fields_prefix = RevList.empty)
        (post : PostDomain.t) =
      match typ.Typ.desc with
      | Tint _ | Tfloat _ | Tptr _ ->
          let {stack; attrs} = (post :> base_domain) in
          let stack, addr = add_edge_on_src timestamp src location stack in
          let attrs = BaseAddressAttributes.add_one addr Uninitialized attrs in
          PostDomain.update ~stack ~attrs post
      | Tstruct typ_name when UninitBlocklist.is_blocklisted_struct typ_name ->
          post
      | Tstruct (CUnion _) | Tstruct (CppClass {is_union= true}) ->
          (* Ignore union fields in the uninitialized checker *)
          post
      | Tstruct _ -> (
        match Typ.name typ |> Option.bind ~f:(Tenv.lookup tenv) with
        | None | Some {fields= [_]} ->
            (* Ignore single field structs: see D26146578 *)
            post
        | Some {fields} ->
            let stack, addr = add_edge_on_src timestamp src location (post :> base_domain).stack in
            let init = PostDomain.update ~stack post in
            List.fold fields ~init ~f:(fun (acc : PostDomain.t) (field, field_typ, _) ->
                if Fieldname.is_internal field then acc
                else
                  let field_addr = CanonValue.mk_fresh () in
                  let fields = RevList.cons field fields_prefix in
                  let history =
                    ValueHistory.singleton (StructFieldAddressCreated (fields, location, timestamp))
                  in
                  let heap =
                    BaseMemory.add_edge addr (HilExp.Access.FieldAccess field)
                      (downcast field_addr, history)
                      (acc :> base_domain).heap
                  in
                  PostDomain.update ~heap acc
                  |> set_uninitialized_post tenv timestamp (`Malloc field_addr) field_typ location
                       ~fields_prefix:fields ) )
      | Tarray _ | Tvoid | Tfun | TVar _ ->
          (* We ignore tricky types to mark uninitialized addresses. *)
          post


    let invalidate address invalidation location astate =
      map_post_attrs ~f:(BaseAddressAttributes.invalidate address invalidation location) astate


    let always_reachable address astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.always_reachable address)


    let allocate allocator address location astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.allocate allocator address location)


    let java_resource_release address astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.java_resource_release address)


    let hack_async_await address astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.hack_async_await address)


    let csharp_resource_release address astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.csharp_resource_release address)


    let get_dynamic_type addr astate =
      BaseAddressAttributes.get_dynamic_type (astate.post :> base_domain).attrs addr


    let get_dynamic_type_source_file addr astate =
      BaseAddressAttributes.get_dynamic_type_source_file (astate.post :> base_domain).attrs addr


    let get_static_type addr astate =
      BaseAddressAttributes.get_static_type (astate.post :> base_domain).attrs addr


    let get_allocation addr astate =
      BaseAddressAttributes.get_allocation addr (astate.post :> base_domain).attrs


    let get_copied_into addr astate =
      BaseAddressAttributes.get_copied_into addr (astate.post :> base_domain).attrs


    let get_copied_return addr astate =
      BaseAddressAttributes.get_copied_return addr (astate.post :> base_domain).attrs


    let remove_copied_return addr astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.remove_copied_return addr)


    let get_must_be_valid addr astate =
      match BaseAddressAttributes.get_must_be_valid addr (astate.pre :> base_domain).attrs with
      | Some _ as must_be_valid ->
          must_be_valid
      | None ->
          BaseAddressAttributes.get_must_be_valid addr (astate.post :> base_domain).attrs


    let get_source_origin_of_copy addr astate =
      BaseAddressAttributes.get_source_origin_of_copy addr (astate.post :> base_domain).attrs


    let add_dynamic_type typ address astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.add_dynamic_type typ address)


    let add_dynamic_type_source_file typ source_file address astate =
      map_post_attrs astate
        ~f:(BaseAddressAttributes.add_dynamic_type_source_file typ source_file address)


    let add_static_type typ address astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.add_static_type typ address)


    let add_ref_counted address astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.add_ref_counted address)


    let is_ref_counted addr astate =
      BaseAddressAttributes.is_ref_counted addr (astate.post :> base_domain).attrs


    let remove_allocation_attr address astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.remove_allocation_attr address)


    let remove_taint_attrs address astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.remove_taint_attrs address)


    let add_one address attributes astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.add_one address attributes)


    let remove_must_be_valid_attr address astate =
      map_pre_attrs astate ~f:(BaseAddressAttributes.remove_must_be_valid_attr address)


    let get_closure_proc_name addr astate =
      BaseAddressAttributes.get_closure_proc_name addr (astate.post :> base_domain).attrs


    let std_vector_reserve addr astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.std_vector_reserve addr)


    let is_java_resource_released addr astate =
      BaseAddressAttributes.is_java_resource_released addr (astate.post :> base_domain).attrs


    let is_csharp_resource_released addr astate =
      BaseAddressAttributes.is_csharp_resource_released addr (astate.post :> base_domain).attrs


    let is_std_vector_reserved addr astate =
      BaseAddressAttributes.is_std_vector_reserved addr (astate.post :> base_domain).attrs


    let mark_as_end_of_collection addr astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.mark_as_end_of_collection addr)


    let add_unreachable_at addr location astate =
      map_post_attrs astate ~f:(BaseAddressAttributes.add_unreachable_at addr location)


    let is_end_of_collection addr astate =
      BaseAddressAttributes.is_end_of_collection addr (astate.post :> base_domain).attrs


    let add_copied_return addr ~source ~is_const_ref from location astate =
      map_post_attrs astate
        ~f:(BaseAddressAttributes.add_copied_return addr ~source ~is_const_ref from location)


    let get_config_usage addr astate =
      BaseAddressAttributes.get_config_usage addr (astate.post :> base_domain).attrs


    let get_const_string addr astate =
      BaseAddressAttributes.get_const_string addr (astate.post :> base_domain).attrs


    let add_attrs value attrs astate =
      let astate =
        match Attributes.get_invalid attrs with
        | Some _ ->
            remove_must_be_valid_attr value astate |> remove_allocation_attr value
        | None ->
            astate
      in
      Attributes.fold attrs ~init:astate ~f:(fun astate attr ->
          let astate = add_one value attr astate in
          match attr with Attribute.WrittenTo _ -> initialize value astate | _ -> astate )


    let get_valid_returned_from_unknown addr astate =
      let open IOption.Let_syntax in
      let+ returned_from =
        BaseAddressAttributes.get_returned_from_unknown addr (astate.post :> base_domain).attrs
      in
      List.filter
        ~f:(fun addr ->
          let addr = CanonValue.canon' astate addr in
          BaseAddressAttributes.check_valid addr (astate.post :> base_domain).attrs |> is_ok )
        returned_from


    let get_written_to addr astate =
      BaseAddressAttributes.get_written_to addr (astate.post :> base_domain).attrs


    let is_copied_from_const_ref addr astate =
      BaseAddressAttributes.is_copied_from_const_ref addr (astate.post :> base_domain).attrs


    let is_std_moved addr astate =
      BaseAddressAttributes.is_std_moved addr (astate.post :> base_domain).attrs


    let get_address_of_stack_variable addr astate =
      BaseAddressAttributes.get_address_of_stack_variable addr (astate.post :> base_domain).attrs
  end

  module SafeMemory = struct
    module Access = BaseMemory.Access

    (** [astate] with [astate.post.heap = f astate.post.heap] *)
    let map_post_heap ~f astate =
      let new_post = PostDomain.update astate.post ~heap:(f (astate.post :> base_domain).heap) in
      if phys_equal new_post astate.post then astate else {astate with post= new_post}


    let add_edge {PathContext.timestamp} (addr, history) access new_addr_hist location astate =
      map_post_heap astate ~f:(BaseMemory.add_edge addr access new_addr_hist)
      |> SafeAttributes.map_post_attrs
           ~f:
             (BaseAddressAttributes.add_one addr
                (WrittenTo (timestamp, Trace.Immediate {location; history})) )


    let find_edge_opt address access astate =
      let get_var_repr v = Formula.get_var_repr astate.path_condition v in
      BaseMemory.find_edge_opt ~get_var_repr address access (astate.post :> base_domain).heap
      |> CanonValue.canon_opt_fst astate


    let eval_edge (addr_src, hist_src) access astate =
      let astate, addr_hist_dst =
        match find_edge_opt addr_src access astate with
        | Some addr_hist_dst ->
            (astate, addr_hist_dst)
        | None ->
            let addr_dst = CanonValue.mk_fresh () in
            let addr_hist_dst = (addr_dst, hist_src) in
            let post_heap =
              BaseMemory.add_edge addr_src access (downcast_fst addr_hist_dst)
                (astate.post :> base_domain).heap
            in
            let foot_heap =
              if BaseMemory.mem addr_src (astate.pre :> base_domain).heap then
                (* HACK: do not record the history of values in the pre as they are unused *)
                BaseMemory.add_edge addr_src access
                  (downcast addr_dst, ValueHistory.epoch)
                  (astate.pre :> base_domain).heap
                |> BaseMemory.register_address addr_dst
              else (astate.pre :> base_domain).heap
            in
            let astate =
              (* This is the first time we are accessing addr_dst. Because it is accessed
                 via addr_src, it should be tainted the same as is addr_src. This is to be
                 consistent with how sources work: if addr_dst would have been accessed
                 before tainting addr_scr, then it would have been tainted as well *)
              let taint_sources, taint_sanitizers =
                SafeAttributes.get_taint_sources_and_sanitizers addr_src astate
              in
              let conditionally_add condition attr astate =
                if condition then SafeAttributes.add_one addr_dst attr astate else astate
              in
              let open Attribute in
              conditionally_add
                (not (TaintedSet.is_empty taint_sources))
                (Tainted taint_sources) astate
              |> conditionally_add
                   (not (TaintSanitizedSet.is_empty taint_sanitizers))
                   (TaintSanitized taint_sanitizers)
            in
            ( { astate with
                post= PostDomain.update astate.post ~heap:post_heap
              ; pre= PreDomain.update astate.pre ~heap:foot_heap }
            , addr_hist_dst )
      in
      let astate =
        map_decompiler astate ~f:(fun decompiler ->
            Decompiler.add_access_source
              (fst addr_hist_dst |> downcast)
              (downcast_access access) ~src:(downcast addr_src) (astate.post :> base_domain).attrs
              decompiler )
      in
      (astate, addr_hist_dst)


    let fold_edges address astate ~init ~f =
      SafeBaseMemory.fold_edges astate address (astate.post :> base_domain).heap ~init ~f


    let iter_edges v astate ~f = Container.iter ~fold:(fold_edges v) astate ~f

    let exists_edge v astate ~f = Container.exists ~iter:(iter_edges v) astate ~f
  end

  let add_static_types tenv astate formals_and_captured =
    let record_static_type astate (_var, typ, (src_addr, _)) =
      match typ with
      | {Typ.desc= Tptr ({desc= Tstruct typ_name}, _)} ->
          let pre_heap = (astate.pre :> BaseDomain.t).heap in
          let post_heap = (astate.post :> BaseDomain.t).heap in
          let addr = CanonValue.mk_fresh () in
          (* safe because this is for creating the initial state only *)
          let[@alert "-deprecated"] src_addr = CanonValue.unsafe_cast src_addr in
          let pre_heap =
            BaseMemory.add_edge src_addr Dereference (downcast addr, ValueHistory.epoch) pre_heap
            |> BaseMemory.register_address addr
          in
          let post_heap =
            BaseMemory.add_edge src_addr Dereference (downcast addr, ValueHistory.epoch) post_heap
          in
          let astate =
            { astate with
              pre= PreDomain.update ~heap:pre_heap astate.pre
            ; post= PostDomain.update ~heap:post_heap astate.post }
          in
          let is_final =
            Tenv.lookup tenv typ_name
            |> Option.value_map ~default:false ~f:(fun {Struct.annots} ->
                   Annot.Item.is_final annots )
          in
          if is_final then SafeAttributes.add_dynamic_type (Typ.mk_struct typ_name) addr astate
          else SafeAttributes.add_static_type typ_name addr astate
      | _ ->
          astate
    in
    List.fold formals_and_captured ~init:astate ~f:record_static_type


  let apply_specialization proc_name specialization astate =
    match specialization with
    | None ->
        astate
    | Some (Specialization.Pulse.Aliases aliases) ->
        (* If a function is alias-specialized, then we want to make sure all the captured
           variables and parameters aliasing each other share the same memory. To do so, we
           simply add a dereference access from each aliasing variables' address to the same
           address in the pre and the post of the initial state.

           e.g. f(x, y) with the aliasing information x = y will have the following pre:
             roots={ &x=v1, &y=v2 };
             mem  ={ v1 -> { * -> v3 }, v2 -> { * -> v3 }, v3 -> { } };
             attrs={ };
        *)
        let pre_heap = (astate.pre :> base_domain).heap in
        let post_heap = (astate.post :> base_domain).heap in
        let pre_heap, post_heap =
          List.fold aliases ~init:(pre_heap, post_heap) ~f:(fun (pre_heap, post_heap) alias ->
              let pre_heap, post_heap, _ =
                List.fold alias ~init:(pre_heap, post_heap, None)
                  ~f:(fun ((pre_heap, post_heap, addr) as acc) pvar ->
                    SafeStack.map_var_address_pre proc_name astate pvar ~default:acc
                      ~f:(fun (src_addr, addr_hist) ->
                        let addr =
                          match addr with None -> CanonValue.mk_fresh () | Some addr -> addr
                        in
                        let pre_heap =
                          BaseMemory.add_edge src_addr Dereference
                            (downcast addr, ValueHistory.epoch)
                            pre_heap
                          |> BaseMemory.register_address addr
                        in
                        let post_heap =
                          BaseMemory.add_edge src_addr Dereference
                            (downcast addr, addr_hist)
                            post_heap
                        in
                        (pre_heap, post_heap, Some addr) ) )
              in
              (pre_heap, post_heap) )
        in
        { astate with
          pre= PreDomain.update ~heap:pre_heap astate.pre
        ; post= PostDomain.update ~heap:post_heap astate.post }
    | Some (Specialization.Pulse.DynamicTypes dtypes) ->
        let pre = (astate.pre :> base_domain) in
        let post = (astate.post :> base_domain) in
        let add_edge_in_pre_and_post pre_heap post_heap src_addr access =
          match BaseMemory.find_edge_opt src_addr access pre_heap with
          | Some (addr, _) ->
              (pre_heap, post_heap, CanonValue.canon astate addr)
          | None ->
              let addr = CanonValue.mk_fresh () in
              let pre_heap =
                BaseMemory.add_edge src_addr access (downcast addr, ValueHistory.epoch) pre_heap
                |> BaseMemory.register_address addr
              in
              let post_heap =
                BaseMemory.add_edge src_addr access (downcast addr, ValueHistory.epoch) post_heap
              in
              (pre_heap, post_heap, addr)
        in
        let rec initialize_heap_path heap_path (pre_heap, post_heap) =
          match (heap_path : Specialization.HeapPath.t) with
          | Pvar pvar ->
              SafeStack.map_var_address_pre proc_name astate pvar
                ~default:(pre_heap, post_heap, None) ~f:(fun (addr, _) ->
                  (pre_heap, post_heap, Some addr) )
          | FieldAccess (fieldname, heap_path) ->
              let pre_heap, post_heap, opt_addr =
                initialize_heap_path heap_path (pre_heap, post_heap)
              in
              Option.value_map opt_addr ~default:(pre_heap, post_heap, None) ~f:(fun src_addr ->
                  let access = HilExp.Access.FieldAccess fieldname in
                  let pre_heap, post_heap, addr =
                    add_edge_in_pre_and_post pre_heap post_heap src_addr access
                  in
                  (pre_heap, post_heap, Some addr) )
          | Dereference heap_path ->
              let pre_heap, post_heap, opt_addr =
                initialize_heap_path heap_path (pre_heap, post_heap)
              in
              Option.value_map opt_addr ~default:(pre_heap, post_heap, None) ~f:(fun src_addr ->
                  let pre_heap, post_heap, addr =
                    add_edge_in_pre_and_post pre_heap post_heap src_addr Dereference
                  in
                  (pre_heap, post_heap, Some addr) )
        in
        let pre_heap, post_heap, attrs =
          Specialization.HeapPath.Map.fold
            (fun heap_path typename (pre_heap, post_heap, attrs) ->
              let pre_heap, post_heap, opt_addr =
                initialize_heap_path heap_path (pre_heap, post_heap)
              in
              let attrs =
                Option.value_map opt_addr ~default:attrs ~f:(fun addr ->
                    let typ = Typ.mk_struct typename in
                    BaseAddressAttributes.add_dynamic_type typ addr attrs )
              in
              (pre_heap, post_heap, attrs) )
            dtypes (pre.heap, post.heap, post.attrs)
        in
        { astate with
          pre= PreDomain.update ~heap:pre_heap ~attrs astate.pre
        ; post= PostDomain.update ~heap:post_heap ~attrs astate.post }


  let check_memory_leaks ~live_addresses ~unreachable_addresses astate =
    let reaches_into addr addrs astate =
      AbstractValue.Set.mem addr addrs
      || BaseDomain.GraphVisit.fold_from_addresses (Seq.return addr) astate ~init:()
           ~already_visited:AbstractValue.Set.empty
           ~finish:(fun () -> (* didn't find any reachable address in [addrs] *) false)
           ~f:(fun () addr' rev_accesses ->
             (* We want to know if [addr] is still reachable from the value [addr'] by pointer
                arithmetic, hence detect if [addr'] is an offset away from [addr]. In particular, if
                we go through a [Dereference] then we have lost the connexion to the original
                address value.

                TODO: this should be part of [live_addresses] since all these addresses are actually
                live. *)
             let can_recover_root_from_accesses =
               List.for_all rev_accesses ~f:(fun (access : RawMemory.Access.t) ->
                   match access with FieldAccess _ | ArrayAccess _ -> true | _ -> false )
             in
             if can_recover_root_from_accesses then
               if AbstractValue.Set.mem addr' addrs then (
                 L.d_printfln ~color:Orange "Live address %a is reachable from %a" AbstractValue.pp
                   addr' AbstractValue.pp addr ;
                 Stop true )
               else Continue ()
             else Stop false )
         |> snd
    in
    let check_memory_leak addr attributes =
      let allocated_not_freed_opt = Attributes.get_allocated_not_freed attributes in
      match allocated_not_freed_opt with
      | None ->
          Ok ()
      | Some (allocator, trace) ->
          (* allocated but not freed => leak *)
          L.d_printfln ~color:Red "LEAK: unreachable address %a was allocated by %a" CanonValue.pp
            addr Attribute.pp_allocator allocator ;
          (* last-chance checks: it could be that the value (or its canonical equal) is reachable via
             pointer arithmetic from live values. This is common in libraries that do their own memory
             management, e.g. they return a field of the malloc()'d pointer, and the latter is a fat
             pointer with, say, a reference count. For example in C:

             {[
              struct fat_int {
                size_t count;
                int data;
              };

              int *alloc_int() {
                fat_int *p = malloc(...);
                p->count = 1;
                return &(p->data);
              }
             ]}

             We don't have a precise enough memory model to understand everything that
             goes on here but we should at least not report a leak. *)
          if reaches_into (downcast addr) live_addresses (astate.post :> BaseDomain.t) then (
            L.d_printfln ~color:Orange
              "False alarm: address is still reachable via other means; forgetting about its \
               allocation site to prevent leak false positives." ;
            Ok () )
          else
            (* if the address became unreachable at a known point use that location *)
            let location = Attributes.get_unreachable_at attributes in
            Error (location, allocator, trace)
    in
    List.fold_result unreachable_addresses ~init:() ~f:(fun () addr ->
        let addr = CanonValue.canon' astate addr in
        match SafeAttributes.find_opt addr astate with
        | Some unreachable_attrs ->
            check_memory_leak addr unreachable_attrs
        | None ->
            Ok () )


  (* A retain cycle is a memory path from an address to itself, following only
     strong references. From that definition, detecting them can be made
     trivial:
     Given an address and a list of adresses seen on the path, if the adress is
     part of the path then it is part of a retain cycle. Otherwise add that
     adress to the path and reiterate for each strongly referenced adresses
     there is from that adress. Explore paths starting from all dead addresses
     (if an address is still reachable from outside the function, then the
     cycle could be broken).
     To improve on that simple algorithm, we can keep track of another marker
     to indicate adresses that have already been explored to indicate there
     will not be any retain cycle to be found down that path and skip it.
     This is handled by [check_retain_cycle] which will recursively explore
     paths from a given adress and mark explored adresses in the [checked]
     list. This function is called over all the [dead_addresses].

     When reporting a retain cycle, we want to give the location of its
     creation, therefore we need to remember location of the latest assignement
     in the cycle *)
  let check_retain_cycles ~dead_addresses tenv astate =
    let get_assignment_trace addr =
      match SafeAttributes.find_opt addr astate with
      | None ->
          None
      | Some attributes ->
          Attributes.get_written_to attributes |> Option.map ~f:snd
    in
    let compare_traces trace1 trace2 =
      let loc1 = Trace.get_outer_location trace1 in
      let loc2 = Trace.get_outer_location trace2 in
      let compared_locs = Location.compare loc2 loc1 in
      if Int.equal compared_locs 0 then Trace.compare trace1 trace2 else compared_locs
    in
    (* remember explored adresses to avoid reexploring path without retain cycles *)
    let checked = ref AbstractValue.Set.empty in
    let check_retain_cycle src_addr =
      let rec contains_cycle decompiler ~assignment_traces ~seen (addr : CanonValue.t) =
        (* [decompiler] is a decompiler filled during the look out for a cycle
           [assignment_traces] tracks the assignments met in the retain cycle
           [seen] tracks addresses met in the current path
           [addr] is the address to explore
        *)
        if AbstractValue.Set.mem (downcast addr) !checked then Ok ()
        else
          let value = Decompiler.find (downcast addr) astate.decompiler in
          let is_known = not (DecompilerExpr.is_unknown value) in
          let is_seen = AbstractValue.Set.mem (downcast addr) seen in
          let is_ref_counted =
            Option.exists ~f:Attributes.is_ref_counted (SafeAttributes.find_opt addr astate)
          in
          if is_known && is_seen && is_ref_counted then
            let assignment_traces = List.dedup_and_sort ~compare:compare_traces assignment_traces in
            match assignment_traces with
            | [] ->
                Ok ()
            | most_recent_trace :: _ ->
                let location = Trace.get_outer_location most_recent_trace in
                let path = Decompiler.find (downcast addr) decompiler in
                Error (assignment_traces, value, path, location)
          else (
            if is_seen && ((not is_known) || not is_ref_counted) then
              (* add the `UNKNOWN` address at which we have found a cycle to the [checked]
                 list in case we would have a cycle of `UNKNOWN` addresses, to avoid
                 looping forever. Also add the not ref_counted addresses to checked, since
                 we could loop forever otherwise *)
              checked := AbstractValue.Set.add (downcast addr) !checked ;
            let res =
              match BaseMemory.find_opt addr (astate.post :> BaseDomain.t).heap with
              | None ->
                  Ok ()
              | Some edges_pre ->
                  BaseMemory.Edges.fold ~init:(Ok ()) edges_pre
                    ~f:(fun acc (access, (accessed_addr, _)) ->
                      let accessed_addr = CanonValue.canon astate accessed_addr in
                      match acc with
                      | Error _ ->
                          acc
                      | Ok () ->
                          if BaseMemory.Access.is_strong_access tenv access then
                            let assignment_traces =
                              match access with
                              | HilExp.Access.FieldAccess _ -> (
                                match get_assignment_trace accessed_addr with
                                | None ->
                                    assignment_traces
                                | Some assignment_trace ->
                                    assignment_trace :: assignment_traces )
                              | _ ->
                                  assignment_traces
                            in
                            let decompiler =
                              Decompiler.add_access_source (downcast accessed_addr)
                                (downcast_access access) ~src:(downcast addr)
                                (astate.post :> base_domain).attrs decompiler
                            in
                            let seen = AbstractValue.Set.add (downcast addr) seen in
                            contains_cycle decompiler ~assignment_traces ~seen accessed_addr
                          else Ok () )
            in
            (* all paths down [addr] have been explored *)
            checked := AbstractValue.Set.add (downcast addr) !checked ;
            res )
      in
      let seen = AbstractValue.Set.empty in
      contains_cycle astate.decompiler ~assignment_traces:[] ~seen src_addr
    in
    List.fold_result dead_addresses ~init:() ~f:(fun () addr ->
        let addr = CanonValue.canon' astate addr in
        match SafeAttributes.find_opt addr astate with
        | None ->
            Ok ()
        | Some attributes ->
            (* retain cycles exist in the context of reference counting *)
            if Attributes.is_ref_counted attributes then check_retain_cycle addr else Ok () )


  let get_all_addrs_marked_as_always_reachable {post} =
    BaseAddressAttributes.fold
      (fun address attr addresses ->
        if Attributes.is_always_reachable attr then Seq.cons address addresses else addresses )
      (post :> BaseDomain.t).attrs Seq.empty


  let filter_pre_addr ~f (foot : PreDomain.t) =
    let heap' = BaseMemory.filter (fun address _ -> f address) (foot :> BaseDomain.t).heap in
    let attrs' =
      BaseAddressAttributes.filter (fun address _ -> f address) (foot :> BaseDomain.t).attrs
    in
    PreDomain.update ~heap:heap' ~attrs:attrs' foot


  let filter_post_addr_with_discarded_addrs ~heap_only ~f (foot : PostDomain.t) =
    let heap' = PulseBaseMemory.filter (fun address _ -> f address) (foot :> BaseDomain.t).heap in
    let attrs', discarded_addresses =
      if heap_only then ((foot :> BaseDomain.t).attrs, [])
      else PulseBaseAddressAttributes.filter_with_discarded_addrs f (foot :> BaseDomain.t).attrs
    in
    (PostDomain.update ~heap:heap' ~attrs:attrs' foot, discarded_addresses)


  let get_reachable ({pre; post} as astate) =
    let pre_addresses = BaseDomain.reachable_addresses (pre :> BaseDomain.t) in
    let post_addresses = BaseDomain.reachable_addresses (post :> BaseDomain.t) in
    let post_addresses =
      (* Also include post addresses reachable from pre addresses *)
      BaseDomain.reachable_addresses_from
        (AbstractValue.Set.to_seq pre_addresses)
        (post :> BaseDomain.t)
        ~already_visited:post_addresses
    in
    let always_reachable_addresses =
      (get_all_addrs_marked_as_always_reachable astate : CanonValue.t Seq.t :> AbstractValue.t Seq.t)
    in
    let always_reachable_trans_closure =
      BaseDomain.reachable_addresses_from always_reachable_addresses
        (post :> BaseDomain.t)
        ~already_visited:post_addresses
    in
    let canon_addresses =
      AbstractValue.Set.map (Formula.get_var_repr astate.path_condition) pre_addresses
      |> AbstractValue.Set.fold
           (fun addr acc ->
             AbstractValue.Set.add (Formula.get_var_repr astate.path_condition addr) acc )
           post_addresses
    in
    (pre_addresses, post_addresses, always_reachable_trans_closure, canon_addresses)


  let discard_unreachable_ ~for_summary ({pre; post} as astate) =
    let pre_addresses, post_addresses, always_reachable_trans_closure, canon_addresses =
      get_reachable astate
    in
    let is_live address =
      AbstractValue.Set.mem address pre_addresses
      || AbstractValue.Set.mem address post_addresses
      || AbstractValue.Set.mem address always_reachable_trans_closure
      ||
      let canon_addr = Formula.get_var_repr astate.path_condition address in
      AbstractValue.Set.mem canon_addr canon_addresses
    in
    let pre_new =
      filter_pre_addr ~f:(fun address -> AbstractValue.Set.mem (downcast address) pre_addresses) pre
    in
    let post_new, dead_addresses =
      (* keep attributes of dead addresses unless we are creating a summary *)
      filter_post_addr_with_discarded_addrs ~heap_only:(not for_summary) ~f:is_live post
    in
    (* note: we don't call {!Formula.simplify} *)
    let astate =
      if phys_equal pre_new pre && phys_equal post_new post then astate
      else {astate with pre= pre_new; post= post_new}
    in
    (astate, pre_addresses, post_addresses, dead_addresses)


  let is_local var astate = not (Var.is_return var || SafeStack.is_abducible astate var)

  (** Inside a function, formals can be used as local variables. But when exiting the function, the
      initial values of formals must be restored. This recreates the graph structure from addresses
      of formals in the precondition into the post-condition, up to the first dereference. The
      reason for this complexity is purely to handle formals that are struct values. For example, if
      [pre=&x=vx, vx --.f-> v1 --.g-> v2 --*-> v3] and
      [post = &x=vx, vx --.f-> v1 --.g-> v2 --*-> v4, vx --.h->v5] then we change [post] to
      [vx --.f-> v1 --.g-> v2 --*-> v3] (i.e. [post]=[pre]). *)
  let restore_formals_for_summary pname location astate =
    (* The [visited] accumulator is to avoid cycles; they are impossible in theory at the moment but
       this could change. *)
    let rec restore_pre_var_value visited ~is_value_visible_outside (addr : CanonValue.t) astate =
      if AbstractValue.Set.mem (downcast addr) visited then (
        L.internal_error
          "Found a cycle when restoring the values of formals, how did this happen?@\n\
           Analyzing %a at %a@\n\
           %a@\n"
          Procname.pp pname Location.pp location pp astate ;
        astate )
      else
        let visited = AbstractValue.Set.add (downcast addr) visited in
        let pre_heap = (astate.pre :> BaseDomain.t).heap in
        let post_heap = (astate.post :> BaseDomain.t).heap in
        match BaseMemory.find_opt addr pre_heap with
        | None ->
            if is_value_visible_outside then astate
            else
              SafeMemory.map_post_heap astate ~f:(fun post_heap -> BaseMemory.remove addr post_heap)
        | Some pre_edges ->
            BaseMemory.Edges.fold pre_edges ~init:astate ~f:(fun astate (access, addr_hist_dest) ->
                let ((addr_dest, _) as addr_hist_dest) =
                  CanonValue.canon_fst astate addr_hist_dest
                in
                match access with
                | Dereference ->
                    (* dereference: we reached the actual value and are done *)
                    if is_value_visible_outside && BaseMemory.has_edge addr access post_heap then
                      (* the changes are visible even outside of the procedure: do not restore the pre value
                         if the post has a value for this access too *)
                      astate
                    else
                      SafeMemory.map_post_heap astate ~f:(fun post_heap ->
                          BaseMemory.add_edge addr access (downcast_fst addr_hist_dest) post_heap )
                | FieldAccess _ | ArrayAccess _ ->
                    (* inlined aggregate value: just an offset, not the actual value yet; recurse *)
                    SafeMemory.map_post_heap astate ~f:(fun post_heap ->
                        BaseMemory.add_edge addr access (downcast_fst addr_hist_dest) post_heap )
                    |> restore_pre_var_value visited ~is_value_visible_outside addr_dest
                | TakeAddress ->
                    assert false )
    in
    let restore_pre_var x addr_hist astate =
      (* the address of a variable never changes *)
      let ((addr, _) as addr_hist) = CanonValue.canon_fst astate addr_hist in
      let astate = SafeStack.add x (downcast_fst addr_hist) astate in
      restore_pre_var_value AbstractValue.Set.empty
        ~is_value_visible_outside:(Var.is_global x || Var.is_return x)
        addr astate
    in
    let post_stack =
      BaseStack.filter
        (fun var _ -> Var.appears_in_source_code var && not (is_local var astate))
        (astate.post :> BaseDomain.t).stack
    in
    BaseStack.fold restore_pre_var (astate.pre :> BaseDomain.t).stack
      {astate with post= PostDomain.update ~stack:post_stack astate.post}


  let add_out_of_scope_attribute addr pvar location history heap typ =
    BaseAddressAttributes.add_one addr
      (Invalid (GoneOutOfScope (pvar, typ), Immediate {location; history}))
      heap


  (** invalidate local variables going out of scope *)
  let invalidate_locals locals astate : t =
    let attrs : BaseAddressAttributes.t = (astate.post :> BaseDomain.t).attrs in
    let attrs' =
      BaseAddressAttributes.fold
        (fun addr attrs acc ->
          Attributes.get_address_of_stack_variable attrs
          |> Option.value_map ~default:acc ~f:(fun (var, location, history) ->
                 let get_local_typ_opt pvar =
                   List.find_map locals ~f:(fun ProcAttributes.{name; typ; modify_in_block} ->
                       if (not modify_in_block) && Mangled.equal name (Pvar.get_name pvar) then
                         Some typ
                       else None )
                 in
                 match var with
                 | Var.ProgramVar pvar ->
                     get_local_typ_opt pvar
                     |> Option.value_map ~default:acc
                          ~f:(add_out_of_scope_attribute addr pvar location history acc)
                 | _ ->
                     acc ) )
        attrs attrs
    in
    if phys_equal attrs attrs' then astate
    else {astate with post= PostDomain.update astate.post ~attrs:attrs'}


  let is_heap_allocated {post; pre} v =
    RawMemory.is_allocated (post :> BaseDomain.t).heap v
    || RawMemory.is_allocated (pre :> BaseDomain.t).heap v


  let is_stack_allocated stack_allocations v =
    AbstractValue.Set.mem v (Lazy.force stack_allocations)


  let subst_var_in_post subst astate =
    let open SatUnsat.Import in
    let+ post = PostDomain.subst_var ~for_summary:false subst astate.post in
    if phys_equal astate.post post then astate else {astate with post}


  let get_stack_allocated astate =
    (* OPTIM: the post stack contains at least the pre stack so no need to check both *)
    SafeStack.fold
      (fun var (address, _) allocated ->
        if Var.is_pvar var then AbstractValue.Set.add (downcast address) allocated else allocated )
      astate AbstractValue.Set.empty


  let check_new_eqs (eqs : Formula.new_eq list) =
    let module V = struct
      module K = struct
        type t = AbstractValue.t option [@@deriving compare, equal]

        let pp = Fmt.option ~none:(Fmt.any "0") AbstractValue.pp
      end

      include K
      module Map = PrettyPrintable.MakePPMap (K)
    end in
    (* We build a more uniform representation of [new_eq]; [None] represents 0. *)
    let eqs =
      let f (e : Formula.new_eq) =
        match e with Equal (a, b) -> (Some a, Some b) | EqZero a -> (Some a, None)
      in
      List.map ~f eqs
    in
    let values =
      eqs |> List.concat_map ~f:(fun (a, b) -> [a; b]) |> List.dedup_and_sort ~compare:V.compare
    in
    (* We simulate left-to-right substitution. A pair [(a,b)] in [substs] means that [a] becomes [b]
     * after substitution. *)
    let substs =
      let init = List.map ~f:(fun x -> (x, x)) values in
      let apply_subst substs (a, b) =
        List.map ~f:(function c, d when V.equal d a -> (c, b) | s -> s) substs
      in
      List.fold ~init ~f:apply_subst eqs
    in
    (* And then we treat equalities as equalities, using union-find to find a rep. *)
    let cls =
      List.fold ~init:V.Map.empty ~f:(fun m v -> V.Map.add v (Union_find.create v) m) values
    in
    List.iter ~f:(function a, b -> Union_find.union (V.Map.find a cls) (V.Map.find b cls)) eqs ;
    (* Finally, we check that for each pair of values the two approaches agree. *)
    let pairs = List.cartesian_product values values in
    List.iter pairs ~f:(function a, b ->
        let equal_in_subst =
          let aa = List.Assoc.find_exn ~equal:V.equal substs a in
          let bb = List.Assoc.find_exn ~equal:V.equal substs b in
          V.equal aa bb
        in
        let equal_in_uf =
          let aa = V.Map.find a cls in
          let bb = V.Map.find b cls in
          Union_find.same_class aa bb
        in
        if Bool.(equal_in_subst <> equal_in_uf) then (
          F.fprintf F.str_formatter "@[<v>" ;
          List.iter eqs ~f:(function x, y ->
              F.fprintf F.str_formatter "@[%a -> %a@]@;" V.pp x V.pp y ) ;
          F.fprintf F.str_formatter "@[See values %a %a: equal_in_subst=%b equal_in_uf=%b@]@;@]"
            V.pp a V.pp b equal_in_subst equal_in_uf ;
          L.die InternalError "%s" (F.flush_str_formatter ()) ) )


  let incorporate_new_eqs astate new_eqs =
    let new_eqs = RevList.to_list new_eqs in
    if Config.pulse_sanity_checks then check_new_eqs new_eqs ;
    let stack_allocations = lazy (get_stack_allocated astate) in
    List.fold_until new_eqs ~init:(astate, None)
      ~finish:(fun astate_error -> Sat astate_error)
      ~f:(fun (astate, error) (new_eq : PulseFormula.new_eq) ->
        L.d_printfln "incorporating new eq: %a" PulseFormula.pp_new_eq new_eq ;
        match new_eq with
        | Equal (v1, v2) when AbstractValue.equal v1 v2 ->
            Continue (astate, error)
        | Equal (v1, v2) -> (
          match subst_var_in_post (v1, v2) astate with
          | Unsat ->
              Stop Unsat
          | Sat astate' ->
              Continue (astate', error) )
        | EqZero v when is_stack_allocated stack_allocations v ->
            L.d_printfln "CONTRADICTION: %a = 0 but is allocated" AbstractValue.pp v ;
            Stop Unsat
        | EqZero v when is_heap_allocated astate v -> (
            (* We want to detect when we know [v|->-] and [v=0] together. This is a contradiction, but
               can also be the sign that there is a real issue. Consider:

                 foo(p) {
                   if(p) {}
                   *p = 42;
                 }

               This creates two paths:
                 p=0 /\ p|->-
                 p≠0 /\ p|->-

               We could discard the first one straight away because it's equivalent to false, but
               the second one will also get discarded when calling this foo(0) because it will fail
               the p≠0 condition, creating FNs. Thus, we create a latent issue instead to report
               on foo(0) calls.

               An alternative design that would be less hacky would be to detect this situation when
               adding pointers from null values, but we'd need to know what values are null at all
               times. This would require normalizing the arithmetic part at each step, which is too
               expensive. *)
            L.d_printfln ~color:Red "Potential ERROR: %a = 0 but is allocated" AbstractValue.pp v ;
            (* unsafe cast safe because these come from the formula *)
            match
              SafeAttributes.get_must_be_valid
                (CanonValue.unsafe_cast v [@alert "-deprecated"])
                astate
            with
            | None ->
                (* we don't know why [v|->-] is in the state, weird and probably cannot happen; drop
                   the path because we won't be able to give a sensible error *)
                L.d_printfln "Not clear why %a should be allocated in the first place, giving up"
                  AbstractValue.pp v ;
                Stop Unsat
            | Some (_, trace, reason_opt) ->
                Stop (Sat (astate, Some (v, (trace, reason_opt)))) )
        | EqZero _ (* [v] not allocated *) ->
            Continue (astate, error) )


  (** it's a good idea to normalize the path condition before calling this function *)
  let canonicalize astate =
    let open SatUnsat.Import in
    let canonicalize_pre (pre : PreDomain.t) =
      (* (ab)use canonicalization to filter out empty edges in the heap and detect aliasing
         contradictions *)
      let* stack' = RawStack.canonicalize ~get_var_repr:Fn.id (pre :> BaseDomain.t).stack in
      let+ heap' = RawMemory.canonicalize ~get_var_repr:Fn.id (pre :> BaseDomain.t).heap in
      let attrs' =
        PulseBaseAddressAttributes.make_suitable_for_pre_summary (pre :> BaseDomain.t).attrs
      in
      PreDomain.update ~stack:stack' ~heap:heap' ~attrs:attrs' pre
    in
    let canonicalize_post (post : PostDomain.t) =
      let get_var_repr v = Formula.get_var_repr astate.path_condition v in
      let* stack' = RawStack.canonicalize ~get_var_repr (post :> BaseDomain.t).stack in
      (* note: this step also de-registers addresses pointing to empty edges *)
      let+ heap' = RawMemory.canonicalize ~get_var_repr (post :> BaseDomain.t).heap in
      let attrs' =
        PulseBaseAddressAttributes.canonicalize_post ~get_var_repr (post :> BaseDomain.t).attrs
      in
      PostDomain.update ~stack:stack' ~heap:heap' ~attrs:attrs' post
    in
    let* pre = canonicalize_pre astate.pre in
    let+ post = canonicalize_post astate.post in
    {astate with pre; post}


  let topl_view ({pre; post; path_condition} as astate) =
    let pulse_pre = (pre :> BaseDomain.t) in
    let pulse_post = (post :> BaseDomain.t) in
    let get_reachable () =
      let pre_addresses, post_addresses, always_reachable_trans_closure, canon_addresses =
        get_reachable astate
      in
      let path_condition =
        Formula.fold_variables path_condition ~init:AbstractValue.Set.empty ~f:(fun vars v ->
            AbstractValue.Set.add v vars )
      in
      let ( ++ ) = AbstractValue.Set.union in
      pre_addresses ++ post_addresses ++ always_reachable_trans_closure ++ canon_addresses
      ++ path_condition
    in
    {PulseTopl.pulse_pre; pulse_post; path_condition; get_reachable}


  let filter_for_summary tenv proc_name location astate0 =
    let open SatUnsat.Import in
    L.d_printfln "Canonicalizing..." ;
    let* astate_before_filter = canonicalize astate0 in
    let pp_state = Pp.html_collapsible_block ~name:"Show/hide canonicalized state" pp in
    L.d_printfln "%a" pp_state astate_before_filter ;
    (* Remove the stack from the post as it's not used: the values of formals are the same as in the
       pre. Moreover, formals can be treated as local variables inside the function's body so we need
       to restore their initial values at the end of the function. Removing them altogether achieves
       this. *)
    let astate = restore_formals_for_summary proc_name location astate_before_filter in
    let astate = {astate with topl= PulseTopl.simplify (topl_view astate) astate.topl} in
    let astate, pre_live_addresses, post_live_addresses, dead_addresses =
      discard_unreachable_ ~for_summary:true astate
    in
    let precondition_vocabulary =
      if PatternMatch.is_entry_point proc_name then
        (* report all latent issues at entry points *)
        AbstractValue.Set.empty
      else pre_live_addresses
    in
    let live_addresses = AbstractValue.Set.union pre_live_addresses post_live_addresses in
    (* [unsafe_cast] is safe because the state has been normalized so all values are already
       canonical ones *)
    let get_dynamic_type v =
      BaseAddressAttributes.get_dynamic_type (astate_before_filter.post :> BaseDomain.t).attrs
        (CanonValue.unsafe_cast v [@alert "-deprecated"])
    in
    let+ path_condition, live_via_arithmetic, new_eqs =
      Formula.simplify tenv ~get_dynamic_type ~precondition_vocabulary ~keep:live_addresses
        astate.path_condition
    in
    let live_addresses = AbstractValue.Set.union live_addresses live_via_arithmetic in
    ( {astate with path_condition; topl= PulseTopl.filter_for_summary (topl_view astate) astate.topl}
    , live_addresses
    , (* we could filter out the [live_addresses] if needed; right now they might overlap *)
      dead_addresses
    , new_eqs )
end

(** {2 Interface for the .mli} *)

open Internal

let get_pre {pre} = (pre :> BaseDomain.t)

let get_post {post} = (post :> BaseDomain.t)

let mk_initial tenv (proc_attrs : ProcAttributes.t) specialization =
  let proc_name = proc_attrs.proc_name in
  (* HACK: save the formals in the stacks of the pre and the post to remember which local variables
     correspond to formals *)
  let formals_and_captured =
    let init_var formal_or_captured pvar typ =
      let event =
        match formal_or_captured with
        | `Formal ->
            ValueHistory.FormalDeclared (pvar, proc_attrs.loc, Timestamp.t0)
        | `Captured mode ->
            ValueHistory.Capture
              {captured_as= pvar; mode; location= proc_attrs.loc; timestamp= Timestamp.t0}
      in
      (Var.of_pvar pvar, typ, (AbstractValue.mk_fresh (), ValueHistory.singleton event))
    in
    let formals =
      List.map proc_attrs.formals ~f:(fun (mangled, typ, _) ->
          init_var `Formal (Pvar.mk mangled proc_name) typ )
    in
    let captured =
      List.map proc_attrs.captured ~f:(fun {CapturedVar.pvar; typ; capture_mode} ->
          init_var (`Captured capture_mode) pvar typ )
    in
    captured @ formals
  in
  let initial_stack =
    List.fold formals_and_captured ~init:(PreDomain.empty :> BaseDomain.t).stack
      ~f:(fun stack (formal, _, addr_loc) -> BaseStack.add formal addr_loc stack)
  in
  let initial_heap =
    let register heap (_, _, (addr, _)) =
      (* safe because the state is empty, i.e. there are no equalities and each value is its own
         canonical representative *)
      let[@alert "-deprecated"] addr = CanonValue.unsafe_cast addr in
      BaseMemory.register_address addr heap
    in
    List.fold formals_and_captured ~init:(PreDomain.empty :> base_domain).heap ~f:register
  in
  let initial_attrs = BaseDomain.empty.attrs in
  let pre =
    PreDomain.update ~stack:initial_stack ~heap:initial_heap ~attrs:initial_attrs PreDomain.empty
  in
  let initial_heap, initial_attrs =
    ((PreDomain.empty :> base_domain).heap, (PreDomain.empty :> base_domain).attrs)
  in
  let post =
    PostDomain.update ~stack:initial_stack ~heap:initial_heap ~attrs:initial_attrs PostDomain.empty
  in
  let post =
    List.fold proc_attrs.locals ~init:post
      ~f:(fun (acc : PostDomain.t) {ProcAttributes.name; typ; modify_in_block; is_constexpr} ->
        if modify_in_block || is_constexpr then acc
        else
          SafeAttributes.set_uninitialized_post tenv Timestamp.t0
            (`LocalDecl (Pvar.mk name proc_name, None))
            typ proc_attrs.loc acc )
  in
  let astate =
    { pre
    ; post
    ; path_condition= Formula.ttrue
    ; decompiler= Decompiler.empty
    ; need_closure_specialization= false
    ; need_dynamic_type_specialization= AbstractValue.Set.empty
    ; topl= PulseTopl.start ()
    ; skipped_calls= SkippedCalls.empty }
  in
  let astate =
    if Language.curr_language_is Hack then
      (* The Hack frontend does not propagate types from declarations to usage,
         so we redo part of the work ourself *)
      add_static_types tenv astate formals_and_captured
    else astate
  in
  apply_specialization proc_name specialization astate


let get_unreachable_attributes {post} =
  let post_addresses = BaseDomain.reachable_addresses (post :> BaseDomain.t) in
  ( BaseAddressAttributes.fold
      (fun address _ dead_addresses ->
        if AbstractValue.Set.mem (downcast address) post_addresses then dead_addresses
        else address :: dead_addresses )
      (post :> BaseDomain.t).attrs []
    : CanonValue.t list
    :> AbstractValue.t list )


let should_havoc_if_unknown () =
  match !Language.curr_language with
  | Java
    (* TODO(T138610370): temporary until we improve the way taint propagates for unknown calls *)
  | Hack ->
      `ShouldOnlyHavocResources
  | _ ->
      `ShouldHavoc


let apply_unknown_effect ?(havoc_filter = fun _ _ _ -> true) hist x astate =
  let x = (CanonValue.canon' astate x :> AbstractValue.t) in
  let havoc_accesses hist addr heap =
    match BaseMemory.find_opt addr heap with
    | None ->
        heap
    | Some edges ->
        let edges =
          SafeBaseMemory.Edges.mapi astate edges ~f:(fun access value ->
              if havoc_filter (downcast addr) (downcast_access access) (downcast_fst value) then (
                L.d_printfln_escaped "havoc'ing access %a" BaseMemory.Access.pp access ;
                (AbstractValue.mk_fresh (), hist) )
              else downcast_fst value )
        in
        BaseMemory.add addr edges heap
  in
  let post = (astate.post :> BaseDomain.t) in
  let heap, attrs =
    BaseDomain.GraphVisit.fold_from_addresses (Seq.return x) post ~init:(post.heap, post.attrs)
      ~already_visited:AbstractValue.Set.empty
      ~f:(fun (heap, attrs) addr _edges ->
        let addr = CanonValue.canon' astate addr in
        match should_havoc_if_unknown () with
        | `ShouldHavoc ->
            let attrs =
              BaseAddressAttributes.remove_allocation_attr addr attrs
              |> BaseAddressAttributes.initialize addr
            in
            let heap = havoc_accesses hist addr heap in
            Continue (heap, attrs)
        | `ShouldOnlyHavocResources ->
            let attrs = BaseAddressAttributes.remove_allocation_attr addr attrs in
            Continue (heap, attrs) )
      ~finish:Fn.id
    |> snd
  in
  {astate with post= PostDomain.update ~attrs ~heap astate.post}


let add_need_dynamic_type_specialization receiver_addr astate =
  let need_dynamic_type_specialization =
    AbstractValue.Set.add receiver_addr astate.need_dynamic_type_specialization
  in
  {astate with need_dynamic_type_specialization}


let remove_from_post addr astate =
  SafeMemory.map_post_heap astate ~f:(BaseMemory.remove (CanonValue.canon' astate addr))


let set_post_edges addr edges astate =
  if RawMemory.Edges.is_empty edges then astate
  else SafeMemory.map_post_heap astate ~f:(BaseMemory.add (CanonValue.canon' astate addr) edges)


let find_post_cell_opt addr {post} = BaseDomain.find_cell_opt addr (post :> BaseDomain.t)

let set_post_cell {PathContext.timestamp} (addr, history) (edges, attr_set) location astate =
  let astate = set_post_edges addr edges astate in
  let addr = CanonValue.canon' astate addr in
  SafeAttributes.map_post_attrs astate ~f:(fun attrs ->
      BaseAddressAttributes.add_one addr
        (WrittenTo (timestamp, Trace.Immediate {location; history}))
        attrs
      |> BaseAddressAttributes.add addr attr_set )


module Summary = struct
  type summary = t [@@deriving compare, equal, yojson_of]

  type t = summary [@@deriving compare, equal, yojson_of]

  let pp = pp

  let leq = leq

  let get_pre = get_pre

  let get_post = get_post

  let get_path_condition {path_condition} = path_condition

  let get_topl {topl} = topl

  let need_closure_specialization {need_closure_specialization} = need_closure_specialization

  let get_skipped_calls {skipped_calls} = skipped_calls

  let is_heap_allocated = is_heap_allocated

  let get_must_be_valid addr summary =
    SafeAttributes.get_must_be_valid (CanonValue.canon' summary addr) summary


  let of_post tenv proc_name (proc_attrs : ProcAttributes.t) location astate0 =
    let open SatUnsat.Import in
    let astate = astate0 in
    (* NOTE: we normalize (to strengthen the equality relation used by canonicalization) then
       canonicalize *before* garbage collecting unused addresses in case we detect any last-minute
       contradictions about addresses we are about to garbage collect *)
    let* path_condition, new_eqs =
      Formula.normalize tenv
        ~get_dynamic_type:(fun v ->
          (* [unsafe_cast] is safe because the formula will only query canonical values *)
          BaseAddressAttributes.get_dynamic_type (astate.post :> BaseDomain.t).attrs
            (CanonValue.unsafe_cast v [@alert "-deprecated"]) )
        astate.path_condition
    in
    let astate = {astate with path_condition} in
    let* astate, error = incorporate_new_eqs astate new_eqs in
    let astate_before_filter = astate in
    (* do not store the decompiler in the summary and make sure we only use the original one by
       marking it invalid *)
    let astate = {astate with decompiler= Decompiler.invalid} in
    let* astate, live_addresses, dead_addresses, new_eqs =
      filter_for_summary tenv proc_name location astate
    in
    let+ astate, error =
      match error with None -> incorporate_new_eqs astate new_eqs | Some _ -> Sat (astate, error)
    in
    match error with
    | None -> (
      match
        check_retain_cycles ~dead_addresses tenv
          {astate_before_filter with decompiler= astate0.decompiler}
      with
      | Error (assignment_traces, value, path, location) ->
          Error
            (`RetainCycle (astate, astate_before_filter, assignment_traces, value, path, location))
      | Ok () -> (
        (* NOTE: it's important for correctness that we check leaks last because we are going to carry
           on with the astate after the leak and we don't want to accidentally skip modifications of
           the state because of the error monad *)
        match
          check_memory_leaks ~live_addresses ~unreachable_addresses:dead_addresses
            astate_before_filter
        with
        | Ok () ->
            Ok (invalidate_locals proc_attrs.locals astate)
        | Error (unreachable_location, JavaResource class_name, trace) ->
            Error
              (`JavaResourceLeak
                ( astate
                , astate_before_filter
                , class_name
                , trace
                , Option.value unreachable_location ~default:location ) )
        | Error (unreachable_location, HackAsync, trace) ->
            Error
              (`HackUnawaitedAwaitable
                ( astate
                , astate_before_filter
                , trace
                , Option.value unreachable_location ~default:location ) )
        | Error (unreachable_location, CSharpResource class_name, trace) ->
            Error
              (`CSharpResourceLeak
                ( astate
                , astate_before_filter
                , class_name
                , trace
                , Option.value unreachable_location ~default:location ) )
        | Error (unreachable_location, allocator, trace) ->
            Error
              (`MemoryLeak
                ( astate
                , astate_before_filter
                , allocator
                , trace
                , Option.value unreachable_location ~default:location ) ) ) )
    | Some (address, must_be_valid) ->
        Error
          (`PotentialInvalidAccessSummary
            (astate, astate_before_filter, Decompiler.find address astate0.decompiler, must_be_valid)
            )


  let skipped_calls_match_pattern astate =
    (* For every skipped function, there needs to be at least one regexp given in --pulse_report_ignore_java_methods_patterns
       that matches it *)
    Option.value_map Config.pulse_report_ignore_unknown_java_methods_patterns ~default:true
      ~f:(fun patt ->
        SkippedCalls.for_all
          (fun skipped_proc _ -> Str.string_match patt (Procname.to_string skipped_proc) 0)
          astate.skipped_calls )


  let with_need_closure_specialization summary = {summary with need_closure_specialization= true}

  let add_need_dynamic_type_specialization = add_need_dynamic_type_specialization

  let heap_paths_that_need_dynamic_type_specialization summary =
    let pre = (summary.pre :> BaseDomain.t) in
    let addresses = summary.need_dynamic_type_specialization in
    let rec mk_heap_path var rev_accesses =
      let open IOption.Let_syntax in
      match (rev_accesses : PulseBaseMemory.Access.t list) with
      | [] ->
          let+ pvar = Var.get_pvar var in
          Specialization.HeapPath.Pvar pvar
      | FieldAccess fieldname :: rev_accesses ->
          let+ heap_path = mk_heap_path var rev_accesses in
          Specialization.HeapPath.FieldAccess (fieldname, heap_path)
      | Dereference :: rev_accesses ->
          let+ heap_path = mk_heap_path var rev_accesses in
          Specialization.HeapPath.Dereference heap_path
      | (TakeAddress | ArrayAccess _) :: _ ->
          None
    in
    BaseDomain.GraphVisit.fold pre
      ~var_filter:(fun _ -> true)
      ~init:(Specialization.HeapPath.Map.empty, AbstractValue.Set.empty)
      ~finish:(fun heap_paths -> heap_paths)
      ~f:(fun var (heap_paths, already_found) addr rev_accesses ->
        Continue
          ( if AbstractValue.Set.mem addr addresses && not (AbstractValue.Set.mem addr already_found)
            then
              mk_heap_path var rev_accesses
              |> Option.value_map ~default:(heap_paths, already_found) ~f:(fun heap_path ->
                     ( Specialization.HeapPath.Map.add heap_path addr heap_paths
                     , AbstractValue.Set.add addr already_found ) )
            else (heap_paths, already_found) ) )
    |> snd |> fst
end

module Topl = struct
  let small_step loc event astate =
    {astate with topl= PulseTopl.small_step loc (topl_view astate) event astate.topl}


  let large_step ~call_location ~callee_proc_name ~substitution ~callee_summary ~callee_is_manifest
      astate =
    { astate with
      topl=
        PulseTopl.large_step ~call_location ~callee_proc_name ~substitution (topl_view astate)
          ~callee_summary ~callee_is_manifest astate.topl }


  let report_errors proc_desc err_log ~pulse_is_manifest astate =
    PulseTopl.report_errors proc_desc err_log ~pulse_is_manifest astate.topl
end

let add_skipped_call pname trace astate =
  let new_skipped_calls = SkippedCalls.add pname trace astate.skipped_calls in
  if phys_equal new_skipped_calls astate.skipped_calls then astate
  else {astate with skipped_calls= new_skipped_calls}


let add_skipped_calls new_skipped_calls astate =
  (* favor calls we already knew about somewhat arbitrarily *)
  let skipped_calls =
    SkippedCalls.union
      (fun _ orig_call _new_call -> Some orig_call)
      astate.skipped_calls new_skipped_calls
  in
  if phys_equal skipped_calls astate.skipped_calls then astate else {astate with skipped_calls}


let is_local = is_local

let is_allocated_this_pointer proc_attrs astate address =
  let open IOption.Let_syntax in
  let address = CanonValue.canon' astate address in
  Option.exists ~f:Fn.id
    (let* this = ProcAttributes.get_this proc_attrs in
     let* this_pointer_address, _ = SafeStack.find_opt (Var.of_pvar this) astate in
     let+ this_pointer, _ = SafeMemory.find_edge_opt this_pointer_address Dereference astate in
     CanonValue.equal this_pointer address )


let incorporate_new_eqs new_eqs astate =
  let open SatUnsat.Import in
  let proc_attrs =
    Procdesc.get_attributes (PulseCurrentProcedure.proc_desc () |> Option.value_exn)
  in
  let* astate, potential_invalid_access_opt = incorporate_new_eqs astate new_eqs in
  match potential_invalid_access_opt with
  | None ->
      Sat (Ok astate)
  | Some (address, must_be_valid) ->
      L.d_printfln ~color:Red "potential error if %a is null" AbstractValue.pp address ;
      if is_allocated_this_pointer proc_attrs astate address then Unsat
      else Sat (Error (`PotentialInvalidAccess (astate, address, must_be_valid)))


let incorporate_new_eqs_on_val new_eqs v =
  let rec subst remaining_eqs w =
    match remaining_eqs with
    | PulseFormula.Equal (v1, v2) :: remaining_eqs when AbstractValue.equal v1 w ->
        subst remaining_eqs v2
    | _ :: remaining_eqs ->
        subst remaining_eqs w
    | [] ->
        w
  in
  subst (RevList.to_list new_eqs) v


module Stack = struct
  include SafeStack

  let fold f astate init =
    SafeStack.fold (fun var addr_hist acc -> f var (downcast_fst addr_hist) acc) astate init


  let find_opt var astate = SafeStack.find_opt var astate |> Option.map ~f:downcast_fst

  let eval origin var astate = SafeStack.eval origin var astate |> downcast_snd_fst

  let exists f astate =
    SafeStack.exists (fun var addr_hist -> f var (downcast_fst addr_hist)) astate
end

module Memory = struct
  include SafeMemory

  let add_edge path orig_addr_hist access dest_addr_hist location astate =
    SafeMemory.add_edge path
      (CanonValue.canon_fst' astate orig_addr_hist)
      (CanonValue.canon_access astate access)
      dest_addr_hist location astate


  let eval_edge addr_hist access astate =
    SafeMemory.eval_edge
      (CanonValue.canon_fst' astate addr_hist)
      (CanonValue.canon_access astate access)
      astate
    |> downcast_snd_fst


  let fold_edges addr astate ~init ~f =
    SafeMemory.fold_edges (CanonValue.canon' astate addr) astate ~init
      ~f:(fun acc access_addr_hist ->
        f acc
          ( access_addr_hist
            : Access.t * (CanonValue.t * ValueHistory.t)
            :> PulseBaseMemory.Access.t * (AbstractValue.t * ValueHistory.t) ) )


  let find_edge_opt address access astate =
    SafeMemory.find_edge_opt
      (CanonValue.canon' astate address)
      (CanonValue.canon_access astate access)
      astate
    |> Option.map ~f:downcast_fst


  let exists_edge addr astate ~f =
    SafeMemory.exists_edge (CanonValue.canon' astate addr) astate ~f:(fun access_addr_hist ->
        f
          ( access_addr_hist
            : Access.t * (CanonValue.t * ValueHistory.t)
            :> PulseBaseMemory.Access.t * (AbstractValue.t * ValueHistory.t) ) )
end

module AddressAttributes = struct
  let abduce_attribute v attr astate =
    SafeAttributes.abduce_attribute (CanonValue.canon' astate v) attr astate


  let abduce_and_add v attr astate =
    SafeAttributes.abduce_and_add (CanonValue.canon' astate v) attr astate


  let add_one v attr astate = SafeAttributes.add_one (CanonValue.canon' astate v) attr astate

  let add_attrs v attrs astate = SafeAttributes.add_attrs (CanonValue.canon' astate v) attrs astate

  let find_opt v astate = SafeAttributes.find_opt (CanonValue.canon' astate v) astate

  let check_valid path ?must_be_valid_reason trace v astate =
    SafeAttributes.check_valid path ?must_be_valid_reason trace (CanonValue.canon' astate v) astate


  let check_initialized path trace v astate =
    SafeAttributes.check_initialized path trace (CanonValue.canon' astate v) astate


  let add_taint_sink path taint trace v astate =
    SafeAttributes.add_taint_sink path taint trace (CanonValue.canon' astate v) astate


  let invalidate addr_hist invalidation location astate =
    SafeAttributes.invalidate (CanonValue.canon_fst' astate addr_hist) invalidation location astate


  let initialize v astate = SafeAttributes.initialize (CanonValue.canon' astate v) astate

  let set_uninitialized tenv {PathContext.timestamp} src typ location astate =
    let src =
      match src with
      | `LocalDecl (pvar, v_opt) ->
          `LocalDecl (pvar, CanonValue.canon_opt' astate v_opt)
      | `Malloc v ->
          `Malloc (CanonValue.canon' astate v)
    in
    { astate with
      post= SafeAttributes.set_uninitialized_post tenv timestamp src typ location astate.post }


  let always_reachable v astate =
    SafeAttributes.always_reachable (CanonValue.canon' astate v) astate


  let allocate allocator v location astate =
    SafeAttributes.allocate allocator (CanonValue.canon' astate v) location astate


  let java_resource_release v astate =
    SafeAttributes.java_resource_release (CanonValue.canon' astate v) astate


  let hack_async_await v astate =
    SafeAttributes.hack_async_await (CanonValue.canon' astate v) astate


  let is_java_resource_released v astate =
    SafeAttributes.is_java_resource_released (CanonValue.canon' astate v) astate


  let csharp_resource_release v astate =
    SafeAttributes.csharp_resource_release (CanonValue.canon' astate v) astate


  let is_csharp_resource_released v astate =
    SafeAttributes.is_csharp_resource_released (CanonValue.canon' astate v) astate


  let add_dynamic_type typ v astate =
    SafeAttributes.add_dynamic_type typ (CanonValue.canon' astate v) astate


  let add_dynamic_type_source_file typ source_file v astate =
    SafeAttributes.add_dynamic_type_source_file typ source_file (CanonValue.canon' astate v) astate


  let add_ref_counted v astate = SafeAttributes.add_ref_counted (CanonValue.canon' astate v) astate

  let is_ref_counted v astate = SafeAttributes.is_ref_counted (CanonValue.canon' astate v) astate

  let remove_allocation_attr v astate =
    SafeAttributes.remove_allocation_attr (CanonValue.canon' astate v) astate


  let remove_taint_attrs v astate =
    SafeAttributes.remove_taint_attrs (CanonValue.canon' astate v) astate


  let get_dynamic_type v astate =
    SafeAttributes.get_dynamic_type (CanonValue.canon' astate v) astate


  let get_dynamic_type_source_file v astate =
    SafeAttributes.get_dynamic_type_source_file (CanonValue.canon' astate v) astate


  let get_static_type v astate = SafeAttributes.get_static_type (CanonValue.canon' astate v) astate

  let get_allocation v astate = SafeAttributes.get_allocation (CanonValue.canon' astate v) astate

  let get_closure_proc_name v astate =
    SafeAttributes.get_closure_proc_name (CanonValue.canon' astate v) astate


  let get_copied_into v astate = SafeAttributes.get_copied_into (CanonValue.canon' astate v) astate

  let get_copied_return v astate =
    ( SafeAttributes.get_copied_return (CanonValue.canon' astate v) astate
      |> CanonValue.canon_opt_fst4' astate
      : (CanonValue.t * bool * Attribute.CopyOrigin.t * Location.t) option
      :> (AbstractValue.t * bool * Attribute.CopyOrigin.t * Location.t) option )


  let remove_copied_return v astate =
    SafeAttributes.remove_copied_return (CanonValue.canon' astate v) astate


  let get_source_origin_of_copy v astate =
    ( SafeAttributes.get_source_origin_of_copy (CanonValue.canon' astate v) astate
      |> CanonValue.canon_opt' astate
      : CanonValue.t option
      :> AbstractValue.t option )


  let get_taint_sources_and_sanitizers v astate =
    SafeAttributes.get_taint_sources_and_sanitizers (CanonValue.canon' astate v) astate


  let get_propagate_taint_from v astate =
    SafeAttributes.get_propagate_taint_from (CanonValue.canon' astate v) astate


  let is_end_of_collection v astate =
    SafeAttributes.is_end_of_collection (CanonValue.canon' astate v) astate


  let mark_as_end_of_collection v astate =
    SafeAttributes.mark_as_end_of_collection (CanonValue.canon' astate v) astate


  let is_std_vector_reserved v astate =
    SafeAttributes.is_std_vector_reserved (CanonValue.canon' astate v) astate


  let std_vector_reserve v astate =
    SafeAttributes.std_vector_reserve (CanonValue.canon' astate v) astate


  let add_unreachable_at v location astate =
    SafeAttributes.add_unreachable_at (CanonValue.canon' astate v) location astate


  let add_copied_return v ~source ~is_const_ref copy_origin location astate =
    SafeAttributes.add_copied_return (CanonValue.canon' astate v)
      ~source:(CanonValue.canon' astate source) ~is_const_ref copy_origin location astate


  let get_config_usage v astate =
    SafeAttributes.get_config_usage (CanonValue.canon' astate v) astate


  let get_valid_returned_from_unknown v astate =
    SafeAttributes.get_valid_returned_from_unknown (CanonValue.canon' astate v) astate


  let get_written_to v astate = SafeAttributes.get_written_to (CanonValue.canon' astate v) astate

  let is_copied_from_const_ref v astate =
    SafeAttributes.is_copied_from_const_ref (CanonValue.canon' astate v) astate


  let is_std_moved v astate = SafeAttributes.is_std_moved (CanonValue.canon' astate v) astate

  let get_const_string v astate =
    SafeAttributes.get_const_string (CanonValue.canon' astate v) astate


  let get_address_of_stack_variable v astate =
    SafeAttributes.get_address_of_stack_variable (CanonValue.canon' astate v) astate
end

module CanonValue = struct
  include CanonValue

  let downcast = downcast
end
