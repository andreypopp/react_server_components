open! Import

type json = Yojson.Safe.t

module React = React
module React_browser = React_browser

let html_prelude ~scripts ~links =
  let open Html in
  let make_link href =
    node "link" [ "href", s href; "rel", s "stylesheet" ] None
  in
  let make_script src = node "script" [ "src", s src ] (Some []) in
  splice ~sep:"\n"
    [
      List.map links ~f:make_link |> Html.splice ~sep:"\n";
      List.map scripts ~f:make_script |> Html.splice ~sep:"\n";
    ]

let rsc_content_type = "application/react.component"

let render_to_html ?(scripts = []) ?(links = []) =
  let html_prelude = html_prelude ~links ~scripts |> Html.to_string in
  fun f : Dream.handler ->
    fun req ->
     match Dream.header req "accept" with
     | Some accept when String.equal accept rsc_content_type ->
         Dream.stream (fun stream ->
             Render_to_model.render (f req) (fun data ->
                 Dream.write stream data >>= fun () -> Dream.flush stream))
     | _ ->
         Dream.stream (fun stream ->
             Dream.write stream html_prelude >>= fun () ->
             Render_to_html.render (f req) (fun data ->
                 Dream.write stream data >>= fun () -> Dream.flush stream))

let render ?(scripts = []) ?(links = []) =
  let html_prelude = html_prelude ~links ~scripts |> Html.to_string in
  fun f : Dream.handler ->
    fun req ->
     match Dream.header req "accept" with
     | Some accept when String.equal accept rsc_content_type ->
         Dream.stream (fun stream ->
             Render_to_model.render (f req) (fun data ->
                 Dream.write stream data >>= fun () -> Dream.flush stream))
     | _ -> Dream.html html_prelude
