(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module L = Logging
module CFG = ProcCfg.NormalOneInstrPerNode

module LineageConfig = struct
  let field_depth = Config.lineage_field_depth

  let field_width = Option.value ~default:Int.max_value Config.lineage_field_width

  let prevent_cycles = Config.lineage_prevent_cycles
end

module FieldPath = struct
  (** A module to help manipulating lists of (nested) fields. *)

  (** We define a type alias to be able use our own json exporting function *)
  type fieldname = Fieldname.t [@@deriving compare, equal, sexp]

  let yojson_of_fieldname fieldname =
    (* The ppx-generated [yojson_of] is unnecessarily complex for our purposes (it's a record that
       involves "class_name", which incidentally seems to always be "_".) *)
    `String (Fieldname.to_string fieldname)


  module T = struct
    (* The list is to be understood in "syntactic order": [["a"; "b"]] represents the field part of
       [X#a#b].*)
    type t = fieldname list [@@deriving compare, equal, sexp, yojson_of]
  end

  include T
  include Comparable.Make (T)

  let pp = Fmt.(list ~sep:nop (any "#" ++ Fieldname.pp))
end

module Cell : sig
  (** See .mli for doc *)

  type t [@@deriving compare, equal, sexp, yojson_of]

  val create : var:Var.t -> field_path:FieldPath.t -> is_abstract:bool -> t

  val pp : t Fmt.t

  val var : t -> Var.t

  val field_path : t -> FieldPath.t

  val is_abstract : t -> bool

  val var_appears_in_source_code : t -> bool
end = struct
  type t = {var: Var.t; field_path: FieldPath.t; is_abstract: bool}
  [@@deriving compare, equal, sexp, fields]

  let create = Fields.create

  let pp fmt {var; field_path; is_abstract} =
    Var.pp fmt var ;
    FieldPath.pp fmt field_path ;
    if is_abstract && Config.debug_mode then
      (* We could also consider printing that by default but that could break some other systems
         expectations. *)
      Fmt.pf fmt "#"


  let yojson_of_t x = `String (Fmt.to_to_string pp x)

  let var_appears_in_source_code x = Var.appears_in_source_code (var x)
end

module Id () : sig
  include Unique_id.Id

  val pp : Format.formatter -> t -> unit
end = struct
  (** Generative unique identifiers with some utility functions *)

  include Unique_id.Int63 ()

  let pp fmt x = Format.fprintf fmt "<%a>" Int63.pp (x : t :> Int63.t)
end

(** This analysis aims at inferring all the fields that may be accessed from some variable, possibly
    through aliases.

    The original goal is to be able to use that information in the lineage analysis, by making
    information flow through fields even if they appear in later instructions. The typical use-case
    is when an argument [$argN] of a function is copied into the name [X], and then the function
    returns some field [foo] of [X]: we want to know that we should create the Lineage node
    [$argN#foo] at the same time as the node [$argN]. *)

module Env : sig
  module State : sig
    (** The [State] module manages shape definitions and typing environments within the context of
        the analysis of a function.

        This is mostly done through a stateful API to ease the implementation that currently heavily
        relies on a union-find data structure (which is easier to implement imperatively). *)

    (** A shape is a handle to which may be attached some subscriptable fields. These fields will
        themselves recursively have an associated shape. Variables will also have a shape associated
        to them. *)
    type shape

    (** An environment associates shapes to variables and fields to shapes. *)
    type t

    val pp : Format.formatter -> t -> unit

    val create_shape : unit -> shape
    (** Create a fresh shape, not associated to any variable yet, and having no known field. *)

    val create : unit -> t
    (** Create a fresh environment with no known variable nor shape fields. *)

    val var_shape : t -> Var.t -> shape
    (** Returns the shape of a variable. If the variable is unknown in the environment, a fresh
        shape will be created, associated to the variable, and returned.

        Will always return a fresh shape for the `_` anonymous erlang variable. *)

    val field_shape : t -> shape -> Fieldname.t -> shape
    (** Given a shape, a subscripted field and an environment, returns the shape of the field
        content. If this field is unknown for that shape in the environment, a fresh shape will be
        created, associated to the field and returned. *)

    val unify : t -> shape -> shape -> unit
    (** Makes two shapes identical by merging their defined fields (unifying the shapes of common
        fields if needed) and making it so that they will both share the same identical set of
        fields in the future (one can now indifferently refer to any of the shapes as an alias of
        the result). *)
  end

  module Summary : sig
    (** Summaries contain the result of the typing analysis of a function, including the types of
        its local variables. They are to be used both for making this shape analysis interprocedural
        (by relating the return types of callee functions to those of their parameters) and for
        using its results later on subsequent analysis (in particular Lineage). *)
    type t

    val pp : Format.formatter -> t -> unit

    val make : State.t -> t
    (** Makes a summary from a state environment. Further updates to the state will have no effect
        on the summary. *)

    val fold_cells :
      t -> Var.t * FieldPath.t -> init:'accum -> f:('accum -> Cell.t -> 'accum) -> 'accum
    (* Doc in .mli *)

    val fold_cell_pairs :
         t
      -> Var.t * FieldPath.t
      -> Var.t * FieldPath.t
      -> init:'accum
      -> f:('accum -> Cell.t -> Cell.t -> 'accum)
      -> 'accum
    (* Doc in .mli *)

    val introduce :
      formals:Var.t list -> return:Var.t -> t -> State.t -> State.shape list * State.shape
    (** Generates fresh shapes into a state environment for the formal parameters and the formal
        return of a function. The summary of the function will be used to also introduce shapes for
        the fields of these formal variables, and to link the parameters and/or the return value
        together. The shapes will be returned, but not linked to any variable already present in the
        state and are to be unified with the actual parameters and return destination. *)
  end
end = struct
  (* Hashtable from/to iterators *)

  let iter_hashtbl htbl f = Hashtbl.iteri ~f:(fun ~key ~data -> f (key, data)) htbl

  let hashtbl_of_iter_exn key_module iter =
    let r = Hashtbl.create key_module in
    iter (fun (key, data) -> Hashtbl.add_exn r ~key ~data) ;
    r


  (* Pretty-printing *)

  let pp_arrow = Fmt.any " ->@ "

  let pp_binding ~bind pp_key pp_value fmt (key, value) =
    Format.fprintf fmt "@[%a%a%a@]" pp_key key bind () pp_value value


  let pp_hashtbl ?(sep = Fmt.semi) ~bind pp_key pp_value fmt hashtbl =
    let pp_binding = pp_binding ~bind pp_key pp_value in
    Format.fprintf fmt "@[(%a)@]"
      (IFmt.Labelled.iter_bindings ~sep Hashtbl.iteri pp_binding)
      hashtbl


  module Types = struct
    (** Type definitions, common to procedure analysis environments and summaries *)

    module type Shape_class = sig
      (** Shape classes are equivalence classes of shape identifiers, that is, sets of shape
          identifiers that share a common set of fields. *)

      type 'id t [@@deriving sexp_of]

      val pp : 'id Fmt.t -> 'id t Fmt.t
    end

    module Make (Shape_class : Shape_class) () = struct
      (** A functor that defines the common types and fundamental functions of shape environments.

          Takes as parameter the (module) type of shape classes and is generative because it will
          generate a fresh Id module. *)

      (** A shape id is what links variables to defined fields. It is a unique identifier to which a
          structure (eg. set of fields) is associated, and that will be indirectly assigned to every
          variable.

          Shape ids do not make sense by themselves and are only valid within the full context of
          the corresponding environment for which they have been generated. *)
      module Shape_id =
      Id ()

      (** A shape is an equivalence class of shape identifiers. *)
      type shape = Shape_id.t Shape_class.t [@@deriving sexp_of]

      type fields = (Fieldname.t, shape) Hashtbl.t [@@deriving sexp_of]

      (** An environment associates to each variable its equivalence class, and to each shape
          equivalence class representative its set of known fields. *)
      type t = {var_shapes: (Var.t, shape) Hashtbl.t; shape_fields: (Shape_id.t, fields) Hashtbl.t}

      let pp fmt {var_shapes; shape_fields} =
        let pp_shape = Shape_class.pp Shape_id.pp in
        Format.fprintf fmt "@[<v>@[<v4>VAR_SHAPES@ @[%a@]@]@ @[<v4>SHAPE_FIELDS@ @[%a@]@]@]"
          (pp_hashtbl ~bind:pp_arrow Var.pp pp_shape)
          var_shapes
          (pp_hashtbl ~bind:pp_arrow Shape_id.pp
             (pp_hashtbl ~bind:IFmt.colon_sp Fieldname.pp pp_shape) )
          shape_fields
    end
  end

  module State = struct
    (** Environments for the in-progress analysis of a procedure. *)

    module Shape_class = struct
      (** Equivalence classes are stored in a Union-find data structures. That allows cheap merging
          of shapes that are inferred to be equivalent during the procedure analysis. *)

      type 'id t = 'id Union_find.t

      let pp pp_id = Fmt.using Union_find.get pp_id

      let sexp_of_t sexp_of_id x = sexp_of_id (Union_find.get x)
    end

    include Types.Make (Shape_class) ()

    let create () =
      {var_shapes= Hashtbl.create (module Var); shape_fields= Hashtbl.create (module Shape_id)}


    let create_shape () =
      let id = Shape_id.create () in
      Union_find.create id


    let var_shape {var_shapes; _} var = Hashtbl.find_or_add ~default:create_shape var_shapes var

    let field_shape {shape_fields; _} shape fieldname =
      (* Proceed in two steps: retrieve the field set of this shape or create it, then return the shape
         of the asked field or create it. *)
      let id = Union_find.get shape in
      let field_table =
        Hashtbl.find_or_add ~default:(fun () -> Hashtbl.create (module Fieldname)) shape_fields id
      in
      Hashtbl.find_or_add ~default:create_shape field_table fieldname


    let unify_step shape_fields shape shape' todo =
      (* Unify the shapes and put in the todo stack all the shapes of their fields that should also be unified. *)
      if Union_find.same_class shape shape' then
        (* We need to explicitly check that we are not trying to unify already unified classes to ensure
           termination. Otherwise, given a recursive shape such as [<0> -> { tail : <0> }], unifying
           [ <0> ] with itself would recursively try to unify its fields, therefore recursively
           proceeding to unify [ <0> ] with itself and so on.

           This check guarantees termination because shape unification can now only strictly reduce the
           number of equivalence classes, which is finite. *)
        ()
      else
        let id = Union_find.get shape in
        let id' = Union_find.get shape' in
        Union_find.union shape shape' ;
        match (Hashtbl.find shape_fields id, Hashtbl.find shape_fields id') with
        | None, None ->
            (* No subfield to unify *)
            ()
        | Some _, None ->
            (* Only one shape has fields, just use it as the new representative *)
            Union_find.set shape id
        | None, Some _ ->
            Union_find.set shape id'
        | Some fields, Some fields' ->
            (* Both shapes have fields. We arbitrarily use the first id as a representative then
               merge the second fields into the first ones. During this merge, if we encounter
               a field present in both shapes, we put the shapes of this field in the todo stack to
               unify them at a later step (when the field table of the current processed shapes will
               be completed). *)
            Union_find.set shape id ;
            Hashtbl.merge_into ~src:fields' ~dst:fields ~f:(fun ~key:_fieldname shape' shape_opt ->
                Option.iter ~f:(fun shape -> Stack.push todo (shape, shape')) shape_opt ;
                Set_to shape' ) ;
            Hashtbl.remove shape_fields id'


    (* Repeat the unification steps until the stack is empty. *)
    let rec unify_stack shape_fields todo =
      match Stack.pop todo with
      | None ->
          ()
      | Some (shape, shape') ->
          unify_step shape_fields shape shape' todo ;
          unify_stack shape_fields todo


    let unify {shape_fields; _} shape shape' =
      unify_stack shape_fields (Stack.singleton (shape, shape'))
  end

  module Summary = struct
    (* A summary is similar to the (final) typing state environment of a function. The difference is
       that it "freezes" the union-find classes into some fixed and marshallable values. *)

    module Shape_class = struct
      (** Once the analysis is done, each class can be frozen into its representative. Therefore
          summary classes are simply shape ids, which trades off the now-uneeded mergeability for
          marshallability. *)

      type 'id t = 'id [@@deriving sexp]

      let pp pp_id = pp_id
    end

    include Types.Make (Shape_class) ()

    let find_var_shape var_shapes var =
      match Hashtbl.find var_shapes var with
      | Some shape ->
          shape
      | None ->
          L.die InternalError "No shape found for var %a" Var.pp var


    let has_fields shape_fields shape =
      match Hashtbl.find shape_fields shape with
      | None ->
          false
      | Some field_table ->
          not (Hashtbl.is_empty field_table)


    let find_field_table shape_fields shape =
      match Hashtbl.find shape_fields shape with
      | Some field_table ->
          field_table
      | None ->
          L.die InternalError "No field table found for shape %a" Shape_id.pp shape


    let find_next_field_shape shape_fields shape field =
      let field_table = find_field_table shape_fields shape in
      match Hashtbl.find field_table field with
      | Some field_shape ->
          field_shape
      | None ->
          L.die InternalError "Field %a unknown for shape %a.@ Known fields are:@ @[{%a}@]"
            Fieldname.pp field Shape_id.pp shape
            (pp_hashtbl ~bind:IFmt.colon_sp Fieldname.pp Shape_id.pp)
            field_table


    let find_var_path_shape {var_shapes; shape_fields} var field_path =
      let var_shape = find_var_shape var_shapes var in
      List.fold
        ~f:(fun shape field -> find_next_field_shape shape_fields shape field)
        ~init:var_shape field_path


    let make {State.var_shapes; shape_fields} =
      (* Making a summary from a state essentially amounts to freezing State shape classes into State
         ids and converting those State ids into Summary ids. We keep an id translation table that
         maps state ids into summary ids and generate a fresh summary id whenever we encounter a new
         state id representative. *)
      let id_translation_tbl = Hashtbl.create (module State.Shape_id) in
      let translate_shape_id state_shape_id =
        Hashtbl.find_or_add id_translation_tbl ~default:Shape_id.create state_shape_id
      in
      let translate_shape state_shape = translate_shape_id (Union_find.get state_shape) in
      let translate_fields fields = Hashtbl.map ~f:translate_shape fields in
      let var_shapes = Hashtbl.map ~f:translate_shape var_shapes in
      let shape_fields =
        iter_hashtbl shape_fields
        |> Iter.map2 (fun shape fields -> (translate_shape_id shape, translate_fields fields))
        |> hashtbl_of_iter_exn (module Shape_id)
      in
      {var_shapes; shape_fields}


    (* Introducing a (callee) summary is not as simple as freezing an environment into a summary,
       because the summary also contains shape fields of all the local variables of the callee that
       we do not want to put into the caller environment. Therefore we proceed by only introducing
       the shapes of some explicit variables (that will be the formals and return of the callee), and
       recursively discovering and introducing their fields. *)
    let rec introduce_shape id_translation_tbl shape_id shape_fields state_shape_fields =
      (* Translate and introduce a shape from the summary into the environment shapes *)
      match Hashtbl.find id_translation_tbl shape_id with
      | Some state_shape ->
          (* If the shape is already present in the table, then it has already been introduced
             earlier. Just return its translation. *)
          state_shape
      | None ->
          (* This is a new shape to translate. Create a fresh environment shape and populate it by
             recursively introducing its fields. *)
          let state_shape = State.create_shape () in
          Hashtbl.set id_translation_tbl ~key:shape_id ~data:state_shape ;
          ( match Hashtbl.find shape_fields shape_id with
          | None ->
              ()
          | Some fields ->
              Hashtbl.set state_shape_fields ~key:(Union_find.get state_shape)
                ~data:(introduce_fields id_translation_tbl fields shape_fields state_shape_fields)
          ) ;
          state_shape


    and introduce_fields id_translation_tbl fields shape_fields state_shape_fields =
      Hashtbl.map
        ~f:(fun shape_id ->
          introduce_shape id_translation_tbl shape_id shape_fields state_shape_fields )
        fields


    let introduce_var ~var id_translation_tbl {var_shapes; shape_fields}
        {State.shape_fields= state_shape_fields; _} =
      introduce_shape id_translation_tbl (Hashtbl.find_exn var_shapes var) shape_fields
        state_shape_fields


    let introduce ~formals ~return summary state =
      (* [id_translation_tbl] maps Ids from the summary to their translation as Ids in the state
         environment of the caller function. *)
      let id_translation_tbl = Hashtbl.create (module Shape_id) in
      (* We introduce into the (caller) state the *formal* parameters and return value from the
         (callee) summary. It will be the responsibility of the call-interpretation code to then
         unify these formals with the actual parameters and ret_id that already live in the caller
         state. *)
      let args_state_shapes =
        List.map ~f:(fun arg -> introduce_var ~var:arg id_translation_tbl summary state) formals
      in
      let return_state_shape = introduce_var ~var:return id_translation_tbl summary state in
      (args_state_shapes, return_state_shape)


    let pp_field_table field_table =
      pp_hashtbl ~sep:Fmt.comma ~bind:IFmt.colon_sp Fieldname.pp Shape_id.pp field_table


    (** Boxing fields are fields that are internally generated by the frontend to box scalar values,
        such as integer or atoms. They should not be considered as actual fields by the Lineage
        analysis. *)
    let is_boxing_field fieldname =
      Array.mem ~equal:Fieldname.equal
        [| Fieldname.make (ErlangType Atom) ErlangTypeName.atom_name
         ; Fieldname.make (ErlangType Atom) ErlangTypeName.atom_hash
         ; Fieldname.make (ErlangType Integer) ErlangTypeName.integer_value |]
        fieldname


    let finalise {var_shapes; shape_fields} var field_path =
      let rec aux remaining_depth traversed_shape_set shape field_path : FieldPath.t * bool =
        match field_path with
        (* Walk through the fields and ensure that we do not:
           - Traverse a field table wider than LineageConfig.field_width
           - Traverse cycles if forbidden by the option
           - "Traverse" (they must be in last position) internal "boxing" fields that should be
             ignored
           Also limit the depth by stopping the traversal once the remaining depth reaches zero.

           Returns the terminal field path and a boolean indicating if the corresponding cell is
           abstract; that is, it semantically has some fields but we forget about them because we hit
           one of the aforementioned limits.
        *)
        | [] ->
            ([], has_fields shape_fields shape)
        | [field] when is_boxing_field field ->
            ([], false)
        | field :: _ when is_boxing_field field ->
            L.die InternalError "LineageShape: unexpected boxing field in non tail position."
        | field :: fields ->
            let field_table = find_field_table shape_fields shape in
            if
              Int.(remaining_depth <= 0)
              || Hashtbl.length field_table > LineageConfig.field_width
              || (LineageConfig.prevent_cycles && Set.mem traversed_shape_set shape)
            then ([], true)
            else
              let terminal_sub_path, is_abstract =
                aux (remaining_depth - 1)
                  (Set.add traversed_shape_set shape)
                  (Hashtbl.find_exn field_table field)
                  fields
              in
              (field :: terminal_sub_path, is_abstract)
      in
      let var_shape = find_var_shape var_shapes var in
      let field_path, is_abstract =
        aux LineageConfig.field_depth (Set.empty (module Shape_id)) var_shape field_path
      in
      Cell.create ~var ~field_path ~is_abstract


    (** Given field shapes, a particular shape, a maximal width, a maximal search depth and a
        boolean indicating that cycles should not be traversed, traverses the field shapes table and
        builds the field paths obtained by recursively adding all the defined fieldnames of the
        considered shape to the prefixes.

        The traversal building a field path will stop when the maximal search depth has been
        reached, a shape with more than [LineageConfig.field_width] fields is encountered, or a
        shape that has already been traversed is encountered and [LineageConfig.prevent_cycles] is
        true.

        When the building of a field path stops, the folding function [f] will be called on the path
        built so far.

        Note that the traversal and the calling of [f] is done from the original argument shape: for
        instance, if [X] has the field [X#foo#bar#baz], the depth limit is 2 and this function is
        called from the shape of [X#foo], then [f] will be called with the field path [bar#baz] --
        even if [X#foo] and [X#bar#baz] have the same shape, or [X] has a thousand other fields. For
        this reason, [~max_search_depth] is an explicit parameter, different from the
        {!LineageConfig.field_depth} configuration option.

        The typical use-case is to then have [f] call {!finalise}, with [X#foo] in the parameters,
        which will repeat a similar traversal to only yield [X#foo#bar] as a final field path. This
        allows implementing {!fold_cell_pairs} by first getting the candidate terminal fields from a
        common shape of two different origin paths, then finalising separately wrt. these two paths
        (which could have different depths to begin with). *)
    let fold_terminal_fields_of_shape shape_fields shape ~search_depth ~init ~f =
      let rec aux shape depth traversed field_path_acc ~init =
        if Int.(depth >= search_depth) || (LineageConfig.prevent_cycles && Set.mem traversed shape)
        then f init (List.rev field_path_acc)
        else
          match Hashtbl.find shape_fields shape with
          | None ->
              f init (List.rev field_path_acc)
          | Some fields ->
              let len = Hashtbl.length fields in
              if Int.(len = 0 || len > LineageConfig.field_width) then
                f init (List.rev field_path_acc)
              else
                let traversed = Set.add traversed shape in
                Hashtbl.fold
                  ~f:(fun ~key:fieldname ~data:fieldshape acc ->
                    aux fieldshape (depth + 1) traversed (fieldname :: field_path_acc) ~init:acc )
                  fields ~init
      in
      aux shape 0 (Set.empty (module Shape_id)) [] ~init


    let fold_cells {var_shapes; shape_fields} (var, field_path) ~init ~f =
      let var_path_shape = find_var_path_shape {var_shapes; shape_fields} var field_path in
      let search_depth = LineageConfig.field_depth - List.length field_path in
      fold_terminal_fields_of_shape shape_fields var_path_shape ~search_depth ~init
        ~f:(fun acc sub_path ->
          f acc (finalise {var_shapes; shape_fields} var (field_path @ sub_path)) )


    let fold_cell_pairs {var_shapes; shape_fields} (var_1, field_path_1) (var_2, field_path_2) ~init
        ~f =
      let var_path_shape_1 = find_var_path_shape {var_shapes; shape_fields} var_1 field_path_1 in
      let var_path_shape_2 = find_var_path_shape {var_shapes; shape_fields} var_2 field_path_2 in
      if not ([%equal: Shape_id.t] var_path_shape_1 var_path_shape_2) then
        L.die InternalError
          "@[Attempting to get related fields of differently shaped fields: @[%a={%a}@]@ vs@ \
           @[%a={%a}@]@]"
          Shape_id.pp var_path_shape_1 (Fmt.option pp_field_table)
          (Hashtbl.find shape_fields var_path_shape_1)
          Shape_id.pp var_path_shape_2 (Fmt.option pp_field_table)
          (Hashtbl.find shape_fields var_path_shape_2)
      else
        let search_depth =
          (* Use the shallowest argument to determine the search depth. *)
          LineageConfig.field_depth - Int.min (List.length field_path_1) (List.length field_path_2)
        in
        fold_terminal_fields_of_shape shape_fields var_path_shape_1 ~search_depth ~init
          ~f:(fun acc sub_path ->
            f acc
              (finalise {var_shapes; shape_fields} var_1 (field_path_1 @ sub_path))
              (finalise {var_shapes; shape_fields} var_2 (field_path_2 @ sub_path)) )
  end
end

(** As the state works imperatively, we do not need to propagate it and therefore use a simple
    Top/Bottom abstract domain that will simply remember which nodes have been reached yet. Note
    that the resulting analysis is flow insensitive, as the same global shape state will be
    augmented during the traversal of a procedure code, and no intermediary version of it will be
    associated to the individual control flow vertices. *)
module Domain = AbstractDomain.Unit

module Summary = Env.Summary

module Report = struct
  (** Reporting utility module. *)

  let debug proc_desc state summary =
    (* Print a local state, a summary and the fields of the returned value in the debug logs. *)
    let procname = Procdesc.get_proc_name proc_desc in
    L.debug Analysis Verbose "@[<v>@ @[<v2>" ;
    L.debug Analysis Verbose "@[<v>Result for procedure : %a@]@ " Procname.pp procname ;
    L.debug Analysis Verbose "@[<v2>LOCAL ENV:@ %a@]@ @ " Env.State.pp state ;
    L.debug Analysis Verbose "@[<v2>SUMMARY:@ %a@]@ @ " Env.Summary.pp summary ;
    L.debug Analysis Verbose "@[<v2>FIELDS OF RETURN:@ (%a)@]"
      (Fmt.iter
         (fun f summary ->
           Env.Summary.fold_cells summary
             (Var.of_pvar (Procdesc.get_ret_var proc_desc), [])
             ~f:(fun () fields -> f fields)
             ~init:() )
         ~sep:Fmt.comma Cell.pp )
      summary ;
    L.debug Analysis Verbose "@]@ @]"
end

(** Transfer functions to compute shapes. As the state is an imperative structure, this module takes
    a global state as a parameter that will be mutated through the analysis by the hereby defined
    transfer functions. *)
module TransferFunctions (State : sig
  val state : Env.State.t
end) =
struct
  module Domain = Domain
  module CFG = CFG

  type analysis_data = Summary.t InterproceduralAnalysis.t

  let state = State.state

  (** Returns the shape of an expression. Fresh shapes will be created as needed. *)
  let rec shape_expr (e : Exp.t) =
    match e with
    | Const _ | Closure _ ->
        (* We use fresh ids to represent shapes that do not hold fields. *)
        Env.State.create_shape ()
    | Var id ->
        Env.State.var_shape state (Var.of_id id)
    | Lvar pvar ->
        Env.State.var_shape state (Var.of_pvar pvar)
    | Lfield (e, fieldname, _) ->
        let shape_e = shape_expr e in
        Env.State.field_shape state shape_e fieldname
    | Sizeof {dynamic_length= None} ->
        Env.State.create_shape ()
    | UnOp (_, e, _) | Exn e | Cast (_, e) | Sizeof {dynamic_length= Some e} ->
        (* We first shape [e] to possibly discover some fields (eg. on [not (x.f)]), then return
           a fresh id as unary operators only return scalar value. *)
        ignore (shape_expr e : Env.State.shape) ;
        Env.State.create_shape ()
    | BinOp (_, e1, e2) | Lindex (e1, e2) ->
        (* Similar to the UnOp case *)
        ignore (shape_expr e1 : Env.State.shape) ;
        ignore (shape_expr e2 : Env.State.shape) ;
        Env.State.create_shape ()


  module CallModel = struct
    let make_tuple ret_id args =
      (* Unify the shapes of the fields of the return with the shapes of the arguments *)
      let ret_shape = Env.State.var_shape state ret_id in
      let tuple_type : Typ.name = ErlangType (Tuple (List.length args)) in
      let fieldname i = Fieldname.make tuple_type (ErlangTypeName.tuple_elem (i + 1)) in
      let ret_field_shape i = Env.State.field_shape state ret_shape (fieldname i) in
      List.iteri ~f:(fun i arg -> Env.State.unify state (shape_expr arg) (ret_field_shape i)) args


    let get_custom_model procname =
      let models = [(BuiltinDecl.__erlang_make_tuple, make_tuple)] in
      List.Assoc.find ~equal:Procname.equal models procname


    let ignore_shape_ret_and_args ret_var args =
      ignore (Env.State.var_shape state ret_var : Env.State.shape) ;
      ignore (List.map ~f:shape_expr args : Env.State.shape list) ;
      ()


    let unknown_model procname ret_var args =
      L.debug Analysis Verbose "@[<v2> LineageShape: no model found for expression `%a`@]@,"
        Procname.pp procname ;
      ignore_shape_ret_and_args ret_var args ;
      ()


    let standard_model procname summary ret_var args =
      (* Standard call of a known function:
         1. We get the shape of the actual args and ret_id
         2. We introduce into the environment the shapes of the formal args and return value of
            the function, obtained from the summary.
         3. We unify the actual and formal params/return together.
         Eventually the ret_id shape will therefore correctly be related to the shapes of the
         actual parameters of the function.
      *)
      let ret_id_shape = Env.State.var_shape state ret_var in
      let actual_args_shapes = List.map ~f:shape_expr args in
      let return = Var.of_pvar (Pvar.get_ret_pvar procname) in
      let formals =
        Attributes.load_exn procname |> ProcAttributes.get_pvar_formals
        |> List.map ~f:(fun (pvar, _typ) -> Var.of_pvar pvar)
      in
      let formal_shapes, returned_shape = Env.Summary.introduce ~return ~formals summary state in
      List.iter2_exn ~f:(fun s1 s2 -> Env.State.unify state s1 s2) actual_args_shapes formal_shapes ;
      Env.State.unify state ret_id_shape returned_shape


    let exec analyze_dependency procname ret_var args =
      match get_custom_model procname with
      | Some model ->
          model ret_var args
      | None -> (
        match analyze_dependency procname with
        | Some summary ->
            standard_model procname summary ret_var args
        | None ->
            unknown_model procname ret_var args )
  end

  let exec_assignment var rhs_exp =
    (* When assigning a value to a variable, we unify the current shape of that variable to the shape
       of the expression, thus merging together the fields that have been collected so far on both
       sides.

       Note that this might lead to over-approximating the field set of a variable that would be
       reassigned in the program with completely unrelated types. We believe that it does not happen
       with the Erlang translation anyway (and even then would not be a fundamental issue). *)
    let var_shape = Env.State.var_shape state var in
    let expr_shape = shape_expr rhs_exp in
    Env.State.unify state var_shape expr_shape


  let procname_of_exp (e : Exp.t) : Procname.t option =
    match e with Closure {name} | Const (Cfun name) -> Some name | _ -> None


  (** Execute an instruction by mutating the environment *)
  let exec_instr_unit {InterproceduralAnalysis.analyze_dependency} (instr : Sil.instr) =
    match instr with
    | Call ((ret_id, _typ), fun_exp, args, _location, _flags) -> (
        let ret_var = Var.of_id ret_id in
        let args = List.map ~f:fst args (* forget SIL types *) in
        match procname_of_exp fun_exp with
        | None ->
            CallModel.ignore_shape_ret_and_args ret_var args ;
            L.debug Analysis Verbose "@[<v>LineageShape: call of unsupported expression `%a`.@]@,"
              Exp.pp fun_exp
        | Some procname ->
            CallModel.exec analyze_dependency procname ret_var args )
    | Prune (e, _, _, _) ->
        ignore (shape_expr e : Env.State.shape)
    | Metadata _ ->
        ()
    | Load {id; e; _} ->
        exec_assignment (Var.of_id id) e
    | Store {e1= Lvar pvar; e2; _} ->
        (* Same as Load *)
        exec_assignment (Var.of_pvar pvar) e2
    | Store _ ->
        L.die InternalError "LineageShape: Store instructions are only supported with Lvar lhs"


  (** Mutates the environment and then return an abstract state (which is actually the same as the
      parameter). *)
  let exec_instr astate interproc_data _node _instr_index instr =
    let () = exec_instr_unit interproc_data instr in
    astate


  let pp_session_name _node fmt = Format.pp_print_string fmt "LineageShape"
end

(** A generative module that creates a fresh environment and passes it to the {!TransferFunctions}
    functor to build an analysis engine. *)
module Analyzer () = struct
  module State = struct
    let state = Env.State.create ()
  end

  include AbstractInterpreter.MakeRPO (TransferFunctions (State))
end

let unskipped_checker ({InterproceduralAnalysis.proc_desc} as analysis_data) =
  let module Analyzer = Analyzer () in
  (* Shape captured vars *)
  let shape_captured_var {CapturedVar.pvar} =
    ignore (Env.State.var_shape Analyzer.State.state (Var.of_pvar pvar) : Env.State.shape)
  in
  List.iter ~f:shape_captured_var (Procdesc.get_captured proc_desc) ;
  (* Analyze the procedure's code  *)
  let _invmap : Analyzer.invariant_map = Analyzer.exec_pdesc analysis_data ~initial:() proc_desc in
  let summary = Env.Summary.make Analyzer.State.state in
  Report.debug proc_desc Analyzer.State.state summary ;
  Some summary


let checker analysis_data =
  (* We skip the functions that would not be analysed by Lineage anyway *)
  LineageUtils.skip_unwanted (fun data () -> unskipped_checker data) analysis_data ()
