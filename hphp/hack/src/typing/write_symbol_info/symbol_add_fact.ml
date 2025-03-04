(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 * These functions build up the JSON necessary and then add facts
 * to the running result.
 *)

open Aast
open Full_fidelity_source_text
open Hh_json
open Hh_prelude
open Namespace_env
open Symbol_build_json
open Symbol_builder_types
open Symbol_json_util

(* Add a namespace fact if the nsenv is non-empty; otherwise,
return progress unchanged *)
let add_namespace_decl_fact nsenv progress =
  match nsenv.ns_name with
  | None -> progress (* Global namespace *)
  | Some "" -> progress
  | Some ns ->
    let json_fields = [("name", build_namespaceqname_json_nested ns)] in
    let (_fid, prog) =
      add_fact NamespaceDeclaration (JSON_Object json_fields) progress
    in
    prog

let add_container_decl_fact decl_pred name progress =
  let json_fact = JSON_Object [("name", build_qname_json_nested name)] in
  add_fact decl_pred json_fact progress

(* Helper function for adding facts for container parents, given
a context, a list of declarations, a predicate type, and progress state *)
let add_parent_decls ctx decls pred prog =
  List.fold decls ~init:([], prog) ~f:(fun (decl_refs, prog) decl ->
      let name = strip_tparams (get_type_from_hint ctx decl) in
      let (decl_id, prog) = add_container_decl_fact pred name prog in
      let ref = build_id_json decl_id in
      (ref :: decl_refs, prog))

let add_container_defn_fact ctx source_map clss decl_id member_decls prog =
  let prog = add_namespace_decl_fact clss.c_namespace prog in
  let tparams =
    List.map clss.c_tparams ~f:(build_type_param_json ctx source_map)
  in
  let common_fields =
    [
      ("declaration", build_id_json decl_id);
      ("members", JSON_Array member_decls);
      ( "attributes",
        build_attributes_json_nested source_map clss.c_user_attributes );
      ("typeParams", JSON_Array tparams);
    ]
  in
  let (req_extends_hints, req_implements_hints) =
    List.partition_tf clss.c_reqs ~f:snd
  in
  let (req_extends, prog) =
    add_parent_decls
      ctx
      (List.map req_extends_hints ~f:fst)
      ClassDeclaration
      prog
  in
  let (req_implements, prog) =
    add_parent_decls
      ctx
      (List.map req_implements_hints ~f:fst)
      InterfaceDeclaration
      prog
  in
  let (defn_pred, json_fields, prog) =
    match get_parent_kind clss with
    | InterfaceContainer ->
      let (extends, prog) =
        add_parent_decls ctx clss.c_extends InterfaceDeclaration prog
      in
      let req_fields =
        common_fields
        @ [
            ("extends_", JSON_Array extends);
            ("requireExtends", JSON_Array req_extends);
          ]
      in
      (InterfaceDefinition, req_fields, prog)
    | TraitContainer ->
      let (impls, prog) =
        add_parent_decls ctx clss.c_implements InterfaceDeclaration prog
      in
      let (uses, prog) =
        add_parent_decls ctx clss.c_uses TraitDeclaration prog
      in
      let req_fields =
        common_fields
        @ [
            ("implements_", JSON_Array impls);
            ("uses", JSON_Array uses);
            ("requireExtends", JSON_Array req_extends);
            ("requireImplements", JSON_Array req_implements);
          ]
      in
      (TraitDefinition, req_fields, prog)
    | ClassContainer ->
      let is_abstract = Ast_defs.is_c_abstract clss.c_kind in
      let (class_fields, prog) =
        let (impls, prog) =
          add_parent_decls ctx clss.c_implements InterfaceDeclaration prog
        in
        let (uses, prog) =
          add_parent_decls ctx clss.c_uses TraitDeclaration prog
        in
        let req_class_fields =
          common_fields
          @ [
              ("isAbstract", JSON_Bool is_abstract);
              ("isFinal", JSON_Bool clss.c_final);
              ("implements_", JSON_Array impls);
              ("uses", JSON_Array uses);
            ]
        in
        match clss.c_extends with
        | [] -> (req_class_fields, prog)
        | [parent] ->
          let (decl_id, prog) =
            let parent_clss = strip_tparams (get_type_from_hint ctx parent) in
            add_container_decl_fact ClassDeclaration parent_clss prog
          in
          (("extends_", build_id_json decl_id) :: req_class_fields, prog)
        | _ ->
          Hh_logger.log
            "WARNING: skipping extends field for class with multiple parents %s"
            (snd clss.c_name);
          (req_class_fields, prog)
      in
      (ClassDefinition, class_fields, prog)
  in
  add_fact defn_pred (JSON_Object json_fields) prog

let add_property_decl_fact con_type decl_id name progress =
  let json_fact =
    JSON_Object
      [
        ("name", build_name_json_nested name);
        ("container", build_container_json_ref con_type decl_id);
      ]
  in
  add_fact PropertyDeclaration json_fact progress

let add_class_const_decl_fact con_type decl_id name progress =
  let json_fact =
    JSON_Object
      [
        ("name", build_name_json_nested name);
        ("container", build_container_json_ref con_type decl_id);
      ]
  in
  add_fact ClassConstDeclaration json_fact progress

let add_type_const_decl_fact con_type decl_id name progress =
  let json_fact =
    JSON_Object
      [
        ("name", build_name_json_nested name);
        ("container", build_container_json_ref con_type decl_id);
      ]
  in
  add_fact TypeConstDeclaration json_fact progress

let add_method_decl_fact con_type decl_id name progress =
  let json_fact =
    JSON_Object
      [
        ("name", build_name_json_nested name);
        ("container", build_container_json_ref con_type decl_id);
      ]
  in
  add_fact MethodDeclaration json_fact progress

let add_method_defn_fact ctx source_map meth decl_id progress =
  let tparams =
    List.map meth.m_tparams ~f:(build_type_param_json ctx source_map)
  in
  let json_fact =
    JSON_Object
      [
        ("declaration", build_id_json decl_id);
        ( "signature",
          build_signature_json
            ctx
            source_map
            meth.m_params
            meth.m_variadic
            meth.m_ret );
        ("visibility", build_visibility_json meth.m_visibility);
        ("isAbstract", JSON_Bool meth.m_abstract);
        ("isAsync", build_is_async_json meth.m_fun_kind);
        ("isFinal", JSON_Bool meth.m_final);
        ("isStatic", JSON_Bool meth.m_static);
        ( "attributes",
          build_attributes_json_nested source_map meth.m_user_attributes );
        ("typeParams", JSON_Array tparams);
      ]
  in
  add_fact MethodDefinition json_fact progress

let add_method_overrides_fact
    meth_name base_cont_name base_cont_type der_cont_name der_cont_type prog =
  let json_fact =
    JSON_Object
      [
        ( "derived",
          build_method_decl_nested meth_name der_cont_name der_cont_type );
        ( "base",
          build_method_decl_nested meth_name base_cont_name base_cont_type );
      ]
  in
  add_fact MethodOverrides json_fact prog

let add_property_defn_fact ctx source_map prop decl_id progress =
  let base_fields =
    [
      ("declaration", build_id_json decl_id);
      ("visibility", build_visibility_json prop.cv_visibility);
      ("isFinal", JSON_Bool prop.cv_final);
      ("isAbstract", JSON_Bool prop.cv_abstract);
      ("isStatic", JSON_Bool prop.cv_is_static);
      ( "attributes",
        build_attributes_json_nested source_map prop.cv_user_attributes );
    ]
  in
  let json_fields =
    match hint_of_type_hint prop.cv_type with
    | None -> base_fields
    | Some h ->
      let ty = get_type_from_hint ctx h in
      ("type", build_type_json_nested ty) :: base_fields
  in
  add_fact PropertyDefinition (JSON_Object json_fields) progress

let add_class_const_defn_fact ctx source_map const decl_id progress =
  let base_fields = [("declaration", build_id_json decl_id)] in
  let json_fields =
    match const.cc_kind with
    | CCAbstract None -> base_fields
    | CCAbstract (Some (_, expr_pos, _))
    | CCConcrete (_, expr_pos, _) ->
      let fp = Relative_path.to_absolute (Pos.filename expr_pos) in
      let value =
        match SMap.find_opt fp source_map with
        | Some st -> source_at_span st expr_pos
        | None -> ""
      in
      ("value", JSON_String (strip_nested_quotes value)) :: base_fields
  in
  let json_fields =
    match const.cc_type with
    | None -> json_fields
    | Some h ->
      let ty = get_type_from_hint ctx h in
      ("type", build_type_json_nested ty) :: json_fields
  in
  add_fact ClassConstDefinition (JSON_Object json_fields) progress

let add_type_const_defn_fact ctx source_map tc decl_id progress =
  let base_fields =
    [
      ("declaration", build_id_json decl_id);
      ("kind", build_type_const_kind_json tc.c_tconst_kind);
      ( "attributes",
        build_attributes_json_nested source_map tc.c_tconst_user_attributes );
    ]
  in
  let json_fields =
    (* TODO(T88552052) should the default of an abstract type constant be used
     * as a value here *)
    match tc.c_tconst_kind with
    | TCConcrete { c_tc_type = h }
    | TCPartiallyAbstract { c_patc_type = h; _ }
    | TCAbstract { c_atc_default = Some h; _ } ->
      let ty = get_type_from_hint ctx h in
      ("type", build_type_json_nested ty) :: base_fields
    | TCAbstract { c_atc_default = None; _ } -> base_fields
  in
  add_fact TypeConstDefinition (JSON_Object json_fields) progress

let add_enum_decl_fact name progress =
  let json_fact = JSON_Object [("name", build_qname_json_nested name)] in
  add_fact EnumDeclaration json_fact progress

let add_enum_defn_fact ctx source_map enm enum_id enum_data enumerators progress
    =
  let prog = add_namespace_decl_fact enm.c_namespace progress in
  let (includes, prog) =
    add_parent_decls ctx enum_data.e_includes EnumDeclaration prog
  in
  let is_enum_class = Aast.is_enum_class enm in
  let json_fields =
    [
      ("declaration", build_id_json enum_id);
      ( "enumBase",
        build_type_json_nested (get_type_from_hint ctx enum_data.e_base) );
      ("enumerators", JSON_Array enumerators);
      ( "attributes",
        build_attributes_json_nested source_map enm.c_user_attributes );
      ("includes", JSON_Array includes);
      ("isEnumClass", JSON_Bool is_enum_class);
    ]
  in
  let json_fields =
    match enum_data.e_constraint with
    | None -> json_fields
    | Some c ->
      ("enumConstraint", build_type_json_nested (get_type_from_hint ctx c))
      :: json_fields
  in
  add_fact EnumDefinition (JSON_Object json_fields) prog

let add_enumerator_fact decl_id const_name progress =
  let json_fact =
    JSON_Object
      [
        ("name", build_name_json_nested const_name);
        ("enumeration", build_id_json decl_id);
      ]
  in
  add_fact Enumerator json_fact progress

let add_func_decl_fact name progress =
  let json_fact = JSON_Object [("name", build_qname_json_nested name)] in
  add_fact FunctionDeclaration json_fact progress

let add_func_defn_fact ctx source_map fd decl_id progress =
  let elem = fd.fd_fun in
  let prog = add_namespace_decl_fact fd.fd_namespace progress in
  let tparams =
    List.map elem.f_tparams ~f:(build_type_param_json ctx source_map)
  in
  let json_fields =
    [
      ("declaration", build_id_json decl_id);
      ( "signature",
        build_signature_json
          ctx
          source_map
          elem.f_params
          elem.f_variadic
          elem.f_ret );
      ("isAsync", build_is_async_json elem.f_fun_kind);
      ( "attributes",
        build_attributes_json_nested source_map elem.f_user_attributes );
      ("typeParams", JSON_Array tparams);
    ]
  in
  add_fact FunctionDefinition (JSON_Object json_fields) prog

let add_typedef_decl_fact name progress =
  let json_fact = JSON_Object [("name", build_qname_json_nested name)] in
  add_fact TypedefDeclaration json_fact progress

let add_typedef_defn_fact ctx source_map elem decl_id progress =
  let prog = add_namespace_decl_fact elem.t_namespace progress in
  let is_transparent =
    match elem.t_vis with
    | Transparent -> true
    | Tinternal -> true
    | Opaque -> false
  in
  let tparams =
    List.map elem.t_tparams ~f:(build_type_param_json ctx source_map)
  in
  let json_fields =
    [
      ("declaration", build_id_json decl_id);
      ("isTransparent", JSON_Bool is_transparent);
      ( "attributes",
        build_attributes_json_nested source_map elem.t_user_attributes );
      ("typeParams", JSON_Array tparams);
    ]
  in
  add_fact TypedefDefinition (JSON_Object json_fields) prog

let add_gconst_decl_fact name progress =
  let json_fact = JSON_Object [("name", build_qname_json_nested name)] in
  add_fact GlobalConstDeclaration json_fact progress

let add_gconst_defn_fact ctx source_map elem decl_id progress =
  let prog = add_namespace_decl_fact elem.cst_namespace progress in
  let value =
    let (_, expr_pos, _) = elem.cst_value in
    let fp = Relative_path.to_absolute (Pos.filename expr_pos) in
    match SMap.find_opt fp source_map with
    | Some st -> source_at_span st expr_pos
    | None -> ""
  in
  let req_fields =
    [
      ("declaration", build_id_json decl_id);
      ("value", JSON_String (strip_nested_quotes value));
    ]
  in
  let json_fields =
    match elem.cst_type with
    | None -> req_fields
    | Some h ->
      let ty = get_type_from_hint ctx h in
      ("type", build_type_json_nested ty) :: req_fields
  in
  let json_fact = JSON_Object json_fields in
  add_fact GlobalConstDefinition json_fact prog

let add_decl_loc_fact pos decl_json progress =
  let filepath = Relative_path.to_absolute (Pos.filename pos) in
  let json_fact =
    JSON_Object
      [
        ("declaration", decl_json);
        ("file", build_file_json_nested filepath);
        ("span", build_bytespan_json pos);
      ]
  in
  add_fact DeclarationLocation json_fact progress

let add_decl_comment_fact pos decl_json progress =
  let filepath = Relative_path.to_absolute (Pos.filename pos) in
  let json_fact =
    JSON_Object
      [
        ("declaration", decl_json);
        ("file", build_file_json_nested filepath);
        ("span", build_bytespan_json pos);
      ]
  in
  add_fact DeclarationComment json_fact progress

let add_decl_span_fact pos decl_json progress =
  let filepath = Relative_path.to_absolute (Pos.filename pos) in
  let json_fact =
    JSON_Object
      [
        ("declaration", decl_json);
        ("file", build_file_json_nested filepath);
        ("span", build_bytespan_json pos);
      ]
  in
  add_fact DeclarationSpan json_fact progress

let add_file_lines_fact filepath sourceText progress =
  let lineLengths =
    Line_break_map.offsets_to_line_lengths sourceText.offset_map
  in
  let endsInNewline = ends_in_newline sourceText in
  let hasUnicodeOrTabs = has_tabs_or_multibyte_codepoints sourceText in
  let json_fact =
    build_file_lines_json filepath lineLengths endsInNewline hasUnicodeOrTabs
  in
  add_fact FileLines json_fact progress

let add_file_xrefs_fact filepath xref_map progress =
  let json_fact =
    JSON_Object
      [
        ("file", build_file_json_nested filepath);
        ("xrefs", build_xrefs_json xref_map);
      ]
  in
  add_fact FileXRefs json_fact progress

let add_file_decls_fact filepath decls progress =
  let json_fact =
    JSON_Object
      [
        ("file", build_file_json_nested filepath);
        ("declarations", JSON_Array decls);
      ]
  in
  add_fact FileDeclarations json_fact progress

let add_method_occ_fact receiver_class name progress =
  let module SO = SymbolOccurrence in
  let json_fact =
    List.concat
    @@ [
         [("name", build_name_json_nested name)];
         (match receiver_class with
         | SO.ClassName className ->
           [("className", build_name_json_nested className)]
         | SO.UnknownClass -> []);
       ]
  in
  add_fact MethodOccurrence (JSON_Object json_fact) progress
