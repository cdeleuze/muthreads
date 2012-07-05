open Muthr


(*s Retry functions *)

(* Each retry function takes a thread procedure as argument, whose
   'return' value (passed to its continuation) is None if it failed
   (and so should be retried) or Some of its result.

   It should raise exception Failed if it definitely failed (don't
   want to be retried).

 *)

exception Failed

(* Retry at most n times. *)

let retry n p kfail k =
  let rec loop i k =
    if i = 0 then raise Failed
    else
      p >>= fun res ->
      match res with
      | Some r -> k (Some r)
      | None -> loop (i-1) k
  in
  trywithk
    (fun k () -> loop n k)
    (fun k _ -> k None)
    (fun r -> match r with
    | Some r -> k r | None -> kfail ())

(* Same as retry, but raise exception [ex] if failure *)

let retryex ex n p k =
  retry n p (fun () -> raise ex) k


(* Retry forever... *)

let retry_forever p kfail k =
  let rec loop k =
    p >>= fun res ->
    match res with
    | Some r -> k r
    | None -> loop k
  in
  trywithk
    (fun k () -> loop k)
    (fun k Failed -> kfail ())
    k
(* ZZZ *)

(* Retry for at most a given time. Number of retries is not
   limited. *)

let retry_tm tm p ktm k =
  timeoutk tm
    (fun k () -> retry_forever p ktm k)
    ktm
    k

(* Retry n times, with a tm timeout each time *)

let retry_n_tm n tm p kfail k =
  retry n
    (fun k ->
      timeoutk tm
	p
	(fun () -> k  None)
	(fun r  -> k (Some r)))
    kfail
    k

(* Retry n times, with a backoff timeout: its initial value is [tm]
   and is multiplied by [bo] at each retry. *)

let retry_n_tm_backoff n tm bo p kfail k =
  let tm = ref tm
  in
  retry n
    (fun k ->
      timeoutk !tm
	p
	(fun () -> tm := !tm *. bo; k  None)
	(fun r  -> k (Some r)))
    kfail
    k

(* Retry for all members of a list *)

let retry_list l p kfail k =
  let rec loop l k =
    match l with
    | []   -> raise Failed
    | h::t ->
	p h >>= fun res ->
	match res with
	| Some r -> k (Some r)
	| None   -> loop t k
  in
  trywithk
    (fun k () -> loop l k)
    (fun k Failed -> k None)
    (fun r -> match r with
    | Some r -> k r | None -> kfail ())

(* Retry for a list, with a tm timeout each time *)

let retry_list_tm l tm p kfail k =
  retry_list l
    (fun h k ->
      timeoutk tm
	(p h)
	(fun () -> k None)
	(fun r  -> k r))
    kfail
    k
