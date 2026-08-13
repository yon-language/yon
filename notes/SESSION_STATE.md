# Yon — stato di sessione (handoff)

> File LOCALE, non committarlo (aggiungilo a .gitignore o cancellalo dopo).
> Nuova sessione: apri la cartella `yon`, di' "leggi SESSION_STATE.md e continua".

## Contesto build (vincoli)
- Il sandbox NON compila Yon (binari Mach-O su Linux). La validazione la fa Antonio sul Mac:
  `cd frontend && dune build` + `cmake --build mlir/build --target topos-opt` + `bash swarm/hooks/gate.sh`.
- Disciplina: una modifica per volta, ogni gap con sonda red→green. Verificare la
  RAGIONE del rifiuto (stderr), non solo l'exit code (trappola "right answer, wrong reason").
- Quirk: a volte resta `.git/index.lock` dai comandi sandbox → `rm -f .git/index.lock`.
- Push: COVERAGE.md è già su origin/main (ok pusharlo). NON pushare: manuscript/, website/,
  to-fix.md, todo-1.2.md, work-items.md, e questo SESSION_STATE.md.

## Git
- Branch main, ultimo commit committato: `0ff29ab` (test-holes + cleanup), in sync con origin/main.
- IN SOSPESO (DA COMMITTARE — vedi comando sotto): batch #54/#57.

### Commit da fare per primo
```bash
cd ~/Projects/yon && rm -f .git/index.lock
git add frontend/lexer.mll frontend/parser.mly \
        regression/test_yon_coverage.py regression/COVERAGE.md \
        regression/keyword_coverage/c_bool_logic.yon \
        regression/keyword_coverage/c_forever.yon \
        regression/_pending_construct_tests/
git commit -m "construct coverage (#54/#57): comment-phantom audit + honest harness"
```
(gate già verde a 777 con queste modifiche)

## Fatto in questa sessione
- child_exit→noreturn (guard concorrenza reale), desugar oracle, handle-neg negativo cablato.
- Pulizia MLIR: rimossi 2 helper static morti (closureSizeFor/trampolineNameFor, F2b ritirato),
  corretti commenti bugiardi (merge wired, F2b/glue/escaping-probe RETIRED, no E0701).
- #54 copertura costrutti: scoperto che `test_yon_coverage.py` tokenizzava i COMMENTI →
  6 keyword coperte solo da commenti. Fix: strip commenti nell'harness. Risolti:
  `forever`,`and`,`or`,`true`,`false` → micro-test veri (c_forever.yon, c_bool_logic.yon);
  `objects` (OBJECTS_KW) = token orfano morto → rimosso da lexer.mll + parser.mly.
- #57: positivi già coperti da examples/c_*; slice-base / cell-endpoint / abstract-prop-param
  VERIFICATI accept-all (stub) → NON cablati (sarebbe falso-verde).

## Aperto (prossimi passi)

> Assorbito in `todo.md` il 2026-08-04: i quattro stub accept-all, la copertura
> keyword per isolamento e il resto vivono lì, nell'unico ledger. Questo file
> resta lo stato di sessione (contesto build, git, mappa pipeline), non una
> lista di lavoro parallela.


## Mappa pipeline (per orientarsi)
lexer.mll → parser.mly → surface_ast → desugar.ml → kernel ast → tycheck/dispatcher →
emit_mlir.ml (Topos dialect) → topos-opt (mlir/passes) → mlir-translate → llc → runtime → binario.
Harness chiave: regression/test_yon_coverage.py (keyword), test_projects.py (progetti emit),
test_yon_pipeline.py (exit code), test_oracle_checks.py (oracoli OCaml [PASS]/[FAIL]).
