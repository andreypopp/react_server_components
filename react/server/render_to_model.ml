open! Import
open Lwt.Infix

type model = json

let text text = `String text
let null = `Null
let list xs = `List xs

let node ~tag_name ~key ~props children : model =
  let key = match key with None -> `Null | Some key -> `String key in
  let props =
    match children with
    | None -> props
    | Some children -> ("children", children) :: props
  in
  `List [ `String "$"; `String tag_name; key; `Assoc props ]

let suspense ~key ~fallback children =
  node ~tag_name:"$Sreact.suspense" ~key
    ~props:[ "fallback", fallback ]
    (Some children)

let lazy_value idx = `String (sprintf "$L%x" idx)
let promise_value idx = `String (sprintf "$@%x" idx)

let suspense_placeholder ~key ~fallback idx =
  suspense ~key ~fallback (lazy_value idx)

let ref ~import_module ~import_name =
  `List
    [
      `String import_module (* id *);
      `List [] (* chunks *);
      `String import_name (* name *);
    ]

type chunk = C_value of model | C_ref of model

let chunk_to_string = function
  | idx, C_ref ref ->
      let buf = Buffer.create 256 in
      Buffer.add_string buf (sprintf "%x:I" idx);
      Yojson.Basic.write_json buf ref;
      Buffer.add_char buf '\n';
      Buffer.contents buf
  | idx, C_value model ->
      let buf = Buffer.create (4 * 1024) in
      Buffer.add_string buf (sprintf "%x:" idx);
      Yojson.Basic.write_json buf model;
      Buffer.add_char buf '\n';
      Buffer.contents buf

type ctx = {
  mutable idx : int;
  mutable pending : int;
  push : string option -> unit;
  remote_ctx : Remote.Context.t;
}

let use_idx ctx =
  ctx.idx <- ctx.idx + 1;
  ctx.idx

let push ctx chunk = ctx.push (Some (chunk_to_string chunk))
let close ctx = ctx.push None

let rec to_model ctx idx el =
  let rec to_model' : React_model.element -> model = function
    | El_null -> `Null
    | El_text s -> `String s
    | El_frag els -> `List (Array.map els ~f:to_model' |> Array.to_list)
    | El_context _ ->
        failwith "react context is not supported in server environment"
    | El_html { tag_name; key; props; children } ->
        let props = (props :> (string * json) list) in
        let children, props =
          match children with
          | None -> None, props
          | Some (Html_children children) ->
              Some (children |> to_model'), props
          | Some (Html_children_raw { __html }) ->
              ( None,
                ( "dangerouslySetInnerHTML",
                  `Assoc [ "__html", `String __html ] )
                :: props )
        in
        node ~tag_name ~key ~props children
    | El_suspense { children; fallback; key } ->
        let fallback = to_model' fallback in
        suspense ~key ~fallback (to_model' children)
    | El_thunk f ->
        let tree, _reqs = Remote.Context.with_ctx ctx.remote_ctx f in
        to_model' tree
    | El_async_thunk f -> (
        let tree = Remote.Context.with_ctx_async ctx.remote_ctx f in
        match Lwt.state tree with
        | Lwt.Return (tree, _reqs) -> to_model' tree
        | Lwt.Fail exn -> raise exn
        | Lwt.Sleep ->
            let idx = use_idx ctx in
            ctx.pending <- ctx.pending + 1;
            Lwt.async (fun () ->
                tree >|= fun (tree, _reqs) ->
                ctx.pending <- ctx.pending - 1;
                to_model ctx idx tree);
            lazy_value idx)
    | El_client_thunk { import_module; import_name; props; thunk = _ } ->
        let idx = use_idx ctx in
        let ref = ref ~import_module ~import_name in
        push ctx (idx, C_ref ref);
        let props =
          List.map props ~f:(function
            | name, React_model.Element element -> name, to_model' element
            | name, Promise (promise, value_to_json) -> (
                match Lwt.state promise with
                | Return value ->
                    let idx = use_idx ctx in
                    let json = value_to_json value in
                    (* NOTE: important to yield a chunk here for React.js *)
                    push ctx (idx, C_value json);
                    name, promise_value idx
                | Sleep ->
                    let idx = use_idx ctx in
                    ctx.pending <- ctx.pending + 1;
                    Lwt.async (fun () ->
                        promise >|= fun value ->
                        let json = value_to_json value in
                        ctx.pending <- ctx.pending - 1;
                        push ctx (idx, C_value json);
                        if ctx.pending = 0 then close ctx);
                    name, promise_value idx
                | Fail exn -> raise exn)
            | name, Json json -> name, json)
        in
        node ~tag_name:(sprintf "$%x" idx) ~key:None ~props None
  in
  push ctx (idx, C_value (to_model' el));
  if ctx.pending = 0 then close ctx

let render el on_chunk =
  let rendering, push = Lwt_stream.create () in
  let ctx =
    { push; pending = 0; idx = 0; remote_ctx = Remote.Context.create () }
  in
  to_model ctx ctx.idx el;
  Lwt_stream.iter_s on_chunk rendering >|= fun () ->
  match Lwt.state (Remote.Context.wait ctx.remote_ctx) with
  | Sleep ->
      (* NOTE: this can happen if a promise which was fired a component wasn't
         waited for *)
      prerr_endline "some promises are not yet finished"
  | _ -> ()
