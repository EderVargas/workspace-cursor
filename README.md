# Workspace Init — Graphify + Cursor

Herramienta de PowerShell que prepara un proyecto Git para trabajar con [Graphify](https://github.com/graphify) y Cursor **antes** de abrir el agente. Todo el trabajo pesado (instalar reglas, extraer/actualizar el grafo, clusters) se hace localmente y sin consumir tokens del agente.

## Requisitos previos

| Requisito | Descripción |
|-----------|-------------|
| **Windows** | PowerShell 5.1 o superior (incluido en Windows 10/11) |
| **Git** | El directorio de trabajo debe ser un repositorio Git (carpeta `.git` presente) |
| **Graphify** | CLI `graphify` instalado y disponible en el `PATH` del sistema |

### Instalar Graphify

Si `graphify` no está en el PATH, el script se detiene con error. Consulta la documentación oficial de Graphify para la instalación en tu entorno.

## Instalación global (una sola vez)

Para ejecutar el comando `workspace` desde cualquier carpeta sin copiar los scripts en cada proyecto:

### 1. Clonar o copiar este repositorio

Ejemplo (cualquier ubicación válida):

```
C:\tools\workspace-init\
```

### 2. Verificar `workspace-cursor.cmd`

El archivo `.cmd` incluido en el repositorio resuelve la ruta del script automáticamente (`%~dp0`), sin configuración manual:

```cmd
@echo off
powershell.exe -ExecutionPolicy Bypass -File "%~dp0workspace-cursor.ps1"
```

No edites rutas absolutas: funciona donde sea que clones el repositorio.

### 3. Agregar la carpeta al PATH de Windows

Añade la carpeta que contiene `workspace-cursor.cmd` (la raíz del clone, por ejemplo `C:\tools\workspace-init`) a las variables de entorno del sistema o del usuario.

### 4. Abrir una terminal nueva

Los cambios en el PATH solo aplican en sesiones nuevas.

### 5. Probar

```powershell
cd C:\ruta\a\tu\proyecto
workspace
```

El script opera siempre sobre el **directorio actual** (`.`), no sobre la carpeta donde está instalado.

## Uso

Desde la raíz de cualquier repositorio Git:

```powershell
workspace
```

También puedes ejecutar el script directamente sin instalarlo en el PATH (desde la carpeta del repositorio):

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\workspace-cursor.ps1"
```

## Escenarios de ejecución

### Escenario 1 — Primera vez en un proyecto

**Condiciones:**

- Existe `.git`
- No existe `graphify-out/`
- Puede o no existir `.cursor/rules/graphify.mdc`

**Qué hace el script:**

1. Valida Git y Graphify
2. Si no hay reglas de Cursor → ejecuta `graphify cursor install`
3. Crea o actualiza `.gitignore` con `.cursor/`, `graphify-out/` y `.cursorignore`
4. Crea `.cursorignore` si no existe, o añade `!graphify-out/` y `!graphify-out/**` si faltan
5. Ejecuta `graphify extract . --code-only` (construcción inicial del grafo)
6. Ejecuta `graphify cluster-only .` (agrupación de comunidades)

**Resultado:** proyecto listo con grafo nuevo, reglas de Cursor y archivos generados ignorados por Git.

---

### Escenario 2 — Proyecto ya inicializado

**Condiciones:**

- Existe `.git`
- Ya existe `graphify-out/` (ejecución anterior)

**Qué hace el script:**

1. Valida Git y Graphify
2. Omite `graphify cursor install` si `.cursor/rules/graphify.mdc` ya existe
3. Asegura entradas en `.gitignore` y las reglas de `graphify-out/` en `.cursorignore` (sin duplicar)
4. Ejecuta `graphify update .` (actualiza el grafo; los clusters se incluyen por defecto)

**Resultado:** grafo actualizado de forma incremental. Más rápido que la primera ejecución.

---

### Escenario 3 — Reglas de Cursor ya instaladas

**Condiciones:**

- Existe `.cursor/rules/graphify.mdc`

**Comportamiento:** no vuelve a ejecutar `graphify cursor install`. La etapa "Cursor Rules" termina en menos de un segundo.

---

### Escenario 4 — `.gitignore` incompleto o ausente

**Condiciones:**

- No existe `.gitignore`, o existe pero le faltan entradas

**Comportamiento:**

- Crea `.gitignore` si no existe
- Añade al final `.cursor/`, `graphify-out/` y `.cursorignore` solo si faltan
- No duplica líneas existentes
- Crea `.cursorignore` si no existe. Si ya existe, conserva sus reglas y añade solo las que falten:

```
!graphify-out/
!graphify-out/**
```

Esas negaciones reabren el grafo para el agente sin versionarlo. Con **Index Repositories for Instant Grep** activo, Cursor no deshace un path ya ignorado por git: Grep y Glob pueden seguir sin ver `graphify-out/`. En ese caso el agente lo lee por ruta directa o ejecuta `graphify` en la terminal.

**Archivos que nunca deben versionarse:**

- `.cursor/` — configuración y reglas generadas por Graphify/Cursor
- `graphify-out/` — grafo de conocimiento, caché y reportes
- `.cursorignore` — reapertura local del grafo; cada máquina lo genera el script

---

### Escenario 5 — Error: no es un repositorio Git

**Condiciones:** no hay carpeta `.git` en el directorio actual

```
[ERROR] Not a Git repository (.git not found).
```

**Solución:** `cd` a la raíz del proyecto o ejecuta `git init` antes de continuar.

---

### Escenario 6 — Error: Graphify no instalado

**Condiciones:** el comando `graphify` no está en el PATH

```
[ERROR] Graphify is not installed or not in PATH.
```

**Solución:** instala Graphify y reinicia la terminal.

---

### Escenario 7 — Error durante Graphify

Si cualquier comando de Graphify falla (extract, update, cluster-only, cursor install), el script se detiene, muestra el mensaje de error y devuelve código de salida `1`.

## Salida esperada

Ejemplo en un proyecto ya inicializado:

```
======================================================
Workspace Initializer
======================================================

[OK] Git repository detected
[OK] Graphify installed
[OK] Cursor rules already installed
[OK] .gitignore updated
[OK] .cursorignore already includes graphify-out
[OK] Knowledge graph updated
[OK] Clusters updated (included in graph update)

------------------------------------------------------
Times

Cursor Rules.............     0.38 s
GitIgnore................     0.01 s
Graph Update.............     7.04 s
Cluster..................     0.00 s

------------------------------------------------------

Total....................     7.43 s

Workspace Ready.
```

En la primera ejecución, la etiqueta de tiempo muestra `Graph Extract` en lugar de `Graph Update`, y `Cluster` tendrá un valor distinto de cero.

## Etapas del script

| Etapa | Función | Comando Graphify (si aplica) |
|-------|---------|------------------------------|
| Validación Git | Comprueba `.git` | — |
| Validación Graphify | Comprueba `graphify` en PATH | — |
| Cursor Rules | Instala reglas solo si faltan | `graphify cursor install` |
| GitIgnore | Asegura `.gitignore` y las reglas de `.cursorignore` | — |
| Grafo (primera vez) | Extrae código y agrupa | `graphify extract . --code-only` + `graphify cluster-only .` |
| Grafo (siguientes) | Actualiza incrementalmente | `graphify update .` |

## Flujo de trabajo recomendado

```
1. git clone <repo>
2. cd <repo>
3. workspace          ← ejecutar antes de abrir Cursor
4. cursor .           ← abrir el proyecto en Cursor
```

El agente de Cursor puede usar el grafo ya construido (`graphify-out/`) y las reglas en `.cursor/rules/graphify.mdc` sin gastar tokens en la preparación inicial.

## Estructura del repositorio

```
workspace-init/
├── README.md
├── workspace-cursor.ps1    # Script principal
├── workspace-cursor.cmd    # Wrapper para PATH (comando: workspace)
├── requerimiento.md        # Especificación funcional
└── .gitignore              # Ignora .cursor/, graphify-out/ y .cursorignore
```

## Licencia

Consulta el archivo de licencia del repositorio si está disponible.
