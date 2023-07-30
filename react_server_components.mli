(** DSL for constructing UI elements, this module is intended to be openned. *)
module React_element : sig
  type t
  (** An abstract UI specification, see [React_element] below for how to
    construct values of such type. *)

  type children = t list
  (** Just a convenience, should be replaced by JSX syntax. *)

  val null : t
  (** An element which renders nothing. *)

  val many : children -> t
  (** An element which renders multiple elements. *)

  val text : string -> t
  (** An element which renders [text]. *)

  val textf : ('a, unit, string, t) format4 -> 'a
  (** Like [text] but allows to use printf formatting. *)

  type html_element = ?className:string -> ?href:string -> children -> t

  val html : string -> html_element
  (** Render HTML element. *)

  val div : html_element
  val span : html_element
  val li : html_element
  val ul : html_element
  val ol : html_element
  val a : html_element
  val h1 : html_element
  val h2 : html_element
  val h3 : html_element

  val thunk : (unit -> t) -> t
  (** [thunk f props children] renders an element tree produced by [f props
      children]. *)

  val async_thunk : (unit -> t Lwt.t) -> t
  (** [async_thunk f props children] works the same as [thunk f props children]
      but is asynchronous. *)

  val suspense : children -> t
  (** Renders a React Suspense boundary. *)

  type json_model =
    [ `Assoc of (string * json_model) list
    | `Bool of bool
    | `Element of t
    | `Float of float
    | `Int of int
    | `Intlit of string
    | `List of json_model list
    | `Null
    | `String of string
    | `Tuple of json_model list
    | `Variant of string * json_model option ]

  val client_thunk :
    ?import_name:string -> string -> (string * json_model) list -> t
  (** This instructs to render a client components in browser which is
      implemented in JavaScript. *)
end

val render :
  ?scripts:string list ->
  ?links:string list ->
  (Dream.request -> React_element.t) ->
  Dream.handler
(** Serve React Server Component. *)

val esbuild : ?sourcemap:bool -> string -> Dream.handler
(** Serve esbuild bundle. 

    This requires [esbuild] executable to be on your [$PATH].
 *)
