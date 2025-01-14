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


(*** Spl -- a small checker for simplifications ***)
Require Import List PArray Bool Uint63 ZMicromega ZArith.
Require Import Misc State SMT_terms BVList.
Require Lia.

Local Open Scope array_scope.
Local Open Scope uint63_scope.


(* Flattening and small arithmetic simplifications *)

Section CheckAtom.

  Import Atom.

  Variable t_i : PArray.array SMT_classes.typ_compdec.
  Variable t_func : PArray.array (tval t_i).
  Variable t_atom : PArray.array atom.

  Local Notation get_atom := (PArray.get t_atom).

  Section AUX.

    Variable check_hatom : hatom -> hatom -> bool.

    Definition check_atom_aux a b :=
      match a, b with
        | Acop o1, Acop o2 => cop_eqb o1 o2

        (* Two ways to define a negative integer *)
        | Auop UO_Zopp p1, Auop UO_Zneg q =>
          match get_atom p1 with
            | Auop UO_Zpos p => check_hatom p q
            | _ => false
          end
        | Auop UO_Zneg p, Auop UO_Zopp q1 =>
          match get_atom q1 with
            | Auop UO_Zpos q => check_hatom p q
            | _ => false
          end

        | Auop o1 a, Auop o2 b => uop_eqb o1 o2 && check_hatom a b
        | Abop o1 a1 a2, Abop o2 b1 b2 =>
          match o1, o2 with
            | BO_Zplus, BO_Zplus
            | BO_Zmult, BO_Zmult => (check_hatom a1 b1 && check_hatom a2 b2) || (check_hatom a1 b2 && check_hatom a2 b1)
            | BO_Zminus, BO_Zminus
            | BO_Zlt, BO_Zlt
            | BO_Zle, BO_Zle
            | BO_Zge, BO_Zge
            | BO_Zgt, BO_Zgt  => check_hatom a1 b1 && check_hatom a2 b2
            | BO_Zge, BO_Zle
            | BO_Zle, BO_Zge
            | BO_Zgt, BO_Zlt
            | BO_Zlt, BO_Zgt => check_hatom a1 b2 && check_hatom a2 b1
            | BO_eq t1, BO_eq t2 =>
              Typ.eqb t1 t2 &&
              ((check_hatom a1 b1 && check_hatom a2 b2) ||
                (check_hatom a1 b2 && check_hatom a2 b1))
            | BO_BVand s1, BO_BVand s2
            | BO_BVor s1, BO_BVor s2 => N.eqb s1 s2 && check_hatom a1 b1 && check_hatom a2 b2
            | _, _ => false
          end
        | Anop o1 l1, Anop o2 l2 =>
          match o1, o2 with
            | NO_distinct t1, NO_distinct t2 => Typ.eqb t1 t2 && list_beq check_hatom l1 l2
          end
        | Aapp f1 aargs, Aapp f2 bargs =>(f1 =? f2) && list_beq check_hatom aargs bargs

        | _, _ => false
      end.


    Hypothesis check_hatom_correct : forall h1 h2, check_hatom h1 h2 ->
      interp_hatom t_i t_func t_atom h1 = interp_hatom t_i t_func t_atom h2.
    Hypothesis Hwf: wf t_atom.
    Hypothesis Hd: default t_atom = Acop CO_xH.


    Lemma list_beq_correct : forall l1 l2,
      list_beq check_hatom l1 l2 = true ->
      List.map (interp_hatom t_i t_func t_atom) l1 =
      List.map (interp_hatom t_i t_func t_atom) l2.
    Proof.
      induction l1 as [ |h1 l1 IHl1]; intros [ |h2 l2]; simpl; try discriminate; auto; rewrite andb_true_iff; intros [H1 H2]; rewrite (IHl1 _ H2); rewrite (check_hatom_correct _ _ H1); auto.
    Qed.


    Lemma list_beq_compute_interp : forall t l1 l2,
      list_beq check_hatom l1 l2 = true -> forall acc,
      compute_interp t_i (interp_hatom t_i t_func t_atom) t acc l1 =
      compute_interp t_i (interp_hatom t_i t_func t_atom) t acc l2.
    Proof.
      intro t; induction l1 as [ |h1 l1 IHl1]; intros [ |h2 l2]; simpl; try discriminate; auto; rewrite andb_true_iff; intros [H1 H2] acc; rewrite (check_hatom_correct _ _ H1); destruct (interp_hatom t_i t_func t_atom h2) as [ta va]; destruct (Typ.cast ta t) as [ka| ]; auto.
    Qed.


    Lemma check_atom_aux_correct : forall a1 a2, check_atom_aux a1 a2 ->
      interp t_i t_func t_atom a1 = interp t_i t_func t_atom a2.
    Proof.
      intros [op1|op1 i1|op1 i1 j1|op1 li1|op1 li1|f1 args1]; simpl.
      (* Constants *)
      - intros [op2|op2 i2|op2 i2 j2|op2 li2|op2 li2|f2 args2]; simpl; try discriminate; pose (H:=reflect_cop_eqb op1 op2); inversion H; try discriminate; subst op1; auto.
      (* Unary operators *)
      - 
      intros [op2|op2 i2|op2 i2 j2|op2 li2|op2 li2|f2 args2]; simpl; try discriminate; try (case op1; discriminate).
      case op1; case op2; try discriminate; try (unfold is_true; rewrite andb_true_iff; intros [_ H]; rewrite (check_hatom_correct _ _ H); auto).

      case_eq (get_atom i2); try discriminate;
        intros [ | | | | | | | | i0 n0 n1| n i0| n i0] i Heq H; try discriminate; simpl;
      unfold apply_unop; rewrite (check_hatom_correct _ _ H); 
      unfold interp_hatom; rewrite (t_interp_wf _ _ _ Hwf Hd i2), Heq; simpl; 
      unfold apply_unop; destruct (t_interp t_i t_func t_atom .[ i]) as [A v]; 
      destruct (Typ.cast A Typ.Tpositive) as [k| ]; auto.
      case_eq (get_atom i1); try discriminate;
        intros [ | | | | | | | | i0 n0 n1| n i0| n i0] i Heq H; try discriminate; simpl; 
      unfold apply_unop. rewrite <- (check_hatom_correct _ _ H); 
      unfold interp_hatom; rewrite (t_interp_wf _ _ _ Hwf Hd i1), Heq; simpl; 
      unfold apply_unop; destruct (t_interp t_i t_func t_atom .[ i]) as [A v]; 
      destruct (Typ.cast A Typ.Tpositive) as [k| ]; auto.

      intros n m n1 m2. simpl. unfold is_true. rewrite !andb_true_iff, beq_nat_true_iff, N.eqb_eq. intros [[-> ->] H]. rewrite (check_hatom_correct _ _ H); auto.
      intros n m. simpl. unfold is_true. rewrite andb_true_iff, N.eqb_eq. intros [-> H]. rewrite (check_hatom_correct _ _ H); auto.
      intros n m. simpl. unfold is_true. rewrite andb_true_iff, N.eqb_eq. intros [-> H]. rewrite (check_hatom_correct _ _ H); auto.
      (* bv_extr *)
      intros i n0 n1 i0 n2 n3.
      unfold is_true. rewrite andb_true_iff.
      intros. destruct H as (Ha, Hb).
      inversion Ha.
      rewrite !andb_true_iff in H0.
      destruct H0 as ((H0a, H0b), H0c).
      rewrite N.eqb_eq in H0a, H0b, H0c.
      subst.
      rewrite (check_hatom_correct _ _ Hb); auto.
      (* bv_zextn *)
      intros n i n0 i0.
      unfold is_true. rewrite andb_true_iff.
      intros. destruct H as (Ha, Hb).
      inversion Ha.
      rewrite !andb_true_iff in H0.
      destruct H0 as (H0a, H0b).
      rewrite N.eqb_eq in H0a, H0b.
      subst.
      rewrite (check_hatom_correct _ _ Hb); auto.
      (* bv_sextn *)
      intros n i n0 i0.
      unfold is_true. rewrite andb_true_iff.
      intros. destruct H as (Ha, Hb).
      inversion Ha.
      rewrite !andb_true_iff in H0.
      destruct H0 as (H0a, H0b).
      rewrite N.eqb_eq in H0a, H0b.
      subst.
      rewrite (check_hatom_correct _ _ Hb); auto.     
            (* Binary operators *)
      - intros [op2|op2 i2|op2 i2 j2|op2 li2|op2 li2|f2 args2]; simpl; try discriminate; case op1; case op2; try discriminate; try (unfold is_true; rewrite andb_true_iff; intros [H1 H2]; rewrite (check_hatom_correct _ _ H1), (check_hatom_correct _ _ H2); auto).
      unfold is_true, interp_bop, apply_binop. rewrite orb_true_iff, !andb_true_iff. intros [[H1 H2]|[H1 H2]]; rewrite (check_hatom_correct _ _ H1), (check_hatom_correct _ _ H2); destruct (interp_hatom t_i t_func t_atom i2) as [A v1]; destruct (interp_hatom t_i t_func t_atom j2) as [B v2]; destruct (Typ.cast B Typ.TZ) as [k2| ]; destruct (Typ.cast A Typ.TZ) as [k1| ]; auto; rewrite Z.add_comm; reflexivity.
      unfold is_true, interp_bop, apply_binop. rewrite orb_true_iff, !andb_true_iff. intros [[H1 H2]|[H1 H2]]; rewrite (check_hatom_correct _ _ H1), (check_hatom_correct _ _ H2); destruct (interp_hatom t_i t_func t_atom i2) as [A v1]; destruct (interp_hatom t_i t_func t_atom j2) as [B v2]; destruct (Typ.cast B Typ.TZ) as [k2| ]; destruct (Typ.cast A Typ.TZ) as [k1| ]; auto; rewrite Z.mul_comm; reflexivity.
      unfold interp_bop, apply_binop; destruct (interp_hatom t_i t_func t_atom j2) as [B v2]; destruct (interp_hatom t_i t_func t_atom i2) as [A v1]; destruct (Typ.cast B Typ.TZ) as [k2| ]; destruct (Typ.cast A Typ.TZ) as [k1| ]; auto; rewrite Z.gtb_ltb; auto.
      unfold interp_bop, apply_binop; destruct (interp_hatom t_i t_func t_atom j2) as [B v2]; destruct (interp_hatom t_i t_func t_atom i2) as [A v1]; destruct (Typ.cast B Typ.TZ) as [k2| ]; destruct (Typ.cast A Typ.TZ) as [k1| ]; auto; rewrite Z.geb_leb; auto.
      unfold interp_bop, apply_binop; destruct (interp_hatom t_i t_func t_atom j2) as [B v2]; destruct (interp_hatom t_i t_func t_atom i2) as [A v1]; destruct (Typ.cast B Typ.TZ) as [k2| ]; destruct (Typ.cast A Typ.TZ) as [k1| ]; auto; rewrite Z.geb_leb; auto.
      unfold interp_bop, apply_binop; destruct (interp_hatom t_i t_func t_atom j2) as [B v2]; destruct (interp_hatom t_i t_func t_atom i2) as [A v1]; destruct (Typ.cast B Typ.TZ) as [k2| ]; destruct (Typ.cast A Typ.TZ) as [k1| ]; auto; rewrite Z.gtb_ltb; auto.
      intros A B; unfold is_true; rewrite andb_true_iff, orb_true_iff; change (Typ.eqb B A = true) with (is_true (Typ.eqb B A)); rewrite Typ.eqb_spec; intros [H2 [H1|H1]]; subst B; rewrite andb_true_iff in H1; destruct H1 as [H1 H2]; rewrite (check_hatom_correct _ _ H1), (check_hatom_correct _ _ H2); auto; simpl; unfold apply_binop; destruct (interp_hatom t_i t_func t_atom j2) as [B v1]; destruct (interp_hatom t_i t_func t_atom i2) as [C v2]; destruct (Typ.cast B A) as [k1| ]; destruct (Typ.cast C A) as [k2| ]; auto; rewrite Typ.i_eqb_sym; auto.
      intros s1 s2; unfold is_true; rewrite !andb_true_iff, N.eqb_eq;
        intros [[-> H1] H2];
        now rewrite (check_hatom_correct _ _ H1), (check_hatom_correct _ _ H2).
      intros s1 s2; unfold is_true; rewrite !andb_true_iff, N.eqb_eq;
        intros [[-> H1] H2];
        now rewrite (check_hatom_correct _ _ H1), (check_hatom_correct _ _ H2).
       (* Ternary operators *)
     - intros. now contradict H.
      (* N-ary operators *)
      - intros [op2|op2 i2|op2 i2 j2|op2 i2 j2|op2 li2|f2 args2]; simpl; try discriminate; destruct op1 as [t1]; destruct op2 as [t2]; unfold is_true; rewrite andb_true_iff; change (Typ.eqb t1 t2 = true) with (is_true (Typ.eqb t1 t2)); rewrite Typ.eqb_spec; intros [H1 H2]; subst t2; rewrite (list_beq_compute_interp _ _ _ H2); auto.
      (* Application *)
      - intros [op2|op2 i2|op2 i2 j2|op2 i2 j2|op2 li2|f2 args2]; simpl; try discriminate; unfold is_true; rewrite andb_true_iff, Uint63.eqb_spec; intros [H2 H1]; subst f2; rewrite (list_beq_correct _ _ H1); auto.
    Qed.

  End AUX.

  Definition check_hatom h1 h2 :=
    foldi
    (fun _ cont h1 h2 => (h1 =? h2) || check_atom_aux cont (t_atom.[h1]) (t_atom.[h2]))
    0 (PArray.length t_atom) (fun h1 h2 => false) h1 h2.

  Definition check_atom := check_atom_aux check_hatom.

  Definition check_neg_hatom h1 h2 :=
    match get_atom h1, get_atom h2 with
      | Abop op1 a1 a2, Abop op2 b1 b2 =>
        match op1, op2 with
          | BO_Zlt, BO_Zle => check_hatom a1 b2 && check_hatom a2 b1
          | BO_Zlt, BO_Zge => check_hatom a1 b1 && check_hatom a2 b2
          | BO_Zle, BO_Zlt => check_hatom a1 b2 && check_hatom a2 b1
          | BO_Zle, BO_Zgt => check_hatom a1 b1 && check_hatom a2 b2
          | BO_Zge, BO_Zlt => check_hatom a1 b1 && check_hatom a2 b2
          | BO_Zge, BO_Zgt => check_hatom a1 b2 && check_hatom a2 b1
          | BO_Zgt, BO_Zle => check_hatom a1 b1 && check_hatom a2 b2
          | BO_Zgt, BO_Zge => check_hatom a1 b2 && check_hatom a2 b1
          | _, _ => false
        end
      | _, _ => false
    end.

  (* TODO : move this *)
  Lemma Zge_is_ge_bool : forall x y, (x >= y)%Z <-> (Zge_bool x y = true).
  Proof.
    intros x y;assert (W:=Zge_cases x y);destruct (Zge_bool x y).
    split;auto.
    split;[intros;auto with zarith | discriminate].
  Qed.


  (* Correctness of check_atom *)

  Lemma check_hatom_correct : wf t_atom ->
    default t_atom = Acop CO_xH ->
    forall h1 h2, check_hatom h1 h2 ->
      interp_hatom t_i t_func t_atom h1 = interp_hatom t_i t_func t_atom h2.
  Proof.
   unfold check_hatom;intros Hwf Hdef.
   apply foldi_ind;try discriminate.
  apply leb_0.
   intros i cont _ _ Hrec h1 h2.
   unfold is_true; rewrite orb_true_iff; intros [H|H].
   rewrite Uint63.eqb_spec in H; rewrite H; reflexivity.
   unfold interp_hatom;rewrite !t_interp_wf;trivial.
   apply check_atom_aux_correct with cont;trivial.
  Qed.


   Lemma check_atom_correct : wf t_atom ->
    default t_atom = Acop CO_xH ->
    forall a1 a2, check_atom a1 a2 ->
        interp t_i t_func t_atom a1 = interp t_i t_func t_atom a2.
  Proof.
   intros Hwf Hdef;unfold check_atom;apply check_atom_aux_correct; auto.
   apply check_hatom_correct;trivial.
  Qed.


  Lemma check_hatom_correct_bool : wf t_atom ->
    default t_atom = Acop CO_xH ->
    forall h1 h2, check_hatom h1 h2 ->
      interp_form_hatom t_i t_func t_atom h1 = interp_form_hatom t_i t_func t_atom h2.
  Proof.
    unfold interp_form_hatom; intros H1 H2 h1 h2 H3; rewrite (check_hatom_correct H1 H2 h1 h2 H3); auto.
  Qed.


  (* Correctness of check_neg_atom *)

  Lemma check_neg_hatom_correct : wt t_i t_func t_atom ->
    wf t_atom -> default t_atom = Acop CO_xH ->
    forall h1 h2, check_neg_hatom h1 h2 ->
      match interp_hatom t_i t_func t_atom h1, interp_hatom t_i t_func t_atom h2 with
        | Val Typ.Tbool v1, Val Typ.Tbool v2 => v1 = negb v2
        | Val _ _, Val _ _ => False
      end.
  Proof.
    unfold wt; unfold is_true at 1; rewrite aforallbi_spec; intros Hwt Hwf Hdef h1 h2; unfold check_neg_hatom; case_eq (get_atom h1); try discriminate; intros b1 t11 t12 H1; case_eq (get_atom h2); try discriminate; intros b2 t21 t22 H2; assert (H7: h1 <? length t_atom) by (apply PArray.get_not_default_lt; rewrite H1, Hdef; discriminate); generalize (Hwt _ H7); rewrite H1; simpl; generalize H1; case b1; try discriminate; clear H1 b1; simpl; intro H1; case (get_type' t_i (t_interp t_i t_func t_atom) h1); try discriminate; simpl; rewrite andb_true_iff; intros [H30 H31]; change (is_true (Typ.eqb (get_type' t_i (t_interp t_i t_func t_atom) t11) Typ.TZ)) in H30; change (is_true (Typ.eqb (get_type' t_i (t_interp t_i t_func t_atom) t12) Typ.TZ)) in H31; rewrite Typ.eqb_spec in H30, H31; generalize (check_aux_interp_hatom _ t_func _ Hwf t11), (check_aux_interp_hatom _ t_func _ Hwf t12); rewrite H30, H31; intros [v1 Hv1] [v2 Hv2]; generalize H2; case b2; try discriminate; clear H2 b2; intro H2; unfold is_true; rewrite andb_true_iff; intros [H3 H4]; generalize (check_hatom_correct Hwf Hdef _ _ H3), (check_hatom_correct Hwf Hdef _ _ H4); unfold interp_hatom; intros H5 H6; rewrite t_interp_wf; auto; rewrite H1; simpl; rewrite Hv1, Hv2; simpl; rewrite t_interp_wf; auto; rewrite H2; simpl; rewrite <- H5; rewrite <- H6, Hv1, Hv2; simpl.
    rewrite Z.ltb_antisym; auto.
    rewrite Z.geb_leb, Z.ltb_antisym; auto.
    rewrite Z.leb_antisym; auto.
    rewrite Z.gtb_ltb, Z.leb_antisym; auto.
    rewrite Z.geb_leb, Z.leb_antisym; auto.
    rewrite Z.geb_leb, Z.gtb_ltb, Z.leb_antisym; auto.
    rewrite Z.gtb_ltb, Z.ltb_antisym; auto.
    rewrite Z.geb_leb, Z.gtb_ltb, Z.ltb_antisym; auto.
  Qed.


  Lemma check_neg_hatom_correct_bool : wt t_i t_func t_atom ->
    wf t_atom -> default t_atom = Acop CO_xH ->
    forall h1 h2, check_neg_hatom h1 h2 ->
      interp_form_hatom t_i t_func t_atom h1 = negb (interp_form_hatom t_i t_func t_atom h2).
  Proof.
    unfold interp_form_hatom. intros Hwt H1 H2 h1 h2 H3. unfold interp_bool. generalize (check_neg_hatom_correct Hwt H1 H2 _ _ H3).
    case (interp_hatom t_i t_func t_atom h1).
    case (interp_hatom t_i t_func t_atom h2).
    simpl. intros [ |i| | | | ] v1 [ |j| | | | ] v2; intro H; inversion H. rewrite Typ.cast_refl. auto.
  Qed.

End CheckAtom.


(* Flattening *)

Section FLATTEN.

  Import Form.

  Variable t_form : PArray.array form.

  Local Notation get_form := (PArray.get t_form).

  Definition remove_not l :=
    match get_form (Lit.blit l) with
      | Fnot2 _ l' => if Lit.is_pos l then l' else Lit.neg l'
      | _ => l
    end.

  Definition get_and l :=
    let l := remove_not l in
      if Lit.is_pos l then
        match get_form (Lit.blit l) with
          | Fand args => Some args
          | _ => None
        end
        else None.

  Definition get_or l :=
    let l := remove_not l in
      if Lit.is_pos l then
        match get_form (Lit.blit l) with
          | For args => Some args
          | _ => None
        end
        else None.

  Definition flatten_op_body (get_op:_lit -> option (array _lit))
    (frec : list _lit -> _lit -> list _lit)
    (largs:list _lit) (l:_lit) : list _lit :=
    match get_op l with
      | Some a => foldi (fun i x => frec x (a.[i])) 0 (length a) largs
      | None => l::largs
    end.
  (* Register flatten_op_body as PrimInline. *)


  Definition flatten_op_lit (get_op:_lit -> option (array _lit)) max :=
    foldi (fun _ => flatten_op_body get_op) 0 max (fun largs l => l::largs).

  Definition flatten_and t :=
    foldi (fun i x => flatten_op_lit get_and (PArray.length t_form) x (t.[i])) 0 (length t) nil.

  Definition flatten_or t :=
    foldi (fun i x => flatten_op_lit get_or (PArray.length t_form) x (t.[i])) 0 (length t) nil.


  Variable check_atom check_neg_atom : atom -> atom -> bool.

  Definition check_flatten_body frec (l lf:_lit) :=
    let l := remove_not l in
      let lf := remove_not lf in
        if l =? lf then true
          else if 1 land (l lxor lf) =? 0 then
            match get_form (Lit.blit l), get_form (Lit.blit lf) with
              | Fatom a1, Fatom a2 => check_atom a1 a2
              | Ftrue, Ftrue => true
              | Ffalse, Ffalse => true
              | Fand args1, Fand args2 =>
                let args1 := flatten_and args1 in
                  let args2 := flatten_and args2 in
                    forallb2 frec args1 args2
              | For args1, For args2 =>
                let args1 := flatten_or args1 in
                  let args2 := flatten_or args2 in
                    forallb2 frec args1 args2
              | Fxor l1 l2, Fxor lf1 lf2 =>
                frec l1 lf1 && frec l2 lf2
              | Fimp args1, Fimp args2 =>
                if PArray.length args1 =? PArray.length args2 then
                  aforallbi (fun i l => frec l (args2.[i])) args1
                  else false
              | Fiff l1 l2, Fiff lf1 lf2 =>
                frec l1 lf1 && frec l2 lf2
              | Fite l1 l2 l3, Fite lf1 lf2 lf3 =>
                frec l1 lf1 && frec l2 lf2 && frec l3 lf3
              | _, _ => false
            end
            else
              match get_form (Lit.blit l), get_form (Lit.blit lf) with
                | Fatom a1, Fatom a2 => check_neg_atom a1 a2
                | _, _ => false (* We maybe need to extend the rule here ... *)
              end.
  (* Register check_flatten_body as PrimInline. *)

  Definition check_flatten_aux l lf :=
    foldi (fun _ => check_flatten_body) 0 (PArray.length t_form) (fun _ _ => false) l lf.

  Definition check_flatten s cid lf :=
    match S.get s cid with
      | l :: nil =>
        if check_flatten_aux l lf then lf::nil else C._true
      | _ => C._true
    end.


  (** Correctness proofs *)
  Variable interp_atom : atom -> bool.
  Variable interp_bvatom : atom -> forall s, BITVECTOR_LIST.bitvector s.
  Hypothesis default_thf : default t_form = Ftrue.
  Hypothesis wf_thf : wf t_form.
  Hypothesis check_atom_correct :
    forall a1 a2, check_atom a1 a2 -> interp_atom a1 = interp_atom a2.
  Hypothesis check_neg_atom_correct :
    forall a1 a2, check_neg_atom a1 a2 -> interp_atom a1 = negb (interp_atom a2).

  Local Notation interp_var := (interp_state_var interp_atom interp_bvatom t_form).
  Local Notation interp_lit := (Lit.interp interp_var).

  Lemma interp_Fnot2 : forall i l, interp interp_atom interp_bvatom t_form (Fnot2 i l) = interp_lit l.
  Proof.
    intros i l;simpl.
    apply foldi_ind.
    apply leb_0.
    reflexivity.
    intros; rewrite negb_involutive; assumption.
  Qed.

  Lemma remove_not_correct :
    forall l, interp_lit (remove_not l) = interp_lit l.
  Proof.
    unfold remove_not;intros l.
    case_eq (get_form (Lit.blit l));intros;trivial.
    unfold Lit.interp, Var.interp.
    rewrite (wf_interp_form interp_atom interp_bvatom t_form default_thf wf_thf (Lit.blit l)), H, interp_Fnot2.
    destruct(Lit.is_pos l);trivial.
    rewrite Lit.is_pos_neg, Lit.blit_neg;unfold Lit.interp;destruct (Lit.is_pos i0);trivial.
    rewrite negb_involutive;trivial.
  Qed.

  Lemma get_and_correct : forall l args, get_and l = Some args ->
    interp_lit l = interp interp_atom interp_bvatom t_form (Fand args).
  Proof.
    unfold get_and;intros l args.
    rewrite <- remove_not_correct;unfold Lit.interp;generalize (remove_not l).
    intros l';unfold Var.interp.
    destruct (Lit.is_pos l');[ | discriminate].
    rewrite wf_interp_form;trivial.
    destruct (get_form (Lit.blit l'));intros Heq;inversion Heq;trivial.
  Qed.

  Lemma get_or_correct : forall l args, get_or l = Some args ->
    interp_lit l = interp interp_atom interp_bvatom t_form (For args).
  Proof.
    unfold get_or;intros l args.
    rewrite <- remove_not_correct;unfold Lit.interp;generalize (remove_not l).
    intros l';unfold Var.interp.
    destruct (Lit.is_pos l');[ | discriminate].
    rewrite wf_interp_form;trivial.
    destruct (get_form (Lit.blit l'));intros Heq;inversion Heq;trivial.
  Qed.

  Lemma flatten_and_correct : forall args,
    List.fold_right (fun l res => andb res (interp_lit l)) true (flatten_and args) =
    afold_left _ true andb (amap interp_lit args).
  Proof.
    intros;rewrite afold_left_spec;auto;unfold flatten_and.
    change true with (List.fold_right (fun (l : int) (res : bool) => res && interp_lit l) true nil) at 2.
    rewrite !foldi_to_list, to_list_amap.
    generalize (@nil int);induction (to_list args);simpl;trivial.
    intros l0;rewrite IHl.
    clear IHl;f_equal; unfold flatten_op_lit.
    clear l;revert a l0;apply foldi_ind;simpl;trivial.
    apply leb_0.
    intros i cont _ Hlt Hrec a l;unfold flatten_op_body.
    case_eq (get_and a);intros;trivial.
    rewrite get_and_correct with (1:= H);simpl.
    rewrite afold_left_spec; auto; rewrite !foldi_to_list.
    rewrite <- !fold_left_rev_right, to_list_amap, <- map_rev.
    clear H a;revert l;induction (List.rev (to_list a0));simpl.
    intros l;rewrite andb_true_r;trivial.
    intros;rewrite Hrec, IHl, andb_assoc;trivial.
  Qed.

  Lemma flatten_or_correct : forall args,
    List.fold_right (fun l res => orb res (interp_lit l)) false (flatten_or args) =
    afold_left _ false orb (amap interp_lit args).
  Proof.
    intros;rewrite afold_left_spec;auto;unfold flatten_or.
    change false with (List.fold_right (fun (l : int) (res : bool) => res || interp_lit l) false nil) at 2.
    rewrite !foldi_to_list, to_list_amap.
    generalize (@nil int);induction (to_list args);simpl;trivial.
    intros l0;rewrite IHl.
    clear IHl;f_equal; unfold flatten_op_lit.
    clear l;revert a l0;apply foldi_ind;simpl;trivial.
    apply leb_0.
    intros i cont _ Hlt Hrec a l;unfold flatten_op_body.
    case_eq (get_or a);intros;trivial.
    rewrite get_or_correct with (1:= H);simpl.
    rewrite afold_left_spec; auto; rewrite !foldi_to_list.
    rewrite <- !fold_left_rev_right, to_list_amap, <- map_rev.
    clear H a;revert l;induction (List.rev (to_list a0));simpl.
    intros l;rewrite orb_false_r;trivial.
    intros;rewrite Hrec, IHl, orb_assoc;trivial.
  Qed.

  Lemma check_flatten_aux_correct : forall l lf,
    check_flatten_aux l lf = true ->
    interp_lit l = interp_lit lf.
  Proof.
    unfold check_flatten_aux.
    apply foldi_ind.
    apply leb_0.
    discriminate.
    intros i cont _ Hle Hrec l lf;unfold check_flatten_body.
    rewrite <- (remove_not_correct l), <- (remove_not_correct lf).
    generalize (remove_not l) (remove_not lf);clear l lf;intros l lf.
    destruct (reflect_eqb l lf);[ intros;subst;trivial | ].
    destruct (reflect_eqb (1 land (l lxor lf)) 0).
    unfold Lit.interp.
    assert (Lit.is_pos l = Lit.is_pos lf).
    unfold Lit.is_pos.
    rewrite <- eqb_spec, landC in e.
    change (is_true (is_even (l lxor lf))) in e.
    rewrite is_even_xor in e.
    destruct (is_even l);destruct (is_even lf);trivial;discriminate.
    rewrite H;match goal with
                |- ?P -> _ =>
                assert (W:P -> Var.interp interp_var (Lit.blit l) = Var.interp interp_var (Lit.blit lf));
                  [ | intros;rewrite W;trivial]
              end.
    unfold Var.interp;rewrite !wf_interp_form;trivial.
    clear e n H.
    destruct (get_form (Lit.blit l));
      destruct (get_form (Lit.blit lf));intros;try discriminate;simpl;trivial.
     (* atom *)
    apply check_atom_correct;trivial.
     (* and *)
    rewrite <- !flatten_and_correct.
    revert H;generalize (flatten_and a) (flatten_and a0);clear a a0.
    induction l0;intros l1;destruct l1;simpl;trivial;try discriminate.
    rewrite andb_true_iff;intros (H1, H2).
    rewrite (Hrec _ _ H1), (IHl0 _ H2);trivial.
     (* or *)
    rewrite <- !flatten_or_correct.
    revert H;generalize (flatten_or a) (flatten_or a0);clear a a0.
    induction l0;intros l1;destruct l1;simpl;trivial;try discriminate.
    rewrite andb_true_iff;intros (H1, H2).
    rewrite (Hrec _ _ H1), (IHl0 _ H2);trivial.
     (* implb *)
    revert H;destruct (reflect_eqb (length a) (length a0));[intros|discriminate].
    apply afold_right_eq;rewrite !length_amap;trivial.
    intros;rewrite !get_amap by congruence;rewrite aforallbi_spec in H;auto.
     (* xorb *)
    unfold is_true in H;rewrite andb_true_iff in H;destruct H as [H H0].
    rewrite (Hrec _ _ H), (Hrec _ _ H0);trivial.
    (* eqb (i.e iff) *)
    unfold is_true in H;rewrite andb_true_iff in H;destruct H as [H H0].
    rewrite (Hrec _ _ H), (Hrec _ _ H0);trivial.
     (* ifb *)
    unfold is_true in H;rewrite !andb_true_iff in H;destruct H as [[H H0] H1].
    rewrite (Hrec _ _ H), (Hrec _ _ H0), (Hrec _ _ H1);trivial.
     (** opposite sign *)
    assert (Lit.is_pos l = negb (Lit.is_pos lf)).
    unfold Lit.is_pos.
    rewrite <- eqb_spec, landC in n0.
    change (~is_true (is_even (l lxor lf))) in n0.
    rewrite is_even_xor in n0.
    destruct (is_even l);destruct (is_even lf);trivial;elim n0;reflexivity.
    unfold Lit.interp;rewrite H. match goal with
                                  |- ?P -> _ =>
                                  assert (W:P -> Var.interp interp_var (Lit.blit l) = negb (Var.interp interp_var (Lit.blit lf)));
                                    [ | intros;rewrite W;trivial]
                                end.
    unfold Var.interp;rewrite !wf_interp_form;trivial.
    destruct (get_form (Lit.blit l));try discriminate.
    destruct (get_form (Lit.blit lf));try discriminate.
    apply check_neg_atom_correct.
    rewrite negb_involutive;destruct (Lit.is_pos lf);trivial.
  Qed.

  Hypothesis Hwf: Valuation.wf interp_var.

  Lemma valid_check_flatten : forall s, S.valid interp_var s ->
    forall cid lf, C.valid interp_var (check_flatten s cid lf).
  Proof.
    unfold check_flatten; intros s Hs cid lf; case_eq (S.get s cid).
    intros; apply C.interp_true; auto.
    intros i [ |l q] Heq; try apply C.interp_true; auto; case_eq (check_flatten_aux i lf); intro Heq2; try apply C.interp_true; auto; unfold C.valid; simpl; rewrite <- (check_flatten_aux_correct _ _ Heq2); unfold S.valid in Hs; generalize (Hs cid); rewrite Heq; auto.
  Qed.

End FLATTEN.

(* 
   Local Variables:
   coq-load-path: ((rec ".." "SMTCoq"))
   End: 
*)
