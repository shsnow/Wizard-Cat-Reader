# Ficha de App Store Connect — Wizard Cat Reader

Material listo para copiar/pegar en App Store Connect. Lo que va entre ⟨ ⟩ se completa a mano.

---

## Información de la app

| Campo | Valor |
|---|---|
| **Nombre** | Wizard Cat Reader |
| **Subtítulo** (≤30) | Tu biblioteca de manga |
| **Categoría principal** | Libros (Books) |
| **Categoría secundaria** | Entretenimiento |
| **Precio** | Gratis |
| **URL de soporte** | https://wizardcatstore.cl/reader/ |
| **URL de privacidad** | https://wizardcatstore.cl/reader/privacidad/ |
| **URL de marketing** | https://wizardcatstore.cl/ |
| **Correo de contacto** | contacto@wizardcatstore.cl (reenvía a wizardcatstore1@gmail.com) |

> Las páginas viven en el repo Wizard-Cat-Store-Web (Cloudflare). La versión 1.0 se envió con
> las de GitHub Pages (`shsnow.github.io/Wizard-Cat-Reader/`), que siguen activas como respaldo.

## Texto promocional (≤170, editable sin nueva versión)

> Lector de manga y webtoons gratuito, sin publicidad y sin cuentas. Tu biblioteca, tus fuentes,
> tus reglas — y todo se queda en tu dispositivo.

## Descripción (español)

> Wizard Cat Reader es un lector de manga, manhwa y webtoons para iPhone: gratuito, sin
> publicidad, sin cuentas y sin recolección de datos.
>
> TU BIBLIOTECA
> • Organiza tus series con categorías, favoritos e insignias de capítulos sin leer.
> • "Seguir leyendo": retoma cualquier serie justo donde quedaste, con un toque.
> • Actualización de biblioteca con descarga automática opcional de capítulos nuevos.
>
> UN LECTOR HECHO PARA LEER
> • Modo webtoon vertical con desplazamiento continuo entre capítulos.
> • Autodesplazamiento con velocidad regulable: lectura manos libres.
> • Modo paginado izquierda→derecha o derecha→izquierda, con zoom y zonas de toque.
> • Descargas para leer sin conexión, donde sea.
>
> TUS FUENTES, TUS DATOS
> • Conecta tus propias fuentes y servidores autoalojados (por ejemplo Komga en tu red local).
>   La app no incluye, aloja ni recomienda contenido: tú decides qué agregar.
> • Importa tus propios cómics CBZ/ZIP desde la app Archivos y léelos sin conexión.
> • Copias de seguridad en formato abierto .tachibk, para llevarte tu biblioteca contigo.
> • Sincroniza entre dispositivos con tu propia nube (iCloud Drive, Google Drive, Dropbox…):
>   sin cuentas ni servidores nuestros, compatible con las copias de Mihon en Android.
> • Estadísticas de lectura calculadas en tu dispositivo.
>
> SIN EXTENSIONES +18
> • Las extensiones calificadas solo para adultos no se pueden instalar.
>
> Wizard Cat Reader es software libre (Apache 2.0).

## Description (English)

> Wizard Cat Reader is a free manga, manhwa and webtoon reader for iPhone — no ads,
> no accounts, no data collection.
>
> YOUR LIBRARY
> • Categories, favorites and unread badges. • "Continue reading" row to resume any series in
> one tap. • Library updates with optional auto-download of new chapters.
>
> A READER BUILT FOR READING
> • Vertical webtoon mode with continuous scrolling across chapters. • Hands-free auto-scroll
> with adjustable speed. • Paged mode (LTR/RTL) with zoom and tap zones. • Offline downloads.
>
> YOUR SOURCES, YOUR DATA
> • Connect your own sources and self-hosted servers (e.g. Komga on your local network). The
> app includes, hosts and recommends no content — you decide what to add. • Import your own
> CBZ/ZIP comics from the Files app and read them offline. • Open .tachibk backups. • Sync
> across devices through your own cloud folder (iCloud Drive, Google Drive, Dropbox…) — no
> accounts, no servers of ours, compatible with Mihon backups on Android. • On-device
> reading stats.
>
> NO 18+ EXTENSIONS
> • Extensions rated adults-only cannot be installed.
>
> Wizard Cat Reader is open source (Apache 2.0).

## Keywords (≤100 caracteres)

```
manga,manhwa,webtoon,comic,lector,reader,komga,biblioteca,offline,descargas,tachibk
```

(No incluir nombres de otras apps — Apple rechaza metadata con marcas de terceros, regla 2.3.7.)

## Clasificación por edades (cuestionario)

Responder honesto; con fuentes agregadas por el usuario lo defendible es:

- Violencia de dibujos animados o fantasía: **Infrecuente/Moderada**
- Temas para adultos/sugerentes: **Infrecuente/Moderada**
- **Acceso web sin restricciones: SÍ** (las fuentes las agrega el usuario)
- Todo lo demás: No

→ Resultado esperado: **17+**. Las extensiones +18 no se pueden instalar, pero las mixtas sí
y sin filtro interno, así que 17+ es la clasificación correcta (y "acceso web sin
restricciones" ya la exige).

## App Privacy (sección de privacidad de datos)

- **Data Not Collected** (no se recolecta ningún dato) — coincide con la política publicada.

## Notas para el revisor (Review Notes, en inglés)

> Wizard Cat Reader is a reader app that ships with NO content and NO sources. Users connect
> their own self-hosted servers (such as Komga) or source repositories; the app itself
> includes, hosts and recommends none.
>
> Extensions rated adults-only by their repository cannot be installed, and this cannot be
> changed by the user. The app is rated 17+.
>
> To review the app's functionality out of the box: the app ships with a built-in sample
> comic ("Guía de Wizard Cat", our own illustrated guide) that appears in the Library on
> first launch — open it to exercise the full reading experience (reading modes, zoom,
> progress tracking). You can also import your own CBZ/ZIP comic archives from the Files
> app using the + button in the Library tab; imported comics work fully offline.
>
> The app is free, has no ads, no purchases, no accounts, and collects no data.
>
> About the App Transport Security exception (NSAllowsArbitraryLoads): users connect
> their own self-hosted media servers (e.g. Komga) on local networks, which commonly
> run on plain HTTP without certificates. The app itself performs no HTTP traffic of
> its own — every connection goes to servers or sources the user explicitly adds.

### La demo: resuelta con contenido local ✅

La app ya NO llega vacía al revisor: al primer arranque la Biblioteca trae la
"Guía de Wizard Cat" (cómic original de 8 páginas, hecho por nosotros, sin copyright de
terceros) y cualquier CBZ/ZIP se importa desde Archivos con el botón + de la Biblioteca.
El revisor puede ejercitar lector, progreso, modos y biblioteca sin montar nada.
No se necesita servidor Komga de demo (sigue siendo una opción si algún revisor pide
ver el flujo de fuentes, pero ya no es el plan principal).

## Capturas (desde tu iPhone, modo oscuro, series inofensivas en pantalla)

Se necesitan de 6.9" (iPhone Pro Max/Plus) o se reutilizan las del tamaño del 17 Pro:

1. Biblioteca con "Seguir leyendo" y categorías.
2. Lector en modo webtoon (página vistosa, sin contenido sensible).
3. Ficha de una serie con capítulos y botón Continuar.
4. Novedades con capítulos nuevos.
5. Descargas / lectura offline.
6. Ajustes (se ve el tema cálido y las opciones).

## Pasos de publicación (en orden)

1. GitHub → repo Wizard-Cat-Reader → Settings → Pages → Source: "Deploy from a branch",
   Branch: `main`, carpeta `/docs` → Save. En ~2 min las URLs de arriba quedan vivas.
2. ASC → App Information → Name: "Wizard Cat Reader" (+ subtítulo).
3. ASC → App Privacy → "Data Not Collected".
4. Preparar la versión: descripción, keywords, URLs, capturas, clasificación.
5. Review Notes (arriba): el cómic guía precargado + importación CBZ son la demo.
6. Enviar a revisión 🤞
