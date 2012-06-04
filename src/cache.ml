open GapiUtils.Infix
open GapiLens.Infix

(* Helpers *)
let escape_sql sql =
  ExtString.String.replace_chars
    (function '\'' -> "''" | c -> String.make 1 c) sql

let fail rc =
  failwith ("Sqlite3 error: " ^ (Sqlite3.Rc.to_string rc))

let expect exptected rc =
  if rc <> exptected then fail rc

let fail_if_not_ok = expect Sqlite3.Rc.OK

let get_result rc result =
  fail_if_not_ok rc;
  !result

let wrap_exec_not_null_no_headers
      db ?(callback = (fun _ -> Some ())) sql =
  let result = ref None in
  let cb row = result := callback row in
  let rc = Sqlite3.exec_not_null_no_headers db ~cb sql in
    get_result rc result

let wrap_exec
      db ?(callback = (fun _ _ -> Some ())) sql =
  let result = ref None in
  let cb row headers = result := callback row headers in
  let rc = Sqlite3.exec db ~cb sql in
    get_result rc result

let reset_stmt stmt =
  Sqlite3.reset stmt |> fail_if_not_ok

let finalize_stmt stmt =
  Sqlite3.finalize stmt |> fail_if_not_ok

let final_step stmt =
  Sqlite3.step stmt |> expect Sqlite3.Rc.DONE
(* END Helpers *)

(* Query helpers *)
let bind to_data stmt name value =
  Option.may
    (fun v ->
       Sqlite3.bind stmt
         (Sqlite3.bind_parameter_index stmt name)
         (to_data v)
       |> fail_if_not_ok)
    value

let bind_text = bind (fun v -> Sqlite3.Data.TEXT v)
let bind_int = bind (fun v -> Sqlite3.Data.INT v)
let bind_float = bind (fun v -> Sqlite3.Data.FLOAT v)

let data_to_int64 = function
    Sqlite3.Data.NULL -> None
  | Sqlite3.Data.INT v -> Some v
  | _ -> failwith "data_to_int64: data does not contain an INT value"

let data_to_string = function
    Sqlite3.Data.NULL -> None
  | Sqlite3.Data.TEXT v -> Some v
  | _ -> failwith "data_to_string: data does not contain a TEXT value"

let data_to_float = function
    Sqlite3.Data.NULL -> None
  | Sqlite3.Data.FLOAT v -> Some v
  | _ -> failwith "data_to_float: data does not contain a FLOAT value"

let get_next_row stmt row_to_data =
  let rc = Sqlite3.step stmt in
    match rc with
        Sqlite3.Rc.ROW ->
          Some (Sqlite3.row_data stmt |> row_to_data)
      | Sqlite3.Rc.DONE -> None
      | _ -> fail rc

let select_first_row stmt bind_parameters row_to_data =
  bind_parameters stmt;
  get_next_row stmt row_to_data

let select_all_rows stmt bind_parameters row_to_data =
  bind_parameters stmt;
  let rec loop rows =
    let row = get_next_row stmt row_to_data in
      match row with
          None -> rows
        | Some r -> loop (r :: rows)
  in
    loop []
(* END Query helpers *)

(* Prepare SQL *)
let prepare_begin_tran_stmt db =
  Sqlite3.prepare db "BEGIN TRANSACTION;"

let prepare_commit_tran_stmt db =
  Sqlite3.prepare db "COMMIT TRANSACTION;"

let prepare_rollback_tran_stmt db =
  Sqlite3.prepare db "ROLLBACK TRANSACTION;"

module ResourceStmts =
struct
  let prepare_insert_stmt db =
    let sql =
      "INSERT INTO resource ( \
         resource_id, \
         kind, \
         md5_checksum, \
         size, \
         last_viewed, \
         last_modified, \
         parent_path, \
         path, \
         state, \
         changestamp, \
         last_update \
       ) \
       VALUES ( \
         :resource_id, \
         :kind, \
         :md5_checksum, \
         :size, \
         :last_viewed, \
         :last_modified, \
         :parent_path, \
         :path, \
         :state, \
         :changestamp, \
         :last_update \
       );"
    in
      Sqlite3.prepare db sql

  let prepare_update_stmt db =
    let sql =
      "UPDATE resource \
        SET \
          resource_id = :resource_id, \
          kind = :kind, \
          md5_checksum = :md5_checksum, \
          size = :size, \
          last_viewed = :last_viewed, \
          last_modified = :last_modified, \
          parent_path = :parent_path, \
          path = :path, \
          state = :state, \
          changestamp = :changestamp, \
          last_update = :last_update \
        WHERE id = :id;"
    in
      Sqlite3.prepare db sql

  let prepare_delete_stmt db =
    let sql =
      "DELETE \
       FROM resource \
       WHERE id = :id;"
    in
      Sqlite3.prepare db sql

  let prepare_delete_with_parent_path_stmt db =
    let sql =
      "DELETE \
       FROM resource \
       WHERE parent_path = :parent_path;"
    in
      Sqlite3.prepare db sql

  let prepare_select_with_path_stmt db =
    let sql =
      "SELECT \
         id, \
         resource_id, \
         kind, \
         md5_checksum, \
         size, \
         last_viewed, \
         last_modified, \
         parent_path, \
         path, \
         state, \
         changestamp, \
         last_update \
       FROM resource \
       WHERE path = :path;"
    in
      Sqlite3.prepare db sql

  let prepare_select_with_parent_path_stmt db =
    let sql =
      "SELECT \
         id, \
         resource_id, \
         kind, \
         md5_checksum, \
         size, \
         last_viewed, \
         last_modified, \
         parent_path, \
         path, \
         state, \
         changestamp, \
         last_update \
       FROM resource \
       WHERE parent_path = :parent_path \
         AND state <> 'NotFound';"
    in
      Sqlite3.prepare db sql

end

module MetadataStmts =
struct
  let prepare_insert_stmt db =
    let sql =
      "INSERT OR REPLACE INTO metadata ( \
         id, \
         largest_changestamp, \
         remaining_changestamps, \
         quota_bytes_total, \
         quota_bytes_used, \
         last_update \
       ) \
       VALUES ( \
         1, \
         :largest_changestamp, \
         :remaining_changestamps, \
         :quota_bytes_total, \
         :quota_bytes_used, \
         :last_update \
       );"
    in
      Sqlite3.prepare db sql

  let prepare_select_stmt db =
    let sql =
      "SELECT \
         largest_changestamp, \
         remaining_changestamps, \
         quota_bytes_total, \
         quota_bytes_used, \
         last_update \
       FROM metadata \
       WHERE id = 1;"
    in
      Sqlite3.prepare db sql

end
(* END Prepare SQL *)

(* Open/close db *)
type t = {
  cache_dir : string;
  db_path : string;
  busy_timeout : int;
}

let create_cache app_dir config =
  let cache_dir = app_dir.AppDir.cache_dir in
  let db_path = Filename.concat cache_dir "cache.db" in
  let busy_timeout = config.Config.sqlite3_busy_timeout in
    { cache_dir;
      db_path;
      busy_timeout;
    }

let open_db cache =
  let db = Sqlite3.db_open cache.db_path in
    Sqlite3.busy_timeout db cache.busy_timeout;
    db

let close_db db =
  try
    (* TODO: handle busy db (close_db returns false) *)
    Sqlite3.db_close db
  with _ -> false

let with_db cache f =
  let db = open_db cache in
    try
      let result = f db in
        close_db db |> ignore;
        result
    with e ->
      close_db db |> ignore;
      raise e
(* END Open/close db *)

module Resource =
struct
  module State =
  struct
    type t =
        InSync
      | ToDownload
      | ToDelete
      | Conflict
      | NotFound

    let to_string = function
        InSync -> "InSync"
      | ToDownload -> "ToDownload"
      | ToDelete -> "ToDelete"
      | Conflict -> "Conflict"
      | NotFound -> "NotFound"

    let of_string = function
        "InSync" -> InSync
      | "ToDownload" -> ToDownload
      | "ToDelete" -> ToDelete
      | "Conflict" -> Conflict
      | "NotFound" -> NotFound
      | s -> failwith ("Resource state unexpected: " ^ s)

  end

  type t = {
    (* rowid *)
    id : int64;
    (* remote data *)
    resource_id : string option;
    kind : string option;
    md5_checksum : string option;
    size : int64 option;
    last_viewed : float option;
    last_modified : float option;
    (* local data *)
    parent_path : string;
    path : string;
    state : State.t;
    changestamp : int64;
    last_update : float;
  }

  let id = {
    GapiLens.get = (fun x -> x.id);
    GapiLens.set = (fun v x -> { x with id = v })
  }
  let resource_id = {
    GapiLens.get = (fun x -> x.resource_id);
    GapiLens.set = (fun v x -> { x with resource_id = v })
  }
  let kind = {
    GapiLens.get = (fun x -> x.kind);
    GapiLens.set = (fun v x -> { x with kind = v })
  }
	let md5_checksum = {
		GapiLens.get = (fun x -> x.md5_checksum);
		GapiLens.set = (fun v x -> { x with md5_checksum = v })
	}
	let size = {
		GapiLens.get = (fun x -> x.size);
		GapiLens.set = (fun v x -> { x with size = v })
	}
	let last_viewed = {
		GapiLens.get = (fun x -> x.last_viewed);
		GapiLens.set = (fun v x -> { x with last_viewed = v })
	}
	let last_modified = {
		GapiLens.get = (fun x -> x.last_modified);
		GapiLens.set = (fun v x -> { x with last_modified = v })
	}
	let parent_path = {
		GapiLens.get = (fun x -> x.parent_path);
		GapiLens.set = (fun v x -> { x with parent_path = v })
	}
  let path = {
    GapiLens.get = (fun x -> x.path);
    GapiLens.set = (fun v x -> { x with path = v })
  }
  let state = {
    GapiLens.get = (fun x -> x.state);
    GapiLens.set = (fun v x -> { x with state = v })
  }
  let changestamp = {
    GapiLens.get = (fun x -> x.changestamp);
    GapiLens.set = (fun v x -> { x with changestamp = v })
  }
  let last_update = {
    GapiLens.get = (fun x -> x.last_update);
    GapiLens.set = (fun v x -> { x with last_update = v })
  }

  (* Queries *)
  let bind_resource_parameters stmt resource =
    bind_text stmt ":resource_id" resource.resource_id;
    bind_text stmt ":kind" resource.kind;
    bind_text stmt ":md5_checksum" resource.md5_checksum;
    bind_int stmt ":size" resource.size;
    bind_float stmt ":last_viewed" resource.last_viewed;
    bind_float stmt ":last_modified" resource.last_modified;
    bind_text stmt ":parent_path" (Some resource.parent_path);
    bind_text stmt ":path" (Some resource.path);
    bind_text stmt ":state" (Some (State.to_string resource.state));
    bind_int stmt ":changestamp" (Some resource.changestamp);
    bind_float stmt ":last_update" (Some resource.last_update)

  let step_insert_resource db stmt resource =
    reset_stmt stmt;
    bind_resource_parameters stmt resource;
    final_step stmt;
    resource |> id ^= Sqlite3.last_insert_rowid db

  let insert_resource cache resource =
    with_db cache
      (fun db ->
         let stmt = ResourceStmts.prepare_insert_stmt db in
         let result = step_insert_resource db stmt resource in
           finalize_stmt stmt;
           result)

  let update_resource cache resource =
    with_db cache
      (fun db ->
         let stmt = ResourceStmts.prepare_update_stmt db in
           bind_resource_parameters stmt resource;
           bind_int stmt ":id" (Some resource.id);
           final_step stmt;
           finalize_stmt stmt)

  let delete_resource cache resource =
    with_db cache
      (fun db ->
         let stmt = ResourceStmts.prepare_delete_stmt db in
           bind_int stmt ":id" (Some resource.id);
           final_step stmt;
           finalize_stmt stmt)

  let delete_resources cache parent_path =
    with_db cache
      (fun db ->
         let stmt = ResourceStmts.prepare_delete_with_parent_path_stmt db in
           bind_text stmt ":parent_path" (Some parent_path);
           final_step stmt;
           finalize_stmt stmt)

  let insert_resources cache resources parent_path =
    with_db cache
      (fun db ->
         let begin_tran_stmt = prepare_begin_tran_stmt db in
         let commit_tran_stmt = prepare_commit_tran_stmt db in
         let stmt = ResourceStmts.prepare_insert_stmt db in
         final_step begin_tran_stmt;
         delete_resources cache parent_path;
         let results =
           List.map
             (step_insert_resource db stmt)
             resources in
         final_step commit_tran_stmt;
         finalize_stmt begin_tran_stmt;
         finalize_stmt commit_tran_stmt;
         finalize_stmt stmt;
         results)

  let row_to_resource row_data =
    { id = row_data.(0) |> data_to_int64 |> Option.get;
      resource_id = row_data.(1) |> data_to_string;
      kind = row_data.(2) |> data_to_string;
      md5_checksum = row_data.(3) |> data_to_string;
      size = row_data.(4) |> data_to_int64;
      last_viewed = row_data.(5) |> data_to_float;
      last_modified = row_data.(6) |> data_to_float;
      parent_path = row_data.(7) |> data_to_string |> Option.get;
      path = row_data.(8) |> data_to_string |> Option.get;
      state = row_data.(9) |> data_to_string |> Option.get |> State.of_string;
      changestamp = row_data.(10) |> data_to_int64 |> Option.get;
      last_update = row_data.(11) |> data_to_float |> Option.get;
    }

  let select_resource_with_path cache path =
    with_db cache
      (fun db ->
         let stmt = ResourceStmts.prepare_select_with_path_stmt db in
         let result =
           select_first_row stmt
             (fun stmt -> bind_text stmt ":path" (Some path))
             row_to_resource
         in
           finalize_stmt stmt;
           result)

  let select_resources_with_parent_path cache parent_path =
    with_db cache
      (fun db ->
         let stmt = ResourceStmts.prepare_select_with_parent_path_stmt db in
         let results =
           select_all_rows stmt
             (fun stmt -> bind_text stmt ":parent_path" (Some parent_path))
             row_to_resource
         in
           finalize_stmt stmt;
           results)
  (* END Queries *)

  let is_folder resource =
    match resource.kind with
        Some "folder" -> true
      | _ -> false

  let is_valid resource largest_changestamp =
    resource.changestamp >= largest_changestamp

end

module Metadata =
struct
  type t = {
    largest_changestamp : int64;
    remaining_changestamps : int64;
    quota_bytes_total : int64;
    quota_bytes_used : int64;
    last_update : float;
  }

	let largest_changestamp = {
		GapiLens.get = (fun x -> x.largest_changestamp);
		GapiLens.set = (fun v x -> { x with largest_changestamp = v })
	}
	let remaining_changestamps = {
		GapiLens.get = (fun x -> x.remaining_changestamps);
		GapiLens.set = (fun v x -> { x with remaining_changestamps = v })
	}
	let quota_bytes_total = {
		GapiLens.get = (fun x -> x.quota_bytes_total);
		GapiLens.set = (fun v x -> { x with quota_bytes_total = v })
	}
	let quota_bytes_used = {
		GapiLens.get = (fun x -> x.quota_bytes_used);
		GapiLens.set = (fun v x -> { x with quota_bytes_used = v })
	}
	let last_update = {
		GapiLens.get = (fun x -> x.last_update);
		GapiLens.set = (fun v x -> { x with last_update = v })
	}

  (* Queries *)
  let save_metadata stmt metadata =
    reset_stmt stmt;
    bind_int stmt ":largest_changestamp" (Some metadata.largest_changestamp);
    bind_int stmt ":remaining_changestamps"
      (Some metadata.remaining_changestamps);
    bind_int stmt ":quota_bytes_total" (Some metadata.quota_bytes_total);
    bind_int stmt ":quota_bytes_used" (Some metadata.quota_bytes_used);
    bind_float stmt ":last_update" (Some metadata.last_update);
    final_step stmt

  let insert_metadata cache resource =
    with_db cache
      (fun db ->
         let stmt = MetadataStmts.prepare_insert_stmt db in
           save_metadata stmt resource;
           finalize_stmt stmt)

  let row_to_metadata row_data =
    { largest_changestamp = row_data.(0) |> data_to_int64 |> Option.get;
      remaining_changestamps = row_data.(1) |> data_to_int64 |> Option.get;
      quota_bytes_total = row_data.(2) |> data_to_int64 |> Option.get;
      quota_bytes_used = row_data.(3) |> data_to_int64 |> Option.get;
      last_update = row_data.(4) |> data_to_float |> Option.get;
    }

  let select_metadata cache =
    with_db cache
      (fun db ->
         let stmt = MetadataStmts.prepare_select_stmt db in
         let result =
           select_first_row stmt (fun _ -> ()) row_to_metadata
         in
           finalize_stmt stmt;
           result)
  (* END Queries *)

  let is_valid metadata_cache_time metadata =
    let now = Unix.gettimeofday () in
      now -. metadata.last_update <= float_of_int metadata_cache_time

end

(* Resource XML entry *)
let get_xml_entry_path cache resource =
  let filename = Printf.sprintf "%Ld.xml" resource.Resource.id in
    Filename.concat cache.cache_dir filename

let save_xml_entry cache resource entry =
  let to_xml_string () =
    entry
      |> GdataDocumentsV3Model.Document.entry_to_data_model
      |> GdataUtils.data_to_xml_string
  in

  let path = get_xml_entry_path cache resource in
  let ch = open_out path in
    try
      let xml_string = to_xml_string () in
        output_string ch xml_string;
        close_out ch
    with e ->
      close_out ch;
      raise e

let load_xml_entry cache resource =
  let path = get_xml_entry_path cache resource in
  let ch = open_in path in
    try
      let entry = GdataUtils.parse_xml
                    (fun () -> input_byte ch)
                    GdataDocumentsV3Model.Document.parse_entry in
        close_in ch;
        entry
    with e ->
      close_in ch;
      raise e
(* END Resource XML entry *)

(* Resource content *)
let get_content_path cache resource =
  Filename.concat cache.cache_dir (Option.get resource.Resource.resource_id)
(* END Resource content *)

(* Setup *)
let setup_db cache =
  with_db cache
    (fun db ->
      wrap_exec_not_null_no_headers db
        "CREATE TABLE IF NOT EXISTS resource ( \
            id INTEGER PRIMARY KEY, \
            resource_id TEXT NULL, \
            kind TEXT NULL, \
            md5_checksum TEXT NULL, \
            size INTEGER NULL, \
            last_viewed REAL NULL, \
            last_modified REAL NULL, \
            parent_path TEXT NOT NULL, \
            path TEXT NOT NULL, \
            state TEXT NOT NULL, \
            changestamp INTEGER NULL, \
            last_update REAL NOT NULL \
         ); \
         CREATE INDEX IF NOT EXISTS path_index ON resource (path); \
         CREATE INDEX IF NOT EXISTS parent_path_index ON resource (parent_path); \
         CREATE INDEX IF NOT EXISTS resource_id_index ON resource (resource_id); \
         CREATE TABLE IF NOT EXISTS metadata ( \
            id INTEGER PRIMARY KEY, \
            largest_changestamp INTEGER NOT NULL, \
            remaining_changestamps INTEGER NOT NULL, \
            quota_bytes_total INTEGER NOT NULL, \
            quota_bytes_used INTEGER NOT NULL, \
            last_update REAL NOT NULL \
         );" |> ignore)
(* END Setup *)

