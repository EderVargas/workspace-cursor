# Plan de acción — Graphify en proyectos Java

## 1. Problema reportado

Al trabajar con proyectos Java:

1. `graphify extract .` desde la raíz "no llega hasta el fondo" (grafo incompleto).
2. Ejecutando `graphify extract src/main` sí funciona, **pero** sin `--out` el grafo se escribe en `src/main/graphify-out/` (no en la raíz).
3. Cursor y el rule (`.cursor/rules/graphify.mdc`) buscan `graphify-out/` en la **raíz** del proyecto.
4. Mover `src/main/graphify-out/` a la raíz rompe el ciclo de actualización.
5. El rule exige `graphify update .` tras cambios de código; en repos Java reales eso **no** re-sincroniza el corpus acotado (ver Fase 0).

## 2. Hallazgos verificados

### 2.1 Pruebas sintéticas (árbol Java anidado + `pom.xml`)

| Prueba | Resultado |
|--------|-----------|
| `graphify extract . --code-only` desde raíz | Encontró **todos** los `.java`, incluido el más profundo (9 nodos). La profundidad NO es el problema en repos pequeños. |
| `graphify extract src/main --out . --code-only` | Escanea `src/main` y escribe `graphify-out/` en la **raíz**. |
| `graphify update .` tras extract con `--out .` (repo sintético) | Re-sincronizó correcto en el caso sintético. |

### 2.2 Fase 0 — Diagnóstico real (`ip-registro-back`)

Artefactos de referencia (renombrados para comparar, no son la ubicación final):

| Artefacto | Comando usado | Salida real | `code` encontrados | Nodos en `graph.json` |
|-----------|---------------|-------------|--------------------|-----------------------|
| `graphify-out_1/` | `graphify extract . --code-only` | `./graphify-out_1/` (raíz) | **1** (solo `pom.xml`) | **1** |
| `src/main/graphify-out_2/` | `graphify extract src/main --code-only` | `src/main/graphify-out/` → renombrado a `_2` | **54** (25 `.java` + recursos clasificados como code) | **434** |

Comportamiento de `--out` (confirmado en repo real):

| Comando | Dónde escribe |
|---------|---------------|
| `graphify extract src/main --code-only` | `<path>/graphify-out/` → **`src/main/graphify-out/`** |
| `graphify extract src/main --out . --code-only` (desde raíz) | **`./graphify-out/`** en la raíz |

Pruebas adicionales en `ip-registro-back`:

| Prueba | Resultado |
|--------|-----------|
| `graphify update .` con grafo de 434 nodos (extract `src/main --out .`) | **Falla segura**: re-escanea `.`, corpus nuevo = 1 nodo (`pom.xml`); **no sobrescribe** el grafo existente. |
| `graphify update src/main` | Actualiza **`src/main/graphify-out/`**, no la raíz. |
| `graphify extract src/main --out . --code-only` (re-corrida) | Incremental OK → escribe en **`./graphify-out/`** (mismo comando que la 1ª corrida). |

### 2.3 Validación end-to-end (2026-07-31, `ip-registro-back`)

Flujo recomendado ejecutado manualmente desde la raíz del repo:

```powershell
graphify extract src/main --out . --code-only
graphify cluster-only .
```

| Métrica | Valor |
|---------|-------|
| Code files | 25 (`.java`) |
| Skipped (no ext) | `MANIFEST.MF`, `ip_registro.properties`, `keystore.jceks` |
| Nodos | 434 |
| Edges | 1098 |
| Communities | 16 |
| Salida | `./graphify-out/graph.json` |

`graphify cluster-only .` → OK (report + comunidades nombradas).

`graphify update .` tras el extract acotado:

```
Re-extracting code files in . (no LLM needed)...
[graphify watch] fail-closed: kept 350 node(s) from 25 file(s) that left the scan corpus ...
[graphify] WARNING: new graph has 1 nodes but existing graph.json has 434. Refusing to overwrite ...
Nothing to update or rebuild failed — check output above.
```

Interpretación:

- `update .` usa **scan root = `.`** (raíz Maven), no el `src/main` del extract original.
- Fail-closed **protege** el grafo: no degrada 434 → 1 nodo.
- Los 350 nodos “kept” son AST de los 25 `.java` que ya no están en el corpus de `.`.
- `--force` degradaría el grafo a 1 nodo — **no usar** en Java con extract acotado.

**Conclusión Fase 0:** En este repo Maven la causa **no** es profundidad ni ruido de build (`/target/` ya está en `.gitignore`, `target/` tiene ~50 archivos). `extract .` desde raíz **no indexa** `src/main/java` — solo `pom.xml`. Hay que acotar el corpus a `src/main` **y** usar `--out .` para dejar el grafo en la raíz. `graphify update .` **no** es sustituto del extract acotado.

## 3. Causa raíz (confirmada en Fase 0)

- **Escaneo desde raíz en Maven real:** `graphify extract . --code-only` clasifica solo el `pom.xml` como code; los `.java` bajo `src/main/java` no entran al corpus.
- **Ubicación de salida:** Sin `--out`, graphify escribe `graphify-out/` **dentro del path escaneado** (`--out DIR` escribe `<DIR>/graphify-out/`; default `DIR` = path del extract).
- **Ciclo `update .`:** Tras un extract acotado con `--out .`, `graphify update .` vuelve a escanear la raíz (1 nodo) y **rechaza** sobrescribir (fail-closed). El incremental equivalente es repetir `graphify extract src/main --out . --code-only` con el **mismo** scan root y `--out`.

Hipótesis descartadas en este repo:

- ~~Profundidad de carpetas~~
- ~~Ruido masivo de `target/`~~ (ya ignorado; corpus pequeño)

## 4. Opciones de solución

### Opción A — Excluir artefactos de build (complementaria, no suficiente sola)

Excluir `target/`, `build/`, etc. ayuda en repos grandes con mucho ruido de build, pero **no** arregla `ip-registro-back` (el extract desde raíz sigue viendo solo `pom.xml`).

- Pros: útil para multi-módulo y repos con `target/` enorme; bajo costo en `workspace-cursor.ps1`.
- Contras: sola no resuelve el caso Maven verificado en Fase 0.

### Opción B — Acotar extract al source root con `--out .` (recomendada)

```
graphify extract src/main --out . --code-only
graphify cluster-only .
```

Para **actualizaciones** (sustituye `graphify update .` en repos Java):

```
graphify extract src/main --out . --code-only
```

- Pros: grafo en la raíz; corpus completo (25 `.java` / 434 nodos en `ip-registro-back`); incremental funciona con el mismo comando.
- Contras: el rule actual manda `graphify update .`, que **rompe** el grafo Java; hay que adaptar `workspace-cursor.ps1` (y eventualmente documentar excepción en el rule o pedir a graphify que persista el scan root con `--out`).

### Opción C — Junction de directorio (descartada)

`graphify update .` desde raíz no alinea con extract desde `src/main`. Requiere tocar el rule y no resuelve el corpus vacío en `.`.

## 5. Estrategia `graphify update` vs rule (sin tocar `graphify.mdc`)

El rule (línea 21) manda `graphify update .` tras editar código. **No modificar el rule** es viable si se entiende el contrato:

| Comando | Scan root | Salida | Java Maven |
|---------|-----------|--------|------------|
| `graphify update .` | `.` | `graphify-out/` raíz | **No sirve**: corpus = `pom.xml`; fail-closed evita corrupción |
| `graphify update src/main` | `src/main` | `src/main/graphify-out/` | Corpus OK pero **grafo fuera de la raíz** (rule no lo encuentra) |
| `graphify extract src/main --out . --code-only` | `src/main` | `graphify-out/` raíz | **Correcto**: AST-only, incremental en re-corridas |
| `graphify update . --force` | `.` | raíz | **Peligroso**: degradaría 434 → 1 nodo |

**Sustituto oficial de `update .` en Java:** repetir el extract acotado (mismo scan root + `--out .`). Graphify trata re-extract sobre grafo existente como incremental (solo archivos cambiados).

**Quién actualiza el grafo:**

| Quién | Hoy | Debe ser (Java) |
|-------|-----|-----------------|
| `workspace-cursor.ps1` | `extract .` / `update .` | `extract <srcRoot> --out . --code-only` (+ `cluster-only` en 1ª corrida) |
| Agente tras editar (rule) | `graphify update .` | En Java: falla segura, grafo queda stale hasta re-extract acotado |

Opciones sin editar el rule:

1. **Recomendada:** Fase 2 en script — grafo fresco al abrir workspace; `update .` del agente en Java es redundante la mayoría del tiempo.
2. **Complemento:** agente detecta `pom.xml` + fallo de `update .` → ejecuta `graphify extract <srcRoot> --out . --code-only` (misma intención del rule, distinto comando). No requiere cambiar el rule si el agente infiere del fallo.
3. **Ideal (upstream):** graphify persiste scan root en `.graphify_analysis.json`; `graphify update .` re-escanea `src/main` automáticamente → rule y Java alineados sin excepción.

Opción descartada para Java: solo cambiar el script y dejar que el agente use `update .` — falla sin actualizar (stale graph en sesión larga).

## 6. Plan de acción (revisado post Fase 0)

### Fase 0 — Diagnóstico ✅ COMPLETADA

Ver sección 2.2. Referencia: `ip-registro-back` con `graphify-out_1/` y `src/main/graphify-out_2/`.

### Fase 1 — Excluir artefactos de build (Opción A, complementaria)

Agregar al `.gitignore` gestionado por `workspace-cursor.ps1`:

```
target/
build/
.gradle/
bin/
out/
```

No sustituye la Opción B en Maven; evita regresiones en otros repos Java grandes.

### Fase 2 — `workspace-cursor.ps1` consciente de Java (Opción B, **principal**)

Detectar proyecto Java (`pom.xml`, `build.gradle`, `build.gradle.kts`) y source root (`src/main/java` o `src/main`).

**Primera corrida** (no existe `graphify-out/`):

```powershell
graphify extract <SRC_ROOT> --out . --code-only
graphify cluster-only .
```

**Corridas siguientes** (existe `graphify-out/`):

```powershell
# NO usar graphify update . en Java — re-escanea raíz y deja solo pom.xml
graphify extract <SRC_ROOT> --out . --code-only
# cluster corre por defecto en extract; si se usó --no-cluster, cluster-only .
```

Bosquejo en `Update-Graph`:

```powershell
function Get-JavaSourceRoot {
    if ((Test-Path "pom.xml") -or (Test-Path "build.gradle") -or (Test-Path "build.gradle.kts")) {
        foreach ($c in @("src/main/java", "src/main")) {
            if (Test-Path $c) { return $c }
        }
    }
    return $null
}

$srcRoot = Get-JavaSourceRoot
if ($srcRoot) {
    Invoke-Graphify -Arguments @("extract", $srcRoot, "--out", ".", "--code-only")
} elseif (-not $graphExists) {
    Invoke-Graphify -Arguments @("extract", ".", "--code-only")
} else {
    Invoke-Graphify -Arguments @("update", ".")
}
if (-not $graphExists -or $srcRoot) {
    Invoke-Graphify -Arguments @("cluster-only", ".")  # solo si hace falta
}
```

### Fase 3 — Verificación

1. Limpiar artefactos de prueba en `ip-registro-back` (ver `SOLICITUD-IP-REGISTRO-BACK.md`).
2. Correr `workspace-cursor.ps1` en el repo Java: `graphify-out/` en la **raíz** con ~434 nodos.
3. Editar un `.java` profundo y re-ejecutar el flujo Java (`extract src/main --out . --code-only`) → el grafo refleja el cambio.
4. Confirmar que `graphify update .` **no** se usa en Java (debe fallar o reducir a 1 nodo si se prueba a propósito).
5. Abrir Cursor: el agente encuentra `graphify-out/graph.json` en la raíz y `graphify query` responde.

## 7. Criterios de aceptación

- `graphify-out/` siempre en la **raíz** del repo Java.
- Corpus Java completo (no solo `pom.xml`).
- Actualización incremental vía `extract <srcRoot> --out . --code-only`, no `update .`.
- Multi-módulo: evaluar lista de `src/main` por módulo o mantener Opción A + extract desde raíz si graphify lo soporta en el futuro.

## 8. Recomendación final

1. **Fase 0 cerrada:** el problema en `ip-registro-back` es corpus Maven desde raíz + ubicación de salida sin `--out`, no profundidad.
2. Implementar **Opción B en Fase 2** como camino principal; Fase 1 como hardening.
3. Pedir limpieza en el repo Java antes de la corrida definitiva (`SOLICITUD-IP-REGISTRO-BACK.md`).
4. Valorar ajuste del rule o issue upstream para `update` con scan root persistido.
