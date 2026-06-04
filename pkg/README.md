# yon-pkg — package manager git-based

"Tutto su git": nessun registry, nessun hosting. Le dipendenze sono repository
git risolti in ./yon_modules/.

## Struttura del progetto
- Package = directory: tutti i .yon in una cartella condividono lo scope.
- `main` presente = eseguibile; assente = libreria (convenzione, nessun flag).
- Tutti i simboli sono visibili (pub opzionale in futuro).

## Manifest (yon.toml)
```
[package]
name = "mio-progetto"
version = "0.1.0"

[dependencies]
geometria = { git = "https://github.com/utente/geometria", version = "1.2" }
algebra   = { git = "https://github.com/altro/algebra", rev = "abc123" }
```
version = tag git (vV o V); rev = commit/branch esplicito.

## Comandi
- `yon-pkg init [nome]` — crea yon.toml
- `yon-pkg install` — clona dipendenze in yon_modules/, genera yon.lock
- `yon-pkg update` — re-risolve le versioni
- `yon-pkg list` — elenca le dipendenze

## Import nel codice
```
import "github.com/utente/geometria"   // dipendenza git -> yon_modules/geometria
import "./sottocartella"               // pacchetto locale relativo
```
L'import porta nello scope tutti i world/place/fun/functor del pacchetto.

## Lockfile (yon.lock)
Generato da yon-pkg, registra i commit esatti risolti. Commit nel repo per
build riproducibili. NON modificare a mano.
