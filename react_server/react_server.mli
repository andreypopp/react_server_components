(** Implementation of React Server Side Rendering (SSR) and React Server
    Components (RSC).
  *)

(** {1 Common definitions} *)

type json = Yojson.Safe.t
(** JSON data type used to communicate between Server Components and Client
    Components. *)

(** {1 React API} *)

(** {2 Server Components} *)

(** A server side implementation of {!module-type: React_api.REACT} module type.

    Use this API to develop React Server Components.
  *)
module React : sig
  include React_api.REACT with type 'a promise = 'a Lwt.t
  (** @inline *)

  val textf : ('a, unit, string, element) format4 -> 'a
  (** Like [text] but allows to use printf formatting. *)

  val thunk : (unit -> element) -> element
  (** [thunk f props children] renders an element tree produced by [f props
      children]. *)

  val async_thunk : (unit -> element promise) -> element
  (** [async_thunk f props children] works the same as [thunk f props children]
      but is asynchronous. *)

  type client_props =
    (string * [ `Json of string | `Element of element ]) list

  val client_thunk :
    ?import_name:string -> string -> client_props -> element -> element
  (** This instructs to render a client components in browser which is
      implemented in JavaScript. *)

  module Html_props : module type of React_server_html_props

  type unsafe_html = { __html : string }

  type html_children =
    | Html_children of children
    | Html_children_raw of unsafe_html

  val unsafe_create_html_element :
    ?key:string ->
    string ->
    Html_props.props ->
    html_children option ->
    element

  val use_effect : (unit -> unit -> unit) -> 'a array -> unit
  [@@alert
    browser_only
      "React.use_effect is only available for client side components"]

  val use_effect' : (unit -> unit) -> 'a array -> unit
  [@@alert
    browser_only
      "React.use_effect' is only available for client side components"]

  val use : 'a promise -> 'a
  [@@alert
    browser_only
      "React.use is only available for client side components, use async \
       components on server instead"]

  exception Browser_only

  type any_promise = Any_promise : 'a promise -> any_promise

  exception Suspend of any_promise
end

(** {1 Rendering to RSC model} *)

val render_to_model :
  React.element -> (string -> unit Lwt.t) -> unit Lwt.t

(** {1 Rendering to HTML} *)

(** Represents a completed or in progress HTML rendering.

    Use {!module-Html.to_string} to serialize {!module-Html.t} values to string. *)
type html_rendering =
  | Html_rendering_done of { html : Html.t }
  | Html_rendering_async of {
      html_shell : Html.t;
      html_iter : (Html.t -> unit Lwt.t) -> unit Lwt.t;
    }

val render_to_html : React.element -> html_rendering Lwt.t
(** [render_to_html elem] renders React element [elem] to HTML. *)

module Html : module type of Html
