# MeetingVox

[English](README.md) · **Español**

MeetingVox es una app de barra de menús para macOS que graba reuniones y las transcribe **en el propio Mac**. Con un clic graba dos pistas por separado: tu micrófono (`mic.caf`, «Yo») y todo el audio que reproduce el Mac (`system.caf`, «Otros», capturado con un *process tap* de Core Audio, sin dispositivos virtuales ni extensiones de kernel). Al detener la grabación, transcribe ambas pistas localmente y genera una transcripción con hablante por turno. Opcionalmente redacta minutas, resúmenes y tareas con un modelo de lenguaje vía OpenRouter, y puede enviar transcripciones a un servidor de memoria Hindsight propio.

La interfaz de la app está en español.

Es un fork de [`digimata/quill`](https://github.com/digimata/quill), renombrado MeetingVox (el ícono de la pluma viene de ahí).

## Índice

1. [Qué sale del Mac y qué no](#qué-sale-del-mac-y-qué-no)
2. [Requisitos](#requisitos)
3. [Obtener el código](#obtener-el-código)
4. [Compilar, instalar y ejecutar](#compilar-instalar-y-ejecutar)
5. [Primera ejecución](#primera-ejecución)
6. [Uso básico](#uso-básico)
7. [Transcripción](#transcripción)
8. [Componentes externos](#componentes-externos)
9. [Configuración](#configuración)
10. [Archivos de cada sesión](#archivos-de-cada-sesión)
11. [Modificar el proyecto](#modificar-el-proyecto)
12. [Notas técnicas: auriculares Bluetooth](#notas-técnicas-auriculares-bluetooth)
13. [Distribuir tu propia versión](#distribuir-tu-propia-versión)
14. [Licencia y créditos](#licencia-y-créditos)

## Qué sale del Mac y qué no

- **El audio nunca sale del Mac.** Los archivos `.caf` solo se leen y escriben localmente.
- **La transcripción es local** (Parakeet Ultra con Core ML). Lo único que se descarga de internet es el modelo de voz, una sola vez.
- **OpenRouter** (opcional, requiere clave y modelo configurados): recibe **solo texto**, y solo para generar minutas, resúmenes y tareas:
  - Minutas: el texto de la transcripción (automáticamente si `minutes.enabled` está activo, o cuando lo pides para una reunión).
  - Resúmenes: el texto de la minuta si existe; si no, el de la transcripción.
  - Tareas y país de la reunión: el mismo texto que el resumen (junto con el resumen o al usar «Reconstruir índice»).
  - Con `openrouter.deny_data_collection` (activo por defecto), OpenRouter solo usa proveedores que no almacenan ni entrenan con los datos.
- **Hindsight** (opcional, desactivado por defecto): recibe la transcripción y sus metadatos (título, fecha, horas, duración, plantilla, asistentes, motor y modelos), y el cliente y el país de la reunión como etiquetas. **Nunca** recibe el audio ni el texto de la minuta (los nombres de asistentes se extraen localmente de la minuta, pero la minuta no se envía). Solo se envían las reuniones que eliges, o todas las elegibles si activas el envío automático.
- **Calendario** (opcional, desactivado por defecto): MeetingVox solo **lee** tu calendario; nunca lo modifica ni lee las notas de los eventos. Si una reunión queda vinculada a un evento (hasta que uses «Quitar evento del calendario»), el título del evento y los **nombres** de los invitados se envían a OpenRouter junto con la transcripción y a Hindsight como `titulo` y `asistentes`. Los correos de los invitados, las notas, la URL y la ubicación del evento nunca salen del Mac.
- Las claves (OpenRouter, token de Hindsight) se guardan en el llavero de macOS, nunca en archivos de configuración, registros ni sesiones.

Estos textos coinciden con los avisos de la app (`Textos.Ajustes.privacidadNota`, `Textos.Memoria.nota` y `NSLocalNetworkUsageDescription` en `Packaging/Info.plist`); si cambias qué se envía, actualiza también esos avisos.

## Requisitos

- **macOS 15 o posterior** (el paquete declara `.macOS(.v15)`; la captura del audio del sistema usa *process taps* de Core Audio).
- **Apple Silicon recomendado** para que la transcripción sea rápida.
- **Toolchain de Swift 6** (`swift-tools-version:6.0`): Xcode, o solo las Command Line Tools (`xcode-select --install`). Con solo las Command Line Tools, compilar funciona igual, pero los tests necesitan flags extra (ver [Tests](#tests)).
- **git** (además, `Scripts/build-app.sh` usa `git rev-list --count HEAD` para el número de build).
- **Espacio en disco para el modelo de voz**: `MeetingVox doctor` lo estima en ~750 MB; descargado ocupa unos 600 MB en `~/Library/Application Support/FluidAudio/Models/parakeet-ultra`.
- Conexión a internet para resolver las dependencias de SwiftPM y descargar el modelo la primera vez.

## Obtener el código

```sh
git clone https://github.com/pipo-arentsen/meetingvox.git
cd meetingvox
```

## Compilar, instalar y ejecutar

Ejecuta todo desde la raíz del repositorio.

### Antes de la primera compilación: certificado de firma

Crea una vez el certificado autofirmado **`MeetingVox Dev`** y respalda su `.p12` (pasos en [Packaging/README.es.md](Packaging/README.es.md)). macOS asocia los permisos de privacidad (micrófono, audio del sistema, red local, calendario) y los «Permitir siempre» del llavero a la firma de la app:

- Con `MeetingVox Dev`, la firma es estable y los permisos sobreviven a cada recompilación.
- Sin él, el script firma **ad hoc** (con una advertencia visible). Esa firma cambia en cada build, así que macOS vuelve a pedir los permisos y el llavero vuelve a preguntar después de cada recompilación.
- Para usar otro certificado: `MEETINGVOX_SIGN_IDENTITY="Mi certificado" Scripts/build-app.sh`.

### Compilar

```sh
swift build -c release   # .build/release/MeetingVox: binario suelto (desarrollo, tests, doctor, diag)
Scripts/build-app.sh     # .build/app/MeetingVox.app: bundle + ícono + firma (no instala nada)
```

`Scripts/build-app.sh` compila en release, arma el bundle (`Info.plist` desde `Packaging/Info.plist`, ícono, agente de inicio de sesión), firma y verifica con `codesign --verify --deep --strict`. Al firmar con el certificado, la salida dice `signing with identity "MeetingVox Dev"`.

El binario suelto no tiene `Info.plist` propio: los permisos se atribuyen a la terminal, no hay notificaciones nativas ni onboarding. Úsalo para `doctor`, `diag` y tests; para usar la app, instala el `.app`.

### Instalar

Sal de MeetingVox si está abierto (menú «Salir de MeetingVox», o `SIGTERM`: una grabación en curso se finaliza antes de salir). Luego, una de estas dos opciones:

```sh
# Opción A: script de instalación (copia a /Applications, registra el inicio de sesión y abre la app)
Scripts/install-app.sh

# Opción B: copia manual
ditto .build/app/MeetingVox.app /Applications/MeetingVox.app
open /Applications/MeetingVox.app
```

- `Scripts/install-app.sh` exige que exista `.build/app/MeetingVox.app` (si no, pide ejecutar `Scripts/build-app.sh`), se niega a continuar si MeetingVox está corriendo, mueve una instalación anterior a `~/MeetingVox-respaldos/app-previous-<fecha>/` (no borra nada), instala con `ditto`, registra el ítem de inicio de sesión y abre la app. No pide confirmación.
- Con la opción B, el inicio automático se activa desde la ventana «Primeros pasos» (paso «Listo») o con `MeetingVox install --launch-at-login` (ver [Packaging/README.es.md](Packaging/README.es.md#ítem-de-inicio-de-sesión)).

### Registros y diagnóstico

- La app instalada escribe su registro en `~/Library/Logs/MeetingVox/meetingvox.log` (rota a `.1` al superar 10 MB): `tail -f ~/Library/Logs/MeetingVox/meetingvox.log`.
- `MeetingVox doctor` revisa micrófono, audio del sistema, carpeta de grabaciones, modelo de voz, OpenRouter, Hindsight y calendario. Los problemas no críticos aparecen como advertencias.

```sh
/Applications/MeetingVox.app/Contents/MacOS/MeetingVox doctor
```

### Experimentos sin tocar tu configuración real

Cualquier invocación del binario (incluso `--help`) ejecuta primero la migración de configuración sobre el `~/.config` real. **`HOME=<tmp>` no aísla la app en macOS** (usa `homeDirectoryForCurrentUser`, que ignora `HOME`). Para experimentar, usa `CFFIXED_USER_HOME`:

```sh
CFFIXED_USER_HOME="$(mktemp -d)" .build/release/MeetingVox doctor
```

La única excepción es `diag --mode snapshot`, que no lee la configuración ni ejecuta la migración. Ojo: `diag` sin `--mode` (o con `mic`, `capture`, `tap-then-mic`, etc.) abre el micrófono y graba; no lo ejecutes desatendido.

## Primera ejecución

Al abrir por primera vez la app instalada aparece la ventana **«Primeros pasos»**, con cuatro pasos: **Permisos**, **Modelo**, **Minutas** y **Listo**. Puedes moverte libremente entre ellos; la ventana solo deja de aparecer al pulsar **«Empezar»** (se guarda en `~/.config/meetingvox/onboarding.json`). Se puede volver a abrir desde el menú («Primeros pasos…») o desde Ajustes.

- **Permisos**: cada permiso se pide solo cuando haces clic en «Permitir»:
  - Micrófono (tu voz).
  - Audio del sistema (la voz de los demás).
  - Notificaciones (aviso cuando una reunión está lista).
  - Red local (solo si usas un servidor Hindsight en tu red).
  Puedes cambiarlos después en Ajustes del Sistema › Privacidad y seguridad. Si deniegas el micrófono, se graba solo la pista del sistema y `doctor` lo marca como advertencia.
- **Modelo**: «Descargar modelo» baja Parakeet Ultra una sola vez. Si no lo descargas aquí, se descarga en la primera transcripción (conviene hacerlo antes de una reunión importante).
- **Minutas**: clave y modelo de OpenRouter, opcional («Omitir» no cambia nada).
- **Listo**: carpeta de grabaciones (el cambio se aplica al reiniciar la app), inicio de sesión, detección de reuniones, minutas automáticas y el calendario, que es *opt-in*. El permiso de Calendarios lo pide macOS solo al activar ese interruptor, nunca al iniciar.

Mientras la ventana está abierta, MeetingVox no inicia tareas automáticas que puedan provocar avisos del sistema (llavero, red); se reanudan al cerrarla.

## Uso básico

- **Grabar**: clic en la pluma de la barra de menús → «Iniciar grabación» (⌘R). Mientras graba, la barra muestra el tiempo transcurrido y aparece una píldora flotante con los niveles de «Yo» y «Otros» y el botón «Detener». Si una pista falla, la otra sigue grabando y recibes un aviso.
- **Detección de reuniones**: cuando Teams, Zoom, WhatsApp o un navegador compatible (BrowserOS, Brave, Safari) empieza a usar el micrófono, la píldora pregunta «… detectada» con «Grabar» / «Ignorar». MeetingVox **nunca empieza a grabar solo**. Al terminar la llamada pregunta si detener («Seguir grabando» / «Detener»). La detención automática es opcional (`meeting_detection.auto_stop`).
- **Al detener**: transcripción automática y, si está configurado, minuta, resumen, tareas y envío a memoria. Se recibe **una** notificación «reunión lista» por sesión.
- **Ventana principal** («Abrir MeetingVox», ⌘J): lista de reuniones con búsqueda en texto completo, clasificación por ámbito (Trabajo, Profesional, Personal), detalle con pestañas Resumen / Minuta / Transcripción (con reproductor), página Tareas y la Biblioteca (Plantillas y Glosario). Desde el detalle también se puede regenerar la minuta, aplicar el glosario, enviar a memoria o mover la reunión a la Papelera.
- **Ajustes…** (⌘,): pestañas OpenRouter, Reuniones y Memoria.

## Transcripción

- Motor: **Parakeet Ultra** (`parakeet-ultra-coreml`) mediante [FluidAudio](https://github.com/FluidInference/FluidAudio) **0.17.4**, con Core ML, 100 % en el Mac, multilingüe. No hay otro motor: `transcription.engine` solo admite `parakeet` (otro valor se ignora con una advertencia).
- **Por qué Ultra**: el modelo anterior (Parakeet v3) inventaba palabras en inglés en reuniones reales en español; Ultra eliminó ese problema en las pruebas, con la misma velocidad. **FluidAudio 0.17.4 y Ultra van juntos**: 0.17.4 con v3 da peores resultados que la versión anterior de FluidAudio con v3, así que no vuelvas a v3 sin probarlo de nuevo.
- Cada pista se transcribe por separado, se alinea con su desfase de inicio y se mezcla por tiempo: «Yo» (`me`) y «Otros» (`them`) sin modelo de diarización.
- Las pistas con volumen muy bajo (por ejemplo, micrófonos Bluetooth en modo manos libres) se normalizan en una copia temporal; el `.caf` original nunca se modifica.
- Cola serie y tolerante a caídas: una sesión con `meta.json` pero sin `transcript.json` está pendiente y se reanuda al siguiente inicio. Los errores van a `transcribe.log` de la sesión y no bloquean las demás.
- **Glosario**: al terminar, corrige en el texto las variantes mal transcritas de los términos marcados (el original queda en `text_raw`).

## Componentes externos

MeetingVox funciona completo (grabar, transcribir, buscar, reproducir) **sin ningún servicio externo**. Los tres siguientes son opcionales.

### Memoria (Hindsight)

- **Hindsight es un servidor de memoria externo. No está incluido en este repositorio ni se distribuye con la app.** Para usar esta función necesitas tener tu propio servidor Hindsight (o acceso a uno) y un token.
- Desactivado por defecto (`hindsight.enabled: false`). Sin él, no se muestra nada de memoria y no se envía nada.
- **Qué se envía**: un documento por sesión (`document_id` `mv-<carpeta>`, de modo que reenviar actualiza el mismo documento) con:
  - La transcripción como turnos con hora (tus turnos con `owner_name`, los demás como «Otros»).
  - Metadatos: título, fecha, horas de inicio y fin, duración, zona horaria, plantilla, asistentes, motor y modelo de transcripción, modelo del resumen.
  - Etiquetas: `fuente:meetingvox`, `tipo:transcripcion`, `plantilla:<id>`, `cliente:<…>` y `pais:<…>` (estas dos, si el resumen los detectó).
  - **Nunca** el audio ni el texto de la minuta.
- **Cuándo**:
  - Manual: «Enviar a memoria» en la ventana principal o en la notificación de reunión lista.
  - Automático: con `hindsight.auto_send`, para las reuniones desde la fecha `hindsight.since` (`yyyy-MM-dd`; sin fecha válida no se envía nada automático). Se omiten las reuniones cortas, es decir, con menos de `min_words` palabras (150) **o** menos de `min_minutes` minutos (2). Los envíos manuales ignoran la fecha y el umbral.
  - Se puede marcar una reunión como «No enviar a memoria».
- **Bancos**: `hindsight.bank` es el banco por defecto. Si el servidor responde, Ajustes › Memoria lista los bancos disponibles. Una reunión ya enviada se queda en el banco al que se envió.
- **Token**: se guarda en el llavero (servicio `com.pipostudio.meetingvox`, cuenta `hindsight_token`), desde Ajustes › Memoria. Un 401/403 pausa los envíos hasta que guardas un token nuevo o cambias la configuración.
- **API usada**: `GET {base_url}/v1/default/banks`, `POST …/banks/{bank}/memories` y `DELETE …/banks/{bank}/documents/{id}` (este último solo si, al mover una reunión a la Papelera, marcas explícitamente «Borrar también de la memoria»), con `Authorization: Bearer <token>`.
- **Red local**: si el servidor está en tu LAN, macOS pide el permiso de Red local. La primera petición tras instalar una build puede fallar como «sin conexión» hasta que respondas el aviso; el siguiente intento automático la reenvía.
- Claves: `hindsight.enabled`, `auto_send`, `base_url`, `bank`, `owner_name` (por defecto «Yo»), `owner_description`, `since`, `min_words`, `min_minutes`.

### OpenRouter

- Servicio externo de LLM ([openrouter.ai](https://openrouter.ai)) para **minutas**, **resúmenes** y **tareas**. Opcional: sin clave ni modelo, MeetingVox solo transcribe.
- La clave API se guarda en el llavero (servicio `com.pipostudio.meetingvox`, cuenta `openrouter_api_key`) desde Ajustes › OpenRouter o el paso «Minutas»; el modelo va en `openrouter.model` (por ejemplo `openai/gpt-4o-mini`).
- `minutes.enabled` está **desactivado** por defecto. Una minuta también se puede pedir para una sesión concreta desde la pestaña Minuta («Generar minuta») o con «Generar minuta con…».
- `summary.enabled` está **activado** por defecto: en cuanto haya modelo y clave, cada reunión transcrita genera `resumen.json` (título, resumen, temas, participantes, cliente, tareas, país). Para no enviar nada por esta vía, pon `summary.enabled: false`.
- Los reintentos por errores transitorios (sin red, 429, 5xx) son automáticos (30 s, 2 min, 10 min). Los permanentes dejan un marcador `*.error` y se pueden reintentar desde la ventana o la notificación.

### Calendario (macOS, EventKit)

- Opcional y *opt-in* (`calendar.enabled: false` por defecto). Se activa en Ajustes › Reuniones o en el paso «Listo». macOS pide el permiso de Calendarios una sola vez, al activar el interruptor.
- **Solo lectura**: al detener una grabación, busca el evento que coincide (en el que participas) y guarda en `meta.json` (`calendar_event`) el título y los nombres de los invitados. Lo usa para nombrar la reunión y como contexto para la minuta y el resumen.
- Nunca escribe en tus calendarios ni lee notas. «Quitar evento del calendario» (menú ⋯ del detalle) deshace el vínculo de una sesión.

## Configuración

Archivo opcional `~/.config/meetingvox/config.json`. Casi todo se edita desde Ajustes; la ventana reescribe el archivo con claves ordenadas y conserva las claves que no conoce. Un JSON inválido no se sobrescribe.

| Clave | Por defecto | Para qué |
|---|---|---|
| `recordings_dir` | `~/Recordings` | Carpeta de sesiones (`--out` > config > por defecto; se lee al iniciar). |
| `transcription.enabled` | `true` | `false` = solo grabar. |
| `transcription.engine` | `parakeet` | Único motor disponible. |
| `mic_voice_processing` | `false` | Cancelación de eco de Apple (útil con altavoces; con auriculares, mejor apagado). Ver las [notas sobre Bluetooth](#notas-técnicas-auriculares-bluetooth). |
| `on_stop` | — | Comando de shell que recibe la carpeta de la sesión al terminar el procesamiento (una vez por sesión). |
| `minutes.enabled` | `false` | Minuta automática tras cada transcripción. |
| `minutes.template` | `general` | Plantilla por defecto. |
| `minutes.language` | `español` | Idioma de la minuta. |
| `summary.enabled` | `true` | Resumen y tareas (requiere clave y modelo). |
| `openrouter.model` | — | ID del modelo en OpenRouter. |
| `openrouter.deny_data_collection` | `true` | Solo proveedores que no guardan ni entrenan con los datos. |
| `glossary` | `[]` | Términos y variantes (ver abajo). |
| `meeting_detection.enabled` | `true` | Preguntar al detectar una reunión. |
| `meeting_detection.ignored_apps` | `[]` | IDs de regla (`teams`, `zoom`, `whatsapp`, `browseros`, `brave`, `safari`, `webkit`) o bundle ids a ignorar. |
| `meeting_detection.prompt_on_end` | `true` | Preguntar si detener cuando termina la reunión. |
| `meeting_detection.auto_stop` | `false` | Detener sola 45 s después de esa pregunta si nadie responde. |
| `recording_pill.enabled` | `true` | Píldora flotante durante la grabación. |
| `calendar.enabled` | `false` | Vincular sesiones con eventos del calendario. |
| `hindsight.*` | `enabled: false`, `auto_send: false` | Ver [Memoria (Hindsight)](#memoria-hindsight). |

- **Plantillas de minuta**: archivos Markdown en `~/.config/meetingvox/plantillas/<id>.md` (con *frontmatter* `nombre` y `descripcion`). Se instalan siete de fábrica (`general`, `comercial`, `daily`, `uno-a-uno`, `levantamiento`, `entrevista`, `familiar`), que se editan y restauran desde Biblioteca › Plantillas. Son genéricas: «Yo» es la persona que grabó la reunión y «Otros» los demás, así que adáptalas a tu contexto (tu empresa, tus términos habituales) según necesites.
- **Glosario**: cada elemento es un término (`"Kubernetes"`) o un objeto `{"term": "MeetingVox", "variants": ["miting vox"], "transcript": true}`. Las variantes de los términos con `transcript: true` se corrigen en la transcripción; todos los términos se sugieren al modelo en minutas y resúmenes. Se edita en Biblioteca › Glosario y se puede reaplicar a una reunión anterior con «Aplicar glosario».

**Si venías de quill**: en el primer inicio, MeetingVox **copia** una sola vez `~/.config/quill` a `~/.config/meetingvox` y sigue leyendo las claves del llavero guardadas por quill hasta que las vuelvas a guardar. La configuración, los ítems del llavero y el binario de quill nunca se modifican ni se borran, y MeetingVox no inicia mientras quill esté corriendo. `Scripts/install-app.sh` no toca el agente de quill: retíralo a mano antes de instalar (ver [Packaging/README.es.md](Packaging/README.es.md#si-venías-de-quill)).

## Archivos de cada sesión

Cada grabación crea `<recordings_dir>/yyyy.MM.dd-HHmm[-N]/`. En la raíz se regenera `indice.md`, un índice Markdown de todas las sesiones.

| Archivo | Contenido |
|---|---|
| `mic.caf`, `system.caf` | Tus pistas de audio (AAC en CAF: legible aunque el proceso muera a mitad de grabación). |
| `meta.json` | Inicio, fin, duración, desfases por pista y, opcionalmente, `minutes_template`, `meeting_app`, `ambito`, `calendar_event`. |
| `transcript.json` / `transcript.md` | Transcripción canónica (segmentos con `speaker` `me`/`them`, `text`, `text_raw`) y su versión legible. |
| `minuta.md`, `minuta.<id>.md`, `minuta-anterior.md` | Minuta automática, minutas manuales con otra plantilla y la versión reemplazada por la última regeneración. |
| `resumen.json` | Resumen, temas, participantes, cliente, tareas y país. |
| `*.log` | `transcribe.log`, `minuta.log`, `resumen.log`, `hindsight.log` (nunca contienen claves). |

Marcadores (archivos vacíos o JSON pequeños; el sistema de archivos es la cola):

| Marcador | Significado |
|---|---|
| `minuta.pendiente` / `minuta.error` | Minuta pedida y pendiente (se reanuda al iniciar) / falló de forma definitiva. |
| `resumen.pendiente` / `resumen.error` | Lo mismo para el resumen. |
| `tareas.pendiente` / `tareas.error` | Extracción de tareas para un resumen antiguo pendiente / fallida (solo «Reconstruir índice» la inicia). |
| `hook.ejecutado` | `on_stop` ya se ejecutó (nunca dos veces). |
| `hindsight.json` / `hindsight.error` | Último contenido aceptado por Hindsight / rechazado. |
| `hindsight.solicitado` / `hindsight.omitir` | Envío pedido por el usuario / no enviar nunca esta sesión. |
| `listo.notificado` | La notificación «reunión lista» ya se publicó. |

Las claves de `meta.json`, `transcript.json` y `resumen.json` y los ids `me`/`them` son estables: un `on_stop` externo puede leerlos.

## Modificar el proyecto

### Estructura

```
Sources/MeetingVox/
  App/            arranque (Entry.swift es el @main), instancia única, registro, salida, inicio de sesión
  Audio/          grabación de micrófono y sistema, detección de reuniones (MeetingDetection/)
  Transcription/  Parakeet, cola de transcripción, glosario, descarga del modelo
  Minutes/        minutas, plantillas, prompts (MinutesPrompts), troceo de transcripciones largas
  Summary/        resúmenes y tareas (SummaryPrompts)
  OpenRouter/     cliente HTTP de OpenRouter
  Hindsight/      exportación a Hindsight
  Calendar/       vínculo con EventKit (solo EventKitCalendarSource toca EventKit)
  MeetingIndex/   índice, lista, filtros, búsqueda en texto completo, lógica pura de la ventana
  Notifications/  avisos nativos y su enrutamiento
  Onboarding/, Permissions/  «Primeros pasos» y estado de permisos
  Pill/, Playback/, Pipeline/, Markdown/  píldora, reproductor, estado de las etapas, visor de minutas
  Config/, Secrets/, Migration/  configuración, llavero, migración desde quill
  UI/             vistas AppKit/SwiftUI; todo el texto visible en UI/Textos.swift
  Diag/           diag y snapshots de vistas
Tests/MeetingVoxTests/  tests con swift-testing (@testable import MeetingVox)
Packaging/      Info.plist, entitlements, agente de inicio de sesión, ícono (ver Packaging/README.es.md)
Scripts/        build-app.sh (compila y firma) e install-app.sh (instala; lo ejecutas tú)
```

### Claves de la arquitectura

- **Arranque**: `App/Entry.swift` es el único `@main`. Orden: limpieza de argumentos → redirección del registro → instancia única → rotación del registro → migración de configuración → comando. Nada lee `Config` antes de la migración.
- **El sistema de archivos es la cola**: cada etapa (transcripción, minuta, resumen, memoria) lee y escribe marcadores en la carpeta de la sesión (ver [Archivos de cada sesión](#archivos-de-cada-sesión)), así que una caída o un reinicio retoman el trabajo pendiente. Los errores se registran y nunca bloquean la cola.
- **Audio**: la captura del micrófono usa `AVCaptureSession` (`Audio/CaptureMicRecorder.swift`); `AVAudioEngine` (`Audio/MicRecorder.swift`) solo se usa con `mic_voice_processing`. El audio del sistema usa un *process tap* que excluye a la propia app. Lee las [notas sobre Bluetooth](#notas-técnicas-auriculares-bluetooth) antes de tocar la captura.
- **Salida**: el único camino de salida es `NSApp.terminate` → `AppDelegate`, de modo que ⌘Q, `SIGTERM`, el cierre de sesión y `launchctl bootout` finalizan una grabación en curso (escriben `meta.json`) antes de salir.
- **Privacidad**: los avisos de la app (`Textos.Ajustes.privacidadNota`, `Textos.Memoria.nota`, `NSLocalNetworkUsageDescription`) deben coincidir con lo que realmente sale del Mac; `PrivacyCopyTests` los fija.
- **Calendario**: EventKit solo se usa dentro de `Calendar/EventKitCalendarSource.swift` y solo en la app empaquetada; los tests y el binario suelto nunca crean un `EKEventStore`.
- **Lógica pura y vistas delgadas**: las decisiones (estado de la píldora, menú, filtros, etapas, notificaciones) son funciones puras con tests; las vistas solo dibujan modelos y no leen `Config` ni el llavero (`SnapshotHomeGuardTests` lo verifica).

### Tests

Con Xcode:

```sh
swift test
```

Con solo las Command Line Tools, `Testing.framework` no está en la ruta de búsqueda por defecto:

```sh
D=/Library/Developer/CommandLineTools/Library/Developer
swift test -Xswiftc -F -Xswiftc $D/Frameworks -Xlinker -F -Xlinker $D/Frameworks \
  -Xlinker -rpath -Xlinker $D/Frameworks -Xlinker -rpath -Xlinker $D/usr/lib
```

Un cambio está terminado cuando `swift build -c release` compila sin errores ni advertencias nuevas y los tests pasan.

### Snapshots de vistas

```sh
.build/release/MeetingVox diag --mode snapshot --out /tmp/meetingvox-snapshots
```

Renderiza estados de la interfaz a PNG (`<estado>.png`) a partir de datos de ejemplo en un directorio temporal, sin leer tu configuración, tu llavero ni tus grabaciones, y sin red. Los estados nuevos se agregan en `SnapshotStates.all`.

### Convenciones

- Swift 6 con concurrencia estricta: la UI es `@MainActor`, las colas de procesamiento son `actor`, y los grabadores son `@unchecked Sendable` protegidos con locks.
- Todo el texto visible está en `UI/Textos.swift` (en español). Los prompts para el LLM están en `Minutes/MinutesPrompts.swift` y `Summary/SummaryPrompts.swift`.
- JSON en snake_case; comentarios `///` que explican el *porqué*; *conventional commits*.
- Lo que persiste (bundle id, rutas, servicio del llavero, etiquetas) se nombra solo en `AppIdentity.swift`.

## Notas técnicas: auriculares Bluetooth

Hallazgos medidos con unos auriculares Bluetooth; explican por qué la captura del micrófono es como es.

- Al abrir el micrófono, los auriculares pasan de A2DP (estéreo) a manos libres (HFP).
- **`AVAudioEngine` no sirve para la captura sin procesar con Bluetooth.** Su nodo de entrada se enlaza a `CADefaultDeviceAggregate` (entrada y salida por defecto), así que también toma la salida de los auriculares. Cada cambio A2DP↔HFP publica `AVAudioEngineConfigurationChange`; destruir y recrear el motor en ese momento provocaba una oscilación A2DP↔HFP: búferes del micrófono ausentes o en cero (desde 5 s hasta toda la sesión) y cortes en lo que el usuario escuchaba. Un motor enlazado directamente al dispositivo de entrada también cortaba la reproducción.
- **`AVCaptureSession` funciona** (`MeetingVox diag --mode capture`): voz desde el primer segundo y reproducción sin cortes, también con el tap del sistema iniciado después del micrófono. Por eso `CaptureMicRecorder` es la ruta de producción y la sesión arranca primero el micrófono y luego el tap (el orden inverso no se probó con la sesión de captura). `AVAudioEngine` queda solo para el procesamiento de voz.
- Cada reinicio completo de la captura reabre el micrófono (un ciclo A2DP↔HFP, con cortes de audio); de ahí el *backoff* entre reintentos.
- En HFP el micrófono entrega 16 kHz a un nivel muy bajo (≈ −37 dBFS); de ahí la normalización de volumen antes de transcribir.
- Al empezar puede llegar una ráfaga corta de ceros digitales (con el motor eran unos 7 s); de ahí los 3 s de gracia del detector de micrófono mudo.
- **`mic_voice_processing` está apagado por defecto.** El procesamiento de voz de Apple no es un efecto de entrada: reemplaza la E/S del motor por una unidad dúplex `VoiceProcessingIO`. Con el grafo incompleto (aceptando el formato que hereda la entrada, por ejemplo 9 canales a 48 kHz en una ruta multicanal, y sin ruta de salida conectada), la pista del micrófono quedaba en silencio digital (≈ −91 dB) aunque el archivo tuviera la duración correcta. Necesita un formato mono explícito en ambos lados de la unidad y la salida conectada, y aun así algunas combinaciones de entrada y salida pueden fallar. Si lo activas, pruébalo antes con tu equipo.
- No toques el grafo del micrófono a la ligera.

## Distribuir tu propia versión

Si publicas una build propia, cambia la identidad para que no choque con la del autor (permisos, llavero, configuración e ítem de inicio de sesión dependen de ella):

- `Sources/MeetingVox/AppIdentity.swift`: `bundleID` (también define el servicio del llavero, las etiquetas de colas y los nombres de notificaciones), `agentLabel`, `configDirName`, `displayName`/`executableName` si cambias el nombre.
- `Packaging/Info.plist`: `CFBundleIdentifier` (y nombre o versión si corresponde).
- `Packaging/LaunchAgents/com.pipostudio.meetingvox.agent.plist`: el nombre del archivo y su `Label` deben ser iguales a `AppIdentity.agentLabel`, y `AssociatedBundleIdentifiers` debe ser el nuevo bundle id.
- `Scripts/build-app.sh` y `Scripts/install-app.sh`: la variable con el nombre del plist del agente (`AGENT_PLIST` / `AGENT_PLIST_NAME`).
- Tests que fijan estos valores: `AppIdentityTests`, `LaunchAgentPlistTests`, `NotifierFactoryTests` y `HindsightConfigTests` (servicio del llavero).
- Opcional: la cabecera `HTTP-Referer` que `OpenRouter/OpenRouterClient.swift` envía a OpenRouter (hoy apunta a `github.com/pipo-arentsen/meetingvox`).
- Firma con tu propio certificado (`MEETINGVOX_SIGN_IDENTITY`). Con un bundle id nuevo, macOS pide los permisos desde cero.

## Licencia y créditos

- Licencia MIT (ver [LICENSE](LICENSE), Copyright (c) 2026 Andrew Jones y Copyright (c) 2026 Felipe Arentsen).
- Basado en [digimata/quill](https://github.com/digimata/quill).
- Transcripción con [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet en Core ML).
- CLI con [swift-argument-parser](https://github.com/apple/swift-argument-parser).
