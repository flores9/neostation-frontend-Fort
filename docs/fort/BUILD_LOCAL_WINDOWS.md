# Build local en Windows - NeoStation Fort

El build autoritativo de las APK Fort se hace en local para no consumir minutos de GitHub Actions.

## Requisitos

- Git para Windows.
- PowerShell 5.1 o superior.
- JDK 17 con `JAVA_HOME` correctamente configurado.
- Android SDK compatible con Flutter.
- FVM recomendado. El repositorio fija Flutter en `.fvmrc` (actualmente 3.47.1).
- Para releases definitivas, la identidad de firma Fort permanente generada una sola vez.

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

## Firma permanente Fort - una sola vez

NeoStation Fort tiene un `applicationId` distinto del NeoStation original y debe conservar siempre la misma clave de firma para que R2, R3, etc. puedan instalarse como actualización de R1.

Ejecuta una sola vez:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\fort_setup_signing.ps1
```

El script:

- solicita dos contraseñas sin mostrarlas;
- crea el keystore en `%USERPROFILE%\.neostation-fort\signing\neostation-fort-release.jks`;
- crea `android\key.properties`;
- se niega a sobrescribir una identidad ya existente;
- no sube ningún secreto a GitHub.

Haz una copia segura del `.jks` y de ambas contraseñas. Si se pierde esa clave, futuras APK Fort no podrán actualizar una instalación ya existente.

El `.gitignore` raíz excluye `key.properties`, `android/key.properties` y `*.jks`.

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
13. Incluye documentación Fort y scripts de build/firma.
14. Genera manifest, historial Git y diffstat.
15. Calcula SHA-256.
16. Genera un ZIP de entrega.

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
    fort_setup_signing.ps1
    docs/
      ...
  NeoStation-Fort-R1-delivery.zip
```

## Primer build de diagnóstico

Si todavía no quieres crear la firma permanente, para la primera compilación técnica puedes usar:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\fort_local_release.ps1 -AllowDebugSigning
```

Esta opción sigue ejecutando formato, analyzer y tests, pero la APK resultante es sólo de diagnóstico y **no** debe publicarse como release Fort definitiva.

También existen `-SkipTests` y `-SkipAnalyze`, pero cualquier build generado con esos switches debe considerarse no liberable hasta repetir el proceso completo sin ellos.

## Regla de publicación

No crear tag/release ni subir la APK definitiva hasta que:

- formato OK,
- analyze OK,
- tests OK,
- build release ARM64 OK,
- firma permanente Fort OK,
- instalación/actualización en AYN Thor OK,
- pruebas manuales R1 completadas,
- SHA-256 guardado,
- commit exacto del build identificado.
