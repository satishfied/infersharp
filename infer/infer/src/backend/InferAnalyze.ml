(*
 * Copyright (c) 2009-2013, Monoidics ltd.
 * Copyright (c) 2013-present, Facebook, Inc.
 * Portions Copyright (c) Microsoft Corporation.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Main module for the analysis after the capture phase *)
open! IStd
open Utils
open Yojson
open Yojson.Safe.Util

(* We use Yojson.Safe to parse json so it handles long integers, which cannot be handled by OCaml's basic integers *)

module L = Logging
module Hashtbl = Caml.Hashtbl

module IntHash =
  struct
    type t = int
    let equal i j = Int.equal i j
    let hash i = i land Int.max_value
  end
module IntTbl = Hashtbl.Make(IntHash)

exception JsonParse_Error of string
exception StringParse_Error of string

let parse_pair (fstparse : Yojson.Safe.json -> 'a) (sndparse : Yojson.Safe.json -> 'b) (json : Yojson.Safe.json) : ('a * 'b)=
  match (to_list json) with
  | (x::y::[]) -> (fstparse x, sndparse y)
  | _ -> raise (JsonParse_Error "JSON Parse Error: Expected pair, got something else")

let parse_triple (fstparse : Yojson.Safe.json -> 'a) (sndparse : Yojson.Safe.json -> 'b) (thdparse : Yojson.Safe.json -> 'c) (json : Yojson.Safe.json) : ('a * 'b * 'c) =
  match (to_list json) with
  | (x::y::z::[]) -> (fstparse x, sndparse y, thdparse z)
  | _ -> raise (JsonParse_Error "JSON Parse Error: Expected triple, got something else")

let parse_quadruple (fstparse : Yojson.Safe.json -> 'a) (sndparse : Yojson.Safe.json -> 'b) (thdparse : Yojson.Safe.json -> 'c) (frthparse : Yojson.Safe.json -> 'd) (json : Yojson.Safe.json) : ('a * 'b * 'c * 'd) =
  match (to_list json) with
  | (x::y::z::u::[]) -> (fstparse x, sndparse y, thdparse z, frthparse u)
  | _ -> raise (JsonParse_Error "JSON Parse Error: Expected quadruple, got something else")

let parse_quintuple (fstparse : Yojson.Safe.json -> 'a) (sndparse : Yojson.Safe.json -> 'b) (thdparse : Yojson.Safe.json -> 'c) (frthparse : Yojson.Safe.json -> 'd) (fithparse : Yojson.Safe.json -> 'e) (json : Yojson.Safe.json) : ('a * 'b * 'c * 'd * 'e) =
  match (to_list json) with
  | (x::y::z::u::v::[]) -> (fstparse x, sndparse y, thdparse z, frthparse u, fithparse v)
  | _ -> raise (JsonParse_Error "JSON Parse Error: Expected quintuple, got something else")

let parse_septuple (parse1 : Yojson.Safe.json -> 'a) (parse2 : Yojson.Safe.json -> 'b) (parse3 : Yojson.Safe.json -> 'c) (parse4 : Yojson.Safe.json -> 'd) (parse5 : Yojson.Safe.json -> 'e) (parse6 : Yojson.Safe.json -> 'f) (parse7 : Yojson.Safe.json -> 'g) (json : Yojson.Safe.json) : ('a * 'b * 'c * 'd * 'e * 'f * 'g) =
  match (to_list json) with
  | (x::y::z::u::v::w::n::[]) -> (parse1 x, parse2 y, parse3 z, parse4 u, parse5 v, parse6 w, parse7 n)
  | _ -> raise (JsonParse_Error "JSON Parse Error: Expected septuple, got something else")

let typename_of_classname cn = Typ.Name.CSharp.from_string cn

let parse_list (eleparse : Yojson.Safe.json -> 'a) (json : Yojson.Safe.json) =
  List.map ~f:eleparse (to_list json)
 
let parse_cil_type_name (str : string) : Typ.Procname.CSharp.csharp_type =
  let r = Str.regexp "\\." in
  try
    let n = Str.search_backward r str (String.length str) in
    let _namespace = Str.string_before str n in
    let _name = Str.string_after str (n+1) in
    Typ.Name.CSharp.Split.make ?namespace:(Some _namespace) _name
  with e ->
    Typ.Name.CSharp.Split.make ?namespace:(None) str

let parse_cil_procname (json : Yojson.Safe.json) : Typ.Procname.t =
  let method_name = to_string (member "method_name" json) in
  match method_name with
  | "__new" ->
    BuiltinDecl.__new
  | _ ->
    let return_type = 
      if String.equal Typ.Procname.CSharp.constructor_method_name method_name then None
      else Some (to_string (member "return_type" json) |> parse_cil_type_name) in
    let class_name = to_string (member "class_name" json) |> Typ.Name.CSharp.from_string in
    let param_types = 
      parse_list 
        to_string
        (member "parameters" json)
    in
    let params = List.map ~f:parse_cil_type_name param_types in
    let is_static = to_bool (member "is_static" json) in
    let method_kind = if is_static then Typ.Procname.CSharp.Static else Typ.Procname.CSharp.Non_Static in
    let proc_name_cs = Typ.Procname.CSharp.make method_name params class_name return_type method_kind in
    Typ.Procname.CSharp proc_name_cs

let parse_ikind (json : Yojson.Safe.json) =
  let ikind_map =
    [ ("IChar", Typ.IChar) ; ("ISChar", Typ.ISChar) ; ("IUChar", Typ.IUChar) ; ("IBool", Typ.IBool) ;
      ("IInt", Typ.IInt) ; ("IUInt", Typ.IUInt) ;
      ("IShort", Typ.IShort) ; ("IUShort", Typ.IUShort) ;
      ("ILong", Typ.ILong) ; ("IULong", Typ.IULong) ; ("ILongLong", Typ.ILongLong) ; ("IULongLong", Typ.IULongLong) ;
      ("I128", Typ.I128) ; ("IU128", Typ.IU128) ] in
  List.Assoc.find_exn ~equal:String.equal ikind_map (to_string json)

let parse_fkind (json : Yojson.Safe.json) =
  let fkind_map = [ ("FFloat", Typ.FFloat) ; ("FDouble", Typ.FDouble) ; ("FLongDouble", Typ.FLongDouble) ] in
  List.Assoc.find_exn ~equal:String.equal fkind_map (to_string json)

let parse_ptr_kind (json : Yojson.Safe.json) =
  let ptr_kind_map = [ ("Pk_pointer", Typ.Pk_pointer) ; ("Pk_reference", Typ.Pk_reference) ; ("Pk_objc_weak", Typ.Pk_objc_weak) ; ("Pk_objc_unsafe_unretained", Typ.Pk_objc_unsafe_unretained) ; ("Pk_objc_autoreleasing", Typ.Pk_objc_autoreleasing) ] in
  List.Assoc.find_exn ~equal:String.equal ptr_kind_map (to_string json)

let parse_if_kind (json : Yojson.Safe.json) =
  let ifkind_map = [ ("Ik_bexp", Sil.Ik_bexp) ; ("Ik_dowhile", Sil.Ik_dowhile) ; ("Ik_for", Sil.Ik_for) ; ("Ik_if", Sil.Ik_if) ; ("Ik_land_lor", Sil.Ik_land_lor) ; ("Ik_while", Sil.Ik_while) ; ("Ik_switch", Sil.Ik_switch) ] in
  List.Assoc.find_exn ~equal:String.equal ifkind_map (to_string json)
  
let parse_csu (json : Yojson.Safe.json) =
  let csu = to_string (member "csu_kind" json) in
  let name = to_string (member "name" json) in
  match csu with
  | "Class" -> typename_of_classname name
  | _ -> raise (JsonParse_Error "JSON Parse Error: Can only parse Class types so far.")

let parse_unop (json : Yojson.Safe.json) =
  let unop_map = [ ("Neg", Unop.Neg) ; ("BNot", Unop.BNot) ; ("LNot", Unop.LNot) ] in
  List.Assoc.find_exn ~equal:String.equal unop_map (to_string json)

let parse_binop (json : Yojson.Safe.json) = (*TODO: need to check the usage of "None" *)
  let binop_map = [ ("PlusA", Binop.PlusA None) ; 
                    ("PlusPI", Binop.PlusPI) ; 
                    ("MinusA", Binop.MinusA None) ; 
                    ("MinusPI", Binop.MinusPI) ; 
                    ("MinusPP", Binop.MinusPP) ; 
                    ("Mult", Binop.Mult None) ; 
                    ("Div", Binop.Div) ; 
                    ("Mod", Binop.Mod) ; 
                    ("Shiftlt", Binop.Shiftlt) ; 
                    ("Shiftrt", Binop.Shiftrt) ; 
                    ("Lt", Binop.Lt) ; 
                    ("Gt", Binop.Gt) ; 
                    ("Le", Binop.Le) ; 
                    ("Ge", Binop.Ge) ; 
                    ("Eq", Binop.Eq) ; 
                    ("Ne", Binop.Ne) ; 
                    ("BAnd", Binop.BAnd) ; 
                    ("BXor", Binop.BXor) ; 
                    ("BOr", Binop.BOr) ; 
                    ("LAnd", Binop.LAnd) ; 
                    ("LOr", Binop.LOr) ] in
  List.Assoc.find_exn ~equal:String.equal binop_map (to_string json)

let parse_typename (json : Yojson.Safe.json) =
  let tname = to_string (member "type_name_kind" json) in
  if String.equal tname "TN_typedef" then
    typename_of_classname (to_string (member "name" json))
  else if String.equal tname "CsuTypeName" then
    parse_csu json (*what about if the name is <Module>*)
  else
    Logging.die InternalError "Can't parse typename"

let parse_long (json: Yojson.Safe.json) =
  Int64.of_string (Yojson.Safe.to_string json)

let parse_intrep (json : Yojson.Safe.json) =
  let s = to_bool (member "unsigned" json) in
  let v = parse_long (member "value" json) in
  let p = to_bool (member "is_pointer" json) in
  match (p,v) with
  | (true, 0L) -> IntLit.null
  | _ -> IntLit.of_int64 v

let parse_ident (json : Yojson.Safe.json) =
  let k = (to_string (member "kind" json)) in
  let kind = 
    if String.equal k "Normal" then
      Ident.knormal
    else if String.equal k "Primed" then
      Ident.kprimed
    else if String.equal k "Footprint" then
      Ident.kfootprint
    else if String.equal k "None" then 
      Ident.knone
    else
      Logging.die InternalError "Unsupported identifier kind: %s" k
  in
  Ident.create_with_stamp
    kind
    (Ident.string_to_name (to_string (member "name" json)))
    (to_int (member "stamp" json))

let parse_fieldident (json : Yojson.Safe.json) =
  Typ.Fieldname.CSharp.from_string (to_string (member "field_name" json))
  
let parse_source_file (json : Yojson.Safe.json) =
  let p = to_string (member "path" json) in
  SourceFile.create ~warn_on_error:false p

let parse_location (json : Yojson.Safe.json) =
  {
    Location.line = to_int (member "line" json) ;
    Location.col = to_int (member "col" json) ;
    Location.file = parse_source_file (member "source_file" json) ;
  }

let rec parse_pvar (json : Yojson.Safe.json) =
  let pvname = Mangled.from_string (to_string (member "pv_name" json)) in
  let pvkind = to_string (member "pv_kind" json) in
  if String.equal pvkind "LocalVariable" then
    let pname = parse_cil_procname (member "proc_name" json) in
    Pvar.mk pvname pname
  else if String.equal pvkind "CalledVariable" then
    let pname = parse_cil_procname (member "proc_name" json) in
    Pvar.mk_callee pvname pname
  else if String.equal pvkind "GlobalVariable" then
    Pvar.mk_global pvname
  else
    Logging.die InternalError "Unknown program variable kind %s" pvkind

and parse_constant (json : Yojson.Safe.json) =
  let const_kind = to_string (member "kind" json) in
  let const_value = (member "const_value" json) in
  if String.equal const_kind "Int" then
    let i = parse_intrep const_value in
    Const.Cint i
  else if String.equal const_kind "Fun" then
    let pname = parse_cil_procname const_value in
    Const.Cfun pname
  else if String.equal const_kind "Str" then
    Const.Cstr (to_string const_value)
  else if String.equal const_kind "Float" then
    match const_value with
      | string -> Const.Cfloat nan
      | _ -> Const.Cfloat (to_float const_value) 
  else if String.equal const_kind "Class" then
    Const.Cclass (Ident.string_to_name (to_string const_value))
  else
    Logging.die InternalError "Unknown constant kind %s" const_kind

and parse_exp (json : Yojson.Safe.json) =
  let ekind = to_string (member "expr_kind" json) in
  if String.equal ekind "VarExpression" then
    Exp.Var (parse_ident (member "identifier" json))
  else if String.equal ekind "UnopExpression" then
    let op = parse_unop (member "operator" json) in
    let e = parse_exp (member "expression" json) in
    let t = 
      let t_nullable = (member "type" json) in
      match t_nullable with 
      | `Null -> None 
      | _ -> Some (parse_sil_type_name t_nullable)
    in
    Exp.UnOp (op, e, t)
  else if String.equal ekind "BinopExpression" then
    let op = parse_binop (member "operator" json) in
    let e1 = parse_exp (member "left" json) in
    let e2 = parse_exp (member "right" json) in
    Exp.BinOp (op, e1, e2)
  else if String.equal ekind "ConstExpression" then
    Exp.Const (parse_constant json)
  else if String.equal ekind "CastExpression" then
    let t = parse_sil_type_name (member "type" json) in
    let e = parse_exp (member "expression" json) in
    Exp.Cast (t, e)
  else if String.equal ekind "LvarExpression" then
    Exp.Lvar (parse_pvar (member "pvar" json))
  else if String.equal ekind "LfieldExpression" then
    let e = parse_exp (member "expression" json) in
    let fi = parse_fieldident (member "identifier" json) in
    let t = parse_sil_type_name (member "type" json) in
    Exp.Lfield (e, fi, t)
  else if String.equal ekind "LindexExpression" then
    let e1 = parse_exp (member "array" json) in
    let e2 = parse_exp (member "index" json) in
    Exp.Lindex (e1, e2)
  else if String.equal ekind "SizeofExpression" then
    let t = parse_sil_type_name (member "type" json) in
    let s = to_string (member "kind" json) in
    match s with
    | "exact" ->
      Exp.Sizeof {typ= t; nbytes= None; dynamic_length= None; subtype= Subtype.exact}
    | _ ->
      Logging.die InternalError "Subtype in Sizeof instruction is not 'exact'"
  else
    Logging.die InternalError "Unknown expression kind %s" ekind

and parse_struct_field (json : Yojson.Safe.json) =
  let fi = parse_fieldident json in
  let t = parse_sil_type_name (member "type" json) in
  let annot = parse_item_annotation (member "annotation" json) in
  (fi, t, annot)

and parse_sil_type_name (json : Yojson.Safe.json): Typ.typ =
  let type_kind = to_string (member "type_kind" json) in
  if String.equal type_kind "Tarray" then
    let t = parse_sil_type_name (member "content_type" json) in
    Typ.mk_array t
  else if String.equal type_kind "Tfloat" then
    let fkind = parse_fkind (member "kind" json) in
    Typ.mk (Typ.Tfloat fkind)
  else if String.equal type_kind "Tint" then
    let ikind = parse_ikind (member "kind" json) in
    Typ.mk (Typ.Tint ikind)
  else if String.equal type_kind "Tptr" then
    let t = parse_sil_type_name (member "type" json) in
    let pkind = parse_ptr_kind (member "kind" json) in
    Typ.mk (Typ.Tptr (t, pkind))
  else if String.equal type_kind "Tstruct" then
    let tn = typename_of_classname (to_string (member "struct_name" json)) in
    Typ.mk (Tstruct tn)
  else if String.equal type_kind "Tvar" then
    let tn = parse_typename (member "type_name" json) in
    Typ.mk (Typ.TVar (Typ.Name.name tn))
  else if String.equal type_kind "Tvoid" then
    Typ.void
  else if String.equal type_kind "Tenum" then
    (* Sil.Tenum (parse_list (parse_pair (fun n -> Mangled.from_string (to_string n)) parse_constant) value) *)
    Logging.die InternalError "Enums are not supported yet"
  else
    Logging.die InternalError "Unknown sil type kind %s" type_kind

and parse_item_annotation (json : Yojson.Safe.json): Annot.Item.t =
  let parse_annotation (json : Yojson.Safe.json) =
    let class_name = to_string (member "class_name" json) in
    let p = member "params" json in
    let parameters = parse_list to_string p in
    { Annot.class_name = class_name ; Annot.parameters = parameters } in
  parse_list 
    (fun j -> 
      let a = member "annotation" j in
      let v = member "visible" j in
      (parse_annotation a, to_bool v))
    (member "annotations" json)

and parse_struct (json : Yojson.Safe.json) = 
  let fields = parse_list parse_struct_field (member "instance_fields" json) in
  let statics = parse_list parse_struct_field (member "static_fields" json) in
  let supers = parse_list parse_csu (member "supers" json) in
  let methods = parse_list parse_cil_procname (member "methods" json) in
  let annots = parse_item_annotation json in
  (fields, statics, supers, methods, annots)
      
let parse_method_annotation (json : Yojson.Safe.json): Annot.Method.t =
  let return = parse_item_annotation (member "return_value" json) in
  let params = parse_list parse_item_annotation (member "params" json) in
  {return; params}

let parse_proc_attributes_var (json : Yojson.Safe.json) =
  let n = to_string (member "name" json) in
  let t = parse_sil_type_name (member "type" json) in
  (Mangled.from_string n, t)

let parse_proc_attributes_locals (json : Yojson.Safe.json) : ProcAttributes.var_data =
  let (n,t) = parse_proc_attributes_var json in
  let mib = to_bool (member "modify_in_block" json) in
  let ice = to_bool (member "is_const_expr" json) in
  { name= n
  ; typ= t
  ; modify_in_block= mib
  ; is_constexpr= ice }

let parse_proc_attributes (json : Yojson.Safe.json) =
  let access = 
    match to_string (member "access" json) with
    | "Default" -> PredSymb.Default
    | "Public" -> PredSymb.Public
    | "Private" -> PredSymb.Private
    | "Protected" -> PredSymb.Protected
    | atype -> Logging.die InternalError "Unsupported access type %s" atype
  in
  let captured =
    parse_list
      parse_proc_attributes_var
      (member "captured" json) in

  let formals =
    parse_list
      parse_proc_attributes_var
      (member "formals" json) in

  let locals =
    parse_list
      parse_proc_attributes_locals
      (member "locals" json)
  in
  let loc = parse_location (member "loc" json) in
  let file = loc.file in
  let proc_name = parse_cil_procname (member "proc_name" json) in
  { 
    (ProcAttributes.default file proc_name) with
    access = access;
    captured;
    exceptions = parse_list to_string (member "exceptions" json) ;
    formals;
    func_attributes = [] ; (* cil todo *)
    is_abstract = to_bool (member "is_abstract" json) ;
    is_bridge_method = to_bool (member "is_bridge_method" json) ;
    is_defined = to_bool (member "is_defined" json) ;
    is_synthetic_method = to_bool (member "is_synthetic_method" json) ;
    loc;
    locals;
    method_annotation = parse_method_annotation (member "method_annotations" json) ;
    ret_type = parse_sil_type_name (member "ret_type" json) 
  }

let parse_call_flags (json : Yojson.Safe.json) =
  {
    CallFlags.default with
    CallFlags.cf_virtual = to_bool (member "cf_virtual" json) ;
    CallFlags.cf_noreturn = to_bool (member "cf_noreturn" json) ;
    CallFlags.cf_is_objc_block = to_bool (member "cf_is_objc_block" json) ;
  }

let parse_call_args (json : Yojson.Safe.json) =
  let e = parse_exp (member "expression" json) in
  let t = parse_sil_type_name (member "type" json) in
  (e, t)

let parse_instr (json : Yojson.Safe.json) =
  let instr_kind = to_string (member "instruction_kind" json) in
  let l = parse_location (member "location" json) in
  if String.equal instr_kind "Load" then
    let i = parse_ident (member "identifier" json) in
    let e = parse_exp (member "expression" json) in
    let t = parse_sil_type_name (member "type" json) in
    Sil.Load(i, e, t, l)
  else if String.equal instr_kind "Store" then
    let e1 = parse_exp (member "lvalue" json) in
    let e2 = parse_exp (member "rvalue" json) in
    let t = parse_sil_type_name (member "type" json) in
    Sil.Store(e1, t, e2, l)
  else if String.equal instr_kind "Prune" then
    let e = parse_exp (member "condition" json) in
    let f = to_bool (member "true_branch" json) in
    let k = parse_if_kind (member "if_kind" json) in
    Sil.Prune (e, l, f ,k)
  else if String.equal instr_kind "Call" then
    let rs = (parse_ident (member "return_var" json), parse_sil_type_name (member "return_type" json)) in
    let e = parse_exp (member "function_expression" json) in
    let ps = parse_list parse_call_args (member "args" json) in
    let fs = parse_call_flags (member "flags" json) in
    Sil.Call (rs, e, ps, l, fs)
  else
    Logging.die InternalError "Unknown instruction kind %s" instr_kind

(* This has the side-effect of inserting the procedure description into the CFG. *)
let parse_pdesc (cfg : Cfg.t) (pd_id_to_pd : Procdesc.t IntTbl.t) (start_nd_tbl : int IntTbl.t) (exit_nd_tbl : int IntTbl.t) (json : Yojson.Safe.json) =
  let _attrs = parse_proc_attributes (member "pd_attributes" json) in
  let _id = to_int (member "pd_id" json) in
  (* Store away start/end node, to be filled in later *)
  IntTbl.add start_nd_tbl _id (to_int (member "pd_start_node" json));
  IntTbl.add exit_nd_tbl _id (to_int (member "pd_exit_node" json));
  (* let open Procdesc in *)
  let pd =
    Cfg.create_proc_desc cfg _attrs
  in
  IntTbl.add pd_id_to_pd _id pd

(* Expect the entire node json to be passed *)
let parse_stmt_nodekind (json: Yojson.Safe.json): Procdesc.Node.stmt_nodekind =
  let nk_comment = (member "stmt_node_comment" json) in
  match (to_string (member "stmt_node_kind" json)) with
  | "AssertionFailure" ->
    Procdesc.Node.AssertionFailure
  | "BetweenJoinAndExit" ->
    Procdesc.Node.BetweenJoinAndExit
  | "BinaryConditionalStmtInit" ->
    Procdesc.Node.BinaryConditionalStmtInit
  | "BinaryOperatorStmt" ->
    Procdesc.Node.BinaryOperatorStmt (to_string nk_comment)
  | "Call" ->
    Procdesc.Node.Call (to_string nk_comment)
  | "CallObjCNew" ->
    Procdesc.Node.CallObjCNew
  | "ClassCastException" ->
    Procdesc.Node.ClassCastException
  | "ConditionalStmtBranch" ->
    Procdesc.Node.ConditionalStmtBranch
  | "ConstructorInit" ->
    Procdesc.Node.ConstructorInit
  | "CXXDynamicCast" ->
    Procdesc.Node.CXXDynamicCast
  | "CXXNewExpr" ->
    Procdesc.Node.CXXNewExpr
  | "CXXStdInitializerListExpr" ->
    Procdesc.Node.CXXStdInitializerListExpr
  | "CXXTypeidExpr" ->
    Procdesc.Node.CXXTypeidExpr
  | "DeclStmt" ->
    Procdesc.Node.DeclStmt
  | "DefineBody" ->
    Procdesc.Node.DefineBody
  | "Destruction" ->
    Procdesc.Node.Destruction
  | "ExceptionHandler" ->
    Procdesc.Node.ExceptionHandler
  | "ExceptionsSink" ->
    Procdesc.Node.ExceptionsSink
  | "FallbackNode" ->
    Procdesc.Node.FallbackNode
  | "FinallyBranch" ->
    Procdesc.Node.FinallyBranch
  | "GCCAsmStmt" ->
    Procdesc.Node.GCCAsmStmt
  | "GenericSelectionExpr" ->
    Procdesc.Node.GenericSelectionExpr
  | "IfStmtBranch" ->
    Procdesc.Node.IfStmtBranch
  | "InitializeDynamicArrayLength" ->
    Procdesc.Node.InitializeDynamicArrayLength
  | "InitListExp" ->
    Procdesc.Node.InitListExp
  | "MessageCall" ->
    Procdesc.Node.MessageCall (to_string nk_comment)
  | "MethodBody" ->
    Procdesc.Node.MethodBody
  | "MonitorEnter" ->
    Procdesc.Node.MonitorEnter
  | "MonitorExit" ->
    Procdesc.Node.MonitorExit
  | "ObjCCPPThrow" ->
    Procdesc.Node.ObjCCPPThrow
  | "OutOfBound" ->
    Procdesc.Node.OutOfBound
  | "ReturnStmt" ->
    Procdesc.Node.ReturnStmt
  | "Skip" ->
    Procdesc.Node.Skip (to_string nk_comment)
  | "SwitchStmt" ->
    Procdesc.Node.SwitchStmt
  | "ThisNotNull" ->
    Procdesc.Node.ThisNotNull
  | "Throw" ->
    Procdesc.Node.Throw
  | "ThrowNPE" ->
    Procdesc.Node.ThrowNPE
  | "UnaryOperator" ->
    Procdesc.Node.UnaryOperator
  | snk ->
    Logging.die InternalError "Unknown stmt node kind %s" snk


let parse_prune_nodekind (json: Yojson.Safe.json): Procdesc.Node.prune_node_kind =
  match to_string json with 
  | "ExceptionHandler" ->
    PruneNodeKind_ExceptionHandler
  | "FalseBranch" ->
    PruneNodeKind_FalseBranch
  | "InBound" ->
    PruneNodeKind_InBound
  | "IsInstance" ->
    PruneNodeKind_IsInstance
  | "MethodBody" ->
    PruneNodeKind_MethodBody
  | "NotNull" ->
    PruneNodeKind_NotNull
  | "TrueBranch" ->
    PruneNodeKind_TrueBranch
  | pnk -> 
    Logging.die InternalError "Unknown prune node kind %s" pnk


let parse_nodekind  (pd_id_to_pd : Procdesc.t IntTbl.t) (json : Yojson.Safe.json) =
  let open Cfg in
  let nkname = to_string (member "nd_kind" json) in
  if String.equal nkname "StartNode" then
    Procdesc.Node.Start_node
  else if String.equal nkname "ExitNode" then
    Procdesc.Node.Exit_node
  else if String.equal nkname "StatementNode" then
    Procdesc.Node.Stmt_node (parse_stmt_nodekind json)
  else if String.equal nkname "JoinNode" then
    Procdesc.Node.Join_node
  else if String.equal nkname "PruneNode" then
    let f = to_bool (member "true_branch" json) in
    let ik = parse_if_kind (member "if_kind" json) in
    let d = parse_prune_nodekind (member "prune_node_kind" json) in
    Procdesc.Node.Prune_node (f, ik, d)
  else if String.equal nkname "SkipNode" then
    Procdesc.Node.Skip_node (to_string (member "skip_node_comment" json))
  else
    Logging.die InternalError "Unknown nodekind: %s" nkname

let parse_node (pd_id_to_pd : Procdesc.t IntTbl.t) (nd_id_to_node : Procdesc.Node.t IntTbl.t) (nd_id_to_exn_nodes : (int list) IntTbl.t) (nd_id_to_pred_nodes : (int list) IntTbl.t) (nd_id_to_succ_nodes : (int list) IntTbl.t) (json : Yojson.Safe.json) =
  let nd_id = to_int (member "nd_id" json) in
  let nd_temps = parse_list parse_ident (member "nd_temps" json) in
  let nd_dead_pvars_after = parse_list parse_pvar (member "nd_dead_pvars_after" json) in
  let nd_dead_pvars_before = parse_list parse_pvar (member "nd_dead_pvars_before" json) in
  IntTbl.add nd_id_to_exn_nodes nd_id (parse_list to_int (member "nd_exn_ids" json));
  let nd_instrs = parse_list parse_instr (member "nd_instrs" json) in
  let nd_kind = parse_nodekind pd_id_to_pd json in
  let nd_loc = parse_location (member "nd_loc" json) in
  IntTbl.add nd_id_to_pred_nodes nd_id (parse_list to_int (member "nd_pred_ids" json));
  IntTbl.add nd_id_to_succ_nodes nd_id (parse_list to_int (member "nd_succ_ids" json));
  let nd_proc_desc = IntTbl.find pd_id_to_pd (to_int (member "nd_proc_id" json)) in
  let node = Procdesc.create_node nd_proc_desc nd_loc nd_kind nd_instrs in
  IntTbl.add nd_id_to_node nd_id node;
  node

let parse_cfg (json : Yojson.Safe.json) =
  let cfg = Cfg.create() in

  (* These hold information that's in the procedure description or nodes, but can only be completed once we've parsed all nodes. *)
  let pd_id_to_pd = IntTbl.create 1000 in
  let pd_id_to_start_node = IntTbl.create 1000 in
  let pd_id_to_exit_node = IntTbl.create 1000 in
  let nd_id_to_node = IntTbl.create 1000 in
  let nd_id_to_exn_nodes = IntTbl.create 1000 in
  let nd_id_to_pred_nodes = IntTbl.create 1000 in
  let nd_id_to_succ_nodes = IntTbl.create 1000 in

  List.iter
    ~f:(fun (_, pdjson) -> parse_pdesc cfg pd_id_to_pd pd_id_to_start_node pd_id_to_exit_node pdjson)
    (to_assoc (member "procs" json));
  let _ = parse_list (parse_node pd_id_to_pd nd_id_to_node nd_id_to_exn_nodes nd_id_to_pred_nodes nd_id_to_succ_nodes) (member "nodes" json) in

  (* Now fix up the dangling ends *)
  IntTbl.iter
    (fun pd_id pd ->
     let start_node = IntTbl.find nd_id_to_node (IntTbl.find pd_id_to_start_node pd_id) in
     let exit_node = IntTbl.find nd_id_to_node (IntTbl.find pd_id_to_exit_node pd_id) in
     Procdesc.set_start_node pd start_node;
     Procdesc.set_exit_node pd exit_node;
    )
    pd_id_to_pd;

  IntTbl.iter
    (fun (nd_id: int) (node: Procdesc.Node.t) ->
     let exn_nodes = List.map ~f:(IntTbl.find nd_id_to_node) (IntTbl.find nd_id_to_exn_nodes nd_id) in
     let succ_nodes = List.map ~f:(IntTbl.find nd_id_to_node) (IntTbl.find nd_id_to_succ_nodes nd_id) in
      Procdesc.set_succs_exn_base node succ_nodes exn_nodes )
    nd_id_to_node;

  cfg

let parse_tenv_type (json : Yojson.Safe.json) (tenv) =
  let tn = parse_typename (member "type_name" json) in
  let (fields, statics, supers, methods, annots) =
    parse_struct (member "type_struct" json)
  in
  ignore (Tenv.mk_struct tenv ~fields ~statics ~methods ~supers ~annots tn)

let parse_tenv (json : Yojson.Safe.json) =
  let tenv = Tenv.create() in
  List.iter
    ~f:(fun entry -> parse_tenv_type entry tenv)
    (to_list json);
  tenv


let clear_caches () =
  Ondemand.clear_cache () ;
  Summary.clear_cache () ;
  Typ.Procname.SQLite.clear_cache ()


(** Create tasks to analyze an execution environment *)
let analyze_source_file : SourceFile.t Tasks.doer =
 fun source_file ->
  if Config.memcached then Memcached.connect () ;
  DB.Results_dir.init source_file ;
  let exe_env = Exe_env.mk () in
  L.task_progress SourceFile.pp source_file ~f:(fun () ->
      (* clear cache for each source file to avoid it growing unboundedly *)
      clear_caches () ;
      Callbacks.analyze_file exe_env source_file ;
      if Config.write_html then Printer.write_all_html_files source_file ) ;
  if Config.memcached then Memcached.disconnect ()


let output_json_makefile_stats clusters =
  let num_files = List.length clusters in
  let num_procs = 0 in
  (* can't compute it at this stage *)
  let num_lines = 0 in
  let file_stats =
    `Assoc [("files", `Int num_files); ("procedures", `Int num_procs); ("lines", `Int num_lines)]
  in
  (* write stats file to disk, intentionally overwriting old file if it already exists *)
  let f = Out_channel.create (Filename.concat Config.results_dir Config.proc_stats_filename) in
  Yojson.Safe.pretty_to_channel f file_stats


let source_file_should_be_analyzed ~changed_files source_file =
  (* whether [fname] is one of the [changed_files] *)
  let is_changed_file = Option.map changed_files ~f:(SourceFile.Set.mem source_file) in
  let check_modified () =
    let modified = SourceFiles.is_freshly_captured source_file in
    if modified then L.debug Analysis Medium "Modified: %a@\n" SourceFile.pp source_file ;
    modified
  in
  match is_changed_file with
  | Some b ->
      b
  | None when Config.reactive_mode ->
      check_modified ()
  | None ->
      true


let register_active_checkers () =
  RegisterCheckers.get_active_checkers () |> RegisterCheckers.register


let main ~changed_files =
  ( match Config.modified_targets with
  | Some file ->
      MergeCapture.record_modified_targets_from_file file
  | None ->
      () ) ;
  register_active_checkers () ;
  if Config.reanalyze then Summary.reset_all ~filter:(Lazy.force Filtering.procedures_filter) ()
  else DB.Results_dir.clean_specs_dir () ;
  let n_all_source_files = ref 0 in
  let n_source_files_to_analyze = ref 0 in
  let filter sourcefile =
    let result =
      (Lazy.force Filtering.source_files_filter) sourcefile
      && source_file_should_be_analyzed ~changed_files sourcefile
    in
    incr n_all_source_files ;
    if result then incr n_source_files_to_analyze ;
    result
  in
  let source_files_to_analyze = SourceFiles.get_all ~filter () in
  L.progress "Found %d%s source file%s to analyze in %s@." !n_source_files_to_analyze
    ( if Config.reactive_mode || Option.is_some changed_files then
      " (out of " ^ string_of_int !n_all_source_files ^ ")"
    else "" )
    (if Int.equal !n_source_files_to_analyze 1 then "" else "s")
    Config.results_dir ;
  (* empty all caches to minimize the process heap to have less work to do when forking *)
  clear_caches () ;
  ( if Int.equal Config.jobs 1 then (
    Tasks.run_sequentially ~f:analyze_source_file source_files_to_analyze ;
    L.progress "@\nAnalysis finished in %as@." Pp.elapsed_time () )
  else
    let source_files_to_analyze =
      List.permute source_files_to_analyze
        ~random_state:(Random.State.make (Array.create ~len:1 0))
    in
    L.environment_info "Parallel jobs: %d@." Config.jobs ;
    (* Prepare tasks one cluster at a time while executing in parallel *)
    let runner = Tasks.Runner.create ~jobs:Config.jobs ~f:analyze_source_file in
    Tasks.Runner.run runner ~tasks:source_files_to_analyze ) ;
output_json_makefile_stats source_files_to_analyze

let analyze_json cfg_json tenv_json =
  clear_caches () ;
  register_active_checkers () ;
  if Config.reanalyze then Summary.reset_all ~filter:(Lazy.force Filtering.procedures_filter) ()
  else DB.Results_dir.clean_specs_dir () ;

  Printexc.record_backtrace true;

  let tenv = parse_tenv (Yojson.Safe.from_file tenv_json) in
  let cfg = parse_cfg (Yojson.Safe.from_file cfg_json) in

  let source_file = SourceFile.create ~warn_on_error:false "./Program.cs" in
  (* let source_dir = DB.source_dir_from_source_file source_file in
  Utils.create_dir (DB.source_dir_to_string source_dir) ;

  let tenv_file = DB.source_dir_get_internal_file source_dir ".tenv" in
  let cfg_file = DB.source_dir_get_internal_file source_dir ".cfg" in
  Tenv.store_to_filename tenv tenv_file ; *)
  Tenv.store_global tenv ;
  Cfg.store source_file cfg ;

  SourceFiles.add source_file cfg Tenv.Global None ;
  
  (*Cfg.print_cfg_procs cfg ;*)

  Language.curr_language := Language.CIL ;

  let exe_env = Exe_env.mk () in
  Callbacks.analyze_file exe_env source_file ;

  if Config.write_html then Printer.write_all_html_files source_file ;
  ()
