# Empaquetado de MeetingVox.app

[English](README.md) · **Español**

`Scripts/build-app.sh` construye `.build/app/MeetingVox.app` a partir del binario de release. **Solo construye**: nunca instala, no toca launchd y no abre la app.

## Ruta rápida (primera vez en un Mac)

1. Crea el certificado **`MeetingVox Dev`** (una vez, a mano): [pasos](#crear-el-certificado-meetingvox-dev).
2. Respáldalo como `.p12` y guarda el archivo y su contraseña fuera del Mac: [pasos](#respaldar-el-certificado-p12).
3. `Scripts/build-app.sh`: la salida debe decir `signing with identity "MeetingVox Dev"`.
4. Sal de MeetingVox si está abierto e instala con `Scripts/install-app.sh` o con `ditto` ([instalar](#instalar-y-reinstalar)).

Si omites los pasos 1 y 2, la app se construye igual, pero con una firma **ad hoc** que cambia en cada build. Ver la sección siguiente.

## Por qué importa una identidad de firma estable

macOS asocia a la firma de código de la app los permisos de Micrófono, Grabación de audio del sistema, Red local y Calendarios, y también los «Permitir siempre» del llavero. Una firma **ad hoc** (la alternativa que usa el script si no encuentra el certificado) es distinta en cada build, así que todos esos permisos se pierden tras cada recompilación. Un certificado autofirmado que no cambia produce una firma que sobrevive a las recompilaciones: el *designated requirement* queda ligado al bundle id y al certificado, no al hash del archivo. Perder el certificado tiene el mismo efecto que firmar ad hoc.

## Archivos de esta carpeta

| Archivo | Rol |
|---|---|
| `Info.plist` | Plantilla de `Contents/Info.plist`: bundle id `com.pipostudio.meetingvox`, `LSUIElement` (sin ícono en el Dock), macOS 15+, textos de permisos en español (`NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, `NSLocalNetworkUsageDescription`, `NSCalendarsFullAccessUsageDescription`) y `NSAppTransportSecurity.NSAllowsLocalNetworking` para un servidor Hindsight en la LAN. `CFBundleVersion` es un marcador de posición: el script lo reemplaza por el número de commits. **No** está incrustado en el binario Mach-O, así que el binario suelto `.build/release/MeetingVox` no tiene `Info.plist` propio. |
| `MeetingVox.entitlements` | `com.apple.security.device.audio-input` y `com.apple.security.personal-information.calendars` (solo lectura, para el vínculo opcional con el calendario). Sin sandbox. |
| `LaunchAgents/com.pipostudio.meetingvox.agent.plist` | Agente de inicio de sesión, copiado a `Contents/Library/LaunchAgents/` y registrado con `SMAppService.agent(plistName:)`. `BundleProgram`, `KeepAlive { SuccessfulExit: false }` (una salida normal no relanza la app) y sin `StandardErrorPath` (launchd no expande `~`; la app redirige su propio stderr a `~/Library/Logs/MeetingVox/meetingvox.log`). El nombre del archivo y su `Label` deben coincidir con `AppIdentity.agentLabel`. |
| `Icon/make-icon.swift` | Dibuja la pluma sobre un fondo degradado en un `.iconset`; el script lo convierte en `AppIcon.icns` con `iconutil`. Se genera en cada build y no se versiona. |

## Crear el certificado «MeetingVox Dev»

El script nunca crea certificados ni modifica la configuración de confianza.

1. Abre **Acceso a Llaveros** (*Keychain Access*, llavero *inicio de sesión*) y elige **Acceso a Llaveros › Asistente para certificados › Crear un certificado…** (*Keychain Access › Certificate Assistant › Create a Certificate…*). Los nombres exactos de menús y opciones dependen del idioma de macOS.
2. Nombre: `MeetingVox Dev`. Tipo de identidad: **Raíz autofirmada** (*Self Signed Root*). Tipo de certificado: **Firma de código** (*Code Signing*). Deja desmarcada la opción para cambiar los valores por omisión (*Let me override defaults*) y crea el certificado.
3. En **Mis certificados**, haz doble clic en `MeetingVox Dev`, despliega **Confiar** (*Trust*) y pon **Firma de código** en **Confiar siempre** (*Always Trust*) (autentícate cuando lo pida). Sin esto, `security find-identity -v` no lo lista como válido y el script firma ad hoc.
4. Comprueba que el script lo ve:

   ```sh
   security find-identity -v -p codesigning | grep "MeetingVox Dev"
   ```

5. Recompila con `Scripts/build-app.sh`. La salida debe decir `signing with identity "MeetingVox Dev"` y el *designated requirement* debe incluir el bundle id.

Para usar un certificado con otro nombre:

```sh
MEETINGVOX_SIGN_IDENTITY="Mi certificado" Scripts/build-app.sh
```

Si hay más de un certificado válido con el mismo nombre, el script se niega a adivinar y termina con error. Elimina los duplicados o usa un nombre o hash único.

El primer inicio de una build firmada con un certificado nuevo vuelve a pedir los permisos (una vez). A partir de ahí se mantienen entre recompilaciones mientras firme el mismo certificado.

## Respaldar el certificado (.p12)

Si pierdes el certificado (Mac nuevo, llavero restablecido, reinstalación), la siguiente build tiene otra identidad y se pierden todos los permisos. Exporta un `.p12` y guárdalo en un lugar seguro fuera del Mac (gestor de contraseñas, volumen cifrado).

1. En **Acceso a Llaveros › Mis certificados**, selecciona `MeetingVox Dev` (la fila con el triángulo desplegable, para que incluya la clave privada).
2. **Archivo › Exportar ítems…**, formato **Intercambio de información personal (.p12)**, guárdalo como `MeetingVoxDev.p12`.
3. Elige una contraseña de exportación fuerte y guárdala aparte del archivo. Un `.p12` sin su contraseña no sirve; con ella puede firmar en tu nombre, así que trátalo como una clave privada.

Para restaurarlo en otro Mac o después de un restablecimiento:

```sh
security import MeetingVoxDev.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
```

Después repite el paso 3 de la sección anterior («Confiar siempre» para firma de código) y el paso 4 para verificar.

## Qué hace la build

```sh
Scripts/build-app.sh
```

1. `swift build -c release`.
2. Arma el bundle en un directorio temporal dentro de `.build/app/`: `Contents/MacOS/MeetingVox`, `Contents/Info.plist` (desde `Packaging/Info.plist`), el agente de inicio de sesión, `Contents/Resources/AppIcon.icns` y los `*.bundle` de recursos de SwiftPM.
3. Pone `CFBundleVersion` = `git rev-list --count HEAD` (o `1` si git falla, con una advertencia).
4. Ejecuta `plutil -lint`, comprueba que existan todas las claves obligatorias del `Info.plist` y valida el plist del agente: `Label` igual al nombre del archivo, `BundleProgram` correcto y sin `StandardErrorPath`.
5. Firma con `MeetingVox Dev` (o `MEETINGVOX_SIGN_IDENTITY`), o ad hoc con una advertencia, usando `Packaging/MeetingVox.entitlements`.
6. Verifica y solo entonces publica en `.build/app/MeetingVox.app`. Una ejecución fallida nunca deja un bundle a medias ni borra el anterior.

### Verificar firma y entitlements

```sh
codesign --verify --deep --strict --verbose=2 .build/app/MeetingVox.app
codesign -d -r- .build/app/MeetingVox.app             # designated requirement
codesign -dv .build/app/MeetingVox.app                # identificador y autoridad
codesign -d --entitlements - .build/app/MeetingVox.app
```

Con firma ad hoc, `codesign -dv` muestra `Signature=adhoc`.

### Sin hardened runtime ni sandbox

La firma **no** usa hardened runtime (`--options runtime`) y la app **no** está en sandbox:

- Sin notarización, el hardened runtime no aporta nada, y su validación de bibliotecas podría romper la carga de FluidAudio/Core ML.
- La app lee `~/.config`, escribe en la carpeta de grabaciones y habla con un servidor en la LAN.

Los entitlements de micrófono y calendarios están declarados igualmente, para que esos permisos sigan funcionando si algún día se activa el hardened runtime.

## Instalar y reinstalar

Antes de instalar una build nueva, **sal de MeetingVox** (menú «Salir de MeetingVox», o `SIGTERM`: una grabación en curso se finaliza antes de salir).

```sh
Scripts/build-app.sh
Scripts/install-app.sh     # lo ejecutas tú en una terminal; no pide confirmación
```

`Scripts/install-app.sh`, en orden:

1. Exige que exista `.build/app/MeetingVox.app` (si no, pide ejecutar `Scripts/build-app.sh`) y se niega a continuar si MeetingVox está corriendo desde `/Applications`: hay que salir de la app primero.
2. Verifica la firma de la app construida y su plist de agente.
3. Copia la app con `ditto` a una ruta temporal en `/Applications` y verifica la copia.
4. Mueve una `/Applications/MeetingVox.app` anterior a `~/MeetingVox-respaldos/app-previous-<fecha>/` y pone la nueva en su lugar.
5. Registra el ítem de inicio de sesión con `MeetingVox install --launch-at-login`. Con código **3** abre el panel de Ítems de inicio de sesión para que lo apruebes.
6. Abre la app si no está corriendo.

No envía SIGKILL ni borra nada. Si algo falla, indica dónde quedó la versión anterior.

Alternativa sin script:

```sh
ditto .build/app/MeetingVox.app /Applications/MeetingVox.app
open /Applications/MeetingVox.app
```

En ese caso, registra el inicio de sesión desde «Primeros pasos» (paso «Listo») o con el comando de la sección siguiente.

## Ítem de inicio de sesión

```sh
/Applications/MeetingVox.app/Contents/MacOS/MeetingVox install --launch-at-login   # registrar
/Applications/MeetingVox.app/Contents/MacOS/MeetingVox install --status            # ver estado (no cambia nada)
/Applications/MeetingVox.app/Contents/MacOS/MeetingVox install --uninstall         # quitar
```

- Hay que pasar **exactamente una** de las tres opciones; si no, sale con código **64**.
- `--launch-at-login` solo registra desde `/Applications/MeetingVox.app`. Desde otra ubicación se niega y sale con código **1**.
- Mecanismo: `SMAppService.agent(plistName:)` sobre el plist incrustado. Si el sistema lo rechaza (por ejemplo, con un bundle autofirmado), usa como alternativa un LaunchAgent en `~/Library/LaunchAgents` con la misma etiqueta, que apunta al ejecutable instalado.
- Códigos de salida de `--launch-at-login`:
  - **0**: registrado.
  - **1**: falló o se negó.
  - **3**: registrado, pero macOS todavía requiere tu aprobación. Nada arranca al iniciar sesión hasta que actives MeetingVox en Ajustes del Sistema › General › Ítems de inicio de sesión y extensiones.
- Repetir `--launch-at-login` es seguro: con el servicio ya registrado no cambia nada. Si queda un archivo de LaunchAgent sobrante, lo borra sin detener el proceso en marcha.
- `--uninstall` quita ambos mecanismos. Como también detiene una instancia de MeetingVox en marcha, una grabación en curso se finaliza antes.
- El registro de la app y del agente alternativo está en `~/Library/Logs/MeetingVox/` (`meetingvox.log`, `launchd.log`).

## Si venías de quill

*Opcional: solo aplica a Macs donde estaba instalado el `quill` original (`/usr/local/bin/quill` con el LaunchAgent `com.digimata.quill`).*

- MeetingVox **copia** una sola vez `~/.config/quill` a `~/.config/meetingvox` (marcador `.migrated-from-quill`) y sigue leyendo las claves del llavero del servicio `com.digimata.quill` hasta que las guardes de nuevo.
- Nunca modifica ni borra `/usr/local/bin/quill`, `~/.config/quill`, los ítems del llavero heredados ni las grabaciones. MeetingVox se niega a iniciar mientras quill esté corriendo.
- `Scripts/install-app.sh` no toca el agente de quill. Si sigue cargado, retíralo a mano antes de instalar (paso opcional; `bootout` es una parada limpia y termina una grabación de quill en curso, así que hazlo cuando no esté grabando):

```sh
launchctl bootout gui/$(id -u)/com.digimata.quill
mv ~/Library/LaunchAgents/com.digimata.quill.plist ~/Library/LaunchAgents/com.digimata.quill.plist.disabled
```

Para volver a quill:

```sh
/Applications/MeetingVox.app/Contents/MacOS/MeetingVox install --uninstall
mv ~/Library/LaunchAgents/com.digimata.quill.plist.disabled ~/Library/LaunchAgents/com.digimata.quill.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.digimata.quill.plist
```

Los cambios de configuración hechos en MeetingVox quedan en `~/.config/meetingvox` y no se copian de vuelta a `~/.config/quill`. macOS puede volver a pedir los permisos de micrófono y audio del sistema para el binario de quill.
