(* Copyright (c) Microsoft Corporation. All rights reserved.
   Licensed under the MIT License. *)

(** This module is Open Enclave's plugin for Intel's Edger8r, allowing
    us to share the same Enclave Definition Language, but emit our
    SDK's bindings. *)

open Ast
open Plugin
open Printf
open Util

(** ----- Begin code borrowed and tweaked from {!CodeGen.ml}. ----- *)
let is_foreign_array (pt : parameter_type) =
  match pt with
  | PTVal _ -> false
  | PTPtr (t, a) -> ( match t with Foreign _ -> a.pa_isary | _ -> false )

(** Get the array declaration from a list of array dimensions. Empty
    [ns] indicates the corresponding declarator is a simple identifier.
    Element of value -1 means that user does not specify the dimension
    size. *)
let get_array_dims (ns : int list) =
  let get_dim n = if n = -1 then "[]" else sprintf "[%d]" n in
  if ns = [] then "" else List.fold_left (fun acc n -> acc ^ get_dim n) "" ns

let get_typed_declr_str (ty : atype) (declr : declarator) =
  let tystr = get_tystr ty in
  let dmstr = get_array_dims declr.array_dims in
  sprintf "%s %s%s" tystr declr.identifier dmstr

(** Check whether given parameter [pt] is [const] specified. *)
let is_const_ptr (pt : parameter_type) =
  let aty = get_param_atype pt in
  match pt with
  | PTVal _ -> false
  | PTPtr (_, pa) -> (
      if not pa.pa_rdonly then false
      else match aty with Foreign _ -> false | _ -> true )

(** Generate parameter [p] representation. *)
let gen_parm_str (p : pdecl) =
  let pt, (declr : declarator) = p in
  let aty = get_param_atype pt in
  let str = get_typed_declr_str aty declr in
  if is_const_ptr pt then "const " ^ str else str

let retval_declr = {identifier= "_retval"; array_dims= []}

let get_ret_tystr (fd : func_decl) = get_tystr fd.rtype

let get_plist_str (fd : func_decl) =
  if fd.plist = [] then ""
  else
    List.fold_left
      (fun acc pd -> acc ^ ",\n        " ^ gen_parm_str pd)
      (gen_parm_str (List.hd fd.plist))
      (List.tl fd.plist)

(** [conv_array_to_ptr] is used to convert Array form into Pointer form.
    {[
      int array[10][20] => [count = 200] int* array
    ]}

    This function is called when generating proxy/bridge code and the
    marshalling structure. *)
let conv_array_to_ptr (pd : pdecl) : pdecl =
  let pt, declr = pd in
  let get_count_attr ilist =
    (* XXX: assume the size of each dimension will be > 0. *)
    ANumber (List.fold_left (fun acc i -> acc * i) 1 ilist)
  in
  match pt with
  | PTVal _ -> (pt, declr)
  | PTPtr (aty, pa) ->
      if is_array declr then
        let tmp_declr = {declr with array_dims= []} in
        let tmp_aty = Ptr aty in
        let tmp_cnt = get_count_attr declr.array_dims in
        let tmp_pa =
          {pa with pa_size= {empty_ptr_size with ps_count= Some tmp_cnt}}
        in
        (PTPtr (tmp_aty, tmp_pa), tmp_declr)
      else (pt, declr)

(** Note that, for a foreign array type [foo_array_t] we will generate
    [foo_array_t* ms_field;] in the marshalling data structure to keep
    the pass-by-address scheme as in the C programming language. *)
let mk_ms_member_decl (pt : parameter_type) (declr : declarator)
    (isecall : bool) =
  let aty = get_param_atype pt in
  let tystr =
    if is_foreign_array pt then
      sprintf "/* foreign array of type %s */ void" (get_tystr aty)
    else get_tystr aty
  in
  let ptr = if is_foreign_array pt then "* " else "" in
  let field = declr.identifier in
  (* String attribute is available for in/in-out both ecall and ocall.
     For ocall ,strlen is called in trusted proxy code, so no need to
     defense it. *)
  let need_str_len_var (pt : parameter_type) =
    match pt with
    | PTVal _ -> false
    | PTPtr (_, pa) ->
        if pa.pa_isstr || pa.pa_iswstr then
          match pa.pa_direction with
          | PtrInOut | PtrIn -> if isecall then true else false
          | _ -> false
        else false
  in
  let str_len =
    if need_str_len_var pt then sprintf "\tsize_t %s_len;\n" field else ""
  in
  let dmstr = get_array_dims declr.array_dims in
  sprintf "    %s%s %s%s;\n%s" tystr ptr field dmstr str_len

(** ----- End code borrowed and tweaked from {!CodeGen.ml} ----- *)

let is_in_ptr (ptype, _) =
  match ptype with
  | PTVal _ -> false
  | PTPtr (_, a) -> a.pa_chkptr && a.pa_direction = PtrIn

let is_out_ptr (ptype, _) =
  match ptype with
  | PTVal _ -> false
  | PTPtr (_, a) -> a.pa_chkptr && a.pa_direction = PtrOut

let is_inout_ptr (ptype, _) =
  match ptype with
  | PTVal _ -> false
  | PTPtr (_, a) -> a.pa_chkptr && a.pa_direction = PtrInOut

let is_str_ptr (ptype, _) =
  match ptype with PTVal _ -> false | PTPtr (_, a) -> a.pa_isstr

let is_wstr_ptr (ptype, _) =
  match ptype with PTVal _ -> false | PTPtr (_, a) -> a.pa_iswstr

(** [open_file] opens [filename] in the directory [dir] and emits a
    comment noting the file is auto generated. *)
let open_file (filename : string) (dir : string) =
  let os =
    if dir = "." then open_out filename
    else open_out (dir ^ separator_str ^ filename)
  in
  fprintf os "/*\n" ;
  fprintf os " *  This file is auto generated by oeedger8r. DO NOT EDIT.\n" ;
  fprintf os " */\n" ;
  os

(** [oe_mk_ms_struct_name] appends our [struct] naming suffix. *)
let oe_mk_ms_struct_name (fname : string) = fname ^ "_args_t"

(** [oe_mk_struct_decl] constructs the string of a [struct] definition. *)
let oe_mk_struct_decl (fs : string) (name : string) =
  String.concat "\n"
    [ sprintf "typedef struct _%s {" name
    ; "    oe_result_t _result;"
    ; sprintf "%s} %s;" fs name ]

(** [oe_gen_marshal_struct_impl] generates a marshalling [struct]
    definition. *)
let oe_gen_marshal_struct_impl (fd : func_decl) (errno : string)
    (isecall : bool) =
  let member_list_str =
    errno
    ^
    let new_param_list = List.map conv_array_to_ptr fd.plist in
    List.fold_left
      (fun acc (pt, declr) -> acc ^ mk_ms_member_decl pt declr isecall)
      "" new_param_list
  in
  let struct_name = oe_mk_ms_struct_name fd.fname in
  match fd.rtype with
  | Void -> oe_mk_struct_decl member_list_str struct_name
  | _ ->
      let rv_str = mk_ms_member_decl (PTVal fd.rtype) retval_declr isecall in
      oe_mk_struct_decl (rv_str ^ member_list_str) struct_name

let oe_gen_ecall_marshal_struct (tf : trusted_func) =
  oe_gen_marshal_struct_impl tf.tf_fdecl "" true

let oe_gen_ocall_marshal_struct (uf : untrusted_func) =
  let errno_decl =
    if uf.uf_propagate_errno then "    int _ocall_errno;\n" else ""
  in
  oe_gen_marshal_struct_impl uf.uf_fdecl errno_decl true

(** [oe_get_param_size] is the most complex function. For a parameter,
    get its size expression. *)
let oe_get_param_size (ptype, decl, argstruct) =
  (* Get the base type of the parameter, that is, recursively
     decompose the pointer. *)
  let atype =
    match get_param_atype ptype with
    | Ptr at -> at
    | _ -> get_param_atype ptype
  in
  let base_t = get_tystr atype in
  let type_expr =
    match ptype with
    | PTPtr (_, ptr_attr) ->
        if ptr_attr.pa_isptr then sprintf "*(%s)0" base_t else base_t
    | _ -> base_t
  in
  (* Convert an attribute to string. *)
  let attr_value_to_string av =
    match av with
    | None -> ""
    | Some (ANumber n) -> string_of_int n
    | Some (AString s) -> sprintf "%s%s" argstruct s
    (* another parameter name *)
  in
  let pa_size_to_string pa =
    let c = attr_value_to_string pa.ps_count in
    if c <> "" then sprintf "(%s * sizeof(%s))" c type_expr
    else attr_value_to_string pa.ps_size
  in
  let decl_size_to_string (ptype : parameter_type) (d : declarator) =
    let dims = List.map (fun i -> "[" ^ string_of_int i ^ "]") d.array_dims in
    let dims_expr = String.concat "" dims in
    sprintf "sizeof(%s%s)" type_expr dims_expr
  in
  match ptype with
  | PTPtr (_, ptr_attr) ->
      let pa_size = pa_size_to_string ptr_attr.pa_size in
      (* Compute declared size *)
      let decl_size = decl_size_to_string ptype decl in
      if ptr_attr.pa_isstr then
        argstruct ^ decl.identifier ^ "_len * sizeof(char)"
      else if ptr_attr.pa_iswstr then
        argstruct ^ decl.identifier ^ "_len * sizeof(wchar_t)"
      else if (* Prefer size attribute over decl size *)
              pa_size = "" then decl_size
      else pa_size
  | _ -> ""

(** Generate the prototype for a given function. Optionally add an
    [oe_enclave_t*] first parameter. *)
let oe_gen_prototype (fd : func_decl) =
  let params_str = if fd.plist = [] then "void" else get_plist_str fd in
  sprintf "%s %s(%s)" (get_ret_tystr fd) fd.fname params_str

let oe_gen_wrapper_prototype (fd : func_decl) (is_ecall : bool) =
  let plist_str = get_plist_str fd in
  let retval_str =
    if fd.rtype = Void then "" else sprintf "%s* _retval" (get_ret_tystr fd)
  in
  let args =
    if is_ecall then ["oe_enclave_t* enclave"; retval_str; plist_str]
    else [retval_str; plist_str]
  in
  let args = List.filter (fun s -> s <> "") args in
  sprintf "oe_result_t %s(\n        %s)" fd.fname
    (String.concat ",\n        " args)

(** Emit [struct], [union], or [enum]. *)
let emit_composite_type =
  let emit_struct_or_union (s : struct_def) (union : bool) =
    [ sprintf "typedef %s %s {" (if union then "union" else "struct") s.sname
    ; String.concat "\n"
        (List.map
           (fun (atype, decl) ->
             let dims = List.map (fun d -> sprintf "[%d]" d) decl.array_dims in
             let dims_str = String.concat "" dims in
             sprintf "    %s %s%s;" (get_tystr atype) decl.identifier dims_str
             )
           s.mlist)
    ; sprintf "} %s;\n" s.sname ]
  in
  let emit_enum (e : enum_def) =
    [ sprintf "typedef enum %s {" e.enname
    ; String.concat ",\n"
        (List.map
           (fun (name, value) ->
             sprintf "    %s%s" name
               ( match value with
               | EnumVal (AString s) -> " = " ^ s
               | EnumVal (ANumber n) -> " = " ^ string_of_int n
               | EnumValNone -> "" ) )
           e.enbody)
    ; sprintf "} %s;\n" e.enname ]
  in
  function
  | StructDef s -> emit_struct_or_union s false
  | UnionDef u -> emit_struct_or_union u true
  | EnumDef e -> emit_enum e

let get_function_id (f : func_decl) = sprintf "fcn_id_%s" f.fname

(** Emit all trusted and untrusted function IDs in enclave [ec]. *)
let emit_function_ids (ec : enclave_content) =
  [ ""
  ; "/* trusted function IDs */"
  ; "enum {"
  ; String.concat "\n"
      (List.mapi
         (fun i f -> sprintf "    %s = %d," (get_function_id f.tf_fdecl) i)
         ec.tfunc_decls)
  ; "    fcn_id_trusted_call_id_max = OE_ENUM_MAX"
  ; "};"
  ; ""
  ; "/* untrusted function IDs */"
  ; "enum {"
  ; String.concat "\n"
      (List.mapi
         (fun i f -> sprintf "    %s = %d," (get_function_id f.uf_fdecl) i)
         ec.ufunc_decls)
  ; "    fcn_id_untrusted_call_max = OE_ENUM_MAX"
  ; "};" ]

(** Generate [args.h] which contains [struct]s for ecalls and ocalls *)
let oe_gen_args_header (ec : enclave_content) (dir : string) =
  let types = List.flatten (List.map emit_composite_type ec.comp_defs) in
  let structs =
    List.append
      (* For each ecall, generate its marshalling struct. *)
      (List.map oe_gen_ecall_marshal_struct ec.tfunc_decls)
      (* For each ocall, generate its marshalling struct. *)
      (List.map oe_gen_ocall_marshal_struct ec.ufunc_decls)
  in
  let with_errno =
    List.exists (fun uf -> uf.uf_propagate_errno) ec.ufunc_decls
  in
  let header_fname = sprintf "%s_args.h" ec.file_shortnm in
  let guard_macro = sprintf "%s_ARGS_H" (String.uppercase ec.enclave_name) in
  let os = open_file header_fname dir in
  fprintf os "#ifndef %s\n" guard_macro ;
  fprintf os "#define %s\n\n" guard_macro ;
  fprintf os "#include <stdint.h>\n" ;
  fprintf os "#include <stdlib.h> /* for wchar_t */\n\n" ;
  if with_errno then fprintf os "#include <errno.h>\n" ;
  fprintf os "#include <openenclave/bits/result.h>\n\n" ;
  List.iter (fun inc -> fprintf os "#include \"%s\"\n" inc) ec.include_list ;
  if ec.include_list <> [] then fprintf os "\n" ;
  if ec.comp_defs <> [] then fprintf os "/* User types specified in edl */\n" ;
  fprintf os "%s" (String.concat "\n" types) ;
  if ec.comp_defs <> [] then fprintf os "\n" ;
  fprintf os "%s" (String.concat "\n" structs) ;
  fprintf os "%s" (String.concat "\n" (emit_function_ids ec)) ;
  fprintf os "\n#endif // %s\n" guard_macro ;
  close_out os

(** Generate a cast expression for a pointer argument. Pointer
    arguments need to be cast to their root type, since the marshalling
    struct has the root pointer. For example:
    {[
      int a[10][20]
    ]}
    needs to be cast to [int *].

    NOTE: Foreign arrays are marshalled as [void *], but foreign pointers
    are marshalled as-is. *)
let get_cast_to_mem_expr (ptype, decl) =
  match ptype with
  | PTVal _ -> ""
  | PTPtr (t, _) ->
      if is_array decl then sprintf "(%s*) " (get_tystr t)
      else if is_foreign_array ptype then
        sprintf "/* foreign array of type %s */ (void*) " (get_tystr t)
      else sprintf "(%s) " (get_tystr t)

(** This function is nearly identical to the above, but does not
    surround the expression with the final set of parentheses, which is
    necessary for passing it to C macros. *)
let get_cast_to_mem_type (ptype, decl) =
  match ptype with
  | PTVal _ -> ""
  | PTPtr (t, _) ->
      if is_array decl then get_tystr t ^ "*"
      else if is_foreign_array ptype then
        sprintf "/* foreign array of type %s */ void* " (get_tystr t)
      else get_tystr t

(** Prepare [input_buffer]. *)
let oe_prepare_input_buffer (fd : func_decl) (alloc_func : string) =
  [ "/* Compute input buffer size. Include in and in-out parameters. */"
  ; sprintf "OE_ADD_SIZE(_input_buffer_size, sizeof(%s_args_t));" fd.fname
    (* TODO: Emit a comment instead of a blank newline if this is empty. *)
  ; String.concat "\n    "
      (List.map
         (fun (ptype, decl) ->
           let size = oe_get_param_size (ptype, decl, "_args.") in
           sprintf "if (%s) OE_ADD_SIZE(_input_buffer_size, %s);"
             decl.identifier size )
         (List.filter (fun p -> is_in_ptr p || is_inout_ptr p) fd.plist))
  ; ""
  ; "/* Compute output buffer size. Include out and in-out parameters. */"
  ; sprintf "OE_ADD_SIZE(_output_buffer_size, sizeof(%s_args_t));" fd.fname
    (* TODO: Emit a comment instead of a blank newline if this is empty. *)
  ; String.concat "\n    "
      (List.map
         (fun (ptype, decl) ->
           let size = oe_get_param_size (ptype, decl, "_args.") in
           sprintf "if (%s) OE_ADD_SIZE(_output_buffer_size, %s);"
             decl.identifier size )
         (List.filter (fun p -> is_out_ptr p || is_inout_ptr p) fd.plist))
  ; ""
  ; "/* Allocate marshalling buffer */"
  ; "_total_buffer_size = _input_buffer_size;"
  ; "OE_ADD_SIZE(_total_buffer_size, _output_buffer_size);"
  ; sprintf "_buffer = (uint8_t*)%s(_total_buffer_size);" alloc_func
  ; "_input_buffer = _buffer;"
  ; "_output_buffer = _buffer + _input_buffer_size;"
  ; "if (_buffer == NULL)"
  ; "{"
  ; "    _result = OE_OUT_OF_MEMORY;"
  ; "    goto done;"
  ; "}"
  ; ""
  ; "/* Serialize buffer inputs (in and in-out parameters) */"
  ; sprintf "_pargs_in = (%s_args_t*)_input_buffer;" fd.fname
  ; "OE_ADD_SIZE(_input_buffer_offset, sizeof(*_pargs_in));"
    (* TODO: Emit a comment instead of a blank newline if this is empty. *)
  ; String.concat "\n    "
      (List.map
         (fun (ptype, decl) ->
           let size = oe_get_param_size (ptype, decl, "_args.") in
           let tystr = get_cast_to_mem_type (ptype, decl) in
           (* These need to be in order and so done together. *)
           sprintf "OE_WRITE_%s_PARAM(%s, %s, %s);"
             (if is_in_ptr (ptype, decl) then "IN" else "IN_OUT")
             decl.identifier size tystr )
         (List.filter (fun p -> is_in_ptr p || is_inout_ptr p) fd.plist))
  ; ""
  ; "/* Copy args structure (now filled) to input buffer */"
  ; "memcpy(_pargs_in, &_args, sizeof(*_pargs_in));" ]

let oe_process_output_buffer (fd : func_decl) =
  List.flatten
    [ [ (* Verify that the ecall succeeded *)
        ""
      ; "/* Setup output arg struct pointer */"
      ; sprintf "_pargs_out = (%s_args_t*)_output_buffer;" fd.fname
      ; "OE_ADD_SIZE(_output_buffer_offset, sizeof(*_pargs_out));"
      ; ""
      ; "/* Check if the call succeeded */"
      ; "if ((_result = _pargs_out->_result) != OE_OK)"
      ; "    goto done;"
      ; ""
      ; "/* Currently exactly _output_buffer_size bytes must be written */"
      ; "if (_output_bytes_written != _output_buffer_size)"
      ; "{"
      ; "    _result = OE_FAILURE;"
      ; "    goto done;"
      ; "}"
      ; ""
      ; (* Unmarshal return value and output buffers *)
        "/* Unmarshal return value and out, in-out parameters */"
      ; ( if fd.rtype <> Void then "*_retval = _pargs_out->_retval;"
        else "/* No return value. */" ) ]
    ; (* This does not use String.concat because the elements are multiple lines. *)
      List.map
        (fun (ptype, decl) ->
          let size = oe_get_param_size (ptype, decl, "_args.") in
          (* These need to be in order and so done together. *)
          if is_out_ptr (ptype, decl) then
            sprintf "OE_READ_OUT_PARAM(%s, (size_t)(%s));" decl.identifier size
          else if is_inout_ptr (ptype, decl) then
            (* Check that strings are null terminated. Note output
              buffer has already been copied into the enclave. *)
            ( if is_str_ptr (ptype, decl) || is_wstr_ptr (ptype, decl) then
              sprintf
                "OE_CHECK_NULL_TERMINATOR%s(_output_buffer + \
                 _output_buffer_offset, _args.%s_len);\n"
                (if is_wstr_ptr (ptype, decl) then "_WIDE" else "")
                decl.identifier
            else "" )
            ^ sprintf "OE_READ_IN_OUT_PARAM(%s, (size_t)(%s));" decl.identifier
                size
          else "" )
        (* We filter the list so an empty string is never output. *)
        (List.filter (fun p -> is_out_ptr p || is_inout_ptr p) fd.plist) ]

(** Generate a cast expression to a specific pointer type. For example,
    [int*] needs to be cast to
    {[
      *(int ( * )[5][6])
    ]}. *)
let get_cast_from_mem_expr (ptype, decl) =
  match ptype with
  | PTVal _ -> ""
  | PTPtr (t, attr) ->
      if is_array decl then
        sprintf "*(%s (*)%s) " (get_tystr t) (get_array_dims decl.array_dims)
      else if is_foreign_array ptype then
        sprintf "/* foreign array */ *(%s *) " (get_tystr t)
      else if attr.pa_rdonly then
        (* for ptrs, only constness is removed; add it back *)
        sprintf "(const %s) " (get_tystr t)
      else ""

let oe_gen_call_function (fd : func_decl) =
  [ ""
  ; "/* Call user function. */"
  ; (match fd.rtype with Void -> "" | _ -> "pargs_out->_retval = ")
    ^ fd.fname ^ "("
  ; String.concat ",\n    "
      (List.map
         (fun (ptype, decl) ->
           let cast_expr = get_cast_from_mem_expr (ptype, decl) in
           sprintf "    %spargs_in->%s" cast_expr decl.identifier )
         fd.plist)
    ^ ");" ]

(** Generate ecall function. *)
let oe_gen_ecall_function (fd : func_decl) =
  [ ""
  ; sprintf "void ecall_%s(" fd.fname
  ; "    uint8_t* input_buffer,"
  ; "    size_t input_buffer_size,"
  ; "    uint8_t* output_buffer,"
  ; "    size_t output_buffer_size,"
  ; "    size_t* output_bytes_written)"
  ; "{"
  ; (* Variable declarations *)
    "    oe_result_t _result = OE_FAILURE;"
  ; ""
  ; "    /* Prepare parameters */"
  ; sprintf "    %s_args_t* pargs_in = (%s_args_t*)input_buffer;" fd.fname
      fd.fname
  ; sprintf "    %s_args_t* pargs_out = (%s_args_t*)output_buffer;" fd.fname
      fd.fname
  ; ""
  ; "    size_t input_buffer_offset = 0;"
  ; "    size_t output_buffer_offset = 0;"
  ; "    OE_ADD_SIZE(input_buffer_offset, sizeof(*pargs_in));"
  ; "    OE_ADD_SIZE(output_buffer_offset, sizeof(*pargs_out));"
  ; ""
  ; (* Buffer validation *)
    "    /* Make sure input and output buffers lie within the enclave. */"
  ; "    if (!input_buffer || !oe_is_within_enclave(input_buffer, \
     input_buffer_size))"
  ; "        goto done;"
  ; ""
  ; "    if (!output_buffer || !oe_is_within_enclave(output_buffer, \
     output_buffer_size))"
  ; "        goto done;"
  ; ""
  ; (* Prepare in and in-out parameters *)
    "    /* Set in and in-out pointers. */"
  ; (let params =
       List.map
         (fun (ptype, decl) ->
           let size = oe_get_param_size (ptype, decl, "pargs_in->") in
           let tystr = get_cast_to_mem_type (ptype, decl) in
           sprintf "    OE_SET_%s_POINTER(%s, %s, %s);"
             (if is_in_ptr (ptype, decl) then "IN" else "IN_OUT")
             decl.identifier size tystr )
         (List.filter (fun p -> is_in_ptr p || is_inout_ptr p) fd.plist)
     in
     if params <> [] then String.concat "\n" params
     else "    /* There were no in nor in-out parameters. */")
  ; ""
  ; (* Prepare out and in-out parameters. The in-out parameter is copied
     to output buffer. *)
    "    /* Set out and in-out pointers. In-out parameters are copied to \
     output buffer. */"
  ; (let params =
       List.map
         (fun (ptype, decl) ->
           let size = oe_get_param_size (ptype, decl, "pargs_in->") in
           let tystr = get_cast_to_mem_type (ptype, decl) in
           sprintf "    OE_%s_POINTER(%s, %s, %s);"
             ( if is_out_ptr (ptype, decl) then "SET_OUT"
             else "COPY_AND_SET_IN_OUT" )
             decl.identifier size tystr )
         (List.filter (fun p -> is_out_ptr p || is_inout_ptr p) fd.plist)
     in
     if params <> [] then String.concat "\n" params
     else "    /* There were no out nor in-out parameters. */")
  ; ""
  ; (* Check for null terminators in string parameters *)
    "    /* Check that in/in-out strings are null terminated. */"
  ; (let params =
       List.map
         (fun (ptype, decl) ->
           sprintf
             "    OE_CHECK_NULL_TERMINATOR%s(pargs_in->%s, pargs_in->%s_len);"
             (if is_wstr_ptr (ptype, decl) then "_WIDE" else "")
             decl.identifier decl.identifier )
         (List.filter
            (fun p ->
              (is_str_ptr p || is_wstr_ptr p) && (is_in_ptr p || is_inout_ptr p)
              )
            fd.plist)
     in
     if params <> [] then String.concat "\n" params
     else "    /* There were no in nor in-out string parameters. */")
  ; ""
  ; "    /* lfence after checks. */"
  ; "    oe_lfence();"
  ; ""
  ; (* Call the enclave function *)
    String.concat "\n    " (oe_gen_call_function fd)
  ; ""
  ; (* Mark call as success *)
    "    /* Success. */"
  ; "    _result = OE_OK;"
  ; "    *output_bytes_written = output_buffer_offset;"
  ; ""
  ; "done:"
  ; "    if (pargs_out && output_buffer_size >= sizeof(*pargs_out))"
  ; "        pargs_out->_result = _result;"
  ; "}"
  ; "" ]

let oe_gen_ecall_functions (tfs : trusted_func list) =
  if tfs <> [] then
    List.flatten (List.map (fun f -> oe_gen_ecall_function f.tf_fdecl) tfs)
  else ["/* There were no ecalls. */"]

let oe_gen_ecall_table (tfs : trusted_func list) =
  if tfs <> [] then
    [ "oe_ecall_func_t __oe_ecalls_table[] = {"
    ; String.concat ",\n"
        (List.map
           (fun f -> sprintf "    (oe_ecall_func_t)ecall_%s" f.tf_fdecl.fname)
           tfs)
    ; "};"
    ; ""
    ; "size_t __oe_ecalls_table_size = OE_COUNTOF(__oe_ecalls_table);" ]
  else ["/* There were no ecalls. */"]

let gen_fill_marshal_struct (fd : func_decl) (args : string) =
  (* Generate assignment argument to corresponding field in args *)
  List.map
    (fun (ptype, decl) ->
      let varname = decl.identifier in
      sprintf "    %s.%s = %s%s;" args varname
        (get_cast_to_mem_expr (ptype, decl))
        varname
      ^
      (* for string parameter fill the len field *)
      if is_str_ptr (ptype, decl) then
        sprintf "\n    %s.%s_len = (%s) ? (strlen(%s) + 1) : 0;" args varname
          varname varname
      else if is_wstr_ptr (ptype, decl) then
        sprintf "\n    %s.%s_len = (%s) ? (wcslen(%s) + 1) : 0;" args varname
          varname varname
      else "" )
    fd.plist

let oe_get_host_ecall_function (os : out_channel) (fd : func_decl) =
  fprintf os "%s" (oe_gen_wrapper_prototype fd true) ;
  fprintf os "\n" ;
  fprintf os "{\n" ;
  fprintf os "    oe_result_t _result = OE_FAILURE;\n\n" ;
  fprintf os "    /* Marshalling struct */\n" ;
  fprintf os "    %s_args_t _args, *_pargs_in = NULL, *_pargs_out=NULL;\n\n"
    fd.fname ;
  fprintf os "    /* Marshalling buffer and sizes */\n" ;
  fprintf os "    size_t _input_buffer_size = 0;\n" ;
  fprintf os "    size_t _output_buffer_size = 0;\n" ;
  fprintf os "    size_t _total_buffer_size = 0;\n" ;
  fprintf os "    uint8_t* _buffer = NULL;\n" ;
  fprintf os "    uint8_t* _input_buffer = NULL;\n" ;
  fprintf os "    uint8_t* _output_buffer = NULL;\n" ;
  fprintf os "    size_t _input_buffer_offset = 0;\n" ;
  fprintf os "    size_t _output_buffer_offset = 0;\n" ;
  fprintf os "    size_t _output_bytes_written = 0;\n\n" ;
  fprintf os "    /* Fill marshalling struct */\n" ;
  fprintf os "    memset(&_args, 0, sizeof(_args));\n" ;
  fprintf os "%s\n" (String.concat "\n" (gen_fill_marshal_struct fd "_args")) ;
  fprintf os "%s"
    (String.concat "\n    " (oe_prepare_input_buffer fd "malloc")) ;
  fprintf os "    /* Call enclave function */\n" ;
  fprintf os "    if((_result = oe_call_enclave_function(\n" ;
  fprintf os "                        enclave,\n" ;
  fprintf os "                        %s,\n" (get_function_id fd) ;
  fprintf os "                        _input_buffer, _input_buffer_size,\n" ;
  fprintf os "                        _output_buffer, _output_buffer_size,\n" ;
  fprintf os "                         &_output_bytes_written)) != OE_OK)\n" ;
  fprintf os "        goto done;\n\n" ;
  fprintf os "%s" (String.concat "\n    " (oe_process_output_buffer fd)) ;
  fprintf os "    _result = OE_OK;\n" ;
  fprintf os "done:\n" ;
  fprintf os "    if (_buffer)\n" ;
  fprintf os "        free(_buffer);\n" ;
  fprintf os "    return _result;\n" ;
  fprintf os "}\n\n"

(** Generate enclave OCALL wrapper function. *)
let oe_gen_enclave_ocall_wrapper (uf : untrusted_func) =
  let fd = uf.uf_fdecl in
  [ oe_gen_wrapper_prototype fd false
  ; "{"
  ; "    oe_result_t _result = OE_FAILURE;"
  ; ""
  ; "    /* If the enclave is in crashing/crashed status, new OCALL should fail"
  ; "       immediately. */"
  ; "    if (oe_get_enclave_status() != OE_OK)"
  ; "        return oe_get_enclave_status();"
  ; ""
  ; "    /* Marshalling struct */"
  ; sprintf "    %s_args_t _args, *_pargs_in = NULL, *_pargs_out = NULL;"
      fd.fname
  ; ""
  ; "    /* Marshalling buffer and sizes */"
  ; "    size_t _input_buffer_size = 0;"
  ; "    size_t _output_buffer_size = 0;"
  ; "    size_t _total_buffer_size = 0;"
  ; "    uint8_t* _buffer = NULL;"
  ; "    uint8_t* _input_buffer = NULL;"
  ; "    uint8_t* _output_buffer = NULL;"
  ; "    size_t _input_buffer_offset = 0;"
  ; "    size_t _output_buffer_offset = 0;"
  ; "    size_t _output_bytes_written = 0;"
  ; ""
  ; "    /* Fill marshalling struct */"
  ; "    memset(&_args, 0, sizeof(_args));"
  ; String.concat "\n" (gen_fill_marshal_struct fd "_args")
  ; ""
  ; "    "
    ^ String.concat "\n    "
        (oe_prepare_input_buffer fd "oe_allocate_ocall_buffer")
  ; ""
  ; "    /* Call host function */"
  ; "    if ((_result = oe_call_host_function("
  ; "             "
    ^ String.concat ",\n             "
        [ sprintf "%s" (get_function_id fd)
        ; "_input_buffer"
        ; "_input_buffer_size"
        ; "_output_buffer"
        ; "_output_buffer_size"
        ; "&_output_bytes_written)) != OE_OK)" ]
  ; "        goto done;"
  ; ""
  ; String.concat "\n    " (oe_process_output_buffer fd)
  ; "    /* Propagate errno */"
  ; ( if uf.uf_propagate_errno then "    errno = _pargs_out->_ocall_errno;\n"
    else sprintf "    /* Errno not enabled */" )
  ; "    _result = OE_OK;"
  ; ""
  ; "done:"
  ; "    if (_buffer)"
  ; "        oe_free_ocall_buffer(_buffer);"
  ; "    return _result;"
  ; "}"
  ; "" ]

(** Generate all enclave OCALL wrapper functions, if any. *)
let oe_gen_enclave_ocall_wrappers (ufs : untrusted_func list) =
  if ufs <> [] then List.flatten (List.map oe_gen_enclave_ocall_wrapper ufs)
  else ["/* There were no ocalls. */"]

(** Generate ocall function table and registration *)
let oe_gen_ocall_table (os : out_channel) (ec : enclave_content) =
  fprintf os "\n/*ocall function table*/\n" ;
  fprintf os "static oe_ocall_func_t __%s_ocall_function_table[]= {\n"
    ec.enclave_name ;
  List.iter
    (fun fd -> fprintf os "    (oe_ocall_func_t) ocall_%s,\n" fd.uf_fdecl.fname)
    ec.ufunc_decls ;
  fprintf os "    NULL\n" ;
  fprintf os "};\n\n"

(** Generate ocalls wrapper function *)
let oe_gen_ocall_host_wrapper (os : out_channel) (uf : untrusted_func) =
  let propagate_errno = uf.uf_propagate_errno in
  let fd = uf.uf_fdecl in
  fprintf os "void ocall_%s(\n" fd.fname ;
  fprintf os "        uint8_t* input_buffer, size_t input_buffer_size,\n" ;
  fprintf os "        uint8_t* output_buffer, size_t output_buffer_size,\n" ;
  fprintf os "        size_t* output_bytes_written)\n" ;
  (* Variable declarations *)
  fprintf os "{\n" ;
  fprintf os "    oe_result_t _result = OE_FAILURE;\n" ;
  fprintf os "    OE_UNUSED(input_buffer_size);\n\n" ;
  fprintf os "    /* Prepare parameters */\n" ;
  fprintf os "    %s_args_t* pargs_in = (%s_args_t*) input_buffer;\n" fd.fname
    fd.fname ;
  fprintf os "    %s_args_t* pargs_out = (%s_args_t*) output_buffer;\n\n"
    fd.fname fd.fname ;
  fprintf os "    size_t input_buffer_offset = 0;\n" ;
  fprintf os "    size_t output_buffer_offset = 0;\n" ;
  fprintf os "    OE_ADD_SIZE(input_buffer_offset, sizeof(*pargs_in));\n" ;
  fprintf os "    OE_ADD_SIZE(output_buffer_offset, sizeof(*pargs_out));\n\n" ;
  (* Buffer validation *)
  fprintf os "    /* Make sure input and output buffers are valid */\n" ;
  fprintf os "    if (!input_buffer || !output_buffer) {\n" ;
  fprintf os "        _result = OE_INVALID_PARAMETER;\n" ;
  fprintf os "        goto done;\n\n" ;
  fprintf os "    }\n" ;
  (* Prepare in and in-out parameters *)
  fprintf os "    /* Set in and in-out pointers */\n" ;
  List.iter
    (fun (ptype, decl) ->
      match ptype with
      | PTPtr (_, ptr_attr) ->
          if ptr_attr.pa_chkptr then
            let size = oe_get_param_size (ptype, decl, "pargs_in->") in
            let tystr = get_cast_to_mem_type (ptype, decl) in
            match ptr_attr.pa_direction with
            | PtrIn ->
                fprintf os "    OE_SET_IN_POINTER(%s, %s, %s);\n"
                  decl.identifier size tystr
            | PtrInOut ->
                fprintf os "    OE_SET_IN_OUT_POINTER(%s, %s, %s);\n"
                  decl.identifier size tystr
            | _ -> ()
          else ()
      | _ -> () )
    fd.plist ;
  fprintf os "\n" ;
  (* Prepare out and in-out parameters. The in-out parameter is copied to output buffer. *)
  fprintf os
    "    /* Set out and in-out pointers. In-out parameters are copied to \
     output buffer. */\n" ;
  List.iter
    (fun (ptype, decl) ->
      match ptype with
      | PTPtr (_, ptr_attr) ->
          if ptr_attr.pa_chkptr then
            let size = oe_get_param_size (ptype, decl, "pargs_in->") in
            let tystr = get_cast_to_mem_type (ptype, decl) in
            match ptr_attr.pa_direction with
            | PtrOut ->
                fprintf os "    OE_SET_OUT_POINTER(%s, %s, %s);\n"
                  decl.identifier size tystr
            | PtrInOut ->
                fprintf os "    OE_COPY_AND_SET_IN_OUT_POINTER(%s, %s, %s);\n"
                  decl.identifier size tystr
            | _ -> ()
          else ()
      | _ -> () )
    fd.plist ;
  (* Call the host function *)
  fprintf os "%s\n" (String.concat "\n    " (oe_gen_call_function fd)) ;
  (* Propagate errno *)
  if propagate_errno then (
    fprintf os "\n    /* Propagate errno */\n" ;
    fprintf os "    pargs_out->_ocall_errno = errno;\n" ) ;
  (* Mark call as success *)
  fprintf os "\n    /* Success. */\n" ;
  fprintf os "    _result = OE_OK;\n" ;
  fprintf os "    *output_bytes_written = output_buffer_offset;\n\n" ;
  fprintf os "done:\n" ;
  fprintf os "    if (pargs_out && output_buffer_size >= sizeof(*pargs_out))\n" ;
  fprintf os "        pargs_out->_result = _result;\n" ;
  fprintf os "}\n\n"

(** Check if any of the parameters or the return type has the given
    root type. *)
let uses_type (root_type : atype) (fd : func_decl) =
  let param_match =
    List.exists (fun (pt, decl) -> root_type = get_param_atype pt) fd.plist
  in
  if param_match then param_match else root_type = fd.rtype

let warn_non_portable_types (fd : func_decl) =
  let print_portability_warning ty =
    printf
      "Warning: Function '%s': %s has different sizes on Windows and Linux. \
       This enclave cannot be built in Linux and then safely loaded in \
       Windows.\n"
      fd.fname ty
  in
  let print_portability_warning_with_recommendation ty recommendation =
    printf
      "Warning: Function '%s': %s has different sizes on Windows and Linux. \
       This enclave cannot be built in Linux and then safely loaded in \
       Windows. Consider using %s instead.\n"
      fd.fname ty recommendation
  in
  (* longs are represented as an Int type *)
  let long_t = Int {ia_signedness= Signed; ia_shortness= ILong} in
  let ulong_t = Int {ia_signedness= Unsigned; ia_shortness= ILong} in
  if uses_type WChar fd then print_portability_warning "wchar_t" ;
  if uses_type LDouble fd then print_portability_warning "long double" ;
  (* Handle long type *)
  if uses_type (Long Signed) fd || uses_type long_t fd then
    print_portability_warning_with_recommendation "long" "int64_t or int32_t" ;
  (* Handle unsigned long type *)
  if uses_type (Long Unsigned) fd || uses_type ulong_t fd then
    print_portability_warning_with_recommendation "unsigned long"
      "uint64_t or uint32_t"

let warn_signed_size_or_count_types (fd : func_decl) =
  let print_signedness_warning p =
    printf
      "Warning: Function '%s': Size or count parameter '%s' should not be \
       signed.\n"
      fd.fname p
  in
  (* Get the names of all size and count parameters for the function [fd]. *)
  let size_params =
    List.map
      (fun (ptype, decl) ->
        (* The size may be either a [count] or [size], and then either a
         number or string. We are interested in the strings, as the
         indicate named [size] or [count] parameters. *)
        let param_name {ps_size; ps_count} =
          match (ps_size, ps_count) with
          (* [s] is the name of the parameter as a string. *)
          | None, Some (AString s) | Some (AString s), None -> s
          (* TODO: Check for [Some (ANumber n)] that [n > 0] *)
          | _ -> ""
        in
        (* Only variables that are pointers where [chkptr] is true may
         have size parameters. TODO: Validate this! *)
        match ptype with
        | PTPtr (_, ptr_attr) when ptr_attr.pa_chkptr ->
            param_name ptr_attr.pa_size
        | _ -> "" )
      fd.plist
    |> List.filter (fun x -> String.length x > 0)
    (* Remove the empty strings. *)
  in
  (* Print warnings for size parameters that are [Signed]. *)
  List.iter
    (fun (ptype, decl) ->
      (* TODO: Maybe make this a utility function. *)
      let get_int_signedness (i : int_attr) = i.ia_signedness in
      let name = decl.identifier in
      if List.mem name size_params then
        match ptype with
        (* TODO: Combine these two patterns. *)
        | PTVal (Long s | LLong s) when s = Signed ->
            print_signedness_warning name
        | PTVal (Int i) when get_int_signedness i = Signed ->
            print_signedness_warning name
        | _ -> () )
    fd.plist

let warn_size_and_count_params (fd : func_decl) =
  let print_size_and_count_warning {ps_size; ps_count} =
    match (ps_size, ps_count) with
    | Some (AString p), Some (AString q) ->
        failwithf
          "Function '%s': simultaneous 'size' and 'count' parameters '%s' and \
           '%s' are not supported by oeedger8r.\n"
          fd.fname p q
    | _ -> ()
  in
  List.iter
    (fun (ptype, _) ->
      match ptype with
      | PTPtr (_, ptr_attr) when ptr_attr.pa_chkptr ->
          print_size_and_count_warning ptr_attr.pa_size
      | _ -> () )
    fd.plist

(** Validate Open Enclave supported EDL features. *)
let validate_oe_support (ec : enclave_content) (ep : edger8r_params) =
  (* check supported options *)
  if ep.use_prefix then
    failwithf "--use_prefix option is not supported by oeedger8r." ;
  List.iter
    (fun f ->
      if f.tf_is_priv then
        failwithf
          "Function '%s': 'private' specifier is not supported by oeedger8r"
          f.tf_fdecl.fname ;
      if f.tf_is_switchless then
        failwithf
          "Function '%s': switchless ecalls and ocalls are not yet supported \
           by Open Enclave SDK."
          f.tf_fdecl.fname )
    ec.tfunc_decls ;
  List.iter
    (fun f ->
      ( if f.uf_fattr.fa_convention <> CC_NONE then
        let cconv_str = get_call_conv_str f.uf_fattr.fa_convention in
        printf
          "Warning: Function '%s': Calling convention '%s' for ocalls is not \
           supported by oeedger8r.\n"
          f.uf_fdecl.fname cconv_str ) ;
      if f.uf_fattr.fa_dllimport then
        failwithf "Function '%s': dllimport is not supported by oeedger8r."
          f.uf_fdecl.fname ;
      if f.uf_allow_list != [] then
        printf
          "Warning: Function '%s': Reentrant ocalls are not supported by Open \
           Enclave. Allow list ignored.\n"
          f.uf_fdecl.fname ;
      if f.uf_is_switchless then
        failwithf
          "Function '%s': switchless ecalls and ocalls are not yet supported \
           by Open Enclave SDK."
          f.uf_fdecl.fname )
    ec.ufunc_decls ;
  (* Map warning functions over trusted and untrusted function
     declarations *)
  let ufuncs = List.map (fun f -> f.uf_fdecl) ec.ufunc_decls in
  let tfuncs = List.map (fun f -> f.tf_fdecl) ec.tfunc_decls in
  let funcs = List.append ufuncs tfuncs in
  List.iter
    (fun f ->
      warn_non_portable_types f ;
      warn_signed_size_or_count_types f ;
      warn_size_and_count_params f )
    funcs

(** Includes are emitted in [args.h]. Imported functions have already
    been brought into function lists. *)
let gen_t_h (ec : enclave_content) (ep : edger8r_params) =
  let fname = ec.file_shortnm ^ "_t.h" in
  let guard = sprintf "EDGER8R_%s_T_H" (String.uppercase ec.file_shortnm) in
  let os = open_file fname ep.trusted_dir in
  fprintf os "#ifndef %s\n" guard ;
  fprintf os "#define %s\n\n" guard ;
  fprintf os "#include <openenclave/enclave.h>\n" ;
  fprintf os "#include \"%s_args.h\"\n\n" ec.file_shortnm ;
  fprintf os "OE_EXTERNC_BEGIN\n\n" ;
  if ec.tfunc_decls <> [] then (
    fprintf os "/* List of ecalls */\n\n" ;
    List.iter
      (fun f -> fprintf os "%s;\n" (oe_gen_prototype f.tf_fdecl))
      ec.tfunc_decls ;
    fprintf os "\n" ) ;
  if ec.ufunc_decls <> [] then (
    fprintf os "/* List of ocalls */\n\n" ;
    List.iter
      (fun d -> fprintf os "%s;\n" (oe_gen_wrapper_prototype d.uf_fdecl false))
      ec.ufunc_decls ;
    fprintf os "\n" ) ;
  fprintf os "OE_EXTERNC_END\n\n" ;
  fprintf os "#endif // %s\n" guard ;
  close_out os

let gen_t_c (ec : enclave_content) (ep : edger8r_params) =
  let content =
    [ sprintf "#include \"%s_t.h\"" ec.file_shortnm
    ; "#include <openenclave/edger8r/enclave.h>"
    ; "#include <stdlib.h>"
    ; "#include <string.h>"
    ; "#include <wchar.h>"
    ; ""
    ; "OE_EXTERNC_BEGIN"
    ; ""
    ; "/**** ECALL functions. ****/"
    ; String.concat "\n" (oe_gen_ecall_functions ec.tfunc_decls)
    ; ""
    ; "/**** ECALL function table. ****/"
    ; String.concat "\n" (oe_gen_ecall_table ec.tfunc_decls)
    ; ""
    ; "/**** OCALL function wrappers. ****/"
    ; String.concat "\n" (oe_gen_enclave_ocall_wrappers ec.ufunc_decls)
    ; ""
    ; "OE_EXTERNC_END" ]
  in
  let ecalls_fname = ec.file_shortnm ^ "_t.c" in
  let os = open_file ecalls_fname ep.trusted_dir in
  fprintf os "%s" (String.concat "\n" content) ;
  close_out os

let oe_emit_create_enclave_decl (os : out_channel) (ec : enclave_content) =
  fprintf os "oe_result_t oe_create_%s_enclave(const char* path,\n"
    ec.enclave_name ;
  fprintf os "                                 oe_enclave_type_t type,\n" ;
  fprintf os "                                 uint32_t flags,\n" ;
  fprintf os "                                 const void* config,\n" ;
  fprintf os "                                 uint32_t config_size,\n" ;
  fprintf os "                                 oe_enclave_t** enclave);\n\n"

let oe_emit_create_enclave_defn (os : out_channel) (ec : enclave_content) =
  fprintf os "oe_result_t oe_create_%s_enclave(const char* path,\n"
    ec.enclave_name ;
  fprintf os "                                 oe_enclave_type_t type,\n" ;
  fprintf os "                                 uint32_t flags,\n" ;
  fprintf os "                                 const void* config,\n" ;
  fprintf os "                                 uint32_t config_size,\n" ;
  fprintf os "                                 oe_enclave_t** enclave)\n" ;
  fprintf os "{\n" ;
  fprintf os "    return oe_create_enclave(path,\n" ;
  fprintf os "               type,\n" ;
  fprintf os "               flags,\n" ;
  fprintf os "               config,\n" ;
  fprintf os "               config_size,\n" ;
  fprintf os "               __%s_ocall_function_table,\n" ec.enclave_name ;
  fprintf os "               %d,\n" (List.length ec.ufunc_decls) ;
  fprintf os "               enclave);\n" ;
  fprintf os "}\n\n"

let gen_u_h (ec : enclave_content) (ep : edger8r_params) =
  let fname = ec.file_shortnm ^ "_u.h" in
  let guard = sprintf "EDGER8R_%s_U_H" (String.uppercase ec.file_shortnm) in
  let os = open_file fname ep.untrusted_dir in
  fprintf os "#ifndef %s\n" guard ;
  fprintf os "#define %s\n\n" guard ;
  fprintf os "#include <openenclave/host.h>\n" ;
  fprintf os "#include \"%s_args.h\"\n\n" ec.file_shortnm ;
  fprintf os "OE_EXTERNC_BEGIN\n\n" ;
  oe_emit_create_enclave_decl os ec ;
  if ec.tfunc_decls <> [] then (
    fprintf os "/* List of ecalls */\n\n" ;
    List.iter
      (fun f -> fprintf os "%s;\n" (oe_gen_wrapper_prototype f.tf_fdecl true))
      ec.tfunc_decls ;
    fprintf os "\n" ) ;
  if ec.ufunc_decls <> [] then (
    fprintf os "/* List of ocalls */\n\n" ;
    List.iter
      (fun d -> fprintf os "%s;\n" (oe_gen_prototype d.uf_fdecl))
      ec.ufunc_decls ;
    fprintf os "\n" ) ;
  fprintf os "OE_EXTERNC_END\n\n" ;
  fprintf os "#endif // %s\n" guard ;
  close_out os

let gen_u_c (ec : enclave_content) (ep : edger8r_params) =
  let ecalls_fname = ec.file_shortnm ^ "_u.c" in
  let os = open_file ecalls_fname ep.untrusted_dir in
  fprintf os "#include \"%s_u.h\"\n" ec.file_shortnm ;
  fprintf os "#include <openenclave/edger8r/host.h>\n" ;
  fprintf os "#include <stdlib.h>\n" ;
  fprintf os "#include <string.h>\n" ;
  fprintf os "#include <wchar.h>\n" ;
  fprintf os "\n" ;
  fprintf os "OE_EXTERNC_BEGIN\n\n" ;
  if ec.tfunc_decls <> [] then (
    fprintf os "/* Wrappers for ecalls */\n\n" ;
    List.iter
      (fun d ->
        oe_get_host_ecall_function os d.tf_fdecl ;
        fprintf os "\n\n" )
      ec.tfunc_decls ) ;
  if ec.ufunc_decls <> [] then (
    fprintf os "\n/* ocall functions */\n\n" ;
    List.iter (fun d -> oe_gen_ocall_host_wrapper os d) ec.ufunc_decls ) ;
  oe_gen_ocall_table os ec ;
  oe_emit_create_enclave_defn os ec ;
  fprintf os "OE_EXTERNC_END\n" ;
  close_out os

(** Generate the Enclave code. *)
let gen_enclave_code (ec : enclave_content) (ep : edger8r_params) =
  validate_oe_support ec ep ;
  if ep.gen_trusted then (
    oe_gen_args_header ec ep.trusted_dir ;
    gen_t_h ec ep ;
    if not ep.header_only then gen_t_c ec ep ) ;
  if ep.gen_untrusted then (
    oe_gen_args_header ec ep.untrusted_dir ;
    gen_u_h ec ep ;
    if not ep.header_only then gen_u_c ec ep ) ;
  printf "Success.\n"

(** Install the plugin. *)
let _ =
  Printf.printf "Generating edge routines for the Open Enclave SDK.\n" ;
  Plugin.instance.available <- true ;
  Plugin.instance.gen_edge_routines <- gen_enclave_code
