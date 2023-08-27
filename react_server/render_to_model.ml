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

let suspense ~key children =
  node ~tag_name:"$Sreact.suspense" ~key ~props:[] (Some children)

let suspense_placeholder ~key idx =
  node ~tag_name:"$Sreact.suspense" ~key ~props:[]
    (Some (`String (sprintf "$L%i" idx)))

let ref ~import_module ~import_name =
  `Assoc
    [
      "id", `String import_module;
      "name", `String import_name;
      "chunks", `List [];
      "async", `Bool false;
    ]

type chunk = C_tree of model | C_ref of model

let chunk_to_string = function
  | idx, C_ref ref ->
      let buf = Buffer.create 256 in
      Buffer.add_string buf (sprintf "%x:I" idx);
      Yojson.Safe.write_json buf ref;
      Buffer.add_char buf '\n';
      Buffer.contents buf
  | idx, C_tree model ->
      let buf = Buffer.create (4 * 1024) in
      Buffer.add_string buf (sprintf "%x:" idx);
      Yojson.Safe.write_json buf model;
      Buffer.add_char buf '\n';
      Buffer.contents buf

type ctx = {
  mutable idx : int;
  mutable pending : int;
  push : string option -> unit;
}

let use_idx ctx =
  ctx.idx <- ctx.idx + 1;
  ctx.idx

let push ctx chunk = ctx.push (Some (chunk_to_string chunk))

let rec to_model ctx idx el =
  let rec to_model' : React_model.element -> model = function
    | El_null -> `Null
    | El_text s -> `String s
    | El_html { tag_name; key; props; children } ->
        let props = (props :> (string * json) list) in
        let children, props =
          match children with
          | None -> None, props
          | Some (Html_children children) ->
              ( Some
                  (Array.to_list children |> List.map ~f:to_model' |> list),
                props )
          | Some (Html_children_raw { __html }) ->
              ( None,
                ( "dangerouslySetInnerHTML",
                  `Assoc [ "__html", `String __html ] )
                :: props )
        in
        node ~tag_name ~key ~props children
    | El_suspense { children; fallback = _; key } ->
        suspense ~key
          (Array.to_list children |> List.map ~f:to_model' |> list)
    | El_thunk f -> to_model' (f ())
    | El_async_thunk f -> (
        let tree = f () in
        match Lwt.state tree with
        | Lwt.Return tree -> to_model' tree
        | Lwt.Fail exn -> raise exn
        | Lwt.Sleep ->
            let idx = use_idx ctx in
            ctx.pending <- ctx.pending + 1;
            Lwt.async (fun () ->
                tree >|= fun tree ->
                ctx.pending <- ctx.pending - 1;
                to_model ctx idx tree);
            `String (sprintf "$L%i" idx))
    | El_client_thunk { import_module; import_name; props; thunk = _ } ->
        let idx = use_idx ctx in
        let ref = ref ~import_module ~import_name in
        push ctx (idx, C_ref ref);
        let props =
          List.map props ~f:(function
            | name, `Element element -> name, to_model' element
            | name, `Json json -> name, `String json)
        in
        node ~tag_name:(sprintf "$%i" idx) ~key:None ~props None
  in
  push ctx (idx, C_tree (to_model' el));
  if ctx.pending = 0 then ctx.push None

let render el on_chunk =
  let rendering, push = Lwt_stream.create () in
  let ctx = { push; pending = 0; idx = 0 } in
  to_model ctx ctx.idx el;
  Lwt_stream.iter_s on_chunk rendering
