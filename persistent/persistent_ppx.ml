open Ppxlib
open Ast_builder.Default
open ContainersLabels
open Ppx_deriving_schema
open Deriving_helper

class virtual deriving_type =
  object (self)
    method virtual name : string

    method derive_of_tuple
        : loc:location -> Repr.type_expr list -> core_type =
      not_supported "tuple types"

    method derive_of_record
        : loc:location -> (label loc * Repr.type_expr) list -> core_type =
      not_supported "record types"

    method derive_of_variant
        : loc:location -> Repr.variant_case list -> core_type =
      not_supported "variant types"

    method derive_of_polyvariant
        : loc:location -> Repr.polyvariant_case list -> core_type =
      not_supported "variant types"

    method derive_of_type_expr
        : loc:location -> Repr.type_expr -> core_type =
      fun ~loc t ->
        match t with
        | _, Repr.Te_tuple ts -> self#derive_of_tuple ~loc ts
        | _, Te_var _ -> not_supported ~loc "type variables"
        | _, Te_opaque (n, ts) ->
            if not (List.is_empty ts) then
              not_supported ~loc "type params"
            else
              let n = map_loc (derive_of_longident self#name) n in
              ptyp_constr ~loc n []
        | _, Te_polyvariant cs -> self#derive_of_polyvariant ~loc cs

    method private derive_type_shape ~(loc : location) =
      function
      | Repr.Ts_expr t -> self#derive_of_type_expr ~loc t
      | Ts_record fs -> self#derive_of_record ~loc fs
      | Ts_variant cs -> self#derive_of_variant ~loc cs

    method derive_type_decl { Repr.name; params; shape; loc }
        : type_declaration list =
      let manifest = self#derive_type_shape ~loc shape in
      if not (List.is_empty params) then not_supported ~loc "type params"
      else
        [
          type_declaration ~loc
            ~name:(map_loc (derive_of_label self#name) name)
            ~manifest:(Some manifest) ~cstrs:[] ~private_:Public
            ~kind:Ptype_abstract ~params:[];
        ]

    method generator
        : ctxt:Expansion_context.Deriver.t ->
          rec_flag * type_declaration list ->
          structure =
      fun ~ctxt (_rec_flag, type_decls) ->
        let loc = Expansion_context.Deriver.derived_item_loc ctxt in
        match List.map type_decls ~f:Repr.of_type_declaration with
        | exception Not_supported (loc, msg) ->
            [ [%stri [%%ocaml.error [%e estring ~loc msg]]] ]
        | reprs ->
            let type_decls =
              List.flat_map reprs ~f:(fun decl ->
                  self#derive_type_decl decl)
            in
            [%str [%%i pstr_type ~loc Recursive type_decls]]
  end

let with_genname_field ~loc col body =
  [%expr
    let genname =
      match [%e col] with
      | "" -> fun n -> n
      | prefix -> fun n -> Printf.sprintf "%s_%s" prefix n
    in
    [%e body [%expr genname]]]

let with_genname_idx ~loc col body =
  [%expr
    let genname =
      match [%e col] with
      | "" -> fun i -> Printf.sprintf "c%i" i
      | prefix -> fun i -> Printf.sprintf "%s_c%i" prefix i
    in
    [%e body [%expr genname]]]

let derive_scope_type =
  object (self)
    inherit deriving_type
    method name = "scope"

    method! derive_of_record
        : loc:location -> (label loc * Repr.type_expr) list -> core_type =
      fun ~loc fs ->
        let fs =
          List.map fs ~f:(fun (n, t) ->
              let loc = n.loc in
              let t = self#derive_of_type_expr ~loc t in
              {
                pof_desc = Otag (n, t);
                pof_loc = loc;
                pof_attributes = [];
              })
        in
        ptyp_object ~loc fs Closed

    method! derive_of_tuple
        : loc:location -> Repr.type_expr list -> core_type =
      fun ~loc ts ->
        let ts = List.map ts ~f:(self#derive_of_type_expr ~loc) in
        ptyp_tuple ~loc ts
  end

let derive_scope =
  let match_table ~loc x f =
    match gen_pat_tuple ~loc "x" 2 with
    | p, [ t; c ] -> pexp_match ~loc x [ p --> f (t, c) ]
    | _, _ -> assert false
  in
  object (self)
    inherit deriving1
    method name = "scope"

    method t ~loc name _t =
      let id = map_loc (derive_of_label derive_scope_type#name) name in
      let id = map_loc lident id in
      let scope = ptyp_constr ~loc id [] in
      [%type: string * string -> [%t scope]]

    method! derive_of_tuple ~loc ts x =
      match_table ~loc x @@ fun (tbl, col) ->
      with_genname_idx ~loc col @@ fun genname ->
      let es =
        List.mapi ts ~f:(fun idx t ->
            let idx = eint ~loc idx in
            self#derive_of_type_expr ~loc t
              [%expr [%e tbl], [%e genname] [%e idx]])
      in
      pexp_tuple ~loc es

    method! derive_of_record ~loc fs x =
      match_table ~loc x @@ fun (tbl, col) ->
      with_genname_field ~loc col @@ fun genname ->
      let fields =
        List.map fs ~f:(fun (n, t) ->
            let loc = n.loc in
            let col' = estring ~loc n.txt in
            let e =
              self#derive_of_type_expr ~loc t
                [%expr [%e tbl], [%e genname] [%e col']]
            in
            {
              pcf_desc = Pcf_method (n, Public, Cfk_concrete (Fresh, e));
              pcf_loc = loc;
              pcf_attributes = [];
            })
      in
      pexp_object ~loc (class_structure ~self:(ppat_any ~loc) ~fields)
  end

let derive_decode =
  object (self)
    inherit deriving1
    method name = "decode"

    method t ~loc _name t =
      [%type: Sqlite3.Data.t array -> Persistent.ctx -> [%t t]]

    method! derive_of_tuple ~loc ts x =
      let n = List.length ts in
      let ps, e = gen_tuple ~loc "x" n in
      let e =
        List.fold_left2 (List.rev ps) (List.rev ts) ~init:e
          ~f:(fun next p t ->
            [%expr
              let [%p p] = [%e self#derive_of_type_expr ~loc t x] ctx in
              [%e next]])
      in
      [%expr fun ctx -> [%e e]]

    method! derive_of_record ~loc fs x =
      let ps, e = gen_record ~loc "x" fs in
      let e =
        List.fold_left2 (List.rev ps) (List.rev fs) ~init:e
          ~f:(fun next p (_, t) ->
            [%expr
              let [%p p] = [%e self#derive_of_type_expr ~loc t x] ctx in
              [%e next]])
      in
      [%expr fun ctx -> [%e e]]
  end

let derive_bind =
  object (self)
    inherit deriving1
    method name = "bind"

    method t ~loc _name t =
      [%type: [%t t] -> Persistent.ctx -> Sqlite3.stmt -> unit]

    method! derive_of_tuple ~loc ts x =
      let n = List.length ts in
      let p, es = gen_pat_tuple ~loc "x" n in
      let e =
        List.fold_left2 (List.rev es) (List.rev ts) ~init:[%expr ()]
          ~f:(fun next e t ->
            [%expr
              [%e self#derive_of_type_expr ~loc t e] ctx stmt;
              [%e next]])
      in
      [%expr fun ctx stmt -> [%e pexp_match ~loc x [ p --> e ]]]

    method! derive_of_record ~loc fs x =
      let p, es = gen_pat_record ~loc "x" fs in
      let e =
        List.fold_left2 (List.rev es) (List.rev fs) ~init:[%expr ()]
          ~f:(fun next e (_, t) ->
            [%expr
              [%e self#derive_of_type_expr ~loc t e] ctx stmt;
              [%e next]])
      in
      [%expr fun ctx stmt -> [%e pexp_match ~loc x [ p --> e ]]]
  end

let derive_columns =
  object (self)
    inherit deriving1
    method name = "columns"
    method t ~loc _name _t = [%type: string -> (string * string) list]

    method! derive_of_tuple ~loc ts x =
      with_genname_idx ~loc x @@ fun genname ->
      let es =
        List.mapi ts ~f:(fun i t ->
            let i = eint ~loc i in
            [%expr
              [%e
                self#derive_of_type_expr ~loc t
                  [%expr [%e genname] [%e i]]]])
      in
      [%expr List.flatten [%e pexp_list ~loc es]]

    method! derive_of_record ~loc fs x =
      with_genname_field ~loc x @@ fun genname ->
      let es =
        List.map fs ~f:(fun ((n : label loc), t) ->
            let n = estring ~loc:n.loc n.txt in
            [%expr
              [%e
                self#derive_of_type_expr ~loc t
                  [%expr [%e genname] [%e n]]]])
      in
      [%expr List.flatten [%e pexp_list ~loc es]]
  end

let derive_fields =
  object (self)
    inherit deriving1
    method name = "fields"

    method t ~loc _name _t =
      [%type: string -> (Persistent.any_expr * string) list]

    method! derive_of_tuple ~loc ts x =
      with_genname_idx ~loc x @@ fun genname ->
      let es =
        List.mapi ts ~f:(fun i t ->
            let i = eint ~loc i in
            [%expr
              [%e
                self#derive_of_type_expr ~loc t
                  [%expr [%e genname] [%e i]]]])
      in
      [%expr List.flatten [%e pexp_list ~loc es]]

    method! derive_of_record ~loc fs x =
      with_genname_field ~loc x @@ fun genname ->
      let es =
        List.map fs ~f:(fun ((n : label loc), t) ->
            let n = estring ~loc:n.loc n.txt in
            [%expr
              [%e
                self#derive_of_type_expr ~loc t
                  [%expr [%e genname] [%e n]]]])
      in
      [%expr List.flatten [%e pexp_list ~loc es]]
  end

let codec =
  Deriving.add "codec"
    ~str_type_decl:
      (Deriving.Generator.V2.make Deriving.Args.empty (fun ~ctxt str ->
           try
             derive_decode#generator ~ctxt str
             @ derive_bind#generator ~ctxt str
             @ derive_columns#generator ~ctxt str
             @ derive_fields#generator ~ctxt str
             @ derive_scope_type#generator ~ctxt str
             @ derive_scope#generator ~ctxt str
           with Not_supported (loc, msg) ->
             [ [%stri [%%ocaml.error [%e estring ~loc msg]]] ]))

let _ =
  let derive_table ({ name; params; shape = _; loc } : Repr.type_decl) =
    if not (List.is_empty params) then
      not_supported ~loc "type parameters";
    let pat = ppat_var ~loc name in
    let columns = map_loc (derive_of_label "columns") name in
    let scope = map_loc lident (map_loc (derive_of_label "scope") name) in
    let fields =
      map_loc lident (map_loc (derive_of_label "fields") name)
    in
    let bind = map_loc lident (map_loc (derive_of_label "bind") name) in
    let decode =
      map_loc lident (map_loc (derive_of_label "decode") name)
    in
    let columns =
      { loc = columns.loc; txt = Longident.parse columns.txt }
    in
    value_binding ~loc ~pat
      ~expr:
        [%expr
          {
            Persistent.table = [%e estring ~loc name.txt];
            scope = (fun t -> [%e pexp_ident ~loc scope] (t, ""));
            columns = [%e pexp_ident ~loc columns] "";
            decode = [%e pexp_ident ~loc decode];
            bind = [%e pexp_ident ~loc bind];
            fields = [%e pexp_ident ~loc fields] "";
          }]
  in
  Deriving.add "entity"
    ~str_type_decl:
      (Deriving.Generator.V2.make ~deps:[ codec ] Deriving.Args.empty
         (fun ~ctxt (rec_flag, type_decls) ->
           let loc = Expansion_context.Deriver.derived_item_loc ctxt in
           match List.map type_decls ~f:Repr.of_type_declaration with
           | exception Not_supported (loc, msg) ->
               [ [%stri [%%ocaml.error [%e estring ~loc msg]]] ]
           | reprs -> (
               try
                 let bindings = List.map reprs ~f:derive_table in
                 [%str
                   [@@@ocaml.warning "-39-11"]

                   [%%i pstr_value ~loc rec_flag bindings]]
               with Not_supported (loc, msg) ->
                 [ [%stri [%%ocaml.error [%e estring ~loc msg]]] ])))

let pexp_errorf ~loc fmt =
  let open Ast_builder.Default in
  Printf.ksprintf
    (fun msg ->
      pexp_extension ~loc (Location.error_extensionf ~loc "%s" msg))
    fmt

exception Error of expression

let raise_errorf ~loc fmt =
  let open Ast_builder.Default in
  Printf.ksprintf
    (fun msg ->
      let expr =
        pexp_extension ~loc (Location.error_extensionf ~loc "%s" msg)
      in
      raise (Error expr))
    fmt

let wrap_expand f ~ctxt e = try f ~ctxt e with Error e -> e

module Expr_form = struct
  let expand ~ctxt:_ (e : expression) =
    let rec rewrite e =
      let loc = e.pexp_loc in
      match e.pexp_desc with
      | Pexp_ident { txt = Lident "="; _ } -> [%expr Persistent.E.( = )]
      | Pexp_ident _ -> e
      | Pexp_field (e, { txt = Lident n; loc = nloc }) ->
          pexp_send ~loc (rewrite e) { txt = n; loc = nloc }
      | Pexp_apply (e, args) ->
          pexp_apply ~loc (rewrite e)
            (List.map args ~f:(fun (l, e) -> l, rewrite e))
      | Pexp_constant (Pconst_integer _) ->
          [%expr Persistent.E.int [%e e]]
      | Pexp_constant (Pconst_char _) -> [%expr Persistent.E.char [%e e]]
      | Pexp_constant (Pconst_string (_, _, _)) ->
          [%expr Persistent.E.string [%e e]]
      | Pexp_constant (Pconst_float (_, _)) ->
          [%expr Persistent.E.float [%e e]]
      | Pexp_field _
      | Pexp_let (_, _, _)
      | Pexp_function _
      | Pexp_fun (_, _, _, _)
      | Pexp_match (_, _)
      | Pexp_try (_, _)
      | Pexp_tuple _
      | Pexp_construct (_, _)
      | Pexp_variant (_, _)
      | Pexp_record (_, _)
      | Pexp_setfield (_, _, _)
      | Pexp_array _
      | Pexp_ifthenelse (_, _, _)
      | Pexp_sequence (_, _)
      | Pexp_while (_, _)
      | Pexp_for (_, _, _, _, _)
      | Pexp_constraint (_, _)
      | Pexp_coerce (_, _, _)
      | Pexp_send (_, _)
      | Pexp_new _
      | Pexp_setinstvar (_, _)
      | Pexp_override _
      | Pexp_letmodule (_, _, _)
      | Pexp_letexception (_, _)
      | Pexp_assert _ | Pexp_lazy _
      | Pexp_poly (_, _)
      | Pexp_object _
      | Pexp_newtype (_, _)
      | Pexp_pack _
      | Pexp_open (_, _)
      | Pexp_letop _ | Pexp_extension _ | Pexp_unreachable ->
          pexp_errorf ~loc "this expression is not supported"
    in
    rewrite e

  let ext =
    let pattern =
      let open Ast_pattern in
      single_expr_payload __
    in
    Context_free.Rule.extension
      (Extension.V3.declare "expr" Extension.Context.expression pattern
         (wrap_expand expand))
end

module Query_form = struct
  let rec expand' ~ctxt e =
    let rec unroll acc e =
      match e.pexp_desc with
      | Pexp_sequence (a, b) -> unroll (a :: acc) b
      | _ -> List.rev (e :: acc)
    in
    let ppat_scope ~loc = function
      | [] -> [%pat? here]
      | [ x ] -> x
      | xs -> ppat_tuple ~loc xs
    in
    let pexp_slot' ~loc names e =
      [%expr
        fun [@ocaml.warning "-27"] [%p ppat_scope ~loc names] -> [%e e]]
    in
    let pexp_slot ~loc names e =
      [%expr
        fun [@ocaml.warning "-27"] [%p ppat_scope ~loc names] ->
          [%e Expr_form.expand ~ctxt e]]
    in
    let rewrite names q =
      let loc = q.pexp_loc in
      match q with
      | [%expr from [%e? id]] ->
          let names =
            match id.pexp_desc with
            | Pexp_ident { txt = Lident txt; loc } ->
                [ ppat_var ~loc { txt; loc } ]
            | _ ->
                raise_errorf ~loc:id.pexp_loc
                  "only identifiers are allowed"
          in
          names, [%expr Persistent.Q.from [%e id]]
      | [%expr where [%e? e]] ->
          names, [%expr Persistent.Q.where [%e pexp_slot ~loc names e]]
      | [%expr order_by [%e? fs]] ->
          let fs =
            let fs =
              match fs.pexp_desc with Pexp_tuple fs -> fs | _ -> [ fs ]
            in
            List.map fs ~f:(function
              | [%expr desc [%e? e]] ->
                  [%expr Persistent.Q.desc [%e Expr_form.expand ~ctxt e]]
              | [%expr asc [%e? e]] ->
                  [%expr Persistent.Q.asc [%e Expr_form.expand ~ctxt e]]
              | e ->
                  raise_errorf ~loc:e.pexp_loc
                    "should have form 'desc e' or 'asc e'")
          in
          let e = pexp_list ~loc fs in
          ( names,
            [%expr Persistent.Q.order_by [%e pexp_slot' ~loc names e]] )
      | [%expr left_join [%e? q] [%e? e]] ->
          let qnames, q = expand' ~ctxt q in
          let names = names @ qnames in
          ( names,
            [%expr
              Persistent.Q.left_join [%e q] [%e pexp_slot ~loc names e]] )
      | { pexp_desc = Pexp_tuple xs; _ } ->
          let xs = List.map xs ~f:(Expr_form.expand ~ctxt) in
          let make_scope =
            let xs =
              List.mapi xs ~f:(fun i e ->
                  let n = estring ~loc (Printf.sprintf "c%i" i) in
                  [%expr Persistent.E.as_col t [%e n] [%e e]])
            in
            pexp_slot' ~loc names [%expr fun t -> [%e pexp_tuple ~loc xs]]
          in
          let ps, e = gen_tuple ~loc "col" (List.length xs) in
          let x, xs =
            match List.combine ps xs with
            | [] -> assert false
            | x :: xs -> x, xs
          in
          let make txt (pat, exp) =
            let exp = [%expr Persistent.P.get [%e exp]] in
            binding_op ~loc ~op:{ loc; txt } ~pat ~exp
          in
          let e =
            pexp_letop ~loc
              (letop ~body:e ~let_:(make "let+" x)
                 ~ands:(List.map xs ~f:(make "and+")))
          in
          let e =
            [%expr
              let open Persistent.P in
              [%e e]]
          in
          let e =
            [%expr
              Persistent.P.select' [%e make_scope]
                [%e pexp_slot' ~loc names e]]
          in
          [ [%pat? here] ], e
      | { pexp_desc = Pexp_record (_fs, None); _ } ->
          raise_errorf ~loc "select is not supported yet"
      | { pexp_desc = Pexp_ident id; _ } ->
          let name =
            match id.txt with
            | Lident txt | Ldot (_, txt) ->
                ppat_var ~loc { txt; loc = id.loc }
            | Lapply _ -> raise_errorf ~loc "cannot query this"
          in
          [ name ], e
      | _ -> raise_errorf ~loc "unknown query form"
    in
    match unroll [] e with
    | [] ->
        raise_errorf
          ~loc:(Expansion_context.Extension.extension_point_loc ctxt)
          "empty query"
    | q :: qs ->
        List.fold_left qs ~init:(rewrite [] q) ~f:(fun (names, prev) e ->
            let loc = prev.pexp_loc in
            let names, e = rewrite names e in
            names, [%expr [%e prev] |> [%e e]])

  let expand ~ctxt e =
    let loc = Expansion_context.Extension.extension_point_loc ctxt in
    match e with
    | [%expr
        let [%p? p] = [%e? e] in
        [%e? body]] ->
        let e = snd (expand' ~ctxt e) in
        [%expr
          let [%p p] = [%e e] in
          [%e body]]
    | e -> snd (expand' ~ctxt e)

  let ext =
    let pattern =
      let open Ast_pattern in
      single_expr_payload __
    in
    Context_free.Rule.extension
      (Extension.V3.declare "query" Extension.Context.expression pattern
         (wrap_expand expand))
end

let () =
  Driver.register_transformation
    ~rules:[ Expr_form.ext; Query_form.ext ]
    "persistent_ppx"
