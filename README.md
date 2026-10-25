# Wizard Cat Reader

Wizard Cat Reader (antes MokaReader): lector de manga gratuito para iPhone, compatible con las extensiones de **Mihon**.

Las extensiones de Mihon (JARs de extension-lib 1.4–1.6) corren dentro de la app en una JVM
embebida (OpenJDK Mobile en modo intérprete) con la capa de compatibilidad Android de Suwayomi.

## Estado

- [x] Repositorios de extensiones (`index.pb`) e instalación de extensiones de Mihon
- [x] Explorar, ficha de serie, biblioteca (orden y columnas), notas por serie
- [x] Lector: webtoon/LTR/RTL, zoom, zonas de toque, fondo, margen webtoon, pantalla encendida
- [x] Descargas offline (simultáneas configurables, borrar al terminar)
- [x] Backups `.tachibk`: restaurar **y exportar** (compatible con Mihon)
- [x] Actividad: novedades de la biblioteca e historial de lectura
- [x] Contenido +18 bloqueado en todas las capas
- [x] Lector: scroll continuo entre capítulos (webtoon) y autoscroll con velocidad regulable
- [x] "Seguir leyendo" en la biblioteca y descarga automática de capítulos nuevos
- [x] Migración de series entre fuentes y filtros de búsqueda por fuente
- [x] Doble página en el lector (horizontal) y recorte de bordes blancos
- [x] Prioridad de scanlators por serie, portadas personalizadas e íconos alternativos
- [x] WebView para resolver Cloudflare e iniciar sesión en fuentes
- [x] Cómics locales CBZ/ZIP: importación desde Archivos y cómic guía precargado
- [x] Sincronización entre dispositivos vía carpeta en la nube (compatible con Mihon)
- [ ] Trackers (AniList, MyAnimeList) — post-lanzamiento
- [ ] Soporte iPad y acciones de Apple Pencil — post-lanzamiento
- [x] Puente Swift/JNI propio (WizardJVMRunner, Apache-2.0) en lugar del paquete GPL

## Estructura

```
Runtime/                 Host Java de extensiones + shims (Apache-2.0, de TachiyomiAZ)
iosApp/
  Sources/App            Punto de entrada y pestañas
  Sources/Core           Modelos, biblioteca, ajustes, persistencia
  Sources/Engine         JVMEngine, repositorios, imágenes
  Sources/Views          Interfaz SwiftUI
  Packages/WizardJVMRunner  Puente Swift/JNI propio (Apache-2.0)
  Scripts/               Build de OpenJDK y del runtime
  project.yml            Proyecto XcodeGen
```

## Compilar

Sin Mac: **Actions → "iOS → TestFlight (firmado)" → Run workflow**. La primera corrida compila
OpenJDK desde fuente (~1 h); después queda en caché.
