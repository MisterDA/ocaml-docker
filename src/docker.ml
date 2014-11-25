module Json = Yojson.Safe

exception Invalid_argument of string
exception Server_error of string

let default_addr =
  ref(Unix.ADDR_UNIX "/var/run/docker.sock")

let set_default_addr addr = default_addr := addr

let connect addr =
  let fd = Unix.socket (Unix.domain_of_sockaddr addr) Unix.SOCK_STREAM 0 in
  try Unix.connect fd addr;
      fd
  with Unix.Unix_error (Unix.ENOENT, _, _) ->
    raise(Server_error "Cannot connect: socket does not exist")

(* Return a number < 0 of not found.
   It is ASSUMED that [pos] and [len] delimit a valid substring. *)
let rec index_CRLF (s: Bytes.t) ~pos ~len =
  if len <= 1 then -1 (* Cannot match "\r\n" *)
  else if Bytes.get s pos = '\r' && Bytes.get s (pos+1) = '\n' then pos
  else index_CRLF s ~pos:(pos + 1) ~len:(len - 1)

(* Return the list of header lines and keep in [buf] the additional
   bytes that may have been read. *)
let read_headers fn_name buf fd =
  let headers = ref [] in
  let b = Bytes.create 4096 in
  let continue = ref true in
  while !continue do
    let r = Unix.read fd b 0 4096 in
    if r > 0 then
      (* Split on \r\n *)
      let i = index_CRLF b ~pos:0 ~len:r in
      if i < 0 then
        Buffer.add_subbytes buf b 0 r
      else if i = 0 && Buffer.length buf = 0 then (
        (* End of headers (all previously captured). *)
        Buffer.add_subbytes buf b 0 r;
        continue := false
      )
      else (
        Buffer.add_subbytes buf b 0 i;
        headers := Buffer.contents buf :: !headers;
        Buffer.clear buf;
        (* Capture all possible additional headers in [b]. *)
        let pos = ref (i+2) and len = ref (r - i - 2) in
        let i = ref 0 in
        while (i := index_CRLF b ~pos:!pos ~len:!len;  !i > !pos) do
          let h_len = !i - !pos in
          headers := Bytes.sub_string b !pos h_len  :: !headers;
          pos := !i + 2;
          len := !len - h_len - 2;
        done;
        if !i < 0 then Buffer.add_subbytes buf b !pos !len
        else ( (* !i = !pos *)
          Buffer.add_subbytes buf b (!pos + 2) (!len - 2);
          continue := false;
        )
      )
    else continue := false
  done;
  match List.rev !headers with
  | [] -> raise (Server_error(fn_name ^ ": No status sent"))
  | status :: tl ->
     let code =
       try let i1 = String.index status ' ' in
           let i2 = String.index_from status (i1 + 1) ' ' in
           int_of_string(String.sub status (i1 + 1) (i2 - i1 - 1))
       with _ ->
         raise (Server_error(fn_name ^ ": Incorrect status line: " ^ status)) in
     if code >= 500 then raise(Server_error fn_name);
     (* Let the client functions deal with 4xx to have more precise
        messages. *)
     code, tl

let read_rest buf fd =
  let b = Bytes.create 4096 in
  let continue = ref true in
  while !continue do
    let r = Unix.read fd b 0 4096 in
    if r > 0 then Buffer.add_subbytes buf b 0 r
    else continue := false
  done;
  Buffer.contents buf

let read_response fn_name fd =
  let buf = Buffer.create 4096 in
  let status, h = read_headers fn_name buf fd in
  if status = 204 (* No Content *) || status = 205 then status, h, ""
  else
    let body = read_rest buf fd in
    status, h, body

let get addr url query =
  let fd = connect addr in
  let buf = Buffer.create 128 in
  Buffer.add_string buf "GET ";
  Buffer.add_string buf url;
  Buffer.add_string buf "?";
  Buffer.add_string buf (Uri.encoded_of_query query);
  Buffer.add_string buf " HTTP/1.1\r\n\r\n";
  ignore(Unix.write fd (Buffer.to_bytes buf) 0 (Buffer.length buf));
  fd

let response_of_get fn_name addr url query =
  let fd = get addr url query in
  Unix.shutdown fd Unix.SHUTDOWN_SEND;
  let r = read_response fn_name fd in
  Unix.close fd;
  r

let post addr url query json =
  let fd = connect addr in
  let buf = Buffer.create 4096 in
  Buffer.add_string buf "POST ";
  Buffer.add_string buf url;
  (match query with
   | [] -> ()
   | _ -> Buffer.add_string buf "?";
         Buffer.add_string buf (Uri.encoded_of_query query));
  Buffer.add_string buf " HTTP/1.1\r\n\
                         Content-Type: application/json\r\n\
                         Content-Length: ";
  (match json with
   | None ->
      Buffer.add_string buf "0\r\n\r\n";
   | Some json ->
      let json = Json.to_string json in
      Buffer.add_string buf (string_of_int (String.length json));
      Buffer.add_string buf "\r\n\r\n";
      Buffer.add_string buf json);
  ignore(Unix.write fd (Buffer.to_bytes buf) 0 (Buffer.length buf));
  fd

let response_of_post fn_name addr url query json =
  let fd = post addr url query json in
  Unix.shutdown fd Unix.SHUTDOWN_SEND;
  let r = read_response fn_name fd in
  Unix.close fd;
  r

let delete fn_name addr url query =
  let fd = connect addr in
  let buf = Buffer.create 128 in
  Buffer.add_string buf "DELETE ";
  Buffer.add_string buf url;
  Buffer.add_string buf "?";
  Buffer.add_string buf (Uri.encoded_of_query query);
  Buffer.add_string buf " HTTP/1.1\r\n\r\n";
  ignore(Unix.write fd (Buffer.to_bytes buf) 0 (Buffer.length buf));
  fd

let status_of_delete fn_name addr url query =
  let fd = delete fn_name addr url query in
  Unix.shutdown fd Unix.SHUTDOWN_SEND;
  let status, _, _ = read_response fn_name fd in
  Unix.close fd;
  status

(* Generic JSON utilities *)

let string_of_json fn_name = function
  | `String s -> s
  | j -> raise(Server_error(fn_name ^ ": Not a JSON string:" ^ Json.to_string j))

let json_of_strings = function
  | [] -> `Null
  | l -> `List(List.map (fun s -> `String s) l)

module Container = struct
  type id = string

  type port = { priv: int;  pub: int;  typ: string }

  let port_of_json_assoc l =
    (* No port is a negative integer. *)
    let priv = ref (-1) and pub = ref (-1) and typ = ref "" in
    let update = function
      | ("PrivatePort", `Int i) -> priv := i
      | ("PublicPort", `Int i) -> pub := i
      | ("Type", `String s) -> typ := s
      | _ -> () in
    List.iter update l;
    if !priv < 0 || !pub < 0 || !typ = "" then
      raise(Server_error("Docker.Container.list: Incorrect port elements"));
    { priv = !priv;  pub = !pub;  typ = !typ }

  let port_of_json = function
    | `Assoc port -> port_of_json_assoc port
    | _ -> raise(Server_error("Docker.Container.list: Incorrect port"));

  type t = {
      id: id;
      names: string list;
      image: string;
      command: string;
      created: float;
      status: string;
      ports: port list;
      size_rw: int;
      size_root_fs: int;
    }

  let container_of_json (c: Json.json) =
    match c with
    | `Assoc l ->
       let id = ref "" and names = ref [] and image = ref "" in
       let command = ref "" and created = ref 0. and status = ref "" in
       let ports = ref [] and size_rw = ref 0 and size_root_fs = ref 0 in
       let update = function
         | ("Id", `String s) -> id := s
         | ("Names", `List l) ->
            names := List.map (string_of_json "Docker.Container.list") l
         | ("Image", `String s) -> image := s
         | ("Command", `String s) -> command := s
         | ("Created", `Int i) -> created := float i (* same as Unix.time *)
         | ("Status", `String s) -> status := s
         | ("Ports", `List p) -> ports := List.map port_of_json p
         | ("SizeRw", `Int i) -> size_rw := i
         | ("SizeRootFs", `Int i) -> size_root_fs := i
         | _ -> () in
       List.iter update l;
       { id = !id;  names = !names;  image = !image;  command = !command;
         created = !created;  status = !status;  ports = !ports;
         size_rw = !size_rw;  size_root_fs = !size_root_fs }
    | _ -> raise(Server_error("Docker.Container.list: \
                              Invalid container: " ^ Json.to_string c))

  let list ?(addr= !default_addr) ?(all=false) ?limit ?since ?before
           ?(size=false) () =
    let q = if all then ["all", ["1"]] else [] in
    let q = match limit with
      | Some l -> ("limit", [string_of_int l]) :: q
      | None -> q in
    let q = match since with
      | Some id -> ("since", [id]) :: q
      | None -> q in
    let q = match before with
      | Some id -> ("before", [id]) :: q
      | None -> q in
    let q = if size then ("size", ["1"]) :: q else q in
    let status, _, body = response_of_get "Docker.Container.list" addr
                                          "/containers/json" q in
    if status >= 400 then
      raise(Invalid_argument("Docker.Container.list: Bad parameter"));
    match Json.from_string body with
    | `List l -> List.map container_of_json l
    | _ ->
       raise(Server_error("Docker.Container.list: response not a JSON list: "
                          ^ body))


  let json_of_bind (host_path, container_path, access) =
    (* FIXME: check the paths to not contain ":" *)
    match access with
    | `RO -> `String(host_path ^ ":" ^ container_path ^ ":ro")
    | `RW -> `String(host_path ^ ":" ^ container_path)

  let json_of_binds = function
    | [] -> (`Null: Json.json)
    | binds -> `List(List.map json_of_bind binds)

  let create ?(addr= !default_addr) ?(hostname="") ?(domainname="")
             ?(user="") ?(memory=0) ?(memory_swap=0)
             ?(attach_stdin=false) ?(attach_stdout=true) ?(attach_stderr=true)
             ?(tty=false) ?(open_stdin=false) ?(stdin_once=false)
             ?(env=[]) ?(workingdir="") ?(networking=false)
             ?(binds=[])
             ~image cmd =
    let json : Json.json =
      `Assoc [
         ("Hostname", `String hostname);
         ("Domainname", `String domainname);
         ("User", `String user);
         ("Memory", `Int memory);
         ("MemorySwap", `Int memory_swap);
         ("CpuShares", `Int 0); (* TODO *)
         ("Cpuset", `String "");  (* TODO *)
         ("AttachStdin", `Bool attach_stdin);
         ("AttachStdout", `Bool attach_stdout);
         ("AttachStderr", `Bool attach_stderr);
         ("Tty", `Bool tty);
         ("OpenStdin", `Bool open_stdin);
         ("StdinOnce", `Bool stdin_once);
         ("Env", json_of_strings env);
         ("Cmd", `List [`String cmd]);
         ("Entrypoint", `Null); (* TODO *)
         ("Image", `String image);
         ("Volumes", `Null);     (* TODO *)
         ("WorkingDir", `String workingdir);
         ("NetworkDisabled", `Bool(not networking));
         ("ExposedPorts", `Null); (* TODO *)
         ("SecurityOpts", `Null); (* TODO *)
         ("HostConfig",
          `Assoc [
             ("Binds", json_of_binds binds);
             ("Links", `Null);              (* TODO *)
             ("LxcConf", `List []);           (* TODO *)
             ("PortBindings", `Assoc []);      (* TODO *)
             ("PublishAllPorts", `Bool false); (* TODO *)
             ("Privileged", `Bool false);      (* TODO *)
             ("Dns", `Null); (* TODO *)
             ("DnsSearch", `Null);  (* TODO *)
             ("VolumesFrom", `List []);          (* TODO *)
             ("CapAdd", `Null);               (* TODO *)
             ("CapDrop", `Null);              (* TODO *)
             ("RestartPolicy",
              `Assoc [("Name", `String "");
                      ("MaximumRetryCount", `Int 0)]);  (* TODO *)
             ("NetworkMode", `String "bridge");  (* TODO *)
             ("Devices", `List []);              (* TODO *)
           ]);
       ] in
    let status, _, body =
      response_of_post "Docker.Container.create" addr
                       "/containers/create" [] (Some json) in
    if status >= 406 then
      raise(Invalid_argument("Docker.Container.create: \
                              Impossible to attach (container not running)"))
    else if status >= 400 then
      raise(Invalid_argument("Docker.Container.create: No such container"));
    (* Extract ID *)
    match Json.from_string body with
    | `Assoc l ->
       (try string_of_json "Docker.Containers.create" (List.assoc "Id" l)
        with Not_found ->
          raise(Server_error("Docker.Containers.create: No ID returned")))
    | _ ->
       raise(Server_error("Docker.Container.create: Response must be an \
                           association list: " ^ body ))


  let start ?(addr= !default_addr) ?(binds=[])
            id =
    (* FIXME: may want to check that [id] does not contain special chars *)
    let json : Json.json =
      `Assoc [
         ("Binds", json_of_binds binds);
         ("Links", `Null);              (* TODO *)
         ("LxcConf", `List []);         (* TODO *)
         ("PortBindings", `Assoc []);   (* TODO *)
         ("PublishAllPorts", `Bool false); (* TODO *)
         ("Privileged", `Bool false);      (* TODO *)
         ("Dns", `Null); (* TODO *)
         ("DnsSearch", `Null);  (* TODO *)
         ("VolumesFrom", `List []);          (* TODO *)
         ("CapAdd", `Null);               (* TODO *)
         ("CapDrop", `Null);              (* TODO *)
         ("RestartPolicy",
          `Assoc [("Name", `String "");
                  ("MaximumRetryCount", `Int 0)]);  (* TODO *)
         ("NetworkMode", `String "bridge");  (* TODO *)
         ("Devices", `List []);              (* TODO *)
       ] in
    let path = "/containers/" ^ id ^ "/start" in
    let status, h, body = response_of_post "Docker.Container.start" addr
                                           path [] (Some json) in
    if status >= 400 then
      raise(Invalid_argument("Docker.Container.start: No such container"))
    (* FIXME: do we want to react on 304 – container already started ? *)


  let stop ?(addr= !default_addr) ?wait id =
    let q = match wait with None -> []
                          | Some t -> ["t", [string_of_int t]] in
    let path = "/containers/" ^ id ^ "/stop" in
    let status, _, _ = response_of_post "Docker.Container.stop" addr
                                        path q None in
    if status >= 400 then
      raise(Invalid_argument("Docker.Container.stop: No such container"))
    (* FIXME: do we want to react on 304 – container already stopped ? *)

  let rm ?(addr= !default_addr) ?(volumes=false) ?(force=false) id =
    let q = ["v", [string_of_bool volumes];
             "force", [string_of_bool force]] in
    let path = "/containers/" ^ id in
    let status = status_of_delete "Docker.Container.rm" addr path q in
    if status >= 404 then
      raise(Invalid_argument("Docker.Container.stop: No such container"))
    else if status >= 400 then
      raise(Invalid_argument("Docker.Container.stop: Bad parameter"))

end

module Images = struct
  type id = string
  type t = {
      id: id;
      created: float;
      size: int;
      virtual_size: int;
      tags: string list;
    }

  let image_of_json (img: Json.json) =
    match img with
    | `Assoc l ->
       let id = ref "" and created = ref nan and size = ref 0 in
       let virtual_size = ref 0 and tags = ref [] in
       let update = function
         | ("RepoTags", `List l) ->
            tags := List.map (string_of_json "Docker.Images.list") l
         | ("Id", `String s) -> id := s
         | ("Created", `Int i) -> created := float i
         | ("Size", `Int i) -> size := i
         | ("VirtualSize", `Int i) -> virtual_size := i
         | _ -> () in
       List.iter update l;
       { id = !id;  created = !created;  size = !size;
         virtual_size = !virtual_size;  tags = !tags }
    | _ -> raise(Server_error("Docker.Images.list: Invalid image: "
                             ^ Json.to_string img))

  let list ?(addr= !default_addr) ?(all=false) () =
    let q = ["all", [string_of_bool all]] in
    let _, _, body = response_of_get "Docker.Images.list" addr
                                     "/images/json" q in
    match Json.from_string body with
    | `List l -> List.map image_of_json l
    | _ ->
       raise(Server_error("Docker.Images.list: Response must be a JSON list: "
                          ^ body))


end

;;
