# tesis-buildspecs

Buildspecs de los proyectos de CodeBuild del prototipo. Se publican en el bucket de buildspecs
de la cuenta compartida (`tesis-entornos-buildspecs-582621604637`) y cada proyecto de CodeBuild
apunta a un archivo de ese bucket.

## Convención

- **Trunk-based.** `main` es la única rama de larga vida; los cambios entran por ramas
  `feature/*` cortas.
- **`main/`** tiene todos los buildspecs. Es lo que publica la rama `main`.
- **Ramas `feature/<x>`.** Cada rama se publica en la carpeta `<x>` en minúsculas y con `/`
  reemplazado por `-` (por ejemplo, `feature/Cache-Pip` → `cache-pip`,
  `feature/ci/Tests` → `ci-tests`). Esa carpeta contiene **solo los archivos de `main/` que la
  rama cambió respecto de `main`**; el resto se sigue leyendo de `main/`.
- **Referencia desde CodeBuild.** Cada proyecto apunta a
  `s3://<bucket>/<carpeta>/<archivo>`, donde `<carpeta>` es `main` o la de la rama.

## Publicación (`buildspec.yml`)

El `buildspec.yml` de la raíz lo ejecuta el proyecto de CodeBuild `tesis-publicar-buildspecs`
(definido en `tesis-terraform/compartida/`), disparado por un webhook en cada push a `main` o
`feature/*`. Es un solo archivo para todas las ramas. El bucket llega por la variable de
entorno `BUILDSPECS_BUCKET` del proyecto.

La rama se toma de `CODEBUILD_WEBHOOK_HEAD_REF` (`refs/heads/...`):

| Rama          | Qué hace                                                                                  |
|---------------|-------------------------------------------------------------------------------------------|
| `main`        | `aws s3 sync main/ s3://<bucket>/main/ --delete`: la carpeta `main/` del bucket queda igual al repo. |
| `feature/<x>` | Calcula la carpeta a partir de `<x>`. Si da `main`, falla. Hace `git fetch` de `origin/main` y sube cada archivo de `git diff --name-only --diff-filter=d origin/main...HEAD -- main/` a `s3://<bucket>/<carpeta>/<ruta sin main/>`. |
| otra          | No hace nada y termina con 0.                                                             |

Al final imprime cada objeto subido con su ETag.

Detalles:

- El diff es contra el merge-base (`...`): cuentan solo los cambios de la rama, no lo que entró
  a `main` después.
- `--diff-filter=d` excluye los archivos borrados en la rama: en la carpeta de la rama no se
  borra nada. Los archivos fuera de `main/` (este README, el propio `buildspec.yml`) no se
  publican.

## Ejemplo

| Rama                 | Archivo cambiado     | Objeto publicado                                   |
|----------------------|----------------------|----------------------------------------------------|
| `main`               | `main/build.yml`     | `s3://<bucket>/main/build.yml`                     |
| `feature/Cache-Pip`  | `main/build.yml`     | `s3://<bucket>/cache-pip/build.yml`                |
