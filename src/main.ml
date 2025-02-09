open Core
open Command.Let_syntax

let ( = ) = Stdlib.( = )
let ( <> ) = Stdlib.( <> )

module Json = Yojson.Safe

let debug = Option.is_some (Sys.getenv "DEBUG_OCAML_LSIF")

let i : int ref = ref 1

let fresh () =
  let id = !i in
  i := !i + 1;
  Int.to_string id

(** LSIF export types. *)
module Export = struct
  type tool_info =
    { name : string
    ; version : string
    }
  [@@deriving to_yojson]

  type content =
    { language : string
    ; value : string
    }
  [@@deriving to_yojson]

  type hover =
    { contents : content list
    }
  [@@deriving to_yojson]

  type location =
    { line : int
    ; character : int
    }
  [@@deriving to_yojson]

  type result =
    | Hover of hover

  let result_to_yojson = function
    | Hover contents -> hover_to_yojson contents

  type entry =
    { id : string
    ; entry_type : string [@key "type"]
    ; label : string
    ; result : result option
               [@default None]
    ; start : location option
              [@default None]
    ; end_ : location option
             [@key "end"]
             [@default None]
    ; version : string option
                [@default None]
    ; project_root : string option
                     [@key "projectRoot"]
                     [@default None]
    ; position_encoding : string option
                          [@key "positionEncoding"]
                          [@default None]
    ; tool_info : tool_info option
                  [@key "toolInfo"]
                  [@default None]
    ; kind : string option
             [@default None]
    ; uri : string option
            [@default None]
    ; language_id : string option
                    [@key "languageId"]
                    [@default None]
    ; contents : string option
                 [@default None]
    ; out_v : string option
              [@key "outV"]
              [@default None]
    ; in_v : string option
             [@key "inV"]
             [@default None]
    ; out_vs : string list option
               [@key "outVs"]
               [@default None]
    ; in_vs : string list option
              [@key "inVs"]
              [@default None]
    ; document : string option
                 [@default None]
    }
  [@@deriving to_yojson]

  let default =
    { id = "-1"
    ; entry_type = ""
    ; label = ""
    ; result = None
    ; start = None
    ; end_ = None
    ; version = None
    ; project_root = None
    ; position_encoding = None
    ; tool_info = None
    ; kind = None
    ; uri = None
    ; language_id = None
    ; contents = None
    ; out_v = None
    ; in_v = None
    ; out_vs = None
    ; in_vs = None
    ; document = None
    }

  module Vertex = struct
    let range start_line start_character end_line end_character =
      { default with
        entry_type = "vertex"
      ; label = "range"
      ; start =
          Some
            { line = start_line
            ; character = start_character
            }
      ; end_ =
          Some
            { line = end_line
            ; character = end_character
            }
      }

    let hover_result value =
      { default with
        entry_type = "vertex"
      ; label = "hoverResult"
      ; result =
          Some
            (Hover
               { contents =
                   [
                     { language = "OCaml"
                     ; value
                     }
                   ]
               })
      }

    let definition_result () =
      { default with
        entry_type = "vertex"
      ; label = "definitionResult"
      ; result = None
      }

    let result_set () =
      { default with
        entry_type = "vertex"
      ; label = "resultSet"
      ; result = None
      }

  end
end

(** Merlin's response. *)
module Import = struct
  type location =
    { line : int
    ; col : int
    }
  [@@deriving of_yojson]

  type type_info =
    { start: location
    ; end_: location [@key "end"]
    ; type_ : string [@key "type"]
    }
  [@@deriving of_yojson]

  type definition_content =
    { file : string
    ; pos : location
    }
  [@@deriving of_yojson]

  type definition_info =
    { start: location
    ; end_: location [@key "end"]
    ; definition : definition_content
    }
  [@@deriving of_yojson]

  type t =
    | Type_info of type_info
    | Definition of definition_info
end

(** Skip or continue directory descent. *)
type 'a next =
  | Skip of 'a
  | Continue of 'a

let fold_directory root ~init ~f =
  let rec aux acc absolute_path depth =
    if Sys_unix.is_file absolute_path = `Yes then
      match f acc ~depth ~absolute_path ~is_file:true with
      | Continue acc
      | Skip acc -> acc
    else if Sys_unix.is_directory absolute_path = `Yes then
      match f acc ~depth ~absolute_path ~is_file:false with
      | Skip acc -> acc
      | Continue acc ->
        Sys_unix.ls_dir absolute_path
        |> List.fold ~init:acc ~f:(fun acc subdir ->
            aux acc (Filename.concat absolute_path subdir) (depth + 1))
    else
      acc
  in
  aux init root (-1)

type hover_result_vertices =
  { result_set_vertex : Export.entry
  ; range_vertex : Export.entry
  ; type_info_vertex : Export.entry
  }

type definition_result_vertices =
  { declaration_result_set_vertex : Export.entry
  ; declaration_range_vertex : Export.entry
  ; reference_range_vertex : Export.entry
  ; definition_result_vertex : Export.entry
  ; destination_file : string
  }

type intermediate_result =
  { hovers : hover_result_vertices list
  ; definitions : definition_result_vertices list
  }

type filepath_hover_results =
  { filepath : string
  ; result : intermediate_result
  }

let connect ?out_v ?in_v ?in_vs ?document ~label () =
  if Option.is_some in_v then
    { Export.default with
      id = fresh ()
    ; entry_type = "edge"
    ; label
    ; out_v
    ; in_v
    ; document
    }
  else if Option.is_some in_vs then
    { Export.default with
      id = fresh ()
    ; entry_type = "edge"
    ; label
    ; out_v
    ; in_vs
    ; document
    }
  else
    failwith "Do not call connect with both in_v and in_vs"

let to_lsif merlin_results : intermediate_result =
  let open Export in
  let open Import in
  let open Option in
  let init = { hovers = []; definitions = [] } in
  List.fold merlin_results ~init ~f:(fun acc merlin_result ->
      let json = Json.from_string merlin_result in
      let result =
        match type_info_of_yojson json with
        | Ok t -> Some (Type_info t)
        | Error _ ->
          match definition_info_of_yojson json with
          | Ok d -> Some (Definition d)
          | Error _ ->
            if debug then
              Format.eprintf
                "Merlin response is not type info or \
                 definition info, ignoring it: %s@."
              @@ Json.pretty_to_string json;
            None
      in
      let exported =
        result >>= function
        | Type_info { start; end_; type_ } ->
          let result_set_vertex = Vertex.result_set () in
          let range_vertex = Vertex.range (start.line - 1) start.col (end_.line - 1) end_.col in
          let type_info_vertex = Vertex.hover_result type_ in
          return (`Hover { result_set_vertex; range_vertex; type_info_vertex })
        | Definition { start; end_; definition = { file; pos } } ->
          (* Create a resultSet vertex for the range where this definition is. *)
          let declaration_result_set_vertex = Vertex.result_set () in
          (* Create the vertex range for it. *)
          let declaration_range_vertex = Vertex.range (pos.line - 1) (pos.col - 1) (pos.line - 1) (pos.col - 1) in
          let reference_range_vertex = Vertex.range (start.line - 1) start.col (end_.line - 1) end_.col in
          (* Create a definitionResult vertex *)
          let definition_result_vertex = Vertex.definition_result () in
          let destination_file = file in
          return
            (`Definition
               { declaration_result_set_vertex
               ; declaration_range_vertex
               ; reference_range_vertex
               ; definition_result_vertex
               ; destination_file
               })
      in
      match exported with
      | Some (`Hover result) -> { acc with hovers = result::acc.hovers }
      | Some (`Definition result) -> { acc with definitions = result::acc.definitions }
      | None -> acc)

let process_filepath filename : intermediate_result option =
  if debug then Format.printf "File: %s@." filename;
  try
    In_channel.read_all (filename ^ ".lsif.in")
    |> String.split_lines
    |> to_lsif
    |> Option.some
  with _ -> None

let header host root =
  { Export.default with
    id = fresh ()
  ; entry_type = "vertex"
  ; label = "metaData"
  ; version = Some "0.4.0"
  ; project_root = Some ("file:///"^host^/root)
  ; tool_info = Some { name = "lsif-ocaml"; version = "0.1.0" }
  ; position_encoding = Some "utf-16"
  }

let project () =
  { Export.default with
    id = fresh ()
  ; entry_type = "vertex"
  ; label = "project"
  ; kind = Some "OCaml"
  }

let make_document host project_root relative_filepath absolute_filepath =
  { Export.default with
    entry_type = "vertex"
  ; label = "document"
  ; uri = Some ("file:///"^host^/project_root^/relative_filepath)
  ; language_id = Some "OCaml"
  ; contents = None
  }

let connect_ranges results document_id =
  let open Export in
  let in_vs = List.filter_map results ~f:(function
      | { id; label = "range"; _ } -> Some id
      | _ -> None)
  in
  connect ~out_v:document_id ~in_vs ~label:"contains" ()

let paths root exclude_directories =
  let f acc ~depth:_ ~absolute_path ~is_file =
    let is_ml_file =
      if is_file then
        [".ml"; ".mli" ]
        |> List.exists ~f:(fun suffix -> String.is_suffix ~suffix absolute_path)
      else
        false
    in
    if is_ml_file then
      Continue (absolute_path::acc)
      (* Don't descend into excluded directories, like _build. *)
    else if List.exists exclude_directories ~f:((=) (Filename.basename absolute_path)) then
      Skip acc
    else
      Continue acc
  in
  fold_directory root ~init:[] ~f

let print =
  Fn.compose
    Json.to_string
    Export.entry_to_yojson

let main host project_root exclude_directories local_absolute_root strip_prefix emit_type_hovers emit_definitions =
  let paths = paths local_absolute_root exclude_directories in
  let header = header host project_root in
  let project = project () in
  Format.printf "%s@." @@ print header;
  Format.printf "%s@." @@ print project;
  let results = List.filter_map paths ~f:(fun filepath ->
      match process_filepath filepath with
      | Some result -> Some { filepath; result }
      | None -> None) in
  let document_id_table = String.Table.create () in
  List.iter results ~f:(fun { filepath = absolute_filepath; result = { hovers; definitions } } ->
      let relative_filepath = String.chop_prefix_exn absolute_filepath ~prefix:strip_prefix in
      let document = make_document host project_root relative_filepath absolute_filepath in
      let document =
        match Hashtbl.find document_id_table absolute_filepath with
        | Some id -> { document with id = Int.to_string id }
        | None ->
          let id = Int.of_string (fresh ()) in
          Hashtbl.add_exn document_id_table ~key:absolute_filepath ~data:id;
          let document = { document with id = Int.to_string id } in
          Format.printf "%s@." @@ print document;
          let document_in_project_edge =
            connect ~out_v:project.id ~in_vs:[document.id] ~label:"contains" ()
          in
          Format.printf "%s@." @@ print document_in_project_edge;
          document
      in
      if emit_type_hovers then
        begin
          (* Reverse list for in-order printing. *)
          let hovers = List.rev hovers in
          let hovers =
            List.concat_map hovers ~f:(fun { result_set_vertex; range_vertex; type_info_vertex } ->
                let result_set_vertex = { result_set_vertex with id = fresh () } in
                let range_vertex = { range_vertex with id = fresh () } in
                (* Connect range (outV) to resultSet (inV). *)
                let result_set_edge =
                  connect ~out_v:range_vertex.id ~in_v:result_set_vertex.id ~label:"next" ()
                in
                let type_info_vertex = { type_info_vertex with id = fresh () } in
                (* Connect resultSet (outV) to hoverResult (inV). *)
                let hover_edge =
                  connect ~out_v:result_set_vertex.id ~in_v:type_info_vertex.id ~label:"textDocument/hover" ()
                in
                [result_set_vertex; range_vertex; result_set_edge; type_info_vertex; hover_edge])
          in
          if hovers <> [] then
            begin
              List.iter hovers ~f:(fun entry -> Format.printf "%s@." @@ print entry);
              let edges_entry = connect_ranges hovers document.id in
              Format.printf "%s@." @@ print edges_entry;
            end
        end;
      if emit_definitions then
        begin
          let definitions : Export.entry list =
            List.concat_map
              definitions
              ~f:(fun
                   { declaration_result_set_vertex
                   ; declaration_range_vertex
                   ; reference_range_vertex
                   ; definition_result_vertex
                   ; destination_file
                   } ->
                   let declaration_result_set_vertex = { declaration_result_set_vertex with id = fresh () } in
                   let declaration_range_vertex = { declaration_range_vertex with id = fresh () } in
                   let reference_range_vertex = { reference_range_vertex with id = fresh () } in
                   let definition_result_vertex = { definition_result_vertex with id = fresh () } in
                   (* Create an edge with 'next' to connect resultSet and declaration range above. *)
                   let declaration_result_set_to_declaration_range_edge =
                     connect
                       ~out_v:declaration_range_vertex.id
                       ~in_v:declaration_result_set_vertex.id
                       ~label:"next"
                       ()
                   in
                   (* Create a range vertex for the reference range. *)
                   let declaration_result_set_to_reference_range_edge =
                     connect
                       ~out_v:reference_range_vertex.id
                       ~in_v:declaration_result_set_vertex.id
                       ~label:"next"
                       ()
                   in
                   (* Connect the definitionResult above to the resultset with textDocument/definition edge. *)
                   let definition_result_to_declaration_result_set_edge =
                     connect
                       ~out_v:declaration_result_set_vertex.id
                       ~in_v:definition_result_vertex.id
                       ~label:"textDocument/definition"
                       ()
                   in
                   let definition_result_to_document_and_range =
                     let destination_file =
                       match destination_file with
                       | "*buffer*" -> absolute_filepath
                       | filepath -> filepath
                     in
                     let document =
                       match Hashtbl.find document_id_table destination_file with
                       | Some id ->
                         (* Case where this was already printed the previous time we added to the table. *)
                         Some { document with id = Int.to_string id }
                       | None ->
                         match String.chop_prefix destination_file ~prefix:strip_prefix with
                         | None ->
                           (* A different path, probably in .opam for external libraries. *)
                           (*destination_file*)
                           None
                         | Some relative_filepath ->
                           let document = make_document host project_root relative_filepath absolute_filepath in
                           let id = Int.of_string (fresh ()) in
                           Hashtbl.add_exn document_id_table ~key:destination_file ~data:id;
                           let document = { document with id = Int.to_string id } in
                           Format.printf "%s@." @@ print document;
                           let document_in_project_edge =
                             connect ~out_v:project.id ~in_vs:[document.id] ~label:"contains" ()
                           in
                           Format.printf "%s@." @@ print document_in_project_edge;
                           Some document
                     in
                     (* Add "item" edge to connect the definitionResult vertex to the range for a particular document (id). *)
                     match document with
                     | None -> None
                     | Some document ->
                       Some (connect
                               ~out_v:definition_result_vertex.id
                               ~in_vs:[declaration_range_vertex.id]
                               ~document:document.id
                               ~label:"item"
                               ())
                   in
                   let declaration_range = match declaration_range_vertex with
                     | { start = None; _ } -> None
                     | { start = Some { line; character = (-1) }; _ } -> None
                     | x -> Some x
                   in
                   let reference_range = match reference_range_vertex with
                     | { start = None; _ } -> None
                     | { start = Some { line; character = (-1) }; _ } -> None
                     | x -> Some x
                   in
                   match
                     definition_result_to_document_and_range,
                     declaration_range,
                     reference_range
                   with
                   | None, _, _
                   | _, None, _
                   | _, _, None
                     -> []
                   | Some definition_result_to_document_and_range, Some _, Some _ ->
                     let single_definition_result =
                       [ declaration_result_set_vertex
                       ; declaration_range_vertex
                       ; declaration_result_set_to_declaration_range_edge
                       ; reference_range_vertex
                       ; declaration_result_set_to_reference_range_edge
                       ; definition_result_vertex
                       ; definition_result_to_declaration_result_set_edge
                       ; definition_result_to_document_and_range
                       ]
                     in
                     List.iter single_definition_result ~f:(fun entry -> Format.printf "%s@." @@ print entry);
                     single_definition_result)
          in
          if definitions <> [] then
            let edges_entry = connect_ranges definitions document.id in
            Format.printf "%s@." @@ print edges_entry;
        end)

let parameters : (unit -> 'result) Command.Param.t =
  [%map_open
    let host = flag "host" (optional_with_default "github.com" string) ~doc:"host The host for this project (default: github.com)"
    and project_root = flag "exported-project-root" ~aliases:["export"; "e"] (optional string) ~doc:"project-root The project root on the host to export to (e.g., username/github-repo-name)"
    and exclude_directories = flag "exclude" (optional_with_default ["_build"; "test"] (Arg_type.comma_separated string)) ~doc:"dir1,dir2,... Exclude these directories ('_build' and 'test' is ignored by default)"
    and emit_type_hovers = flag "only-type-hovers" no_arg ~doc:"only emit hover type information"
    and emit_definitions = flag "only-definitions" no_arg ~doc:"only emit definition information"
    in
    fun () ->
      let project_root =
        match project_root with
        | Some project_root -> project_root
        | None ->
          try
            Core_unix.open_process_in "git config --get remote.origin.url"
            |> In_channel.input_all
            |> String.substr_replace_all ~pattern:"https://github.com/" ~with_:""
            |> String.substr_replace_all ~pattern:".git" ~with_:""
            |> String.strip
          with _ ->
            Format.eprintf "Name the project root, like '-e user/project', where user/project is the part coming from github.com/user/project.";
            exit 1
      in
      let local_root = Sys_unix.getcwd () in
      let strip_prefix = Sys_unix.getcwd () in
      let emit_type_hovers, emit_definitions =
        match emit_type_hovers, emit_definitions with
        | false, false -> true, true
        | _ as t -> t
      in
      main host project_root exclude_directories local_root strip_prefix emit_type_hovers emit_definitions
  ]

let () =
  Command.basic
    parameters
    ~summary:
      "Output LSIF data. The file path scheme is\n \
       file:///<host>/<project_root>/directories, where, for example:\n \
       host is github.com\n \
       project-root is username/github-project\n \
       directories is computed from the root of where this command is run."
  |> Command_unix.run ~version:"0.1.0"
