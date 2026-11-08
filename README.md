# tesis-buildspecs

Buildspecs de los proyectos de CodeBuild del prototipo. Se publican en el bucket
`tesis-entornos-buildspecs-582621604637` (cuenta compartida) y cada proyecto de CodeBuild
apunta a un archivo de ese bucket.

## Convención

- **Trunk-based.** `main` es la única rama de larga vida; los cambios entran por ramas
  `feature/*` cortas.
- **`main/`** tiene todos los buildspecs. Es lo que publica la rama `main`.
- **Ramas `feature/*`.** Cada rama se publica en una carpeta con el *slug* de la rama:
  el nombre en minúsculas y con `/` reemplazado por `-`
  (por ejemplo, `feature/Cache-Pip` → `feature-cache-pip`). Esa carpeta contiene **solo los
  archivos que la rama cambió respecto de `main`**; el resto se sigue leyendo de `main/`.
- **Referencia desde CodeBuild.** Cada proyecto apunta a
  `s3://<bucket>/<carpeta>/<archivo>`, donde `<carpeta>` es `main` o el slug de la rama.

## Ejemplo

| Rama                 | Archivo cambiado     | Objeto publicado                                   |
|----------------------|----------------------|----------------------------------------------------|
| `main`               | `main/build.yml`     | `s3://<bucket>/main/build.yml`                     |
| `feature/Cache-Pip`  | `build.yml`          | `s3://<bucket>/feature-cache-pip/build.yml`        |
