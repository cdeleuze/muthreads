(*type 'a thread*) (* à définir comme autre chose ? *)

(** The muthr (micro threads) library *)

exception Stop

val set_debug : bool -> unit

(** Starts the scheduler *)
val start : unit -> unit

(** Stops the scheduler *)
val stop : unit -> 'a


val ( >>= ) : ('a -> 'b) -> 'a -> 'b
(** Infix monadic like operator for continuation application. [process >>= k] ZZZ *)

(*
val ( >>== ) : (('a -> 'b) -> 'c) -> ('a -> 'd -> 'b) -> 'd -> 'c
*)

(** {2 MVars} *)

type 'a mvar
(** The type of MVars holding a value of type ['a].  An mvar is either
    empty or contains a single ['a] value. *)

(** {3 Basic operations} *)

val make_mvar : unit -> 'a mvar
(** [make_mvar ()] creates a fresh empty MVar. *)

val put_mvar : 'a mvar -> 'a -> (unit -> unit) -> unit
(** [put_mvar mv v >>= k] puts value [v] in [mv] and continues with [k]. *)

val take_mvar : 'a mvar -> ('a -> unit) -> unit
(** [take_mvar mv >>= k] takes value out of [mv] and passes it to
    continuation [k]. *)

(** {3 Timed operations} *)

val timed_take : float -> 'a mvar -> ('a option -> unit) -> unit
(** [timed_take d mv >>= fun r -> ...] takes the value of the MVar if
    it's available before [d] seconds. [r] is bound to [Some v] with [v]
    the value taken. Otherwise, [r] is bound to [None]. *)

val timed_put : float -> 'a mvar -> 'a -> ('a option -> unit) -> unit
(** [timed_put d mv v >>= fun r -> ...] puts the value in the MVar if
    it's possible before [d] seconds. [r] is bound to [None] if the
    put has been performed, or to [Some v] if not. *)

(** {2 FIFOs} *)

type 'a fifo
(** Contrary to an MVar, a fifo can contain an arbitrary number of
    elements.  Thus [put_fifo] never blocks. *)
  
val make_fifo : unit -> 'a fifo
val make_fifo_init : 'a list -> 'a fifo
val put_fifo : 'a fifo -> 'a -> unit
val take_fifo : 'a fifo -> ('a -> unit) -> unit


(** {3 Various operations} *)

val skip : (unit -> 'a) -> 'a
(** [skip >>= k] does nothing, then continues with [k]. *)

val yield : (unit -> unit) -> unit
(** [yield >>= k] sets a cooperation point. *) 

val sleep : float -> (unit -> unit) -> unit
(** [sleep d >>= k] sleeps for [d] seconds then continues with [k]. *)

val sleep_until : float -> (unit -> unit) -> unit
(** [sleep_until t >>= k] sleeps until time [t] then continues with [k]. *)

val spawn : (unit -> unit) -> unit
(** Spawns a new thread. *)

val nothing : unit -> unit
(** Empty continuation. *)

val terminate : unit -> unit
(** To be called by a thread that's done. *)

val merge :
  ((unit -> unit) -> unit) ->
  ((unit -> unit) -> unit) -> (unit -> unit) -> unit
(** TODO *)

val trywith : (unit -> unit) -> (exn -> unit) -> (unit -> unit) -> unit
(** [trywith t h k] runs [t] with [h] as exception handler. [k] is run
    after [t] or [h] has completed. *)

val trywithk : (('a -> unit) -> unit -> unit) -> (('a -> unit) -> exn -> unit) -> ('a -> unit) -> unit
(** Same as [trywith] but [t] passes a value to [k] when completed (or
    [h] does). *)

val timeout : float -> (unit -> unit) -> (unit -> unit) -> (unit -> unit) -> unit
(** [timeout d t expired normal] runs [t].  If [t] terminates in no
    more than [d] seconds, [normal] is taken as the continuation.
    Otherwise, [t] is interrupted (at a cooperation point) and [expired]
    is the continuation. *)

val timeoutk :
  float ->
  (('a -> unit) -> unit -> unit) -> (unit -> unit) -> ('a -> unit) -> unit
(** Same as [timeout] but [t] passes a value to [normal] when completed. *)


(** {2 I/O operations} *)

(** {3 Unix I/O primitives} *)

val socket : Unix.socket_domain -> Unix.socket_type -> int -> Unix.file_descr
(** Creates a socket (set in non blocking mode as all sockets should
be for using the library.) *)

val read : Unix.file_descr -> string -> int -> int -> (int -> unit) -> unit
(** Same as [Unix.read] with continuation argument. *)

val write : Unix.file_descr -> string -> int -> int -> (int -> unit) -> unit
(** See [read]. *)

val accept :
  Unix.file_descr -> (Unix.file_descr * Unix.sockaddr -> unit) -> unit
(** See [read]. *)

val connect : Unix.file_descr -> Unix.sockaddr -> (unit -> unit) -> unit
(** See [read]. *)

val recvfrom :
  Unix.file_descr ->
  string ->
  int -> int -> Unix.msg_flag list -> (int * Unix.sockaddr -> unit) -> unit
(*val recv :
  Unix.file_descr ->
  string ->
  int -> int -> Unix.msg_flag list -> (int -> unit) -> unit*)

val close : Unix.file_descr -> unit
(** [close fd] closes file descriptor [fd]. *)

val really_write :
  Unix.file_descr -> string -> int -> int -> (unit -> unit) -> unit
(** Blocks until the required bytes have actually been written. *)

(** {3 Combined MVar-I/O operations} *)

val read_or_take : 'a mvar -> Unix.file_descr -> string -> int -> int -> (int -> unit) -> ('a -> unit) -> unit
(** [read_or_take mv fd s ofs len kread ktake] either takes a value
   out of [mv] and passes it to [ktake] or [read] (see above) from
   [fd] and passes number of bytes read to [kread].  The call blocks
   until either there's some data ready to be read on the socket, or a
   value is available in the MVar.  If both events happen "at the same
   time" only one action will be taken up.  Either the read action is
   performed and the mvar is left full, or the take action is run (so
   the mvar value is taken out) and the read operation is cancelled.

   If the [take] is possible immediately, it is performed whatever the
   status of the file descriptor.

    TODO: rename take_or_read ?

   The same applies to the following functions.
*)

val accept_or_take :
  'a mvar -> Unix.file_descr -> (Unix.file_descr * Unix.sockaddr -> unit) -> ('a -> unit) -> unit
(** see [read_or_take]. *)

val connect_or_take : 'a mvar ->
  Unix.file_descr -> Unix.sockaddr -> (unit -> unit) -> ('a -> unit) -> unit
(** see [read_or_take]. *)

val write_or_take :
  'a mvar -> Unix.file_descr ->
  string -> int -> int -> (int -> unit) -> ('a -> unit) -> unit
(** see [read_or_take]. *)

val really_write_or_take :
  'a mvar ->
  Unix.file_descr ->
  string -> int -> int -> (unit -> unit) -> ('a -> unit) -> unit
(** TODO: semantics to be clarified *)
