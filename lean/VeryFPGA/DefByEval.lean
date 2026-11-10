/-
`def_by_eval x : T := e` runs `e` at build time, defines `x` as the resulting
value written out as a literal, and adds the theorem `x_eq : e = x` proved by
`rfl`.

Not trusted: the kernel checks `x_eq` by evaluating `e` itself. If this
command produced a wrong literal, `x_eq` would be rejected and the build would
fail. It exists so that proofs can see the literal (for `simp` to unfold)
instead of the unevaluated `e`.
-/
import Lean

open Lean Elab Command Term Meta

namespace VeryFPGA

elab "def_by_eval " id:ident " : " ty:term " := " val:term : command => do
  let name := (← getCurrNamespace) ++ id.getId
  liftTermElabM do
    let tyE ← elabType ty
    let valE ← elabTermEnsuringType val tyE
    synthesizeSyntheticMVarsNoPostponing
    let valE ← instantiateMVars valE
    -- `T : Type u`: `ToExpr` takes `u`, `Eq` takes the sort level `u + 1`.
    let lvl ← instantiateLevelMVars (← getDecLevel tyE)
    let tyE ← instantiateMVars tyE
    if tyE.hasMVar || valE.hasMVar || lvl.hasMVar then
      throwError "def_by_eval: type or value still has metavariables"
    let inst ← synthInstance (mkApp (mkConst ``ToExpr [lvl]) tyE)
    -- Evaluate `toExpr val`, i.e. compute the value and turn it into a term.
    let lit ← unsafe evalExpr Expr (mkConst ``Expr)
      (mkApp3 (mkConst ``ToExpr.toExpr [lvl]) tyE inst valE)
    addAndCompile <| .defnDecl {
      name, levelParams := [], type := tyE, value := lit,
      hints := .regular 0, safety := .safe }
    enableRealizationsForConst name
    let lvl1 ← instantiateLevelMVars (← getLevel tyE)
    addDecl <| .thmDecl {
      name := name ++ `eq_def_by_eval, levelParams := []
      type := mkApp3 (mkConst ``Eq [lvl1]) tyE valE (mkConst name)
      value := mkApp2 (mkConst ``Eq.refl [lvl1]) tyE valE }

end VeryFPGA
