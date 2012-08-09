(* Dataflow module for use with the ocamlgraph library
   @author Ivan Jager

   XXX: MakeWide should be the 'main' functor, since Make can be
   implemented by adding a default widening operator.

*)

open Util
open BatListFull
module D = Debug.Make(struct let name = "GraphDataflow" and default = `NoDebug end)
open D

module type G =
sig
  type t
  module V : Graph.Sig.COMPARABLE
  module E : Graph.Sig.EDGE with type vertex = V.t
  val pred_e : t -> V.t -> E.t list
  val succ_e : t -> V.t -> E.t list
  val fold_vertex : (V.t -> 'a -> 'a) -> t -> 'a -> 'a
end


(** dataflow directions *)
type direction = Forward | Backward


module type BOUNDED_MEET_SEMILATTICE =
sig
  type t
  val top : t
  val meet : t -> t -> t
  val equal : t -> t -> bool
end

module type BOUNDED_MEET_SEMILATTICE_WITH_WIDENING =
sig
  include BOUNDED_MEET_SEMILATTICE
  val widen : t -> t -> t
end

(* a dataflow is defined by a lattice over a graph. *)
module type DATAFLOW =
sig

  module L : BOUNDED_MEET_SEMILATTICE
  module G : G

  val node_transfer_function : G.t -> G.V.t -> L.t -> L.t
  val edge_transfer_function : G.t -> G.E.t -> L.t -> L.t
  val s0 : G.t -> G.V.t
  val init : G.t -> L.t
  val dir : direction
end

module type DATAFLOW_WITH_WIDENING =
sig

  module L : BOUNDED_MEET_SEMILATTICE_WITH_WIDENING
  module G : G

  val node_transfer_function : G.t -> G.V.t -> L.t -> L.t
  val edge_transfer_function : G.t -> G.E.t -> L.t -> L.t
  val s0 : G.t -> G.V.t
  val init : G.t -> L.t
  val dir : direction
end


module Make (D:DATAFLOW) = 
struct
  module H = Hashtbl.Make(D.G.V)

 let worklist_iterate ?(init = D.init) g = 
    let nodes = D.G.fold_vertex (fun x acc -> x::acc) g [] in
    let f_t = D.node_transfer_function g in 
    let succ_e,pred_e,dst,src = match D.dir with
      | Forward ->
	  (D.G.succ_e g, D.G.pred_e g,
           D.G.E.dst, D.G.E.src)
      | Backward ->
	  (D.G.pred_e g, D.G.succ_e g,
           D.G.E.src, D.G.E.dst)
    in
    let htin = H.create (List.length nodes) in
    let dfin = H.find htin in (* function to be returned *)
    let htout = H.create (List.length nodes) in
    let dfout n =
      try
	H.find htout n
      with Not_found ->
	let out = (f_t n (dfin n)) in
	H.add htout n out;
	out
    in
    List.iter (fun n -> H.add htin n D.L.top) nodes;
    H.replace htin (D.s0 g) (init g);
    let rec do_work = function
      | [] -> ()
      | b::worklist ->  
	  let inset = (dfin b) in 
	  let outset = (f_t b inset) in 
	  H.replace htout b outset;
	  let affected_edges =
	    List.filter 
	      (fun se ->
                let s = dst se in
                (* Apply edge transfer function *)
                let outset' = D.edge_transfer_function g se outset in
		let oldin = dfin s in
		let newin = D.L.meet oldin outset' in
		if D.L.equal oldin newin
		then false
		else let () = H.replace htin s newin in true
	      )
	      (succ_e b)
	  in
          let affected_elems = List.map dst affected_edges in
	  let newwklist = worklist@list_difference affected_elems worklist
	  in
	  do_work newwklist
    in
    do_work [D.s0 g];
    (dfin, dfout)

end

module MakeWide (D:DATAFLOW_WITH_WIDENING) = 
struct
  include Make(D)

 let worklist_iterate_widen ?(init = D.init) ?(nmeets=0) g = 
    let nodes = D.G.fold_vertex (fun x acc -> x::acc) g [] in
    let f_t = D.node_transfer_function g in 
    let succ_e,pred_e,dst,src = match D.dir with
      | Forward ->
	  (D.G.succ_e g, D.G.pred_e g,
           D.G.E.dst, D.G.E.src)
      | Backward ->
	  (D.G.pred_e g, D.G.succ_e g,
           D.G.E.src, D.G.E.dst)
    in
    let htin = H.create (List.length nodes) in
    let dfin = H.find htin in (* function to be returned *)
    let htout = H.create (List.length nodes) in
    let dfout n =
      try
	H.find htout n
      with Not_found ->
	let out = (f_t n (dfin n)) in
	H.add htout n out;
	out
    in
    let visited = H.create (List.length nodes) in
    let backedge = Hashtbl.create (List.length nodes) in
    let is_backedge s d =
      try Hashtbl.find backedge (s,d)
      with Not_found ->
        (* self loop, or we visited the destination edge already *)
        let v = D.G.V.equal s d || (H.mem visited s = false && H.mem visited d = true) in
        Hashtbl.add backedge (s,d) v;
        v
    in
    let counth = Hashtbl.create (List.length nodes) in
    let count s d =
      let n = (try Hashtbl.find counth (s,d) with Not_found -> 0)+1 in
      let () = Hashtbl.replace counth (s,d) n in
      n
    in
    List.iter (fun n -> H.add htin n D.L.top) nodes;
    H.replace htin (D.s0 g) (init g);
    let rec do_work = function
      | [] -> ()
      | b::worklist ->  
	  let inset = (dfin b) in 
	  let outset = (f_t b inset) in 
	  H.replace htout b outset;
	  let affected_edges =
	    List.filter 
	      (fun se ->
                let s = dst se in
                (* Apply edge transfer function *)
                let outset' = D.edge_transfer_function g se outset in
		let oldin = dfin s in
		let newin = D.L.meet oldin outset' in
		if D.L.equal oldin newin
		then false
		else
                  let newin =
                    if is_backedge b s && count b s > nmeets
                    then (dprintf "widening"; D.L.widen oldin outset')
                    else newin
                  in
                  let () = H.replace htin s newin in
                  true)
	      (succ_e b)
	  in
          let affected_elems = List.map dst affected_edges in
          (* Note we must mark b as visited after we look at the
             affected elements, because we look for back edges there. *)
          H.replace visited b ();
          dprintf "visited";
	  let newwklist = worklist@list_difference affected_elems worklist
	  in
	  do_work newwklist
    in
    do_work [D.s0 g];
    (dfin, dfout)

end
