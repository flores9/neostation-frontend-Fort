# Build local en Windows - NeoStation Fort

El build autoritativo de las APK Fort se hace en local para no consumir minutos de GitHub Actions.

## Requisitos

- Git para Windows.
- PowerShell 5.1 o superior.
- JDK 17 con `JAVA_HOME` correctamente configurado.
- Android SDK compatible con Flutter.
- FVM recomendado. El repositorio fija Flutter en `.fvmrc` (actualmente 3.47.1).
- Material de firma permanente para releases publicables en `android/key.properties` y un keystore local que **nunca** se sube al repositorio.

## Primera preparación

Desde PowerShell:

```powershell
cd C:\ruta\donde\quieras\guardar\el\proyecto
git clone https://github.com/flores9/neostation-frontend-Fort.git
cd .\neostation-frontend-Fort\
git fetch --all --prune
git checkout fort/esde-integration-r1
git pull --ff-only
```

Comprueba Java:

```powershell
java -version
$env:JAVA_HOME
```

Si `java` no aparece, instala/configura JDK 17 antes de continuar.

## Firma

El Gradle del proyecto lee `android/key.properties`. Mantén el keystore y las contraseñas sólo en tu PC. El script rechaza por defecto generar una release publicable si no existe `android/key.properties`.

Para una APK puramente temporal puede usarse `-AllowDebugSigning`, pero esa APK no debe publicarse como release Fort definitiva.

## Construcción completa

Desde la raíz del repositorio:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\fort_local_release.ps1
```

El script:

1. Rechaza builds desde `main`.
2. Rechaza un árbol Git con cambios sin commit.
3. Lee la versión Flutter de `.fvmrc`.
4. Usa FVM si está instalado.
5. Comprueba Java.
6. Comprueba la configuración de firma.
7. Ejecuta `flutter pub get`.
8. Comprueba `dart format` sin modificar fuentes.
9. Ejecuta `flutter analyze`.
10. Ejecuta `flutter test`.
11. Compila sólo Android ARM64 en release.
12. Copia y renombra la APK.
13. Incluye la documentación Fort, manifest de build, historial Git y diffstat.
14. Calcula SHA-256.
15. Genera un ZIP de entrega.

Salida esperada:

```text
dist/
  NeoStation-Fort-R1/
    NeoStation-Fort-R1-arm64-v8a.apk
    BUILD_MANIFEST.txt
    GIT_HISTORY.txt
    UPSTREAM_BASE_DIFFSTAT.txt
    SHA256SUMS.txt
    fort_local_release.ps1
    docs/
      ...
  NeoStation-Fort-R1-delivery.zip
```

## Build de diagnóstico

Sólo para aislar un fallo, nunca como release final:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\fort_local_release.ps1 -AllowDebugSigning
```

También existen `-SkipTests` y `-SkipAnalyze`, pero cualquier build generado con esos switches debe considerarse no liberable hasta repetir el proceso completo sin ellos.

## Regla de publicación

No crear tag/release ni subir la APK definitiva hasta que:

- formato OK,
- analyze OK,
- tests OK,
- build release ARM64 OK,
- instalación/actualización en AYN Thor OK,
- pruebas manuales R1 completadas,
- SHA-256 guardado,
- commit exacto del build identificado.
