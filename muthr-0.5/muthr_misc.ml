

(*

*)

let log_file = ref stdout


let string_of_date t =
  let t = Unix.localtime t in
  Printf.sprintf "%02d/%02d/%02d %02d:%02d:%02d" t.Unix.tm_mday
    (t.Unix.tm_mon + 1) (t.Unix.tm_year mod 100) t.Unix.tm_hour
    t.Unix.tm_min t.Unix.tm_sec

let date_string () = 
  string_of_date (Unix.time ())

let log msg =
  output_string !log_file (date_string () ^ " " ^ msg ^ "\n");
  flush !log_file
    

let open_log name =
  log_file := open_out_gen [ Open_creat; Open_append ] 0o644 name;
  log "Opening"

let close_log () =
  log "Closing";
  close_out !log_file;
  log_file := stdout
