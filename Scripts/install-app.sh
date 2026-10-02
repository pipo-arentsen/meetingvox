#!/usr/bin/env bash
# Instala .build/app/MeetingVox.app en /Applications/MeetingVox.app.
# Lo ejecutas tú desde una terminal.
#
#   Scripts/build-app.sh          # primero, construir y firmar .build/app/MeetingVox.app
#   Scripts/install-app.sh
#
# Qué hace, en orden (nunca envía SIGKILL ni borra nada):
#   1. se niega a continuar si MeetingVox está corriendo desde /Applications
#      (al salir de la app se finaliza una grabación en curso)
#   2. verifica la firma de la app construida y su agente de inicio de sesión incrustado
#   3. copia la app a una ruta temporal en /Applications y verifica la copia
#   4. mueve una /Applications/MeetingVox.app anterior a
#      ~/MeetingVox-respaldos/app-previous-<fecha>/ y pone la nueva en su lugar
#   5. registra el ítem de inicio de sesión con la CLI de la propia app
#      (`MeetingVox install --launch-at-login`; código 3 = registrado, pero hay que
#      aprobarlo en Ítems de inicio de sesión, cuyo panel se abre)
#   6. abre la app si no está corriendo
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MeetingVox"
BUILT_APP="$ROOT/.build/app/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
# Estos literales reflejan AppIdentity (agentPlistName, displayName);
# si cambian allí, cámbialos aquí.
AGENT_PLIST_NAME="com.pipostudio.meetingvox.agent.plist"
STAMP="$(date +%Y%m%d-%H%M%S)"
ASIDE=""      # adónde se movió la app anterior de /Applications, si se movió
INSTALLED=0   # 1 = la app nueva ya está en $DEST; 2 = además se registró el ítem de inicio
LOGIN_ITEMS_PANE="x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# 0. Requisitos previos.
[[ "$(uname -s)" == "Darwin" ]] || die "solo funciona en macOS"
[[ -d "$BUILT_APP" ]] || die "no se encontró $BUILT_APP; ejecuta primero Scripts/build-app.sh"

# 1. Una instancia en marcha seguiría usando el bundle reemplazado (y podría estar
#    grabando): hay que salir de ella antes, nunca matarla.
if pgrep -f "$DEST/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    die "$APP_NAME está corriendo desde $DEST; sal de la app (menú «Salir de $APP_NAME»: una grabación en curso se finaliza antes de salir) y vuelve a ejecutar este script"
fi

# 2. Verificar lo que se va a instalar.
say "verificando $BUILT_APP"
codesign --verify --deep --strict "$BUILT_APP" \
    || die "la verificación de la firma falló; vuelve a construir con Scripts/build-app.sh"
[[ -f "$BUILT_APP/Contents/Library/LaunchAgents/$AGENT_PLIST_NAME" ]] \
    || die "falta el plist del agente incrustado en la app; vuelve a construir con Scripts/build-app.sh"

# 3. Primero una copia temporal: si la copia falla, la instalación anterior
#    sigue intacta en su lugar.
STAGE="/Applications/.$APP_NAME.installing.$$"

# Ante cualquier fallo: quitar la copia temporal y decir dónde quedó cada cosa.
on_exit() {
    local rc=$?
    rm -rf "$STAGE"
    # Si falló entre apartar la app anterior y poner la nueva, /Applications quedó
    # sin MeetingVox: se devuelve la anterior a su lugar.
    if (( rc != 0 && ! INSTALLED )) && [[ -n "$ASIDE" && ! -e "$DEST" ]]; then
        mv "$ASIDE" "$DEST" && ASIDE=""
    fi
    if (( rc != 0 )); then
        {
            printf '\nLa instalación no terminó.\n'
            if (( INSTALLED == 1 )); then
                printf '%s quedó instalada en %s, pero el ítem de inicio de sesión no se registró.\n' "$APP_NAME" "$DEST"
                printf 'Para reintentarlo:\n  "%s/Contents/MacOS/%s" install --launch-at-login\n' "$DEST" "$APP_NAME"
            fi
            if [[ -n "$ASIDE" ]]; then
                printf 'La versión anterior de %s está en: %s\n' "$APP_NAME" "$ASIDE"
            fi
        } >&2
    fi
}
trap on_exit EXIT

say "copiando a $STAGE"
ditto "$BUILT_APP" "$STAGE"
codesign --verify --deep --strict "$STAGE" || die "la copia temporal no pasó la verificación de la firma"

# 4. Poner la app en su lugar; una anterior se mueve aparte, no se borra.
if [[ -e "$DEST" ]]; then
    ASIDE_DIR="$HOME/MeetingVox-respaldos/app-previous-$STAMP"
    say "moviendo la $DEST existente a $ASIDE_DIR"
    mkdir -p "$ASIDE_DIR"
    mv "$DEST" "$ASIDE_DIR/"
    ASIDE="$ASIDE_DIR/$APP_NAME.app"
fi
mv "$STAGE" "$DEST"
INSTALLED=1

# 5. Ítem de inicio de sesión, con la CLI de la app instalada. Código 3 = registrado,
#    pero el usuario todavía debe permitirlo, así que aún no arrancaría al iniciar sesión.
say "registrando el ítem de inicio de sesión"
rc=0
"$DEST/Contents/MacOS/$APP_NAME" install --launch-at-login || rc=$?
APPROVAL_NEEDED=0
case "$rc" in
    0) ;;
    3) APPROVAL_NEEDED=1 ;;
    *) exit "$rc" ;;
esac
INSTALLED=2   # instalada y con el ítem de inicio de sesión registrado

# 6. La app debe quedar funcionando ahora, haga lo que haga el ítem en el próximo inicio de sesión.
if (( APPROVAL_NEEDED )); then
    cat <<APPROVAL

Falta tu aprobación: macOS todavía no permite $APP_NAME como ítem de inicio de sesión,
así que NO arrancará sola al iniciar sesión hasta que la actives en:
  Ajustes del Sistema › General › Ítems de inicio de sesión y extensiones › $APP_NAME
Abriendo ese panel ahora.
APPROVAL
    open "$LOGIN_ITEMS_PANE" \
        || printf 'no se pudo abrir Ajustes del Sistema; abre Ítems de inicio de sesión a mano\n' >&2
fi
if pgrep -f "$DEST/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    say "$APP_NAME ya está corriendo"
else
    say "abriendo $APP_NAME"
    open "$DEST"
fi

cat <<DONE

Listo. $APP_NAME quedó instalada en $DEST.

Para revisarla:
  "$DEST/Contents/MacOS/$APP_NAME" install --status
  tail -f "$HOME/Library/Logs/$APP_NAME/meetingvox.log"
En el primer inicio, macOS puede pedir los permisos de Micrófono, Audio del sistema y Red local.
DONE
if [[ -n "$ASIDE" ]]; then
    printf 'La versión anterior quedó en: %s (puedes borrarla cuando compruebes que la nueva funciona).\n' "$ASIDE"
fi
