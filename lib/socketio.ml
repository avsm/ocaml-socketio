(*
 * Copyright (c) 2012 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Printf

module Transport = struct
  type transport =
    | XHR_polling

  let to_string =
    function
    | XHR_polling -> "xhr-polling"

  type state =
    | Closed
    | Closing
    | Open
    | Opening

  type t = {
    transport: transport;
    mutable state: state;
  }
end

module Connection = struct
  type sid = string
    
  let make_sid =
    (* TODO XXX This might be need to be a tad more secure *)
    let ctr = ref 0 in
    fun () ->
      incr ctr;
      Printf.sprintf "sid%d" !ctr

  type state = 
    | Connected
    | Connecting
    | Disconnecting
    | Disconnected

  let state_to_string =
    function
    | Connected -> "connected"
    | Connecting -> "connecting"
    | Disconnecting -> "disconnecting"
    | Disconnected -> "disconnected"

  (* An individual connection *)
  type conn = {
    sid: string;
    state: state;
    heartbeat: int;
    timeout: int;
    tx: string Lwt_stream.t; 
    tx_push: string option -> unit;
    rx: string Lwt_stream.t;
    rx_push: string option -> unit;
  }
   
  type t = {
    active: (sid, conn) Hashtbl.t;
  }

  type s = unit Lwt.t * t

  let make () : s =
    let state = { active = Hashtbl.create 1 } in
    let t =
      while_lwt true do
        Lwt_unix.sleep 5.0 >>
        return (printf "ctx_t\n%!")
      done
    in
    t, state

  let add ~conns ?(heartbeat=15) ?(timeout=10) () =
    let sid = make_sid () in
    let tx, tx_push = Lwt_stream.create () in
    let rx, rx_push = Lwt_stream.create () in
    let state = Connecting in
    let conn = { sid; state; heartbeat; timeout; rx; rx_push; tx; tx_push } in
    Hashtbl.add conns.active sid conn;
    conn
 
  let get ~conns ~sid =
    try Some (Hashtbl.find conns.active sid)
    with Not_found -> None

  let string_of_conn conn =
    sprintf "%s:%d:%d:%s" conn.sid conn.heartbeat conn.timeout
      (String.concat "," (List.map Transport.to_string [Transport.XHR_polling]))
 
end

let make_server () =
  Connection.make ()

module Packet = struct

  type endpoint = string option
  type id = int option

  type message =
    |Disconnect of endpoint
    |Connect of endpoint
    |Heartbeat 
    |Message of endpoint * id * string
    |JSON of endpoint * id * Yojson.Safe.json
    |Event of endpoint * id * Yojson.Safe.json (* TODO must have name, args *)
    |Ack of id 
    |Error of endpoint * string * string option (* reason, advice *)
    |Noop 

  let endpoint_to_string =
    function
    |None -> ""
    |Some ep -> ep

  let id_to_string =
    function
    |None -> ""
    |Some id -> string_of_int id

  let to_string =
    function
    |Disconnect e -> sprintf "0::%s" (endpoint_to_string e)
    |Connect e -> sprintf "1::%s" (endpoint_to_string e)
    |Heartbeat -> "2"
    |Message (e, id, data) ->
       sprintf "3:%s:%s:%s" (id_to_string id) (endpoint_to_string e) data
    |JSON (e, id, data) ->
       sprintf "4:%s:%s:%s" (id_to_string id)
         (endpoint_to_string e) (Yojson.Safe.to_string data)
    |Event (e, id, data) ->
       sprintf "5:%s:%s:%s" (id_to_string id)
         (endpoint_to_string e) (Yojson.Safe.to_string data)
    |Ack id -> sprintf "6:::%s" (id_to_string id)
    |Error (None, reason, None) -> sprintf "7:::%s" reason
    |Error (None, reason, Some advice) -> sprintf "6:::%s+%s" reason advice
    |Error (Some e, reason, None) -> sprintf "7::%s:%s" e reason
    |Error (Some e, reason, Some advice) -> sprintf "7::%s:%s+%s" e reason advice
    |Noop -> "8"

  let endpoint_of_string =
    function
    |"" -> None
    |x -> Some x

  let id_of_string x =
    try Some (int_of_string x)
    with _ -> None
  
  let of_string s =
    try begin
    let bits = Re_str.(bounded_split (regexp_string ":") s 4) in
    match bits with
    |"0"::_::ep::_ -> Some (Disconnect (endpoint_of_string ep))
    |"0"::_ -> Some (Disconnect None)
    |"1"::_::ep::_ -> Some (Connect (endpoint_of_string ep))
    |"1"::_ -> Some (Connect None)
    |"2"::_ -> Some Heartbeat
    |["3";id;ep;data] -> 
      Some (Message (endpoint_of_string ep, id_of_string id, data))
    |["4";id;ep;data] ->
      Some (JSON (endpoint_of_string ep, id_of_string id, Yojson.Safe.from_string data))
    |["5";id;ep;data] ->
      Some (Event (endpoint_of_string ep, id_of_string id, Yojson.Safe.from_string data))
    |["6";"";"";id] ->
      Some (Ack (id_of_string id))
    |["7";ep;"";reason] ->
      Some (Error (endpoint_of_string ep, reason, None)) (* TODO parse advice *)
    |_ -> None
    end with exn -> prerr_endline (Printexc.to_string exn); None
end

let create ~conns req =
  let conn = Connection.add ~conns () in
  let body = Connection.string_of_conn conn in
  Cohttpd.Server.respond ~body ()

let connection ~conns ~conn req = 
  lwt body = Cohttp.Message.string_of_body (Cohttp.Request.body req) in
  let m = Packet.of_string body in
  match conn.Connection.state with
  | Connection.Connecting ->
     let body = Packet.(to_string (Connect None)) in
     Cohttpd.Server.respond ~body ()
  | _ ->
    Lwt_unix.sleep conn.Connection.heartbeat >>
    let body = Packet.(to_string (Message (None, None, "wassu"))) in
    let uni = String.create 3 in
    uni.[0] <- Char.chr 0xef;
    uni.[1] <- Char.chr 0xbf;
    uni.[2] <- Char.chr 0xbd;
    let body = Printf.sprintf "%s%d%s%s" uni (String.length body) uni body in
    Cohttpd.Server.respond ~body ()

let callback (server_t,conns) id req =
  let open Cohttp.Request in
  Printf.printf "%s %s\n%!" (Cohttp.Common.string_of_method (meth req)) (Cohttp.Types.(path req));
(*  List.iter (fun (k,v) -> Printf.printf "  %s: %s\n%!" k v) (headers req); *)
  match meth req, (Re_str.(split (regexp_string "/") (path req))) with
  |`GET, ([]|[""]) ->
    Cohttpd.Server.respond_file ~fname:"lib_test/index.html"
      ~mime_type:"application/html" ()
  |`GET, ["socket.io.js"] ->
    Cohttpd.Server.respond_file ~fname:"lib_test/socket.io.js"
      ~mime_type:"application/javascript" ()
  |`GET, "socket.io"::"1"::[] -> create ~conns req
  |(`GET|`POST), "socket.io"::"1"::"xhr-polling"::sid::_ -> begin
     match Connection.get ~conns ~sid with
     |None -> Cohttpd.Server.respond_error ()
     |Some conn -> connection ~conns ~conn req
  end
  |_,_ -> Cohttpd.Server.respond_error ()

