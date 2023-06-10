(**************************************************************************)
(*                                                                        *)
(*     SMTCoq                                                             *)
(*     Copyright (C) 2011 - 2022                                          *)
(*                                                                        *)
(*     See file "AUTHORS" for the list of authors                         *)
(*                                                                        *)
(*   This file is distributed under the terms of the CeCILL-C licence     *)
(*                                                                        *)
(**************************************************************************)


(* Constr generation and manipulation *)
type id = Names.variable
let mkId = Names.Id.of_string


type name = Names.Name.t
let name_of_id i = Names.Name i
let mkName s =
  let id = mkId s in
  name_of_id id
let string_of_name = function
    Names.Name id -> Names.Id.to_string id
  | _ -> failwith "unnamed rel"


type constr = Constr.t
type types = Constr.types
let eq_constr = Constr.equal
let hash_constr = Constr.hash
let mkProp = Constr.mkProp
let mkConst = Constr.mkConst
let mkVar = Constr.mkVar
let mkRel = Constr.mkRel
let isRel = Constr.isRel
let destRel = Constr.destRel
let lift = Vars.lift
let mkApp = Constr.mkApp
let decompose_app = Constr.decompose_app
let mkLambda (n, t, c) = Constr.mkLambda (Context.make_annot n Sorts.Relevant, t, c)
let mkProd (n, t, c) = Constr.mkProd (Context.make_annot n Sorts.Relevant, t, c)
let mkLetIn (n, c1, t, c2) = Constr.mkLetIn (Context.make_annot n Sorts.Relevant, c1, t, c2)
let mkArrow a b = Term.mkArrow a Sorts.Relevant b

let pr_constr_env env = Printer.pr_constr_env env Evd.empty
let pr_constr = pr_constr_env Environ.empty_env


let mkUConst : Constr.t -> Declare.proof_entry = fun c ->
  let env = Global.env () in
  let evd = Evd.from_env env in
  let evd, ty = Typing.type_of env evd (EConstr.of_constr c) in
  Declare.definition_entry
    ~opaque:false
    ~inline:false
    ~types:(EConstr.Unsafe.to_constr ty) (* Cannot contain evars since it comes from a Constr.t *)
    ~univs:(Evd.univ_entry ~poly:false evd)
    c

let mkTConst c noc ty =
  let env = Global.env () in
  let evd = Evd.from_env env in
  let evd, _ = Typing.type_of env evd (EConstr.of_constr noc) in
  Declare.definition_entry
    ~opaque:false
    ~inline:false
    ~types:ty
    ~univs:(Evd.univ_entry ~poly:false evd)
    c

(* TODO: when switching to econstr, may have universe constraints *)
let empty_named_universes_entry =
  UState.univ_entry ~poly:false UState.empty

(* TODO : Set -> Type *)
let declare_new_type t =
  let _ = ComAssumption.declare_variable Vernacexpr.NoCoercion ~kind:Decls.Definitional Constr.mkSet empty_named_universes_entry [] Glob_term.Explicit (CAst.make t) in
  Constr.mkVar t

let declare_new_variable v constr_t =
  let _ = ComAssumption.declare_variable Vernacexpr.NoCoercion ~kind:Decls.Definitional constr_t empty_named_universes_entry [] Glob_term.Explicit (CAst.make v) in
  Constr.mkVar v

let declare_constant n c =
  Declare.declare_constant ~name:n ~kind:(Decls.IsDefinition Decls.Definition) (Declare.DefinitionEntry c)


type cast_kind = Constr.cast_kind
let vmcast = Constr.VMcast
let mkCast = Constr.mkCast


(* EConstr *)
type econstr = EConstr.t
let econstr_of_constr = EConstr.of_constr


(* Int63 *)
let mkInt : int -> Constr.constr =
  fun i -> Constr.mkInt (Uint63.of_int i)


(* PArray *)
let max_array_size : int = 4194302


(* Traces *)
(* WARNING: side effect on r! *)
let mkTrace step_to_coq next _ clist cnil ccons cpair size step def_step r =
  let rec mkTrace s =
    if s = size then
      mkApp (Lazy.force cnil, [|step|])
    else (
      r := next !r;
      let st = step_to_coq !r in
      mkApp (Lazy.force ccons, [|step; st; mkTrace (s+1)|])
    ) in
  mkApp (Lazy.force cpair, [|mkApp (Lazy.force clist, [|step|]); step; mkTrace 0; def_step|])


(* Micromega *)
module Micromega_plugin_Micromega = Micromega_plugin.Micromega
module Micromega_plugin_Certificate = Micromega_plugin.Certificate

let micromega_dump_proof_term p =
  (* Cannot contain evars *)
  EConstr.Unsafe.to_constr (Micromega_plugin.Coq_micromega.dump_proof_term p)


(* Tactics *)
type tactic = unit Proofview.tactic
let tclTHEN = Tacticals.tclTHEN
let tclTHENLAST = Tacticals.tclTHENLAST
let assert_before n c = Tactics.assert_before n (EConstr.of_constr c)

let vm_cast_no_check c = Tactics.vm_cast_no_check (EConstr.of_constr c)

let mk_tactic tac =
  Proofview.Goal.enter (fun gl ->
    let env = Proofview.Goal.env gl in
    let sigma = Tacmach.project gl in
    let t = Proofview.Goal.concl gl in
    let t = EConstr.to_constr sigma t in (* The goal should not contain uninstanciated evars *)
    tac env sigma t
  )
let set_evars_tac noc =
  mk_tactic (
      fun env sigma _ ->
      let sigma, _ = Typing.type_of env sigma (EConstr.of_constr noc) in
      Proofview.Unsafe.tclEVARS sigma)


(* Other differences between the two versions of Coq *)
type constr_expr = Constrexpr.constr_expr
let error s = CErrors.user_err (Pp.str s)
let anomaly s = CErrors.anomaly (Pp.str s)
let warning n s = CWarnings.create ~name:n ~category:"SMTCoq plugin" Pp.str s

let destruct_rel_decl r = Context.Rel.Declaration.get_name r,
                          Context.Rel.Declaration.get_type r

(* Cannot contain evars since it comes from a Constr.t *)
let interp_constr env sigma t = Constrintern.interp_constr env sigma t |> fst |> EConstr.Unsafe.to_constr

let ppconstr_lsimpleconstr = Ppconstr.lsimpleconstr

let constrextern_extern_constr c =
  let env = Global.env () in
  Constrextern.extern_constr ~inctx:false env (Evd.from_env env) (EConstr.of_constr c)

let get_rel_dec_name = function
  | Context.Rel.Declaration.LocalAssum (n, _) | Context.Rel.Declaration.LocalDef (n, _, _) ->
     Context.binder_name n

let retyping_get_type_of env sigma c =
  (* Cannot contain evars since it comes from a Constr.t *)
  EConstr.Unsafe.to_constr (Retyping.get_type_of env sigma (EConstr.of_constr c))

let vm_conv = Vconv.vm_conv

(* Cannot contain evars since it comes from a Constr.t *)
let cbv_vm env c t = EConstr.Unsafe.to_constr (Vnorm.cbv_vm env Evd.empty (EConstr.of_constr c) (EConstr.of_constr t))
