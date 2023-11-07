open Printf
open ContainersLabels

type ctx = { mutable idx : int }
type columns = string -> (string * string) list
type 'a decode = ctx * Sqlite3.Data.t array -> 'a
type 'a bind = 'a -> ctx -> Sqlite3.stmt -> unit

let option_decode decode (ctx, row) =
  let v =
    (* TODO: this is wrong, this way decoder can still can succeed *)
    match row.(ctx.idx) with
    | Sqlite3.Data.NULL -> None
    | _ -> Some (decode (ctx, row))
  in
  ctx.idx <- ctx.idx + 1;
  v

let bool_columns name = [ name, "INT" ]

let bool_decode (ctx, row) =
  let v =
    match row.(ctx.idx) with
    | Sqlite3.Data.INT 0L -> false
    | Sqlite3.Data.INT 1L -> true
    | _ -> failwith "sql type error: expected bool (int)"
  in
  ctx.idx <- ctx.idx + 1;
  v

let bool_bind v ctx stmt =
  Sqlite3.Rc.check
    (Sqlite3.bind stmt ctx.idx (INT (Int64.of_int (Bool.to_int v))));
  ctx.idx <- ctx.idx + 1

let string_columns name = [ name, "TEXT" ]

let string_decode (ctx, row) =
  let v =
    match row.(ctx.idx) with
    | Sqlite3.Data.TEXT v -> v
    | _ -> failwith "sql type error: expected text"
  in
  ctx.idx <- ctx.idx + 1;
  v

let string_bind v ctx stmt =
  Sqlite3.Rc.check (Sqlite3.bind stmt ctx.idx (TEXT v));
  ctx.idx <- ctx.idx + 1

let int_columns name = [ name, "INT" ]

let int_decode (ctx, row) =
  let v =
    match row.(ctx.idx) with
    | Sqlite3.Data.INT v -> Int64.to_int v
    | _ -> failwith "sql type error: expected int"
  in
  ctx.idx <- ctx.idx + 1;
  v

let int_bind v ctx stmt =
  Sqlite3.Rc.check (Sqlite3.bind stmt ctx.idx (INT (Int64.of_int v)));
  ctx.idx <- ctx.idx + 1

let float_columns name = [ name, "FLOAT" ]

let float_decode (ctx, row) =
  let v =
    match row.(ctx.idx) with
    | Sqlite3.Data.FLOAT v -> v
    | _ -> failwith "sql type error: expected float"
  in
  ctx.idx <- ctx.idx + 1;
  v

let float_bind v ctx stmt =
  Sqlite3.Rc.check (Sqlite3.bind stmt ctx.idx (FLOAT v));
  ctx.idx <- ctx.idx + 1

type 'a table = {
  table : string;
  columns : (string * string) list;
  decode : 'a decode;
  bind : 'a bind;
}

let create_table_sql t =
  Printf.sprintf "CREATE TABLE IF NOT EXISTS %s(%s)" t.table
    (t.columns
    |> List.map ~f:(fun (n, t) -> Printf.sprintf "%s %s" n t)
    |> String.concat ~sep:",")

let insert_sql t =
  Printf.sprintf "INSERT INTO %s(%s) VALUES(%s)" t.table
    (t.columns |> List.map ~f:fst |> String.concat ~sep:", ")
    (t.columns |> List.map ~f:(fun _ -> "?") |> String.concat ~sep:", ")

let select_sql t =
  Printf.sprintf "SELECT %s FROM %s"
    (t.columns |> List.map ~f:fst |> String.concat ~sep:", ")
    t.table

let init t =
  let sql = create_table_sql t in
  fun db -> Sqlite3.Rc.check (Sqlite3.exec db sql)

let rec insert_work stmt =
  match Sqlite3.step stmt with
  | Sqlite3.Rc.DONE -> ()
  | OK -> insert_work stmt
  | rc -> Sqlite3.Rc.check rc

let insert t =
  let sql = insert_sql t in
  fun db ->
    let stmt = Sqlite3.prepare db sql in
    fun v ->
      let ctx = { idx = 1 } in
      Sqlite3.Rc.check (Sqlite3.reset stmt);
      t.bind v ctx stmt;
      insert_work stmt

let fold' decode sql ~init ~f db =
  let stmt = Sqlite3.prepare db sql in
  let rc, acc =
    Sqlite3.fold stmt ~init ~f:(fun acc row ->
        let ctx = { idx = 0 } in
        let user = decode (ctx, row) in
        f acc user)
  in
  Sqlite3.Rc.check rc;
  acc

let fold t ~init ~f = fold' t.decode (select_sql t) ~init ~f
let iter t decode ~f = fold t decode ~init:() ~f:(fun () -> f)

type 's opt = Opt of 's
type 's agg = Agg of 's

module E : sig
  type not_null = private NOT_NULL
  type null = private NULL
  type ('a, 'n) t
  type 'a e = ('a, not_null) t
  type 'a eopt = ('a, null) t

  val int : int -> int e
  val bool : bool -> bool e
  val string : string -> string e
  val eq : ('a, 'n) t -> ('b, 'n) t -> (bool, 'n) t
  val and_ : (bool, 'n) t -> (bool, 'n) t -> (bool, 'n) t
  val or_ : (bool, 'n) t -> (bool, 'n) t -> (bool, 'n) t
  val ( = ) : ('a, 'n) t -> ('a, 'n) t -> (bool, 'n) t
  val ( && ) : (bool, 'n) t -> (bool, 'n) t -> (bool, 'n) t
  val ( || ) : (bool, 'n) t -> (bool, 'n) t -> (bool, 'n) t
  val coalesce : ('a, _) t -> ('a, 'n) t -> ('a, 'n) t
  val of_opt : 's opt -> ('s -> ('a, _) t) -> 'a eopt
  val inject : string -> 'a decode -> 'a e
  val inject_opt : string -> 'a decode -> 'a eopt
  val as_col : int -> string -> string -> ('a, 'n) t -> ('a, 'n) t
  val col : int -> string -> string -> 'a decode -> 'a e
  val col_opt : int -> string -> string -> 'a decode -> 'a eopt
  val decode : 'a e -> 'a decode
  val decode_opt : 'a eopt -> 'a option decode
  val to_sql : (_, _) t -> string
  val cols : (_, _) t -> (int * string) list
end = struct
  type not_null = private NOT_NULL
  type null = private NULL

  type ('a, 'n) t = {
    sql : string;
    decode : 'a decode;
    cols : (int * string) list;
  }

  let cols e = e.cols

  type 'a e = ('a, not_null) t
  type 'a eopt = ('a, null) t

  let int v = { sql = string_of_int v; decode = int_decode; cols = [] }
  let bool v = { sql = string_of_bool v; decode = bool_decode; cols = [] }

  let string v =
    { sql = Printf.sprintf "'%s'" v; decode = string_decode; cols = [] }

  let make_binop decode op a b =
    {
      sql = Printf.sprintf "(%s %s %s)" a.sql op b.sql;
      decode;
      cols = a.cols @ b.cols;
    }

  let eq a b = make_binop bool_decode "=" a b
  let and_ a b = make_binop bool_decode "AND" a b
  let or_ a b = make_binop bool_decode "OR" a b
  let ( = ) = eq
  let ( && ) = and_
  let ( || ) = or_

  let coalesce ov v =
    {
      sql = Printf.sprintf "COALESCE(%s, %s)" ov.sql v.sql;
      decode = v.decode;
      cols = ov.cols @ v.cols;
    }

  let inject sql decode = { sql; decode; cols = [] }
  let inject_opt sql decode = { sql; decode; cols = [] }

  let col id t col decode =
    { sql = sprintf "%s.%s" t col; decode; cols = [ id, col ] }

  let col_opt id t col decode =
    { sql = sprintf "%s.%s" t col; decode; cols = [ id, col ] }

  let as_col id t col e =
    { e with sql = sprintf "%s.%s" t col; cols = [ id, col ] }

  let to_sql e = e.sql
  let decode e = e.decode
  let decode_opt e = option_decode e.decode

  let of_opt (Opt s : 's opt) f =
    let e = f s in
    { sql = e.sql; decode = e.decode; cols = e.cols }
end

type 'a e = 'a E.e
type any_expr = Any_expr : ('a, 'n) E.t -> any_expr

module Q = struct
  type void = private Void
  type order = Asc : (_, _) E.t -> order | Desc : (_, _) E.t -> order

  let asc e = Asc e
  let desc e = Desc e

  type fields = (any_expr * string) list
  type 's make_scope = int -> string -> 's

  type (_, _) q =
    | From : 'a table * fields * 's make_scope -> ('s, 'a) q
    | Where : ('s, 'a) q * ('s -> bool e) -> ('s, 'a) q
    | Order_by : ('s, 'a) q * ('s -> order list) -> ('s, 'a) q
    (* | Join : *)
    (*     ('sa, 'a) q * ('sb, 'b) q * ('sa * 'sb -> bool e) *)
    (*     -> ('sa * 'sb, 'a * 'b) q *)
    | Left_join :
        ('sa, 'a) q * ('sb, 'b) q * ('sa * 'sb -> bool e)
        -> ('sa * 'sb opt, 'a * 'b option) q
    | Select :
        ('s, 'a) q * ('s -> 's1 make_scope * fields * 'a1 decode)
        -> ('s1, 'a1) q

  let genid =
    let id = ref 0 in
    fun () ->
      let v = !id in
      id := v + 1;
      v

  type ('s, 'a) rel = {
    id : int;
    tree : tree;
    scope : int -> string -> 's;
    fields : (any_expr * string) list;
    mutable select : (any_expr * string) list;
    default_select : string;
    decode : 'a decode;
  }

  and tree =
    | SUBQUERY : (_, _) rel -> tree
    | FROM : _ table -> tree
    | WHERE : (_, _) rel * (_, _) E.t -> tree
    | ORDER_BY : (_, _) rel * order list -> tree
    | JOIN : (_, _) rel * (_, _) rel * (_, _) E.t -> tree

  let rec render_rel : type s a. (s, a) rel -> string =
   fun rel ->
    let select =
      match rel.select with
      | [] -> rel.default_select
      | select ->
          List.map select ~f:(fun (Any_expr e, n) ->
              sprintf "%s AS %s" (E.to_sql e) n)
          |> String.concat ~sep:", "
    in
    Printf.sprintf "SELECT %s %s" select (render_tree rel.tree)

  and render_tree = function
    | SUBQUERY rel -> Printf.sprintf "FROM (%s) AS t" (render_rel rel)
    | FROM t -> Printf.sprintf "FROM %s AS t" t.table
    | JOIN (a, b, e) ->
        Printf.sprintf "FROM (%s) AS a LEFT JOIN (%s) as b ON %s"
          (render_rel a) (render_rel b) (E.to_sql e)
    | WHERE (rel, e) ->
        Printf.sprintf "FROM (%s) AS t WHERE %s" (render_rel rel)
          (E.to_sql e)
    | ORDER_BY (rel, os) ->
        Printf.sprintf "FROM (%s) AS t ORDER BY %s" (render_rel rel)
          (List.map os ~f:render_order |> String.concat ~sep:", ")

  and render_order = function
    | Asc e -> Printf.sprintf "%s ASC" (E.to_sql e)
    | Desc e -> Printf.sprintf "%s DESC" (E.to_sql e)

  module Col_set = Set.Make (struct
    type t = int * string

    let compare = Ord.pair Ord.int Ord.string
  end)

  let used_expr e used =
    List.fold_left (E.cols e)
      ~f:(fun used col -> Col_set.add col used)
      ~init:used

  let used_fields fs used =
    List.fold_left fs ~init:used ~f:(fun used (Any_expr e, _) ->
        used_expr e used)

  let mark rel used_select used =
    print_endline (sprintf "======== %i" rel.id);
    Col_set.iter
      (fun (id, n) -> print_endline (sprintf "- used %i %s" id n))
      used;
    print_endline "---";
    if not (Col_set.is_empty used_select) then
      rel.select <-
        List.filter rel.fields ~f:(fun (_, n) ->
            print_endline (sprintf "- field %s" n);
            Col_set.mem (rel.id, n) used)

  let rec trim_select : type s a. (s, a) rel -> unit =
   fun rel ->
    let used_select = used_fields rel.select Col_set.empty in
    match rel.tree with
    | SUBQUERY inner ->
        mark inner used_select used_select;
        trim_select inner
    | FROM _ -> ()
    | WHERE (inner, e) ->
        let used = used_expr e used_select in
        mark inner used_select used;
        trim_select inner
    | ORDER_BY (inner, fs) ->
        let used =
          List.fold_left fs
            ~f:(fun used -> function
              | Asc e -> used_expr e used | Desc e -> used_expr e used)
            ~init:used_select
        in
        mark inner used_select used;
        trim_select inner
    | JOIN (a, b, e) ->
        let used = used_expr e used_select in
        mark a used_select used;
        trim_select a;
        mark b used_select used;
        trim_select b

  let forward_fields id t fs =
    List.map fs ~f:(fun (Any_expr e, n) ->
        Any_expr (E.as_col id t n e), n)

  let rec to_rel : type s a. (s, a) q -> (s, a) rel = function
    | From (t, fields, scope) ->
        let id = genid () in
        {
          id;
          decode = t.decode;
          scope;
          tree = FROM t;
          fields;
          select = [];
          default_select = "*";
        }
    | Where (q, e) ->
        let id = genid () in
        let inner = to_rel q in
        let e = e (inner.scope inner.id "t") in
        {
          id;
          decode = inner.decode;
          scope = inner.scope;
          tree = WHERE (inner, e);
          fields = forward_fields inner.id "t" inner.fields;
          select = [];
          default_select = "t.*";
        }
    | Order_by (q, e) ->
        let inner = to_rel q in
        let id = genid () in
        {
          id;
          decode = inner.decode;
          scope = inner.scope;
          tree = ORDER_BY (inner, e (inner.scope inner.id "t"));
          fields = forward_fields inner.id "t" inner.fields;
          select = [];
          default_select = "t.*";
        }
    (* | Join (a, b, e) -> *)
    (*     let a = to_rel a in *)
    (*     let b = to_rel b in *)
    (*     let scope = a.scope, b.scope in *)
    (*     let decode v = *)
    (*       let a = a.decode v in *)
    (*       let b = b.decode v in *)
    (*       a, b *)
    (*     in *)
    (*     { *)
    (*       decode; *)
    (*       scope; *)
    (*       sql = *)
    (*         Printf.sprintf "FROM (%s) AS a JOIN (%s) AS b ON %s" a.sql *)
    (*           b.sql *)
    (*           (E.to_rel (e scope)); *)
    (*       select = []; *)
    (*       default_select = "a.*, b.*"; *)
    (*     } *)
    | Left_join (a, b, e) ->
        let id = genid () in
        let a = to_rel a in
        let b = to_rel b in
        let a_scope, b_scope = a.scope a.id "a", b.scope b.id "b" in
        let scope id s = a.scope id s, Opt (b.scope id s) in
        let decode v =
          let a = a.decode v in
          let b = option_decode b.decode v in
          a, b
        in
        {
          id;
          decode;
          scope;
          tree = JOIN (a, b, e (a_scope, b_scope));
          select = [];
          fields =
            forward_fields a.id "a" a.fields
            @ forward_fields b.id "b" b.fields;
          default_select = "a.*, b.*";
        }
    | Select (q, f) ->
        let inner = to_rel q in
        let id = genid () in
        let scope, fields, decode = f (inner.scope inner.id "t") in
        {
          id;
          decode;
          scope;
          tree = SUBQUERY inner;
          fields;
          select = fields;
          default_select = "t.*";
        }

  let to_sql q =
    let rel = to_rel q in
    trim_select rel;
    rel.decode, rel.scope, render_rel rel

  let from t f s = From (t, f, s)
  let where e q = Where (q, e)
  let order_by e q = Order_by (q, e)

  (* let join b e a = Join (a, b, e) *)
  let left_join b e a = Left_join (a, b, e)
  let select f q = Select (q, f)

  let fold db q ~init ~f =
    let decode, _scope, sql = to_sql q in
    print_endline sql;
    fold' decode sql db ~init ~f

  let iter db q ~f = fold db q ~init:() ~f:(fun () row -> f row)
end

module P = struct
  type _ t =
    | E : 'a e -> 'a t
    | B : 'a t * 'b t -> ('a * 'b) t
    | F : 'a t * ('a -> 'b) -> 'b t

  let get e = E e
  let both a b = B (a, b)
  let map f a = F (a, f)
  let ( let+ ) a f = map f a
  let ( and+ ) a b = both a b

  let rec cols : type a. a t -> (int * string) list = function
    | E e -> E.cols e
    | B (a, b) -> cols a @ cols b
    | F (a, _) -> cols a

  let fields p =
    let rec fields : type a. a t -> Q.fields = function
      | E e -> [ Any_expr e, "c" ]
      | B (a, b) -> fields a @ fields b
      | F (a, _) -> fields a
    in
    List.mapi (fields p) ~f:(fun i (e, _) -> e, sprintf "c%i" i)

  let rec decode : type a. a t -> a decode =
   fun p data ->
    match p with
    | E e -> E.decode e data
    | B (a, b) ->
        let a = decode a data in
        let b = decode b data in
        a, b
    | F (a, f) ->
        let a = decode a data in
        f a

  let fold p db q ~init ~f =
    let q =
      Q.select
        (fun scope ->
          let p = p scope in
          let fields = fields p in
          (fun _ _ -> object end), fields, decode p)
        q
    in
    let decode, _scope, sql = Q.to_sql q in
    print_endline sql;
    fold' decode sql db ~init ~f

  let iter p db q ~f = fold p db q ~init:() ~f:(fun () row -> f row)
end
