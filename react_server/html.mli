type attrs = (string * attr_value) list
(** A collection of HTML attributes. *)

and attr_value = [ `String of string | `Bool of bool ]

val s : string -> attr_value
val b : bool -> attr_value

type t
(** A piece of HTML. *)

val node : string -> attrs -> t list option -> t
val text : string -> t
val splice : ?sep:string -> t list -> t
val empty : t

val unsafe_raw : string -> t
(** Unsafely (without any escaping) embed a string into HTML. Never use this
    untrusted input. *)

val unsafe_rawf : ('a, unit, string, t) format4 -> 'a
(** Same as [unsafe_raw] but allows to use a format string.  Never use this
    untrusted input. *)

val to_string : t -> string
(** Render HTML into string. *)

val json_escape : string -> string
(** Escape JSON string to be able to embed it safely into HTML <script> tag. *)
