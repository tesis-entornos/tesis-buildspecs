# tesis-buildspecs

Buildspecs de los proyectos de CodeBuild del prototipo. Se publican en el bucket de buildspecs
de la cuenta compartida (`tesis-entornos-buildspecs-582621604637`) y cada proyecto de CodeBuild
apunta a un archivo de ese bucket.

## Convención

- **Trunk-based.** `main` es la única rama de larga vida; los cambios entran por ramas
  `feature/*` cortas.
- **`buildspecs/`** tiene todos los buildspecs. Es la única carpeta que se publica.
- **Publicación completa.** En cada push, la carpeta `buildspecs/` se copia **completa** al
  bucket:
  - rama `main` → `s3://<bucket>/main/`
  - rama `feature/<x>` → `s3://<bucket>/<x>/` (`<x>` tal cual, sin cambiar mayúsculas ni `/`)
  - cualquier otra rama → el build falla y no publica nada.
- **Referencia desde CodeBuild.** Cada proyecto apunta a
  `s3://<bucket>/<carpeta>/<archivo>`, donde `<carpeta>` es `main` o la `<x>` de la rama.

## Publicación (`buildspec.yml`)

El `buildspec.yml` de la raíz lo ejecuta el proyecto de CodeBuild `tesis-publicar-buildspecs`
(definido en `tesis-terraform/compartida/`), disparado por un webhook en cada push a `main` o
`feature/*`. Es un solo archivo para todas las ramas. El bucket llega por la variable de
entorno `BUILDSPECS_BUCKET` del proyecto.

1. **pre_build** (aborta el build si falla): exige `BUILDSPECS_BUCKET`, toma la rama de
   `CODEBUILD_WEBHOOK_HEAD_REF` (`refs/heads/...`) y calcula la carpeta destino. Falla si la
   rama no es `main` ni `feature/*`, y si es `feature/main` (pisaría la carpeta de `main`).
2. **build**: `aws s3 sync buildspecs/ s3://<bucket>/<carpeta>/ --delete`. La carpeta del
   bucket queda igual a `buildspecs/` en esa rama (lo borrado en el repo se borra en S3).
3. **post_build**: lista los objetos de la carpeta destino.

Lo que está fuera de `buildspecs/` (este README, el propio `buildspec.yml`) no se publica.

## Ejemplo

| Rama                 | Archivo en el repo        | Objeto publicado                      |
|----------------------|---------------------------|---------------------------------------|
| `main`               | `buildspecs/build.yml`    | `s3://<bucket>/main/build.yml`        |
| `feature/cache-pip`  | `buildspecs/build.yml`    | `s3://<bucket>/cache-pip/build.yml`   |
