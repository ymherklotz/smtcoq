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


Require Import Bool Uint63 PArray.
Require Import Misc State SMT_terms.
Require Import Syntactic Arithmetic Operators Assumptions.
Require Import Cnf Euf Lia BVList Bva_checker Array_checker.

Local Open Scope array_scope.
Local Open Scope uint63_scope.

Set Implicit Arguments.
Unset Strict Implicit.
Set Vm Optimize.
Section trace.

  (* We are given a certificate, a checker for it (that modifies a
     state), and a proof that the checker is correct: the state it
     returns must be valid and well-formed. *)

  Variable step : Type.

  Variable check_step : S.t -> step -> S.t.

  Variable rho : Valuation.t.

  Definition _trace_ := ((list step) * step)%type.

  (* A checker for such a trace *)

  Variable is_false : C.t -> bool.
  Hypothesis is_false_correct : forall c, is_false c -> ~ C.interp rho c.

  Definition _checker_ (s: S.t) (t: _trace_) (confl:clause_id) : bool :=
    let s' := List.fold_left check_step (fst t) s in
    (* let s' := PArray.fold_left (fun s a => PArray.fold_left check_step s a) s t in *)
    is_false (S.get s' confl).
  (* Register _checker_ as PrimInline. *)

  (* For debugging *)
  (*
  Variable check_step_debug : S.t -> step -> option S.t.
  Definition _checker_debug_ (s: S.t) (t: _trace_) : sum S.t ((int*int)*S.t) :=
    let s' := PArray.foldi_left (fun i s a => PArray.foldi_left (fun j s' a' =>
      match s' with
        | inl s'' =>
          match check_step_debug s'' a' with
            | Some s''' => inl s'''
            | None => inr ((i,j),s'')
          end
        | u => u
      end) s a) (inl s) t in
    s'.
  Definition _checker_partial_ (s: S.t) (t: _trace_) (max:int) : S.t :=
    PArray.fold_left (fun s a => PArray.foldi_left (fun i s' a' => if i <? max then check_step s' a' else s') s a) s t.
  *)

  (* Proof of its partial correction: if it returns true, then the
     initial state is not valid *)

  Hypothesis valid_check_step :
    forall s, S.valid rho s -> forall c, S.valid rho (check_step s c).

  Lemma _checker__correct :
    forall s, forall t confl, _checker_ s t confl-> ~ (S.valid rho s).
  Proof.
    unfold _checker_.
    intros s t' cid Hf Hv.
    apply (is_false_correct Hf).
    apply S.valid_get.
    clear Hf.
    rewrite <- List.fold_left_rev_right in *.
    induction (List.rev (fst t')); [ apply Hv | ].
    apply valid_check_step.
    apply IHl.
    (* apply PArray.fold_left_ind; auto. *)
    (* intros a i _ Ha;apply PArray.fold_left_ind;trivial. *)
    (* intros a0 i0 _ H1;auto. *)
  Qed.

End trace.


(* Application to resolution *)

Module Sat_Checker.

 Inductive step :=
   | Res (_:int) (_:resolution).

(*
 Parameters (s s': (list _lit) -> bool) (t: (array (list _lit))) (i: int) (r: resolution).
 Check (fun s (st:step) => let (pos, r) := st in S.set_resolve s pos r).
 Check (_checker_ (fun s' (st:step) => let (pos, r) := st in S.set_resolve s' pos r) s t).
*)

 Definition resolution_checker s t :=
   _checker_ (fun s (st:step) => let (pos, r) := st in S.set_resolve s pos r) s t.

 Lemma resolution_checker_correct :
    forall rho, Valuation.wf rho ->
    forall s t cid, resolution_checker C.is_false s t cid->
     ~S.valid rho s.
 Proof.
   intros rho Hwr; apply _checker__correct.
   intros; apply C.is_false_correct; trivial.
   intros s Hv (pos, r); apply S.valid_set_resolve; trivial.
 Qed.

 (** Application to Zchaff *)
 Definition dimacs := PArray.array (PArray.array _lit).

 Definition C_interp_or rho c :=
   afold_left _ false orb (amap (Lit.interp rho) c).

 Lemma C_interp_or_spec : forall rho c,
   C_interp_or rho c = C.interp rho (to_list c).
 Proof.
   intros rho c; unfold C_interp_or; case_eq (C.interp rho (to_list c)).
   unfold C.interp; rewrite List.existsb_exists; intros [x [H1 H2]]; destruct (In_to_list _ _ H1) as [i [H3 H4]]; subst x; apply (afold_left_orb_true i); rewrite ?length_amap,?get_amap;auto.
   unfold C.interp; intro H; apply afold_left_orb_false; rewrite length_amap; intros i H1; rewrite get_amap; case_eq (Lit.interp rho (c .[ i])); auto; intro Heq; assert (H2: exists x, List.In x (to_list c) /\ Lit.interp rho x = true).
   exists (c.[i]); split; auto; apply to_list_In; auto.
   rewrite <- List.existsb_exists in H2; rewrite H2 in H; auto.
Qed.

 Definition valid rho (d:dimacs) :=
   afold_left _ true andb (amap (C_interp_or rho) d).

 Lemma valid_spec : forall rho d,
   valid rho d <->
   (forall i : int, i <? length d -> C.interp rho (to_list (d.[i]))).
 Proof.
   unfold valid; intros rho d; split; intro H.
   intros i Hi; case_eq (C.interp rho (to_list (d .[ i]))); try reflexivity.
   intro Heq; erewrite afold_left_andb_false in H; rewrite ?length_amap, ?get_amap; try eassumption.
   rewrite C_interp_or_spec; auto.
   apply afold_left_andb_true; rewrite length_amap; intros i Hi; rewrite get_amap, C_interp_or_spec by assumption; apply H; auto.
 Qed.

 Inductive certif :=
   | Certif : int -> _trace_ step -> clause_id -> certif.

 Definition add_roots s (d:dimacs) :=
   foldi (fun i s => S.set_clause s i (to_list (d.[i]))) 0 (length d) s.

 Definition checker (d:dimacs) (c:certif) :=
   let (nclauses, t, confl_id) := c in
   resolution_checker C.is_false (add_roots (S.make nclauses) d) t confl_id.

 Lemma valid_add_roots : forall rho, Valuation.wf rho ->
    forall d s, valid rho d -> S.valid rho s ->
    S.valid rho (add_roots s d).
 Proof.
   intros rho Hwr d s Hd Hs; unfold add_roots.
apply (foldi_ind _ (fun _ a => S.valid rho a)); [ apply leb_0 | | ]; auto; intros i a _ Hle Hv; apply S.valid_set_clause; auto; rewrite valid_spec in Hd; apply Hd; auto.
 Qed.

 Lemma checker_correct : forall d c,
    checker d c = true ->
    forall rho, Valuation.wf rho -> ~ valid rho d.
 Proof.
   unfold checker; intros d (nclauses, t, confl_id) Hc rho Hwf Hv.
   apply (resolution_checker_correct Hwf Hc).
   apply valid_add_roots; auto.
   apply S.valid_make; auto.
 Qed.

 Definition interp_var rho x :=
   match compare x 1 with
   | Lt => true
   | Eq => false
   | Gt => rho (x - 1)
     (* This allows to have variable starting at 1 in the interpretation as in dimacs files *)
   end.

 Lemma theorem_checker :
   forall d c,
     checker d c = true ->
     forall rho, ~ (valid (interp_var rho) d).
 Proof.
   intros d c H rho;apply checker_correct with c;trivial.
   split;compute;trivial;discriminate.
 Qed.

End Sat_Checker.


Module Cnf_Checker.

  Inductive step :=
  | Res (pos:int) (res:resolution)
  | ImmFlatten (pos:int) (cid:clause_id) (lf:_lit)
  | CTrue (pos:int)
  | CFalse (pos:int)
  | BuildDef (pos:int) (l:_lit)
  | BuildDef2 (pos:int) (l:_lit)
  | BuildProj (pos:int) (l:_lit) (i:int)
  | ImmBuildDef (pos:int) (cid:clause_id)
  | ImmBuildDef2 (pos:int) (cid:clause_id)
  | ImmBuildProj (pos:int) (cid:clause_id) (i:int).

  Local Open Scope list_scope.

  Local Notation check_flatten t_form := (check_flatten t_form (fun i1 i2 => i1 =? i2) (fun _ _ => false)) (only parsing).

  Definition step_checker t_form s (st:step) :=
    match st with
    | Res pos res => S.set_resolve s pos res
    | ImmFlatten pos cid lf => S.set_clause s pos (check_flatten t_form s cid lf)
    | CTrue pos => S.set_clause s pos Cnf.check_True
    | CFalse pos => S.set_clause s pos Cnf.check_False
    | BuildDef pos l => S.set_clause s pos (check_BuildDef t_form l)
    | BuildDef2 pos l => S.set_clause s pos (check_BuildDef2 t_form l)
    | BuildProj pos l i => S.set_clause s pos (check_BuildProj t_form l i)
    | ImmBuildDef pos cid => S.set_clause s pos (check_ImmBuildDef t_form s cid)
    | ImmBuildDef2 pos cid => S.set_clause s pos (check_ImmBuildDef2 t_form s cid)
    | ImmBuildProj pos cid i => S.set_clause s pos (check_ImmBuildProj t_form s cid i)
    end.

  Lemma step_checker_correct : forall rho rhobv t_form,
    Form.check_form t_form ->
    forall s, S.valid (Form.interp_state_var rho rhobv t_form) s ->
      forall st : step, S.valid (Form.interp_state_var rho rhobv t_form)
        (step_checker t_form s st).
  Proof.
    intros rho rhobv t_form Ht s H; destruct (Form.check_form_correct rho rhobv _ Ht) as [[Ht1 Ht2] Ht3]; intros [pos res|pos cid lf|pos|pos|pos l|pos l|pos l i|pos cid|pos cid|pos cid i]; simpl; try apply S.valid_set_clause; auto.
    apply S.valid_set_resolve; auto.
    apply valid_check_flatten; auto; try discriminate; intros a1 a2; unfold is_true; rewrite Uint63.eqb_spec; intro; subst a1; auto.
    apply valid_check_True; auto.
    apply valid_check_False; auto.
    apply valid_check_BuildDef; auto.
    apply valid_check_BuildDef2; auto.
    apply valid_check_BuildProj; auto.
    apply valid_check_ImmBuildDef; auto.
    apply valid_check_ImmBuildDef2; auto.
    apply valid_check_ImmBuildProj; auto.
  Qed.

  Definition cnf_checker t_form s t :=
    _checker_ (step_checker t_form) s t.

  Lemma cnf_checker_correct : forall rho rhobv t_form,
    Form.check_form t_form -> forall s t confl,
      cnf_checker t_form C.is_false s t confl ->
      ~ (S.valid (Form.interp_state_var rho rhobv t_form) s).
  Proof.
    unfold cnf_checker; intros rho rhobv t_form Ht; apply _checker__correct.
    intros c H; apply C.is_false_correct; auto.
    apply step_checker_correct; auto.
  Qed.


 Inductive certif :=
   | Certif : int -> _trace_ step -> int -> certif.

 Definition checker t_form l (c:certif) :=
   let (nclauses, t, confl) := c in
   Form.check_form t_form &&
                   cnf_checker t_form C.is_false (S.set_clause (S.make nclauses) 0 (l::nil)) t confl.

 Lemma checker_correct : forall t_form l c,
    checker t_form l c = true ->
    forall rho rhobv, ~ (Lit.interp (Form.interp_state_var rho rhobv t_form) l).
 Proof.
   unfold checker; intros t_form l (nclauses, t, confl); unfold is_true; rewrite andb_true_iff; intros [H1 H2] rho rhobv H; apply (cnf_checker_correct (rho:=rho) (rhobv:=rhobv) H1 H2); destruct (Form.check_form_correct rho rhobv _ H1) as [[Ht1 Ht2] Ht3]; apply S.valid_set_clause; auto.
   apply S.valid_make; auto.
   unfold C.valid; simpl; rewrite H; auto.
 Qed.

 Definition checker_b t_form l (b:bool) (c:certif) :=
   let l := if b then Lit.neg l else l in
   checker t_form l c.

 Lemma checker_b_correct : forall t_var t_form l b c,
    checker_b t_form l b c = true ->
    Lit.interp (Form.interp_state_var (PArray.get t_var) (fun _ s => BITVECTOR_LIST.zeros s) t_form) l = b.
 Proof.
   unfold checker_b; intros t_var t_form l b c; case b; case_eq (Lit.interp (Form.interp_state_var (get t_var) (fun _ s => BITVECTOR_LIST.zeros s) t_form) l); auto with smtcoq_core; intros H1 H2; elim (checker_correct H2 (rho:=get t_var) (rhobv:=fun _ s => BITVECTOR_LIST.zeros s)); auto with smtcoq_core; rewrite Lit.interp_neg, H1; auto with smtcoq_core.
 Qed.

 Definition checker_eq t_form l1 l2 l (c:certif) :=
   negb (Lit.is_pos l) &&
   match t_form.[Lit.blit l] with
   | Form.Fiff l1' l2' => (l1 =? l1') && (l2 =? l2')
   | _ => false
   end &&
   checker t_form l c.

 Lemma checker_eq_correct : forall t_var t_form l1 l2 l c,
   checker_eq t_form l1 l2 l c = true ->
    Lit.interp (Form.interp_state_var (PArray.get t_var) (fun _ s => BITVECTOR_LIST.zeros s) t_form) l1 =
    Lit.interp (Form.interp_state_var (PArray.get t_var) (fun _ s => BITVECTOR_LIST.zeros s) t_form) l2.
 Proof.
   unfold checker_eq; intros t_var t_form l1 l2 l c; rewrite !andb_true_iff; case_eq (t_form .[ Lit.blit l]); [intros _ _|intros _|intros _|intros _ _ _|intros _ _|intros _ _|intros _ _|intros _ _ _|intros l1' l2' Heq|intros _ _ _ _|intros a ls Heq]; intros [[H1 H2] H3]; try discriminate; rewrite andb_true_iff in H2; rewrite !Uint63.eqb_spec in H2; destruct H2 as [H2 H4]; subst l1' l2'; case_eq (Lit.is_pos l); intro Heq'; rewrite Heq' in H1; try discriminate; clear H1; assert (H:PArray.default t_form = Form.Ftrue /\ Form.wf t_form).
   unfold checker in H3; destruct c as (nclauses, t, confl); rewrite andb_true_iff in H3; destruct H3 as [H3 _]; destruct (Form.check_form_correct (get t_var) (fun _ s => BITVECTOR_LIST.zeros s) _ H3) as [[Ht1 Ht2] Ht3]; split; auto with smtcoq_core.
   destruct H as [H1 H2]; case_eq (Lit.interp (Form.interp_state_var (get t_var) (fun _ s => BITVECTOR_LIST.zeros s) t_form) l1); intro Heq1; case_eq (Lit.interp (Form.interp_state_var (get t_var) (fun _ s => BITVECTOR_LIST.zeros s) t_form) l2); intro Heq2; auto with smtcoq_core; elim (checker_correct H3 (rho:=get t_var) (rhobv:=fun _ s => BITVECTOR_LIST.zeros s)); unfold Lit.interp; rewrite Heq'; unfold Var.interp; rewrite Form.wf_interp_form; auto with smtcoq_core; rewrite Heq; simpl; rewrite Heq1, Heq2; auto with smtcoq_core.
 Qed.

End Cnf_Checker.


(* Application to resolution + cnf justification + euf + lia *)

(* Require Cnf.Cnf. *)
(* Require Euf.Euf. *)
(* Require Lia.Lia. *)

Module Euf_Checker.

  Section Checker.

  Variable t_i : array  SMT_classes.typ_compdec.
  Variable t_func : array (Atom.tval t_i).
  Variable t_atom : array Atom.atom.
  Variable t_form : array Form.form.

Inductive step :=
  | Res (pos:int) (res:resolution)
  | Weaken (pos:int) (cid:clause_id) (cl:list _lit)
  | ImmFlatten (pos:int) (cid:clause_id) (lf:_lit)
  | CTrue (pos:int)
  | CFalse (pos:int)
  | BuildDef (pos:int) (l:_lit)
  | BuildDef2 (pos:int) (l:_lit)
  | BuildProj (pos:int) (l:_lit) (i:int)
  | ImmBuildDef (pos:int) (cid:clause_id)
  | ImmBuildDef2 (pos:int) (cid:clause_id)
  | ImmBuildProj (pos:int) (cid:clause_id) (i:int)
  | EqTr (pos:int) (l:_lit) (fl: list _lit)
  | EqCgr (pos:int) (l:_lit) (fl: list (option _lit))
  | EqCgrP (pos:int) (l1:_lit) (l2:_lit) (fl: list (option _lit))
  | LiaMicromega (pos:int) (cl:list _lit) (c:list ZMicromega.ZArithProof)
  | LiaDiseq (pos:int) (l:_lit)
  | SplArith (pos:int) (orig:clause_id) (res:_lit) (l:list ZMicromega.ZArithProof)
  | SplDistinctElim (pos:int) (orig:clause_id) (res:_lit)
  (* Bit-blasting *)
  | BBVar (pos:int) (res:_lit)
  | BBConst (pos:int) (res:_lit)
  | BBOp (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBNot (pos:int) (orig:clause_id) (res:_lit)
  | BBNeg (pos:int) (orig:clause_id) (res:_lit)
  | BBAdd (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBConcat (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBMul (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBUlt (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBSlt (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBEq (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBDiseq (pos:int) (res:_lit)
  | BBExtract (pos:int) (orig:clause_id) (res:_lit)
  | BBZextend (pos:int) (orig:clause_id) (res:_lit)
  | BBSextend (pos:int) (orig:clause_id) (res:_lit)
  | BBShl (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBShr (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | RowEq (pos:int) (res: _lit)
  | RowNeq (pos:int) (cl: C.t)
  | Ext (pos:int) (res: _lit)
  (* Offer the possibility to discharge parts of the proof to (manual) Coq proofs.
     This breaks extraction, which is what the extractable version of
     the checker is now in a separate module. *)
  | Hole (pos:int) (prem_id:list clause_id) (prem:list C.t) (concl:C.t)
    (p:interp_conseq_uf (Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form) prem concl)
  | ForallInst (pos:int) (lemma:Prop) (plemma:lemma) (concl:C.t)
    (p: lemma -> interp_conseq_uf (Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form) nil concl)
  .

  Local Open Scope list_scope.

  Local Notation check_flatten t_atom t_form := (check_flatten t_form (check_hatom t_atom) (check_neg_hatom t_atom)) (only parsing).

  Definition step_checker s (st:step) :=
    match st with
      | Res pos res => S.set_resolve s pos res
      | Weaken pos cid cl => S.set_weaken s pos cid cl
      | ImmFlatten pos cid lf => S.set_clause s pos (check_flatten t_atom t_form s cid lf)
      | CTrue pos => S.set_clause s pos Cnf.check_True
      | CFalse pos => S.set_clause s pos Cnf.check_False
      | BuildDef pos l => S.set_clause s pos (check_BuildDef t_form l)
      | BuildDef2 pos l => S.set_clause s pos (check_BuildDef2 t_form l)
      | BuildProj pos l i => S.set_clause s pos (check_BuildProj t_form l i)
      | ImmBuildDef pos cid => S.set_clause s pos (check_ImmBuildDef t_form s cid)
      | ImmBuildDef2 pos cid => S.set_clause s pos (check_ImmBuildDef2 t_form s cid)
      | ImmBuildProj pos cid i => S.set_clause s pos (check_ImmBuildProj t_form s cid i)
      | EqTr pos l fl => S.set_clause s pos (check_trans t_form t_atom l fl)
      | EqCgr pos l fl => S.set_clause s pos (check_congr t_form t_atom l fl)
      | EqCgrP pos l1 l2 fl => S.set_clause s pos (check_congr_pred t_form t_atom l1 l2 fl)
      | LiaMicromega pos cl c => S.set_clause s pos (check_micromega t_form t_atom cl c)
      | LiaDiseq pos l => S.set_clause s pos (check_diseq t_form t_atom l)
      | SplArith pos orig res l => S.set_clause s pos (check_spl_arith t_form t_atom (S.get s orig) res l)
      | SplDistinctElim pos orig res => S.set_clause s pos (check_distinct_elim t_form t_atom (S.get s orig) res)
      | BBVar pos res => S.set_clause s pos (check_bbVar t_atom t_form res)
      | BBConst pos res => S.set_clause s pos (check_bbConst t_atom t_form res)
      | BBOp pos orig1 orig2 res => S.set_clause s pos (check_bbOp t_atom t_form s orig1 orig2 res)
      | BBNot pos orig res => S.set_clause s pos (check_bbNot t_atom t_form s orig res)
      | BBNeg pos orig res => S.set_clause s pos (check_bbNeg t_atom t_form s orig res)
      | BBAdd pos orig1 orig2 res => S.set_clause s pos (check_bbAdd t_atom t_form s orig1 orig2 res)
      | BBConcat pos orig1 orig2 res => S.set_clause s pos (check_bbConcat t_atom t_form s orig1 orig2 res)
      | BBMul pos orig1 orig2 res => S.set_clause s pos (check_bbMult t_atom t_form s orig1 orig2 res)
      | BBUlt pos orig1 orig2 res => S.set_clause s pos (check_bbUlt t_atom t_form s orig1 orig2 res)
      | BBSlt pos orig1 orig2 res => S.set_clause s pos (check_bbSlt t_atom t_form s orig1 orig2 res)
      | BBEq pos orig1 orig2 res => S.set_clause s pos (check_bbEq t_atom t_form s orig1 orig2 res)
      | BBDiseq pos res => S.set_clause s pos (check_bbDiseq t_atom t_form res)
      | BBExtract pos orig res => S.set_clause s pos (check_bbExtract t_atom t_form s orig res)
      | BBZextend pos orig res => S.set_clause s pos (check_bbZextend t_atom t_form s orig res)
      | BBSextend pos orig res => S.set_clause s pos (check_bbSextend t_atom t_form s orig res)
      | BBShl pos orig1 orig2 res => S.set_clause s pos (check_bbShl t_atom t_form s orig1 orig2 res)
      | BBShr pos orig1 orig2 res => S.set_clause s pos (check_bbShr t_atom t_form s orig1 orig2 res)
      | RowEq pos res => S.set_clause s pos (check_roweq t_form t_atom res)
      | RowNeq pos cl => S.set_clause s pos (check_rowneq t_form t_atom cl)
      | Ext pos res => S.set_clause s pos (check_ext t_form t_atom res)
      | @Hole pos prem_id prem concl _ => S.set_clause s pos (check_hole s prem_id prem concl)
      | @ForallInst pos lemma _ concl  _ => S.set_clause s pos concl
    end.

  (* Opaque S.set_weaken. *)

  Lemma step_checker_correct :
    let rho := Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form in
      Form.check_form t_form -> Atom.check_atom t_atom ->
      Atom.wt t_i t_func t_atom ->
      forall s, S.valid rho s ->
        forall st : step, S.valid rho (step_checker s st).
  Proof.
    set (empty_bv := (fun (a:Atom.atom) s => BITVECTOR_LIST.zeros s)).
    intros rho H1 H2 H10 s Hs. destruct (Form.check_form_correct (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) _ H1)
    as [[Ht1 Ht2] Ht3]. destruct (Atom.check_atom_correct _ H2) as
    [Ha1 Ha2]. intros [pos res|pos cid c|pos cid lf|pos|pos|pos l|pos l|pos l i|pos cid
    |pos cid|pos cid i|pos l fl|pos l fl|pos l1 l2 fl|pos cl c|pos l|pos orig res l
    |pos orig res|pos res|pos res|pos orig1 orig2 res|pos orig res|pos orig res
    |pos orig1 orig2 res|pos orig1 orig2 res
    |pos orig1 orig2 res|pos orig1 orig2 res|pos orig1 orig2 res|pos orig1 orig2 res
    |pos cl |pos orig res |pos orig res |pos orig res | pos orig1 orig2 res | pos orig1 orig2 res |pos res|pos res
    |pos res |pos prem_id prem concl p|pos lemma plemma concl p]; simpl; try apply S.valid_set_clause; auto with smtcoq_core.
    - apply S.valid_set_resolve; auto with smtcoq_core.
    - apply S.valid_set_weaken; auto with smtcoq_core.
    - apply valid_check_flatten; auto with smtcoq_core; intros h1 h2 H.
      + rewrite (Syntactic.check_hatom_correct_bool _ _ _ Ha1 Ha2 _ _ H); auto with smtcoq_core.
      + rewrite (Syntactic.check_neg_hatom_correct_bool _ _ _ H10 Ha1 Ha2 _ _ H); auto with smtcoq_core.
    - apply valid_check_True; auto with smtcoq_core.
    - apply valid_check_False; auto with smtcoq_core.
    - apply valid_check_BuildDef; auto with smtcoq_core.
    - apply valid_check_BuildDef2; auto with smtcoq_core.
    - apply valid_check_BuildProj; auto with smtcoq_core.
    - apply valid_check_ImmBuildDef; auto with smtcoq_core.
    - apply valid_check_ImmBuildDef2; auto with smtcoq_core.
    - apply valid_check_ImmBuildProj; auto with smtcoq_core.
    - apply valid_check_trans; auto with smtcoq_core.
    - apply valid_check_congr; auto with smtcoq_core.
    - apply valid_check_congr_pred; auto with smtcoq_core.
    - apply valid_check_micromega; auto with smtcoq_core.
    - apply valid_check_diseq; auto with smtcoq_core.
    - apply valid_check_spl_arith; auto with smtcoq_core.
    - apply valid_check_distinct_elim; auto with smtcoq_core.
    - eapply valid_check_bbVar; eauto with smtcoq_core.
    - apply valid_check_bbConst; auto with smtcoq_core.
    - apply valid_check_bbOp; auto with smtcoq_core.
    - apply valid_check_bbNot; auto with smtcoq_core.
    - apply valid_check_bbNeg; auto with smtcoq_core.
    - apply valid_check_bbAdd; auto with smtcoq_core.
    - apply valid_check_bbConcat; auto with smtcoq_core.
    - apply valid_check_bbMult; auto with smtcoq_core.
    - apply valid_check_bbUlt; auto with smtcoq_core.
    - apply valid_check_bbSlt; auto with smtcoq_core.
    - apply valid_check_bbEq; auto with smtcoq_core.
    - apply valid_check_bbDiseq; auto with smtcoq_core.
    - apply valid_check_bbExtract; auto with smtcoq_core.
    - apply valid_check_bbZextend; auto with smtcoq_core.
    - apply valid_check_bbSextend; auto with smtcoq_core.
    - apply valid_check_bbShl; auto with smtcoq_core.
    - apply valid_check_bbShr; auto with smtcoq_core.
    - apply valid_check_roweq; auto with smtcoq_core.
    - apply valid_check_rowneq; auto with smtcoq_core.
    - apply valid_check_ext; auto with smtcoq_core.
    - apply valid_check_hole; auto with smtcoq_core.
    - apply valid_check_forall_inst with lemma; auto with smtcoq_core.
  Qed.

  Definition euf_checker (* t_atom t_form *) s t :=
    _checker_ (step_checker (* t_atom t_form *)) s t.

  Lemma euf_checker_correct : (* forall t_i t_func t_atom t_form, *)
    let rho := Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form in
      Form.check_form t_form -> Atom.check_atom t_atom ->
      Atom.wt t_i t_func t_atom ->
      forall s t confl,
        euf_checker (* t_atom t_form *) C.is_false s t confl ->
        ~ (S.valid rho s).
  Proof.
    unfold euf_checker; intros (* t_i t_func t_atom t_form *) rho H1 H2 H10; apply _checker__correct.
    intros c H; apply C.is_false_correct; auto with smtcoq_core.
    apply step_checker_correct; auto with smtcoq_core.
  Qed.

  Inductive certif :=
  | Certif : int -> _trace_ step -> int -> certif.

  Definition add_roots s d used_roots :=
    match used_roots with
      | Some ur => foldi (fun i s =>
        let c := if (ur.[i]) <? length d then (d.[ur.[i]])::nil else C._true in
          S.set_clause s i c) 0 (length ur) s
      | None => foldi (fun i s => S.set_clause s i (d.[i]::nil)) 0 (length d) s
    end.

  Definition valid t_i t_func t_atom t_form d :=
    let rho := Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form in
    afold_left _ true andb (amap (Lit.interp rho) d).

  Lemma add_roots_correct : (* forall t_i t_func t_atom t_form, *)
    let rho := Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form in
      Form.check_form t_form -> Atom.check_atom t_atom ->
      Atom.wt t_i t_func t_atom ->
      forall s d used_roots, S.valid rho s -> valid t_func t_atom t_form d ->
        S.valid rho (add_roots s d used_roots).
  Proof.
    intros (* t_i t_func t_atom t_form *) rho H1 H2 H10 s d used_roots H3; unfold valid; intro H4; pose (H5 := (afold_left_andb_true_inv _ H4)); unfold add_roots; assert (Valuation.wf rho) by (destruct (Form.check_form_correct (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) _ H1) as [_ H]; auto with smtcoq_core); case used_roots.
    intro ur; apply (foldi_ind _ (fun _ a => S.valid rho a)); [ apply leb_0 | | ]; auto with smtcoq_core; intros i a _ H6 Ha; apply S.valid_set_clause; auto with smtcoq_core; case_eq (ur .[ i] <? length d).
    intro; unfold C.valid; simpl; specialize (H5 (ur.[i])); rewrite length_amap, get_amap in H5 by assumption; unfold rho; rewrite H5; auto with smtcoq_core.
    intros; apply C.interp_true; auto with smtcoq_core.
    apply (foldi_ind _ (fun _ a => S.valid rho a)); [ apply leb_0 | | ]; auto with smtcoq_core; intros i a _ H6 Ha; apply S.valid_set_clause; auto with smtcoq_core; unfold C.valid; simpl; specialize (H5 i); rewrite length_amap, get_amap in H5 by assumption; unfold rho; rewrite H5; auto with smtcoq_core.
  Qed.

  Definition checker (* t_i t_func t_atom t_form *) d used_roots (c:certif) :=
    let (nclauses, t, confl) := c in
    Form.check_form t_form && Atom.check_atom t_atom &&
    Atom.wt t_i t_func t_atom &&
    euf_checker (* t_atom t_form *) C.is_false (add_roots (S.make nclauses) d used_roots) t confl.
  Arguments checker d used_roots c : clear implicits.


  Definition setup_checker_step_debug d used_roots (c:certif) :=
    let (nclauses, t, confl) := c in
    let s := add_roots (S.make nclauses) d used_roots in
    (s, fst t).


  Definition position_of_step (st:step) :=
    match st with
      | Res pos _
      | Weaken pos _ _
      | ImmFlatten pos _ _
      | CTrue pos
      | CFalse pos
      | BuildDef pos _
      | BuildDef2 pos _
      | BuildProj pos _ _
      | ImmBuildDef pos _
      | ImmBuildDef2 pos _
      | ImmBuildProj pos _ _
      | EqTr pos _ _
      | EqCgr pos _ _
      | EqCgrP pos _ _ _
      | LiaMicromega pos _ _
      | LiaDiseq pos _
      | SplArith pos _ _ _
      | SplDistinctElim pos _ _
      | BBVar pos _
      | BBConst pos _
      | BBOp pos _ _ _
      | BBNot pos _ _
      | BBNeg pos _ _
      | BBAdd pos _ _ _
      | BBConcat pos _ _ _
      | BBMul pos _ _ _
      | BBUlt pos _ _ _
      | BBSlt pos _ _ _
      | BBEq pos _ _ _
      | BBDiseq pos _
      | BBExtract pos _ _
      | BBZextend pos _ _
      | BBSextend pos _ _
      | BBShl pos _ _ _
      | BBShr pos _ _ _
      | RowEq pos _
      | RowNeq pos _
      | Ext pos _
      | @Hole pos _ _ _ _
      | @ForallInst pos _ _ _ _ => pos
    end.


  Definition checker_step_debug s step_t :=
    let s := step_checker s step_t in
    (s, C.has_true (S.get s (position_of_step step_t))).


  Definition ignore_true_step (st:step) :=
    match st with
    | CTrue _
    (* | Res _ _  *)
    | @Hole _ _ _ _ _ => true
    | _ => false
    end.

  Inductive name_step :=
  | Name_Res
  | Name_Weaken
  | Name_ImmFlatten
  | Name_CTrue
  | Name_CFalse
  | Name_BuildDef
  | Name_BuildDef2
  | Name_BuildProj
  | Name_ImmBuildDef
  | Name_ImmBuildDef2
  | Name_ImmBuildProj
  | Name_EqTr
  | Name_EqCgr
  | Name_EqCgrP
  | Name_LiaMicromega
  | Name_LiaDiseq
  | Name_SplArith
  | Name_SplDistinctElim
  | Name_BBVar
  | Name_BBConst
  | Name_BBOp
  | Name_BBNot
  | Name_BBNeg
  | Name_BBAdd
  | Name_BBConcat
  | Name_BBMul
  | Name_BBUlt
  | Name_BBSlt
  | Name_BBEq
  | Name_BBDiseq
  | Name_BBExtract
  | Name_BBZextend
  | Name_BBSextend
  | Name_BBShl
  | Name_BBShr
  | Name_RowEq
  | Name_RowNeq
  | Name_Ext
  | Name_Hole
  | Name_ForallInst.

  Definition name_of_step (st:step) :=
    match st with
    | Res _ _ => Name_Res
    | Weaken _ _ _ => Name_Weaken
    | ImmFlatten _ _ _ => Name_ImmFlatten
    | CTrue _ => Name_CTrue
    | CFalse _ => Name_CFalse
    | BuildDef _ _ => Name_BuildDef
    | BuildDef2 _ _ => Name_BuildDef2
    | BuildProj _ _ _ => Name_BuildProj
    | ImmBuildDef _ _ => Name_ImmBuildDef
    | ImmBuildDef2 _ _ => Name_ImmBuildDef2
    | ImmBuildProj _ _ _ => Name_ImmBuildProj
    | EqTr _ _ _ => Name_EqTr
    | EqCgr _ _ _ => Name_EqCgr
    | EqCgrP _ _ _ _ => Name_EqCgrP
    | LiaMicromega _ _ _ => Name_LiaMicromega
    | LiaDiseq _ _ => Name_LiaDiseq
    | SplArith _ _ _ _ => Name_SplArith
    | SplDistinctElim _ _ _ => Name_SplDistinctElim
    | BBVar _ _ => Name_BBVar
    | BBConst _ _ => Name_BBConst
    | BBOp _ _ _ _ => Name_BBOp
    | BBNot _ _ _ => Name_BBNot
    | BBNeg _ _ _ => Name_BBNeg
    | BBAdd _ _ _ _ => Name_BBAdd
    | BBConcat _ _ _ _ => Name_BBConcat
    | BBMul _ _ _ _ => Name_BBMul
    | BBUlt _ _ _ _ => Name_BBUlt
    | BBSlt _ _ _ _ => Name_BBSlt
    | BBEq _ _ _ _ => Name_BBEq
    | BBDiseq _ _ => Name_BBDiseq
    | BBExtract _ _ _ => Name_BBExtract
    | BBZextend _ _ _ => Name_BBZextend
    | BBSextend _ _ _ => Name_BBSextend
    | BBShl _ _ _ _ => Name_BBShl
    | BBShr _ _ _ _ => Name_BBShr
    | RowEq _ _ => Name_RowEq
    | RowNeq _ _ => Name_RowNeq
    | Ext _ _ => Name_Ext
    | @Hole _ _ _ _ _ => Name_Hole
    | @ForallInst _ _ _ _ _ => Name_ForallInst
    end.


  Definition checker_debug d used_roots (c:certif) :=
    let (nclauses, t, confl) := c in
    let s := add_roots (S.make nclauses) d used_roots in
    let '(_, nb, failure) :=
        List.fold_left
          (fun acc step =>
             match acc with
             | (s, nb, None) =>
               let nb := S nb in
               let s := step_checker s step in
               if negb (ignore_true_step step) &&
                  C.has_true (S.get s (position_of_step step)) then
                 (s, nb, Some step)
               else (s, nb, None)
             | _ => acc
             end
          ) (fst t) (s, O, None)
    in
    match failure with
    | Some st => Some (nb, name_of_step st)
    | None => None
    end
  .


  Lemma checker_correct : forall (* t_i t_func t_atom t_form *) d used_roots c,
    checker (* t_i t_func t_atom t_form *) d used_roots c = true ->
    ~ (valid t_func t_atom t_form d).
  Proof.
    unfold checker; intros (* t_i t_func t_atom t_form *) d used_roots (nclauses, t, confl); rewrite !andb_true_iff; intros [[[H1 H2] H10] H3] H; eelim euf_checker_correct; try eassumption; apply add_roots_correct; try eassumption; apply S.valid_make; destruct (Form.check_form_correct (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) _ H1) as [_ H4]; auto with smtcoq_core.
  Qed.

  Definition checker_b (* t_i t_func t_atom t_form *) l (b:bool) (c:certif) :=
    let l := if b then Lit.neg l else l in
    let (nclauses,_,_) := c in
    checker (* t_i t_func t_atom t_form *) (PArray.make nclauses l) None c.

  Lemma checker_b_correct : forall (* t_i t_func t_atom t_form *) l b c,
    checker_b (* t_func t_atom t_form *) l b c = true ->
    Lit.interp (Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form) l = b.
  Proof.
   unfold checker_b; intros (* t_i t_func t_atom t_form *) l b (nclauses, t, confl); case b; intros H2; case_eq (Lit.interp (Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form) l); auto with smtcoq_core; intros H1; elim (checker_correct H2); auto with smtcoq_core; unfold valid; apply afold_left_andb_true; rewrite length_amap; intros i Hi; rewrite get_amap by assumption; rewrite get_make; auto with smtcoq_core; rewrite Lit.interp_neg, H1; auto with smtcoq_core.
 Qed.

  Definition checker_eq (* t_i t_func t_atom t_form *) l1 l2 l (c:certif) :=
    negb (Lit.is_pos l) &&
    match t_form.[Lit.blit l] with
      | Form.Fiff l1' l2' => (l1 =? l1') && (l2 =? l2')
      | _ => false
    end &&
    let (nclauses,_,_) := c in
    checker (* t_i t_func t_atom t_form *) (PArray.make nclauses l) None c.

  Lemma checker_eq_correct : forall (* t_i t_func t_atom t_form *) l1 l2 l c,
    checker_eq (* t_func t_atom t_form *) l1 l2 l c = true ->
    Lit.interp (Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form) l1 =
    Lit.interp (Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form) l2.
  Proof.
   unfold checker_eq; intros (* t_i t_func t_atom t_form *) l1 l2 l (nclauses, t, confl); rewrite !andb_true_iff; case_eq (t_form .[ Lit.blit l]); [intros _ _|intros _|intros _|intros _ _ _|intros _ _|intros _ _|intros _ _|intros _ _ _|intros l1' l2' Heq|intros _ _ _ _|intros a ls Heq]; intros [[H1 H2] H3]; try discriminate; rewrite andb_true_iff in H2; rewrite !Uint63.eqb_spec in H2; destruct H2 as [H2 H4]; subst l1' l2'; case_eq (Lit.is_pos l); intro Heq'; rewrite Heq' in H1; try discriminate; clear H1; assert (H:PArray.default t_form = Form.Ftrue /\ Form.wf t_form).
   unfold checker in H3; rewrite !andb_true_iff in H3; destruct H3 as [[[H3 _] _] _]; destruct (Form.check_form_correct (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) _ H3) as [[Ht1 Ht2] Ht3]; split; auto with smtcoq_core.
   destruct H as [H1 H2]; case_eq (Lit.interp (Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form) l1); intro Heq1; case_eq (Lit.interp (Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form) l2); intro Heq2; auto with smtcoq_core; elim (checker_correct H3); unfold valid; apply afold_left_andb_true; rewrite length_amap; intros i Hi; rewrite get_amap by assumption; rewrite get_make; unfold Lit.interp; rewrite Heq'; unfold Var.interp; rewrite Form.wf_interp_form; auto with smtcoq_core; rewrite Heq; simpl; rewrite Heq1, Heq2; auto with smtcoq_core.
 Qed.

  End Checker.

End Euf_Checker.


Unset Implicit Arguments.


(* Register constants for OCaml access *)
Register Sat_Checker.valid as SMTCoq.Trace.Sat_Checker.valid.
Register Sat_Checker.interp_var as SMTCoq.Trace.Sat_Checker.interp_var.
Register Sat_Checker.Certif as SMTCoq.Trace.Sat_Checker.Certif.
Register Sat_Checker.step as SMTCoq.Trace.Sat_Checker.step.
Register Sat_Checker.Res as SMTCoq.Trace.Sat_Checker.Res.
Register Sat_Checker.dimacs as SMTCoq.Trace.Sat_Checker.dimacs.
Register Sat_Checker.certif as SMTCoq.Trace.Sat_Checker.certif.
Register Sat_Checker.theorem_checker as SMTCoq.Trace.Sat_Checker.theorem_checker.
Register Sat_Checker.checker as SMTCoq.Trace.Sat_Checker.checker.

Register Cnf_Checker.certif as SMTCoq.Trace.Cnf_Checker.certif.
Register Cnf_Checker.Certif as SMTCoq.Trace.Cnf_Checker.Certif.
Register Cnf_Checker.checker_b_correct as SMTCoq.Trace.Cnf_Checker.checker_b_correct.
Register Cnf_Checker.checker_b as SMTCoq.Trace.Cnf_Checker.checker_b.
Register Cnf_Checker.checker_eq_correct as SMTCoq.Trace.Cnf_Checker.checker_eq_correct.
Register Cnf_Checker.checker_eq as SMTCoq.Trace.Cnf_Checker.checker_eq.
Register Cnf_Checker.step as SMTCoq.Trace.Cnf_Checker.step.
Register Cnf_Checker.Res as SMTCoq.Trace.Cnf_Checker.Res.
Register Cnf_Checker.ImmFlatten as SMTCoq.Trace.Cnf_Checker.ImmFlatten.
Register Cnf_Checker.CTrue as SMTCoq.Trace.Cnf_Checker.CTrue.
Register Cnf_Checker.CFalse as SMTCoq.Trace.Cnf_Checker.CFalse.
Register Cnf_Checker.BuildDef as SMTCoq.Trace.Cnf_Checker.BuildDef.
Register Cnf_Checker.BuildDef2 as SMTCoq.Trace.Cnf_Checker.BuildDef2.
Register Cnf_Checker.BuildProj as SMTCoq.Trace.Cnf_Checker.BuildProj.
Register Cnf_Checker.ImmBuildDef as SMTCoq.Trace.Cnf_Checker.ImmBuildDef.
Register Cnf_Checker.ImmBuildDef2 as SMTCoq.Trace.Cnf_Checker.ImmBuildDef2.
Register Cnf_Checker.ImmBuildProj as SMTCoq.Trace.Cnf_Checker.ImmBuildProj.

Register Euf_Checker.Certif as SMTCoq.Trace.Euf_Checker.Certif.
Register Euf_Checker.certif as SMTCoq.Trace.Euf_Checker.certif.
Register Euf_Checker.checker as SMTCoq.Trace.Euf_Checker.checker.
Register Euf_Checker.checker_correct as SMTCoq.Trace.Euf_Checker.checker_correct.
Register Euf_Checker.checker_b_correct as SMTCoq.Trace.Euf_Checker.checker_b_correct.
Register Euf_Checker.checker_b as SMTCoq.Trace.Euf_Checker.checker_b.
Register Euf_Checker.checker_eq_correct as SMTCoq.Trace.Euf_Checker.checker_eq_correct.
Register Euf_Checker.checker_eq as SMTCoq.Trace.Euf_Checker.checker_eq.
Register Euf_Checker.checker_debug as SMTCoq.Trace.Euf_Checker.checker_debug.
Register Euf_Checker.name_step as SMTCoq.Trace.Euf_Checker.name_step.
Register Euf_Checker.Name_Res as SMTCoq.Trace.Euf_Checker.Name_Res.
Register Euf_Checker.Name_Weaken as SMTCoq.Trace.Euf_Checker.Name_Weaken.
Register Euf_Checker.Name_ImmFlatten as SMTCoq.Trace.Euf_Checker.Name_ImmFlatten.
Register Euf_Checker.Name_CTrue as SMTCoq.Trace.Euf_Checker.Name_CTrue.
Register Euf_Checker.Name_CFalse as SMTCoq.Trace.Euf_Checker.Name_CFalse.
Register Euf_Checker.Name_BuildDef as SMTCoq.Trace.Euf_Checker.Name_BuildDef.
Register Euf_Checker.Name_BuildDef2 as SMTCoq.Trace.Euf_Checker.Name_BuildDef2.
Register Euf_Checker.Name_BuildProj as SMTCoq.Trace.Euf_Checker.Name_BuildProj.
Register Euf_Checker.Name_ImmBuildDef as SMTCoq.Trace.Euf_Checker.Name_ImmBuildDef.
Register Euf_Checker.Name_ImmBuildDef2 as SMTCoq.Trace.Euf_Checker.Name_ImmBuildDef2.
Register Euf_Checker.Name_ImmBuildProj as SMTCoq.Trace.Euf_Checker.Name_ImmBuildProj.
Register Euf_Checker.Name_EqTr as SMTCoq.Trace.Euf_Checker.Name_EqTr.
Register Euf_Checker.Name_EqCgr as SMTCoq.Trace.Euf_Checker.Name_EqCgr.
Register Euf_Checker.Name_EqCgrP as SMTCoq.Trace.Euf_Checker.Name_EqCgrP.
Register Euf_Checker.Name_LiaMicromega as SMTCoq.Trace.Euf_Checker.Name_LiaMicromega.
Register Euf_Checker.Name_LiaDiseq as SMTCoq.Trace.Euf_Checker.Name_LiaDiseq.
Register Euf_Checker.Name_SplArith as SMTCoq.Trace.Euf_Checker.Name_SplArith.
Register Euf_Checker.Name_SplDistinctElim as SMTCoq.Trace.Euf_Checker.Name_SplDistinctElim.
Register Euf_Checker.Name_BBVar as SMTCoq.Trace.Euf_Checker.Name_BBVar.
Register Euf_Checker.Name_BBConst as SMTCoq.Trace.Euf_Checker.Name_BBConst.
Register Euf_Checker.Name_BBOp as SMTCoq.Trace.Euf_Checker.Name_BBOp.
Register Euf_Checker.Name_BBNot as SMTCoq.Trace.Euf_Checker.Name_BBNot.
Register Euf_Checker.Name_BBNeg as SMTCoq.Trace.Euf_Checker.Name_BBNeg.
Register Euf_Checker.Name_BBAdd as SMTCoq.Trace.Euf_Checker.Name_BBAdd.
Register Euf_Checker.Name_BBConcat as SMTCoq.Trace.Euf_Checker.Name_BBConcat.
Register Euf_Checker.Name_BBMul as SMTCoq.Trace.Euf_Checker.Name_BBMul.
Register Euf_Checker.Name_BBUlt as SMTCoq.Trace.Euf_Checker.Name_BBUlt.
Register Euf_Checker.Name_BBSlt as SMTCoq.Trace.Euf_Checker.Name_BBSlt.
Register Euf_Checker.Name_BBEq as SMTCoq.Trace.Euf_Checker.Name_BBEq.
Register Euf_Checker.Name_BBDiseq as SMTCoq.Trace.Euf_Checker.Name_BBDiseq.
Register Euf_Checker.Name_BBExtract as SMTCoq.Trace.Euf_Checker.Name_BBExtract.
Register Euf_Checker.Name_BBZextend as SMTCoq.Trace.Euf_Checker.Name_BBZextend.
Register Euf_Checker.Name_BBSextend as SMTCoq.Trace.Euf_Checker.Name_BBSextend.
Register Euf_Checker.Name_BBShl as SMTCoq.Trace.Euf_Checker.Name_BBShl.
Register Euf_Checker.Name_BBShr as SMTCoq.Trace.Euf_Checker.Name_BBShr.
Register Euf_Checker.Name_RowEq as SMTCoq.Trace.Euf_Checker.Name_RowEq.
Register Euf_Checker.Name_RowNeq as SMTCoq.Trace.Euf_Checker.Name_RowNeq.
Register Euf_Checker.Name_Ext as SMTCoq.Trace.Euf_Checker.Name_Ext.
Register Euf_Checker.Name_Hole as SMTCoq.Trace.Euf_Checker.Name_Hole.
Register Euf_Checker.step as SMTCoq.Trace.Euf_Checker.step.
Register Euf_Checker.Res as SMTCoq.Trace.Euf_Checker.Res.
Register Euf_Checker.Weaken as SMTCoq.Trace.Euf_Checker.Weaken.
Register Euf_Checker.ImmFlatten as SMTCoq.Trace.Euf_Checker.ImmFlatten.
Register Euf_Checker.CTrue as SMTCoq.Trace.Euf_Checker.CTrue.
Register Euf_Checker.CFalse as SMTCoq.Trace.Euf_Checker.CFalse.
Register Euf_Checker.BuildDef as SMTCoq.Trace.Euf_Checker.BuildDef.
Register Euf_Checker.BuildDef2 as SMTCoq.Trace.Euf_Checker.BuildDef2.
Register Euf_Checker.BuildProj as SMTCoq.Trace.Euf_Checker.BuildProj.
Register Euf_Checker.ImmBuildProj as SMTCoq.Trace.Euf_Checker.ImmBuildProj.
Register Euf_Checker.ImmBuildDef as SMTCoq.Trace.Euf_Checker.ImmBuildDef.
Register Euf_Checker.ImmBuildDef2 as SMTCoq.Trace.Euf_Checker.ImmBuildDef2.
Register Euf_Checker.EqTr as SMTCoq.Trace.Euf_Checker.EqTr.
Register Euf_Checker.EqCgr as SMTCoq.Trace.Euf_Checker.EqCgr.
Register Euf_Checker.EqCgrP as SMTCoq.Trace.Euf_Checker.EqCgrP.
Register Euf_Checker.LiaMicromega as SMTCoq.Trace.Euf_Checker.LiaMicromega.
Register Euf_Checker.LiaDiseq as SMTCoq.Trace.Euf_Checker.LiaDiseq.
Register Euf_Checker.SplArith as SMTCoq.Trace.Euf_Checker.SplArith.
Register Euf_Checker.SplDistinctElim as SMTCoq.Trace.Euf_Checker.SplDistinctElim.
Register Euf_Checker.BBVar as SMTCoq.Trace.Euf_Checker.BBVar.
Register Euf_Checker.BBConst as SMTCoq.Trace.Euf_Checker.BBConst.
Register Euf_Checker.BBOp as SMTCoq.Trace.Euf_Checker.BBOp.
Register Euf_Checker.BBNot as SMTCoq.Trace.Euf_Checker.BBNot.
Register Euf_Checker.BBEq as SMTCoq.Trace.Euf_Checker.BBEq.
Register Euf_Checker.BBDiseq as SMTCoq.Trace.Euf_Checker.BBDiseq.
Register Euf_Checker.BBNeg as SMTCoq.Trace.Euf_Checker.BBNeg.
Register Euf_Checker.BBAdd as SMTCoq.Trace.Euf_Checker.BBAdd.
Register Euf_Checker.BBMul as SMTCoq.Trace.Euf_Checker.BBMul.
Register Euf_Checker.BBUlt as SMTCoq.Trace.Euf_Checker.BBUlt.
Register Euf_Checker.BBSlt as SMTCoq.Trace.Euf_Checker.BBSlt.
Register Euf_Checker.BBConcat as SMTCoq.Trace.Euf_Checker.BBConcat.
Register Euf_Checker.BBExtract as SMTCoq.Trace.Euf_Checker.BBExtract.
Register Euf_Checker.BBZextend as SMTCoq.Trace.Euf_Checker.BBZextend.
Register Euf_Checker.BBSextend as SMTCoq.Trace.Euf_Checker.BBSextend.
Register Euf_Checker.BBShl as SMTCoq.Trace.Euf_Checker.BBShl.
Register Euf_Checker.BBShr as SMTCoq.Trace.Euf_Checker.BBShr.
Register Euf_Checker.RowEq as SMTCoq.Trace.Euf_Checker.RowEq.
Register Euf_Checker.RowNeq as SMTCoq.Trace.Euf_Checker.RowNeq.
Register Euf_Checker.Ext as SMTCoq.Trace.Euf_Checker.Ext.
Register Euf_Checker.Hole as SMTCoq.Trace.Euf_Checker.Hole.
Register Euf_Checker.ForallInst as SMTCoq.Trace.Euf_Checker.ForallInst.


(* Checker for extraction, that does not know the evaluation contexts.
   TODO: show that there always exists a well-typed evaluation
   context. *)

Module Checker_Ext.

  Section Checker.

  Variable t_atom : array Atom.atom.
  Variable t_form : array Form.form.

  Inductive step :=
  | Res (pos:int) (res:resolution)
  | Weaken (pos:int) (cid:clause_id) (cl:list _lit)
  | ImmFlatten (pos:int) (cid:clause_id) (lf:_lit)
  | CTrue (pos:int)
  | CFalse (pos:int)
  | BuildDef (pos:int) (l:_lit)
  | BuildDef2 (pos:int) (l:_lit)
  | BuildProj (pos:int) (l:_lit) (i:int)
  | ImmBuildDef (pos:int) (cid:clause_id)
  | ImmBuildDef2 (pos:int) (cid:clause_id)
  | ImmBuildProj (pos:int) (cid:clause_id) (i:int)
  | EqTr (pos:int) (l:_lit) (fl: list _lit)
  | EqCgr (pos:int) (l:_lit) (fl: list (option _lit))
  | EqCgrP (pos:int) (l1:_lit) (l2:_lit) (fl: list (option _lit))
  | LiaMicromega (pos:int) (cl:list _lit) (c:list ZMicromega.ZArithProof)
  | LiaDiseq (pos:int) (l:_lit)
  | SplArith (pos:int) (orig:clause_id) (res:_lit) (l:list ZMicromega.ZArithProof)
  | SplDistinctElim (pos:int) (orig:clause_id) (res:_lit)
  (* Bit-blasting *)
  | BBVar (pos:int) (res:_lit)
  | BBConst (pos:int) (res:_lit)
  | BBOp (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBNot (pos:int) (orig:clause_id) (res:_lit)
  | BBNeg (pos:int) (orig:clause_id) (res:_lit)
  | BBAdd (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBConcat (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBMul (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBUlt (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBSlt (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBEq (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBDiseq (pos:int) (res:_lit)
  | BBExtract (pos:int) (orig:clause_id) (res:_lit)
  | BBZextend (pos:int) (orig:clause_id) (res:_lit)
  | BBSextend (pos:int) (orig:clause_id) (res:_lit)
  | BBShl (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | BBShr (pos:int) (orig1 orig2:clause_id) (res:_lit)
  | RowEq (pos:int) (res: _lit)
  | RowNeq (pos:int) (cl: C.t)
  | Ext (pos:int) (res: _lit)
  .

  Local Open Scope list_scope.

  Local Notation check_flatten t_atom t_form := (check_flatten t_form (check_hatom t_atom) (check_neg_hatom t_atom)) (only parsing).

  Definition step_checker s (st:step) :=
    match st with
      | Res pos res => S.set_resolve s pos res
      | Weaken pos cid cl => S.set_weaken s pos cid cl
      | ImmFlatten pos cid lf => S.set_clause s pos (check_flatten t_atom t_form s cid lf)
      | CTrue pos => S.set_clause s pos Cnf.check_True
      | CFalse pos => S.set_clause s pos Cnf.check_False
      | BuildDef pos l => S.set_clause s pos (check_BuildDef t_form l)
      | BuildDef2 pos l => S.set_clause s pos (check_BuildDef2 t_form l)
      | BuildProj pos l i => S.set_clause s pos (check_BuildProj t_form l i)
      | ImmBuildDef pos cid => S.set_clause s pos (check_ImmBuildDef t_form s cid)
      | ImmBuildDef2 pos cid => S.set_clause s pos (check_ImmBuildDef2 t_form s cid)
      | ImmBuildProj pos cid i => S.set_clause s pos (check_ImmBuildProj t_form s cid i)
      | EqTr pos l fl => S.set_clause s pos (check_trans t_form t_atom l fl)
      | EqCgr pos l fl => S.set_clause s pos (check_congr t_form t_atom l fl)
      | EqCgrP pos l1 l2 fl => S.set_clause s pos (check_congr_pred t_form t_atom l1 l2 fl)
      | LiaMicromega pos cl c => S.set_clause s pos (check_micromega t_form t_atom cl c)
      | LiaDiseq pos l => S.set_clause s pos (check_diseq t_form t_atom l)
      | SplArith pos orig res l => S.set_clause s pos (check_spl_arith t_form t_atom (S.get s orig) res l)
      | SplDistinctElim pos orig res => S.set_clause s pos (check_distinct_elim t_form t_atom (S.get s orig) res)
      | BBVar pos res => S.set_clause s pos (check_bbVar t_atom t_form res)
      | BBConst pos res => S.set_clause s pos (check_bbConst t_atom t_form res)
      | BBOp pos orig1 orig2 res => S.set_clause s pos (check_bbOp t_atom t_form s orig1 orig2 res)
      | BBNot pos orig res => S.set_clause s pos (check_bbNot t_atom t_form s orig res)
      | BBNeg pos orig res => S.set_clause s pos (check_bbNeg t_atom t_form s orig res)
      | BBAdd pos orig1 orig2 res => S.set_clause s pos (check_bbAdd t_atom t_form s orig1 orig2 res)
      | BBConcat pos orig1 orig2 res => S.set_clause s pos (check_bbConcat t_atom t_form s orig1 orig2 res)
      | BBMul pos orig1 orig2 res => S.set_clause s pos (check_bbMult t_atom t_form s orig1 orig2 res)
      | BBUlt pos orig1 orig2 res => S.set_clause s pos (check_bbUlt t_atom t_form s orig1 orig2 res)
      | BBSlt pos orig1 orig2 res => S.set_clause s pos (check_bbSlt t_atom t_form s orig1 orig2 res)
      | BBEq pos orig1 orig2 res => S.set_clause s pos (check_bbEq t_atom t_form s orig1 orig2 res)
      | BBDiseq pos res => S.set_clause s pos (check_bbDiseq t_atom t_form res)
      | BBExtract pos orig res => S.set_clause s pos (check_bbExtract t_atom t_form s orig res)
      | BBZextend pos orig res => S.set_clause s pos (check_bbZextend t_atom t_form s orig res)
      | BBSextend pos orig res => S.set_clause s pos (check_bbSextend t_atom t_form s orig res)
      | BBShl pos orig1 orig2 res => S.set_clause s pos (check_bbShl t_atom t_form s orig1 orig2 res)
      | BBShr pos orig1 orig2 res => S.set_clause s pos (check_bbShr t_atom t_form s orig1 orig2 res)
      | RowEq pos res => S.set_clause s pos (check_roweq t_form t_atom res)
      | RowNeq pos cl => S.set_clause s pos (check_rowneq t_form t_atom cl)
      | Ext pos res => S.set_clause s pos (check_ext t_form t_atom res)
    end.

  (* Opaque S.set_weaken. *)

  Lemma step_checker_correct :
    Form.check_form t_form -> Atom.check_atom t_atom ->
    forall t_i t_func,
    let rho := Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form in
      Atom.wt t_i t_func t_atom ->
      forall s, S.valid rho s ->
        forall st : step, S.valid rho (step_checker s st).
  Proof.
    set (empty_bv := (fun (a:Atom.atom) s => BITVECTOR_LIST.zeros s)).
    intros H1 H2 t_i t_func rho H10 s Hs. destruct (Form.check_form_correct (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) _ H1)
    as [[Ht1 Ht2] Ht3]. destruct (Atom.check_atom_correct _ H2) as
    [Ha1 Ha2]. intros [pos res|pos cid c|pos cid lf|pos|pos|pos l|pos l|pos l i|pos cid
    |pos cid|pos cid i|pos l fl|pos l fl|pos l1 l2 fl|pos cl c|pos l|pos orig res l
    |pos orig res|pos res|pos res|pos orig1 orig2 res|pos orig res|pos orig res
    |pos orig1 orig2 res|pos orig1 orig2 res
    |pos orig1 orig2 res|pos orig1 orig2 res|pos orig1 orig2 res|pos orig1 orig2 res
    |pos cl |pos orig res |pos orig res |pos orig res | pos orig1 orig2 res | pos orig1 orig2 res |pos res|pos res
    |pos res]; simpl; try apply S.valid_set_clause; auto with smtcoq_core.
    - apply S.valid_set_resolve; auto with smtcoq_core.
    - apply S.valid_set_weaken; auto with smtcoq_core.
    - apply valid_check_flatten; auto with smtcoq_core; intros h1 h2 H.
      + rewrite (Syntactic.check_hatom_correct_bool _ _ _ Ha1 Ha2 _ _ H); auto with smtcoq_core.
      + rewrite (Syntactic.check_neg_hatom_correct_bool _ _ _ H10 Ha1 Ha2 _ _ H); auto with smtcoq_core.
    - apply valid_check_True; auto with smtcoq_core.
    - apply valid_check_False; auto with smtcoq_core.
    - apply valid_check_BuildDef; auto with smtcoq_core.
    - apply valid_check_BuildDef2; auto with smtcoq_core.
    - apply valid_check_BuildProj; auto with smtcoq_core.
    - apply valid_check_ImmBuildDef; auto with smtcoq_core.
    - apply valid_check_ImmBuildDef2; auto with smtcoq_core.
    - apply valid_check_ImmBuildProj; auto with smtcoq_core.
    - apply valid_check_trans; auto with smtcoq_core.
    - apply valid_check_congr; auto with smtcoq_core.
    - apply valid_check_congr_pred; auto with smtcoq_core.
    - apply valid_check_micromega; auto with smtcoq_core.
    - apply valid_check_diseq; auto with smtcoq_core.
    - apply valid_check_spl_arith; auto with smtcoq_core.
    - apply valid_check_distinct_elim; auto with smtcoq_core.
    - eapply valid_check_bbVar; eauto with smtcoq_core.
    - apply valid_check_bbConst; auto with smtcoq_core.
    - apply valid_check_bbOp; auto with smtcoq_core.
    - apply valid_check_bbNot; auto with smtcoq_core.
    - apply valid_check_bbNeg; auto with smtcoq_core.
    - apply valid_check_bbAdd; auto with smtcoq_core.
    - apply valid_check_bbConcat; auto with smtcoq_core.
    - apply valid_check_bbMult; auto with smtcoq_core.
    - apply valid_check_bbUlt; auto with smtcoq_core.
    - apply valid_check_bbSlt; auto with smtcoq_core.
    - apply valid_check_bbEq; auto with smtcoq_core.
    - apply valid_check_bbDiseq; auto with smtcoq_core.
    - apply valid_check_bbExtract; auto with smtcoq_core.
    - apply valid_check_bbZextend; auto with smtcoq_core.
    - apply valid_check_bbSextend; auto with smtcoq_core.
    - apply valid_check_bbShl; auto with smtcoq_core.
    - apply valid_check_bbShr; auto with smtcoq_core.
    - apply valid_check_roweq; auto with smtcoq_core.
    - apply valid_check_rowneq; auto with smtcoq_core.
    - apply valid_check_ext; auto with smtcoq_core.
  Qed.

  Definition checker s t := _checker_ (step_checker) s t.

  Lemma checker_correct :
    Form.check_form t_form -> Atom.check_atom t_atom ->
    forall t_i t_func,
    let rho := Form.interp_state_var (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) t_form in
      Atom.wt t_i t_func t_atom ->
      forall s t confl,
        checker C.is_false s t confl ->
        ~ (S.valid rho s).
  Proof.
    unfold checker; intros H1 H2 t_i t_func rho H10; apply _checker__correct.
    intros c H; apply C.is_false_correct; auto with smtcoq_core.
    apply step_checker_correct; auto with smtcoq_core.
  Qed.

  Inductive certif :=
  | Certif : int -> _trace_ step -> int -> certif.

  Definition checker_ext d used_roots (c:certif) :=
    let (nclauses, t, confl) := c in
    Form.check_form t_form && Atom.check_atom t_atom &&
      checker C.is_false (Euf_Checker.add_roots (S.make nclauses) d used_roots) t confl.

  Lemma checker_ext_correct : forall d used_roots c,
    checker_ext d used_roots c = true ->
    forall t_i t_func, Atom.wt t_i t_func t_atom ->
                       ~ Euf_Checker.valid t_func t_atom t_form d.
  Proof.
    unfold checker_ext.
    intros d used_roots (nclauses, t, confl).
    rewrite !andb_true_iff.
    intros [[H1 H2] H3] t_i t_func H10 H.
    eelim checker_correct; try eassumption.
    apply Euf_Checker.add_roots_correct; try assumption.
    apply S.valid_make.
    destruct (Form.check_form_correct (Atom.interp_form_hatom t_i t_func t_atom) (Atom.interp_form_hatom_bv t_i t_func t_atom) _ H1) as [_ H4]; auto with smtcoq_core.
  Qed.

  End Checker.

End Checker_Ext.


(*
   Local Variables:
   coq-load-path: ((rec "." "SMTCoq"))
   End:
*)
