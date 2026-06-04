(* eval.ml — high-level evaluator interface
 *
 * Wraps Reduce.step / Reduce.reduce with:
 *   - Trace recording (sequence of intermediate terms)
 *   - Termination diagnostics
 *   - Result reporting in human-readable form
 *)

open Ast
open Reduce

(* A trace of execution: each step records the term before and after. *)
type trace_step = {
  ts_before : term;
  ts_after : term;
}

type result =
  | Done of term * trace_step list  (* reached a normal form *)
  | Stuck of term * trace_step list  (* no further step but not a value *)
  | OutOfFuel of term * trace_step list  (* hit the fuel limit *)

(* Step-by-step reduction with trace.
 * Returns the result plus the chain of intermediate steps.
 *)
let run_with_trace ?(fuel = 1000) ctx t =
  let rec go fuel current trace =
    if fuel <= 0 then OutOfFuel (current, List.rev trace)
    else
      match step ctx current with
      | None ->
          if is_value current then Done (current, List.rev trace)
          else Stuck (current, List.rev trace)
      | Some next ->
          let step_record = { ts_before = current; ts_after = next } in
          go (fuel - 1) next (step_record :: trace)
  in
  go fuel t []

(* Just evaluate without trace. *)
let run ?(fuel = 1000) ctx t = reduce ~fuel ctx t

(* Pretty-print a trace for debugging. *)
let pp_trace trace =
  let buf = Buffer.create 256 in
  List.iteri (fun i step ->
    Buffer.add_string buf
      (Printf.sprintf "Step %d:\n  %s\n  ->  %s\n"
         (i + 1)
         (Pretty.pp_compact step.ts_before)
         (Pretty.pp_compact step.ts_after))
  ) trace;
  Buffer.contents buf

let pp_result result =
  match result with
  | Done (v, trace) ->
      Printf.sprintf "DONE in %d steps. Final value:\n  %s"
        (List.length trace)
        (Pretty.pp_compact v)
  | Stuck (t, trace) ->
      Printf.sprintf "STUCK after %d steps. Final term:\n  %s"
        (List.length trace)
        (Pretty.pp_compact t)
  | OutOfFuel (t, trace) ->
      Printf.sprintf "OUT OF FUEL after %d steps. Last term:\n  %s"
        (List.length trace)
        (Pretty.pp_compact t)
