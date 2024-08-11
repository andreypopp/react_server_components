(** Tag requests to invalidate cached responses. *)
module Tag : sig
  type t

  val make : string -> t
end

(** Create a client for a given route declaration. *)
module Make (Route : sig
  type 'a t

  val http_method : 'a t -> [ `DELETE | `GET | `POST | `PUT ]
  val href : 'a t -> string
  val body : 'a t -> Json.t option
  val decode_response : 'a t -> Fetch.response -> 'a Promise.t
  val witness : 'a t -> 'a Ppx_deriving_router_runtime.Witness.t
end) : sig
  val fetch : ?tags:Tag.t list -> 'a Route.t -> 'a Promise.t
  (** send a request to the server, caching the response *)

  val run : 'a Route.t -> 'a Promise.t
  (** send a request to the server, WITHOUT caching the response *)

  val invalidate : 'a Route.t -> unit
  (** invalidate the cache for a given route *)

  val invalidate_tags : Tag.t list -> unit
  (** invalidate the cache for given tags *)
end
