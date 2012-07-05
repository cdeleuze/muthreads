(** Retry combinators *)

exception Failed 
(** To be raised by an operation that definitely fails (don't want to
    be retried) *)

val retry :
  int -> (('a option -> unit) -> unit) -> (unit -> unit) -> ('a -> unit) -> unit
(** [retry n c kfail k] retries [c] at most [n] times.  [c] must pass
    its continuation [Some r] for result [r], [None] for temporary
    failure, or raise [Failed] for definitive failure. *)

(** to_kopt would be useful here *)

(** {2 Very experimental operations} *)

val retryex : exn -> int -> (('a option -> unit) -> unit) -> ('a -> unit) -> unit

val retry_forever : (('a option -> unit) -> unit) -> (unit -> unit) -> ('a -> unit) -> unit

val retry_tm :
  float ->
  (('a option -> unit) -> unit) -> (unit -> unit) -> ('a -> unit) -> unit

val retry_n_tm :
  int ->
  float ->
  (('a -> unit) -> unit -> unit) -> (unit -> unit) -> ('a -> unit) -> unit

val retry_n_tm_backoff :
  int ->
  float ->
  float ->
  (('a -> unit) -> unit -> unit) -> (unit -> unit) -> ('a -> unit) -> unit

val retry_list :
  'a list ->
  ('a -> ('b option -> unit) -> unit) -> (unit -> unit) -> ('b -> unit) -> unit
(** [retry_list l c kfail k] retries [c] with each each value in [l]. *)


val retry_list_tm :
  'a list ->
  float ->
  ('a -> ('b option -> unit) -> unit -> unit) ->
  (unit -> unit) -> ('b -> unit) -> unit
(** Retry for a list, with a [tm] timeout each time *)
