(* muthr.ml - $\mu{}$threads - trampoline style *)

(*i TODO: internal data

   - enqueue/dequeue assymetry (transfer)

   - a module for DNS resolutions

   - a module for handling events from Graphics module

   - OK - race condition on read_or_take and others
          the mv.read <- None should be done immediately in check_io

   - really_write_or_take : what semantics?

   - nb of threads active
   - ...

  - OK open/close sockets
  - I/O channels ?

  - select EBADF if given closed fd (user error)
  - same for lost xfd ?

i*)

exception Error of string
let error msg = raise (Error msg)

(* Some debugging stuff. *)

let do_debug = ref false
let do_debug_xfd = false

let set_debug v = do_debug := v

let log s = output_string stderr s; flush stderr
let debug = 
  if !do_debug then 
    fun s -> (if s <> "" then log ("Muthr: " ^ s))
  else
    fun s -> ()

let dbg_xfd =
  if do_debug_xfd then fun xfd -> 
    log ("rfd: " ^ (String.concat "\n"
		      (List.map (fun f -> Printf.sprintf "%i " (Obj.magic f))
			 !xfd)))
  else fun xfd -> ()

(* A thread is made of a continuation, a context stack, and a
   [pending_io ref], used to clean-up I/O data structures if the
   thread is cancelled (eg from a timeout) while blocked on an I/O
   operation. *)

type pending_io =
  | FdRead  of Unix.file_descr
  | FdWrite of Unix.file_descr
  | Nofd

type 'a thread = pending_io ref * context * ('a -> unit)

and ctxt_elt = 
  | TryWith of (exn -> unit) * (unit -> unit)     
  | Timeout of bool ref * float * (unit -> unit)
  | NoTimeout of (unit -> unit)
  | Seq       of (unit -> unit)

and context = ctxt_elt list

(* These globals are refs to the context and the [pending_io] of the
   currently executing thread. *)

let ctxt = ref []
let io = ref (ref Nofd)

(* [runq] is a FIFO of currently runnable threads.  [enqueue] and
   [dequeue] add/get a thread in/from [runq].  [continue k] adds the
   continuation [k] of the current thread in [runq], using the current
   context stack and pending io (from globals [ctxt] and [io]).
   [context] does the same thing but uses the provided context.

   [continue] is to be run from an operation called by the thread
   itself, while enqueue should be called from the scheduler (or
   another thread).

   [term] is used by the scheduler.
 *)

let runq = Queue.create ()
let enqueue p  = Queue.push p runq
let dequeue () = Queue.take runq

let continue  k = Queue.push (!io, !ctxt, k) runq
let context c k = Queue.push (!io, c , k) runq

let term = ref true

exception Stop

(*s MVars *)

type 'a mvar = { mutable v:'a option; 
		 mutable read:'a thread option;
		 mutable write:(unit thread * 'a) option }

let make_mvar () = { v=None; read=None; write=None }

let rec put_mvar out v k =
  match out with
  | { v=Some v'; read=_; write=None } -> term := false;
      out.write <- Some ((!io,!ctxt,k),v)

  | { v=None; read=Some(l,c,r); write=None } -> 
      out.read <- None; continue k; out.v <- Some v;
      enqueue (l,c,(fun () -> take_mvar out r));
      term := false

  | { v=None; read=None; write=None } -> out.v <- Some v; k ()

  | _ -> error "failed put_mvar"

and take_mvar inp k =
  match inp with
  | { v=Some v; read=None; write=None } -> inp.v <- None; k v

  | { v=Some v; read=None; write=Some((l,c,r),v') } -> 
      inp.v <- None; inp.write <- None;
      enqueue (l,c,(fun () -> put_mvar inp v' r)); k v

  | { v=None; read=None; write=_ } -> inp.read <- Some(!io, !ctxt,k);
      term := false

  | _ -> error "failed take_mvar"


(*s FIFOs *)

type 'a fifo = { q : 'a Queue.t; mutable w: 'a thread option }

let make_fifo () = { q=Queue.create (); w=None }

let make_fifo_init l = 
  let q = Queue.create () in
  List.iter (fun a -> Queue.add a q) l;
  { q=q; w=None }

let take_fifo f k =
  if Queue.length f.q = 0 then
    (f.w <- Some(!io, !ctxt, k); term := false)
  else
    k (Queue.take f.q)

let put_fifo f v =
  Queue.add v f.q;
  match f.w with
  | Some(l,c,r) -> enqueue (l,c, (fun () -> take_fifo f r)); f.w <- None
  | None -> ()


(*s Sleep internals

  [sleepers] is a list of (wake-up time, thread) tuples, sorted by
  wake-up time. *)

let sleepers : (float * unit thread) list ref = ref []

let insert_sleeper date p =
  let rec insert (t,p) l =
    match l with 
      | [] -> [ (t,p) ]
      | (t',p')::rest -> 
	if t' < t then 
	  (t',p') :: (insert (t,p) rest)
	else
	  (t,p)::l
  in
  sleepers := insert (date,p) !sleepers

(* Wake up sleepers that need to: move them to [runq], return delay
   for next wakeup, or -1 if no more sleepers. *)

let enqueue_expired_sleepers () =
  let now = Unix.gettimeofday () in
  let rec loop l =
    match l with
      | [] -> []
      | (t,p)::rest ->
	if t<=now then begin
	  enqueue p;
	  loop rest
	end else l
  in
  sleepers := loop !sleepers;
  match !sleepers with
    | [] -> -1.
    | (t,_)::_ -> t -. now


(*s I/O *)

(* Each thread blocked on a I/O operation on file descriptor [fd] has
   its state (the operation, its parameters and the continuation, see
   types [reader] and [writer]) stored in the [readers] or [writers]
   array at index the relevant fd.  [rfd] and [wfd] are lists of the
   file descriptors for which there's an operation stored in [readers]
   and [writers].  *)

let max_fd = 65536

type writer = 
  | NoWrite
  | Write   of bool ref * string * int * int * int thread
  | Connect of bool ref * unit thread

type reader =
  | NoRead
  | Read     of bool ref * string * int * int * int thread
  | Recv     of string * int * int * Unix.msg_flag list * int thread
  | Recvfrom of string * int * int * Unix.msg_flag list *
      (int * Unix.sockaddr) thread
  | Accept   of bool ref * (Unix.file_descr * Unix.sockaddr) thread

let writers = Array.create max_fd NoWrite
let readers = Array.create max_fd NoRead

let rfd = ref []
let wfd = ref []

(* Remove a fd from [rfd] or [wfd] *)

let rem_from_xfd xfd fd =
  xfd := List.filter (fun fd' -> fd <> fd') !xfd

(* A read operation on [fd] was blocked, we know it's now possible, so
   do it.  Precisely:
   \begin{itemize}
   \setlength{\itemsep}{0cm}
   \item [enqueue] a thread doing the operation and passing the result
     to the continuation,
   \item reset the thread [pending_io] (since it's no more blocked on
     the I/O operation),
   \item reset the [readers] entry.
   \end{itemize}

   The [go] parameter is for combined I/O--MVar operations, if it is
   set the [read] operation is cancelled, see relevant section.  *)

let do_read_fd fd =
  let op = readers.(Obj.magic fd) in
  readers.(Obj.magic fd) <- NoRead;
  match op with
    | Read(go, s, ofs, len, (r,c,k)) -> 
      r := Nofd;
      if !go then begin
	go := false;
	enqueue (r,c,(fun () -> k (Unix.read fd s ofs len)))
      end

    | Recv(s, ofs, len, l, (r,c,k)) -> failwith "recv not implemented"
      
    | Recvfrom(s, ofs, len, l, (r,c,k)) -> 
      r := Nofd;
      enqueue (r, c,(fun () -> k (Unix.recvfrom fd s ofs len l)))
	
    | Accept(go,(r,c,k)) -> 
      r := Nofd;
      if !go then begin
	go := false;
	enqueue (r, c, (fun () -> 
	  let (fd',addr) = Unix.accept fd in
	  Unix.set_nonblock fd'; k (fd', addr)))
      end
	
    | NoRead -> error "lost rfd"

(* The same thing for a write operation. *)

let do_write_fd fd =
  let op = writers.(Obj.magic fd) in
  writers.(Obj.magic fd) <- NoWrite;
  match op with
    | Write(go, s, ofs, len, (r,c,k)) ->
      r := Nofd;
      if !go then begin
	go := false;
	enqueue (r, c, (fun () -> k (Unix.write fd s ofs len)))
      end
	
    | Connect(go,(r,c,k)) -> 
      r := Nofd;
      if !go then begin
	go := false;
	let err = Unix.getsockopt_int fd Unix.SO_ERROR 
	in
	if err = 0 then
	  enqueue (r,c,k)
	(* ZZZ + EINTR ? *)
	else 
	  (* [connect] has failed, we raise an exception \textbf{in} the
	     thread. *)
	  enqueue (r,c, fun () -> 
	    raise (Unix.Unix_error(Obj.magic err, "connect", "")))
      end
	
    | NoWrite -> error "lost wfd"

(* [check_io] is a thread that checks for threads blocked for I/O or
   sleeping.  It enqueues itself when done so it is called regularly
   even if other threads are always ready to run.

   It first calls [enqueue_expired_sleepers] to wake up sleepers and
   get the delay for the next sleeper.  If there's no thread blocked
   on I/O and no sleepers, there's nothing more to do.

   Otherwise, call [select] on the active fds with the appropriate
   timeout value.  When this returns, update [rfd] and [wfd] and
   perform the operations.  Note that it doesn't need to set term to
   [false], since it's always running in an empty context.

*)

let rec check_io () =
  debug "check_io";
  let first_sleep = enqueue_expired_sleepers ()
  in
  dbg_xfd rfd;
  if !rfd @ !wfd <> [] || first_sleep <> -1. then begin
    let timeout = if Queue.length runq = 0 then first_sleep else 0. in
    let rdo, wdo, _ = Unix.select !rfd !wfd [] timeout
    in
    ignore (enqueue_expired_sleepers ());

    rfd := List.filter (fun fd -> not (List.mem fd rdo)) !rfd;
    wfd := List.filter (fun fd -> not (List.mem fd wdo)) !wfd;

    List.iter do_read_fd  rdo;
    List.iter do_write_fd wdo
  end;
  continue check_io
;;

(*s Exception handling *)

(* A thread has raised an exception [e]: try to catch it, unrolling
   the context stack [cs] until [e] is catched. 

   When a [TryWith(h,k)] context element is found, we wrap the handler
   [h] in [h'] and schedule it to run, followed by k ([Seq] context
   element).  The wrapping is to check if the handler refuses the
   exception (it raises [Match_failure] during the first step): in
   this case, we make it call [trycatch] with the initial exception
   (thus looking for another exception handler deeper in the stack).
   If, during this first step, it raises another exception, just pass
   it on (it has accepted the provided exception but then raised one).

   Exceptions raised in the next steps of the handler will be
   processed normally. ZZZ

*)

let rec trycatch e cs lio =
  debug "trycatch";
  match cs with

  | TryWith(h,k)::t -> 
    let h' () =
      debug "trycatch: running handler"; 
      (try h e with
	| Match_failure _ -> debug "trycatch: uncaught"; trycatch e !ctxt !io
	| other -> raise other);
      debug "trycatch: handler done (first step)"
    in
    debug "found TryWith context";
    term := false;
    enqueue (lio, Seq(k)::t, h')
	
  | Timeout(s,_,_) :: t -> s := true; trycatch e t lio    (* kill timer *)
  | NoTimeout _    :: t -> trycatch e t lio
  | Seq _          :: t -> trycatch e t lio

  | [] -> 
      match e with Stop -> raise e
      | _ -> 
	  let msg = ("Warning: uncaught exception, thread killed! "
		     ^ (Printexc.to_string e) ^ "\n")
	  in
	  output_string stderr msg; flush stderr;
	  term := false

(*s Scheduler *)

(* Set up context and io, then run thread (run function [f], catching
   exceptions as specified by context [c]). *)

let run (lio, c, f) =
  io := lio;
  ctxt := c;
  try f () with e -> trycatch e c lio  (* raise e *)

let rec find_shot cs =
  match cs with
  | Timeout(shot, _, _) :: _ when !shot -> true
  | c::cs -> find_shot cs
  | [] -> false

let dbg_ctxt c =
  debug ("RUN (" ^ (string_of_int (Queue.length runq)) ^ "): " ^ 
	 (String.concat "," (List.map
			       (fun c -> match c with
			       | Timeout _   -> "T"
			       | NoTimeout _ -> "N"
			       | Seq _       -> "S"
			       | TryWith _   -> "W") c)))

(* The scheduler is an infinite loop.  Dequeue a thread, check if it's
   not been shot, [run] it, enqueue continuation with updated context
   if applicable. 

   [term] is set to true before calling the thread current function.
   The thread will set it to false if it doesn't want the scheduler to
   schedule it again (either it dies or has taken care of its
   continuation itself).

  *)

let sched () =
  let context_msg msg c t = debug msg; context c t
  in
  enqueue (ref Nofd, [], check_io);
  try
    while true do
      term := true;
      let (l, c, f) as p = dequeue () in begin
	dbg_ctxt c;
	if find_shot c then debug "SHOT!" else (* ZZZ *)
	match c with
	  
	| Timeout(shot, date, t) :: c' ->
	  if !shot then debug "thread shot" else begin (* useless ! find shot ZZZ *)
	    debug "thread not shot";
	    run p;
	    if !term then begin  (* timed operation completed:   *)
	      shot := true;      (* kill timer         *)
	      context_msg "killing timer" c' t
	    end
	  end
	      
	| NoTimeout(t)::c' -> run p;
	    if !term then context c' t

	| Seq(t)::c' -> run p;
	    if !term then context_msg "end Seq" c' t

	| [] -> run p

	| TryWith(h,t)::c' -> debug "run trywith"; run p;
	    if !term then context_msg "trywith done!" c' t
      end;
      flush stdout
    done
  with Stop -> () (* ZZZ empty runq and other data structs? *)



(*s Basic API *)

let skip  k = k ()
let yield k = term := false; continue k
let spawn k = debug "spawn"; enqueue (ref Nofd, (*!ctxt*) [], k)
let start () = sched ()
let stop  () = raise Stop

let (>>=) inst k = inst k

let (>>==) a1 t2 = fun k -> a1 (fun r -> t2 r k)

let nothing = fun () -> ()
let terminate () = term := false

(* spawn two synchronized threads -- ZZZ shared context! *)
let merge t1 t2 after =
  let you_re_last = ref false in
  let finish () =
    if !you_re_last then after ()
    else you_re_last := true
  in
  continue (fun () -> t1 >>= finish); (*ZZZ*)
  continue (fun () -> t2 >>= finish)


let sleep t k =
  debug "..sleep";
  term := false;
  let t = Unix.gettimeofday () +. t
  in
  insert_sleeper t (!io, !ctxt, k)

let sleep_until d k =
  term := false;
  insert_sleeper d (!io, !ctxt, k)


(*s Exception handling *)

(* We want to run [f], with [h] as exception handler.  When this is
done (either [f] has completed or [h] has caught an exception, execute
[after].

We simply schedule [f] to be executed in a context on which has been
pushed a exception handling frame ([TryWith] context element).
*)

let trywith f h after =
  debug "entering trywith";
  term := false;
  context (TryWith(h, after)::!ctxt) f

(*


*)

let trywithk f h after =
  debug "entering trywithk";
  term := false;
  let res = ref None
  in
  let k () = debug "trywithk: using res"; match !res with Some r -> after r in
  let h e = h (fun r -> debug "trywithk: h setting res"; res := Some r) e in
  let th  = f (fun r -> debug "trywithk: f setting res"; res := Some r)
  in
  context (TryWith(h, k) :: !ctxt) th


(*s Timeouts *)

(* This is to be called with pending io of a thread when a pending I/O
   operation is aborted -- this can only occur on timeouts (more
   generally it is needed if the thread may be killed by another
   one). *)

let clear_pending_io io =
  match !io with
    | Nofd -> ()
    | FdRead  fd -> readers.(Obj.magic fd) <- NoRead;  rem_from_xfd rfd fd
    | FdWrite fd -> writers.(Obj.magic fd) <- NoWrite; rem_from_xfd wfd fd

(* A new timeout is valid except if an already established timeout
   would expire sooner.  The shorter already established timeout is
   the syntactically innermost (ie the most recently pushed on the
   stack) by construction.  *)

let is_valid_timeout d =
  let rec loop c =
    match c with
      | Timeout(_, d',_)::_ -> d<d'
      | [] -> true
      | h::t -> loop t
  in
  loop !ctxt

(* A timeout is implemented by spawning a thread sleeping for the
   specified amount of time, sharing a boolean ref with the initial
   thread.  The first one to complete will set the boolean ref to
   true, thus informing the other one it has ``shot'' first.

   If the timer shots first, it has to [clear_pending_io] in case the
   timed thread was blocked on an I/O operation.

   If the timeout is not valid, we don't actually have to set a timer,
   but we need to arrange for the provided continuation to run when
   the operation has completed: for this we push a [NoTimeout] context
   element to the stack.

*)

let timeout t f h k =
  let shot = ref false in
  let t = Unix.gettimeofday () +. t in
  let tio = !io
  in
  term := false;
  if is_valid_timeout t then begin 
    debug "set timeout";
    enqueue (tio, Timeout(shot,t,k)::!ctxt, f);
    let timer () = 
      if !shot then (term := false; debug "old timer") else begin
	debug "timer fire!";
	shot := true;          (* kill the thread *)
	clear_pending_io tio;
	h ()
      end
    in
    insert_sleeper t (ref Nofd, !ctxt, timer)
  end else
    (debug "notimeout!";
     enqueue (!io, NoTimeout(k)::!ctxt, f))

(* timeout with passing of result ... *)
(* ok, but can we make a cleaner interface? *)

let timeoutk t f h f' =
  let shot = ref false in
  let t = Unix.gettimeofday () +. t in
  let tio = !io in
  let res = ref None
  in
  term := false;
  let k () = match !res with Some r -> f' r in
  let th   = f (fun r -> res := Some r)
  in
  if is_valid_timeout t then begin 
    debug "set timeoutk";
    enqueue (tio, Timeout(shot,t,k)::!ctxt, th);
    let timer () = 
      if !shot then (term := false; debug "old timerk") else begin
	debug "timerk fire!";
	shot := true;           (* kill the thread *)
	clear_pending_io tio;
	h ()
      end
    in
    insert_sleeper t (ref Nofd, !ctxt, timer)
  end else
  (debug "notimeoutk!";
   enqueue (!io, NoTimeout(k)::!ctxt, th))


(*s Temporized operations on MVars *)

let timed_take d mv k =
  timeoutk d
    (fun k () -> take_mvar mv k)
    (fun () -> k None)
    (fun v -> k (Some v))

let timed_put d mv v k =
  timeoutk d
    (fun k () -> put_mvar mv v k)
    (fun () -> k (Some v))
    (fun () -> k None)

(*s Non blocking I/O  -- low-level API *)

(* [readb] is used both for simple [read] and [read_or_take].

   The [go] boolean is there to avoid race conditions in
   [read_or_take].  In the simple read case, it's just a ref to true.

   In [read_or_take], a thread [mvar_wait] is put in the [mv.read] so
   that it is scheduled for execution as soon as a value is put in the
   mvar.  When run, if [go] is not true it sets it, kills the [read]
   thread by cleaning the readers entry and run [ktake] proper. If
   [go] is true, that means that [check_io] has scheduled the [read]
   thread (certainly between the moment we were scheduled and the
   moment we actually run) so we do nothing (but put back the mvar
   value, since we cancel its taking up).

   [check_io] checks [go] as well.  If it is set, the [ktake] has been
   run, we do nothing (clean readers ZZZ). Otherwise we set it, clean
   the [mv.read] entry so to avoid the [ktake] branch been triggered
   later, and proceed.

*)

let readb go fd s ofs len k =
(*i  let res, ok =
    try
      Unix.read fd s ofs len, true
    with Unix.Unix_error((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
      -> 0, false
  in if ok then k res
  else begin i*)
  debug "readb: blocked";
  (* if List.mem fd !rfd then debug "fd already in rfd!" else*)
  rfd := fd :: !rfd;
  !io := FdRead fd;
  readers.(Obj.magic fd) <- Read (go, s, ofs, len, (!io, !ctxt, k));
  term := false
(*i  end i*)

let read fd s ofs len k =
  readb (ref true) fd s ofs len k

let read_or_take mv fd s ofs len kread ktake =
  match mv.v with
  | Some v -> take_mvar mv >>= ktake
  | None   ->
      let c   = !ctxt in
      let tio = !io   in
      let go = ref true
      in
      let mvar_wait v =
	if !go then begin (* ok, we go *)
	  go := false;
	  rem_from_xfd rfd fd;
	  readers.(Obj.magic fd) <- NoRead;
	  continue (fun () -> ktake v)
	end else (* read has already been scheduled, cancel ourselves *)
	  mv.v <- Some v;
	terminate ()
      in
      mv.read <- Some(tio, c, mvar_wait);
      readb go fd s ofs len (fun l -> mv.read <- None; kread l)
	
(* The same applies for the other I/O primitives. *)

let writeb go fd s ofs len k =
  let res, ok =
    try
      Unix.write fd s ofs len, true
    with Unix.Unix_error((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
      -> 0, false
  in 
  if ok then k res
  else begin
    debug "writeb: blocked";
    wfd := fd :: !wfd;
    !io := FdWrite fd;
    writers.(Obj.magic fd) <- Write (go, s, ofs, len, (!io, !ctxt, k));
    term := false
  end

let write fd s ofs len k =
  writeb (ref true) fd s ofs len k

let write_or_take mv fd s ofs len kwrite ktake =
  match mv.v with
  | Some v -> take_mvar mv >>= ktake
  | None ->
      let c   = !ctxt in
      let tio = !io   in
      let go = ref true in
      let mvar_wait v = 
	if !go then begin
	  rem_from_xfd wfd fd;
	  writers.(Obj.magic fd) <- NoWrite;
	  continue (fun () -> ktake v)
	end else
	  mv.v <- Some v;
	terminate ();
      in
      mv.read <- Some(tio, c, mvar_wait);
      writeb go fd s ofs len (fun l -> mv.read <- None; kwrite l)


(* ZZZ check exceptions ?
   check if n = 0 ? no it can happen according to man page *)

let rec really_write o s p l k =
  write o s p l >>= fun n ->
  if l = n then
    yield >>= k (* ZZZ pas besoin yield ? *)
  else
    really_write o s (p+n) (l-n) k

let rec really_write_or_take mv o s p l kwrite ktake =
  write_or_take mv o s p l
    (fun n ->
      if l = n then
	yield >>= kwrite
      else
	really_write_or_take mv o s (p+n) (l-n) kwrite ktake)
    ktake


let acceptb go fd k =
  let (fd', addr), ok =
    try
      Unix.accept fd, true
    with Unix.Unix_error((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
      -> (fd, (Unix.ADDR_UNIX "")), false
  in
  if ok then begin
    Unix.set_nonblock fd';
    k (fd', addr)
  end
  else begin
    debug "acceptb: blocked";
    rfd := fd :: !rfd;
    !io := FdRead fd;
    readers.(Obj.magic fd) <- Accept (go, (!io, !ctxt, k));
    term := false
  end

let accept fd k =
  acceptb (ref true) fd k

let accept_or_take mv fd kaccept ktake =
  match mv.v with
  | Some v -> take_mvar mv >>= ktake
  | None ->
      let c = !ctxt in
      let tio = !io in
      let go = ref true
      in
      let mvar_wait v = 
	if !go then begin
	  rem_from_xfd rfd fd;
	  readers.(Obj.magic fd) <- NoRead;
	  continue (fun () -> ktake v)
	end else
	  mv.v <- Some v;
	terminate ()
      in
      mv.read <- Some(tio, c, mvar_wait);
      acceptb go fd (fun (fd',addr) -> mv.read <- None; kaccept (fd',addr))

let connectb go fd addr k =
  Unix.set_nonblock fd; 
  let ok =
    try
      Unix.connect fd addr; true
    with Unix.Unix_error(Unix.EINPROGRESS,_,_) -> false
  in
  if ok then k ()
  else begin
    debug "connectb: blocked";
    wfd := fd :: !wfd;
    !io := FdWrite fd;
    writers.(Obj.magic fd) <- Connect (go, (!io, !ctxt, k));
    term := false
  end

let connect fd addr k =
  connectb (ref true) fd addr k

let connect_or_take mv fd addr kconnect ktake =
  match mv.v with
  | Some v -> take_mvar mv >>= ktake
  | None   ->
      let c   = !ctxt in
      let tio = !io   in
      let go = ref true in
      let mvar_wait v =
	if !go then begin
	  rem_from_xfd wfd fd;
	  writers.(Obj.magic fd) <- NoWrite;
	  continue (fun () -> ktake v)
	end else
	  mv.v <- Some v;
	terminate ()
      in
      mv.read <- Some(tio, c, mvar_wait);
      connectb go fd addr (fun () -> mv.read <- None; kconnect ())


let socket d t p =
  let s = Unix.socket d t p in
  Unix.set_nonblock s;
  s

(* TODO 

   UDP
   sendto

   single\_write plutot que write ?
*)


let recvfrom fd s ofs len l k =
  let res, ok =
    try
      Unix.recvfrom fd s ofs len l, true
    with Unix.Unix_error((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
      -> (0,Unix.ADDR_INET(Unix.inet_addr_any,0)), false
  in if ok then k res
  else begin
    debug "recvfrom: blocked";
    rfd := fd :: !rfd;
    !io := FdRead fd;
    readers.(Obj.magic fd) <- 
      Recvfrom (s, ofs, len, l, (!io, !ctxt, k));
    term := false
  end

(*  
   ZZZ if we protect the Unix.close in a try/with, the select then fails...
 *)

let close fd =
  debug "closing fd";
(*i  Unix.clear_nonblock fd;i*)
(*i  try Unix.close fd with _ -> (); i*)
  Unix.close fd;
  (match writers.(Obj.magic fd) with
  | NoWrite -> ()
  | _ ->
      writers.(Obj.magic fd) <- NoWrite;
      debug "rem wfd";
      rem_from_xfd wfd fd;
      !io := Nofd
  );
  (match readers.(Obj.magic fd) with
  | NoRead -> ()
  | _ -> 
      readers.(Obj.magic fd) <- NoRead;
      debug "rem rfd";
      rem_from_xfd rfd fd;
      !io := Nofd
  );
  dbg_xfd rfd

(*i
let recv fd s ofs len l k =
  let res, ok =
    try
      Unix.recv fd s ofs len l, true
    with Unix.Unix_error((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
      -> 0, false
  in if ok then k res
  else begin
    rfd := fd :: !rfd;
    readers.(Obj.magic fd) <- Recv (s, ofs, len, l, (!alive, !ctxt, k));
    term := false
  end
i*)



(*i
let read fd s ofs len k =
  let res, ok =
    try
      Unix.read fd s ofs len, true
    with Unix.Unix_error((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
      -> 0, false
  in if ok then k res
  else begin
    debug "blocked reading";
    (*if List.mem fd !rfd then debug "fd already in rfd!" else*)
    rfd := fd :: !rfd;
    !io := FdRead fd;
    readers.(Obj.magic fd) <- Read (s, ofs, len, (!io, !ctxt, k));
    term := false
  end
i*)

