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

**Conclusión Fase 0:** En este repo Maven **de un módulo** la causa **no** es profundidad ni ruido de build (`/target/` ya está en `.gitignore`, `target/` tiene ~50 archivos). `extract .` desde raíz **no indexa** `src/main/java` — solo `pom.xml`. Hay que acotar el corpus a `src/main` **y** usar `--out .` para dejar el grafo en la raíz. `graphify update .` **no** es sustituto del extract acotado.

### 2.4 Fase multi-módulo — Diagnóstico real (`BESOP`, 2026-09-10)

`C:\SFP\monoliticos\BESOP` es un POM aggregator (`packaging=pom`), **sin** `src/main` en la raíz:

| Módulo | Packaging | `.java` en `src/main` | ¿Graphify? |
|--------|-----------|----------------------|------------|
| BESOP-utils | jar | 119 | Sí |
| BESOP-jpa | ejb | 948 | Sí |
| BESOP-ejb | ejb | 350 | Sí |
| BESOP-web | war | 219 | Sí (Java; Facelets `.xhtml` no se indexan) |
| BESOP-ear | ear | 0 | No (solo empaqueta) |

`graphify detect` desde la **raíz de BESOP** (no el caso `ip-registro-back`):

| Métrica | Valor |
|---------|-------|
| Code files | 1686 (1668 `.java` + poms + js) |
| `.java` main / test | 1636 / 32 |
| Por módulo | jpa 967, ejb 358, web 222, utils 121 |
| `target/` | podado (`_SKIP_DIRS`) |

El nodo único en la raíz aparece cuando el extract no entra a los módulos (solo el POM padre) o cuando el script buscaba un único `src/main` en el aggregator y no lo encontraba.

### 2.5 Corrida real (`workspace-cursor.cmd` en BESOP, 2026-09-10)

El inicializador detectó bien el aggregator (4 módulos, 1636 `.java`) y terminó en **1.81 s**. `graphify-out/graph.json` quedó con **1 nodo** (`mx.gob.sfp:BESOP`, el POM padre), `manifest.json` solo tiene `pom.xml`, y **no hay `graph.html`**.

Eso no es un extract de 1636 clases (tardaría minutos). Había **dos graphify** en la máquina:

| Binario | Versión | `detect` en la raíz de BESOP |
|---------|---------|------------------------------|
| PATH (`pythoncore-3.14-64\Scripts\graphify.exe`) | **0.9.15** | **1** code file (`pom.xml`), 9 archivos en total |
| uv tool (`...\uv\tools\graphifyy\Scripts\graphify.exe`) | **0.9.28** | **1686** code (1668 `.java`) |

`workspace-cursor.ps1` llamaba al `graphify` del PATH (0.9.15). En 0.9.15 un `.gitignore` anidado se aplica a **todo** el repo. BESOP tiene `.github/modernize/java-upgrade/.gitignore` con `**/*`, así que el walk **no baja** a `BESOP-ejb` / `jpa` / `web` / `utils`. 0.9.28 acota esos patrones al directorio del ignore (issue #1206).

`--no-viz` es correcto en un grafo grande (~28 000 nodos): el HTML se omite a propósito. En el grafo stub de 1 nodo no habría hecho falta, pero el síntoma real era la versión vieja, no el flag.

**El script ahora elige el graphify más nuevo (≥ 0.9.28, preferencia uv), fuerza `--force` si el grafo existente es stub, y falla si tras el extract hay menos de 20 nodos con ≥20 `.java`.**

### 2.6 Aviso de skill en stderr (`graphify` 0.9.58, 2026-09-11)

`graphify --version` 0.9.58 imprime en **stderr** avisos de skills desactualizadas (Copilot/Claude 0.9.15 vs paquete 0.9.58) y el número de versión en **stdout**. `workspace-cursor.ps1` usa `$ErrorActionPreference = Stop` y capturaba `--version` con `2>&1`; PowerShell convierte esas líneas en `ErrorRecord` y abortaba **antes** del extract:

```
[ERROR] warning: skill at ...\.copilot\skills\graphify is from graphify 0.9.15, package is 0.9.58.
```

Eso no es un fallo de graphify (exit code 0). El script ahora ignora esos avisos al leer la versión, no toma `0.9.15` del texto del warning, y los muestra como `[INFO]`.

`graphify install --platform claude` desde una terminal **no** actualiza las skills si el `graphify` del PATH sigue siendo el pip 0.9.15. En esta máquina coexisten:

| Binario | Origen | Qué hace `graphify install` |
|---------|--------|-----------------------------|
| `%USERPROFILE%\AppData\Local\Python\pythoncore-*\Scripts\graphify.exe` | `pip install graphifyy` | Reescribe skills **0.9.15** (el banner lo muestra) |
| `%USERPROFILE%\.local\bin\graphify.exe` | `uv tool install graphifyy` | Instala skills **0.9.58** |

`uv tool install --upgrade graphifyy` **no** mete el shim en PATH (uv lo avisa). Hay que invocar el exe de uv, no el nombre `graphify`:

```powershell
& "$env:USERPROFILE\.local\bin\graphify.exe" install --platform claude
& "$env:USERPROFILE\.local\bin\graphify.exe" install --platform copilot
```

Para que `graphify` en la terminal deje de aferrarse a 0.9.15: `python -m pip uninstall graphifyy` y `uv tool update-shell` (el shim de uv primero en PATH).

`uv tool update-shell` escribe `~\.local\bin` en el **PATH de usuario del registro**. Las terminales (y Cursor) que ya estaban abiertas **no** lo ven: `where.exe graphify` queda vacío tras el `pip uninstall` aunque el exe de uv exista. Hay que **cerrar Cursor por completo** y reabrirlo, o recargar PATH en esa sesión:

```powershell
$env:PATH = [Environment]::GetEnvironmentVariable("Path","User") + ";" + [Environment]::GetEnvironmentVariable("Path","Machine")
where.exe graphify
graphify --version
```

El inicializador **no** corre `graphify install` solo: escribe fuera del repo y puede pisar skills editadas.

**No extraer un grafo por módulo** ni usar `merge-graphs`:

- Graphify resuelve imports Java **dentro del mismo extract** (`_resolve_cross_file_java_imports`). Eso es lo que conecta `web → ejb → jpa → utils`.
- `merge-graphs` prefija ids (`BESOP-ejb::Foo` vs `BESOP-jpa::Foo`) y **rompe** esa identidad. Sirve para repos distintos, no para un EAR.
- Cursor busca `graphify-out/` en la raíz del workspace; grafos por carpeta dejan al agente ciego.
- Un extract por módulo solo tiene sentido como vista temporal (p. ej. solo JPA), sabiendo que se pierden las aristas entre capas.

Grafo estimado: ~1636 clases × ~17 nodos/archivo ≈ **~28 000 nodos** → `cluster-only --no-viz` (el HTML se agrega y parece un blob).

## 3. Causa raíz (confirmada en Fase 0)

- **Un módulo (`ip-registro-back`):** `graphify extract . --code-only` clasifica solo el `pom.xml` como code; los `.java` bajo `src/main/java` no entran al corpus. Hay que acotar a `src/main` y usar `--out .`.
- **Aggregator (`BESOP`):** `extract . --code-only` **sí** indexa el Java de los módulos hijos **con graphify ≥ 0.9.28**. Con 0.9.15 un `.gitignore` anidado (`**/*`) oculta los módulos y el grafo queda en 1 nodo (POM padre). El script debe usar ese binario (no el `graphify` viejo del PATH) y no buscar un único `src/main` en el padre.
- **Ubicación de salida:** Sin `--out`, graphify escribe `graphify-out/` **dentro del path escaneado** (`--out DIR` escribe `<DIR>/graphify-out/`; default `DIR` = path del extract).
- **Ciclo `update .`:** Tras un extract acotado con `--out .`, `graphify update .` vuelve a escanear la raíz (1 nodo) y **rechaza** sobrescribir (fail-closed). El incremental equivalente es repetir el **mismo** extract (un módulo: `src/main --out .`; aggregator: `.`).

Hipótesis descartadas en `ip-registro-back`:

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

### Opción D — Aggregator Maven: un grafo en la raíz (BESOP)

```
graphify extract . --code-only --no-cluster
graphify cluster-only . --no-viz
```

- Pros: un `graphify-out/` en la raíz; corpus completo; imports entre módulos; poms aportan `depends_on` Maven; `target/` ya se poda.
- Contras: corpus grande (HTML poco útil; usar `--no-viz`); Facelets `.xhtml` no entran al grafo.
- **No** `merge-graphs` entre módulos del mismo producto.
- EAR sin Java se ignora como extract aparte; en el scan de `.` solo aporta su `pom.xml`.

## 5. Estrategia `graphify update` vs rule (sin tocar `graphify.mdc`)

El rule (línea 21) manda `graphify update .` tras editar código. **No modificar el rule** es viable si se entiende el contrato:

| Comando | Scan root | Salida | Un módulo (`ip-registro-back`) | Aggregator (`BESOP`) |
|---------|-----------|--------|--------------------------------|----------------------|
| `graphify update .` | `.` | raíz | **No sirve**: corpus = `pom.xml`; fail-closed | Detect SÍ ve el Java, pero el script **no** lo usa: el incremental es re-extract |
| `graphify update src/main` | `src/main` | `src/main/graphify-out/` | Corpus OK, grafo fuera de la raíz | No hay `src/main` en la raíz |
| `graphify extract src/main --out . --code-only` | `src/main` | raíz | **Correcto** | Incorrecto: no hay `src/main` en el padre |
| `graphify extract . --code-only` | `.` | raíz | Corpus = `pom.xml` (1 nodo) | **Correcto con ≥0.9.28**: 1668 `.java`. Con 0.9.15: 1 nodo (ignore anidado) |
| `graphify merge-graphs` entre módulos | n/a | raíz | n/a | **No**: prefija ids y rompe imports cruzados |
| `graphify update . --force` | `.` | raíz | **Peligroso** (434 → 1) | No usar; re-extract `. --code-only` |

**Sustituto oficial de `update .` en Java:** repetir el extract acotado (mismo scan root + `--out .`). Graphify trata re-extract sobre grafo existente como incremental (solo archivos cambiados).

**Quién actualiza el grafo:**

| Quién | Hoy | Debe ser (Java) |
|-------|-----|-----------------|
| `workspace-cursor.ps1` | `extract .` / `update .` | Un módulo: `extract src/main --out . --code-only`. Aggregator: `extract . --code-only --no-cluster` + `cluster-only . --no-viz` si ≥500 `.java` |
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

### Fase 2 — `workspace-cursor.ps1` consciente de Java ✅ IMPLEMENTADA

`Get-JavaExtractPlan` clasifica el repo:

| Kind | Cómo se detecta | Extract | Cluster |
|------|-----------------|---------|---------|
| `aggregator` | `pom.xml` en raíz + ≥1 hijo con `pom.xml` y `src/main/java` | `extract . --code-only --no-cluster` | `cluster-only .` + `--no-viz` si ≥500 `.java` |
| `single-module` | `pom.xml` / Gradle + `src/main` (o `src/main/java`) en raíz, sin módulos Java hijos | `extract src/main --out . --code-only` | `cluster-only .` (+ `--no-viz` si ≥500 `.java`) |
| no Java | resto | `extract .` / `update .` | incluido en `update` |

**Un módulo** (`ip-registro-back`):

```powershell
graphify extract src/main --out . --code-only
graphify cluster-only .
```

**Aggregator** (`BESOP`):

```powershell
graphify extract . --code-only --no-cluster
graphify cluster-only . --no-viz
```

No usar `graphify update .` en Java. No extraer EAR ni `merge-graphs` entre módulos del mismo producto.

**Graphify ≥ 0.9.28:** el script resuelve el binario más nuevo (uv tool / `%USERPROFILE%\.local\bin` antes que PATH). 0.9.15 en PATH indexa solo el POM padre en BESOP; un `graphify install` de esa copia también reescribe skills 0.9.15. Si `graphify-out/graph.json` tiene menos de 10 nodos y hay 20 o más `.java`, re-extract con `--force`. Tras el extract, si el grafo sigue con menos de 20 nodos, el script falla (no reporta "Workspace Ready" con un stub). Avisos de skill en stderr (0.9.58+) no abortan el inicializador.

### Fase 2b — Multi-módulo aggregator ✅ IMPLEMENTADA

Ver sección 2.4. EAR sin Java no se extrae aparte. Vista por módulo: solo ad hoc, no es el default del script.

### Fase 3 — Verificación

1. Limpiar artefactos de prueba en `ip-registro-back` (ver `SOLICITUD-IP-REGISTRO-BACK.md`).
2. Correr `workspace-cursor.ps1` en el repo Java: `graphify-out/` en la **raíz** con ~434 nodos.
3. Editar un `.java` profundo y re-ejecutar el flujo Java (`extract src/main --out . --code-only`) → el grafo refleja el cambio.
4. Confirmar que `graphify update .` **no** se usa en Java (debe fallar o reducir a 1 nodo si se prueba a propósito).
5. Abrir Cursor: el agente encuentra `graphify-out/graph.json` en la raíz y `graphify query` responde.
6. En un aggregator (`BESOP`): `Get-JavaExtractPlan` → `Kind=aggregator`, graphify ≥ 0.9.28, extract `. --code-only --no-cluster` (`--force` si el grafo previo es stub), `cluster-only . --no-viz`; un solo `graphify-out/` en la raíz; EAR no se extrae aparte. `graph.html` ausente a propósito en corpus grande.

## 7. Criterios de aceptación

- `graphify-out/` siempre en la **raíz** del repo Java (un módulo o aggregator).
- Corpus Java completo (no solo `pom.xml`). Graphify ≥ 0.9.28; el inicializador no acepta un grafo stub (menos de 20 nodos con 20 o más `.java`).
- Un módulo: incremental vía `extract src/main --out . --code-only`, no `update .`.
- Aggregator: incremental vía `extract . --code-only`, un solo grafo, **sin** `merge-graphs` ni un grafo por EAR/EJB/JPA/web/utils.
- Corpus grande (≥500 `.java`): `cluster-only --no-viz`.

## 8. Recomendación final

1. **Fase 0 cerrada:** en `ip-registro-back` el problema es corpus Maven desde raíz + `--out`, no profundidad.
2. **Fase 2 + 2b implementadas** en `workspace-cursor.ps1`: Opción B (un módulo) y Opción D (aggregator).
3. Pedir limpieza en el repo Java de un módulo antes de la corrida definitiva (`SOLICITUD-IP-REGISTRO-BACK.md`).
4. Valorar ajuste del rule o issue upstream para `update` con scan root persistido.
5. En monolitos JEE, graphify no indexa Facelets (`.xhtml`); el grafo web es backing beans / servicios Java.
