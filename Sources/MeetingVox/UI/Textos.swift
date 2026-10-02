import Foundation

/// Every user-visible string in one place, in neutral Spanish. The binary has
/// no `.app` bundle, so there are no `.lproj` / `Localizable.strings`
/// resources to lean on — centralizing the copy here is the lightweight
/// substitute. Code, logs, CLI and `doctor` output stay in English; only what
/// the user sees in the menu, notifications and transcript.md lives here.
/// Keep the terse lowercase style. The visible app name is "MeetingVox"; the
/// legacy "quill" name survives only as migration ids and paths in
/// `AppIdentity`, never in what the user reads.
enum Textos {
    // MARK: - Menu

    enum Menu {
        static let inactivo = "inactivo"
        /// "● Grabando · 12:34 · Teams" (the app only when the meeting prompt started it).
        static func grabando(_ elapsed: String, app: String? = nil) -> String {
            ["● Grabando", elapsed, app].compactMap { $0 }.joined(separator: " · ")
        }
        static func ultima(_ titulo: String) -> String { "Última: \(titulo)" }
        static let iniciarGrabacion = "Iniciar grabación"
        static let detenerGrabacion = "Detener grabación"
        static let abrirCarpeta = "Abrir carpeta de grabaciones"
        static let configuracion = "Ajustes…"
        static let primerosPasos = "Primeros pasos…"
        static let abrirVentana = "Abrir MeetingVox"
        static let salir = "Salir de MeetingVox"
        static let plantillaMinuta = "Plantilla de la minuta"
        static let sinPlantillas = "No hay plantillas"
    }

    // MARK: - Meeting detection

    enum Reuniones {
        static let teams = "Reunión Teams"
        static let zoom = "Reunión Zoom"
        static let whatsApp = "Llamada de WhatsApp"
        static func navegador(_ app: String) -> String { "Llamada en \(app)" }
        static let navegadorGenerico = "Llamada en el navegador"
        // How a list row names the app (`MeetingApp.shortName`).
        static let teamsCorto = "Teams"
        static let zoomCorto = "Zoom"
        static let whatsAppCorto = "WhatsApp"
        static let navegadorGenericoCorto = "Navegador"
        /// Settings-list name of the generic WebKit rule.
        static let otroNavegador = "Otro navegador (WebKit)"
        /// Every label is feminine ("Reunión…", "Llamada…").
        static func detectada(_ label: String) -> String { "\(label) detectada" }
        static let pregunta = "¿Grabar con MeetingVox?"
        static let plantilla = "Plantilla"
        static let ignorar = "Ignorar"
        static let grabar = "Grabar"

        // End panel (while recording). Titles per app, see `MeetingApp.endedTitle`.
        static let teamsTermino = "La reunión de Teams terminó"
        static let zoomTermino = "La reunión de Zoom terminó"
        static let whatsAppTermino = "La llamada de WhatsApp terminó"
        static func navegadorTermino(_ app: String) -> String { "La llamada en \(app) terminó" }
        static let navegadorGenericoTermino = "La llamada en el navegador terminó"
        static let preguntaDetener = "¿Quieres detener la grabación?"
        static let seguirGrabando = "Seguir grabando"
        static let detener = "Detener"
    }

    // MARK: - Recording pill

    /// The floating pill's own copy; the detected/ended prompts reuse `Reuniones`.
    enum Pildora {
        static let grabando = "Grabando"
        static let yo = "Yo"
        static let otros = "Otros"
        /// A meter with nothing to show (track off, failed or silent for good).
        static let sinSenal = "—"
        static let ocultar = "Ocultar"
        static let micSilenciado = "Tu micrófono no capta audio. ¿Está silenciado?"
        static let cambiarMicrofono = "Cambiar micrófono"
        static func seDetieneSola(_ restante: String) -> String { "Se detiene sola en \(restante)" }
    }

    // MARK: - Transcription status (menu)

    enum Transcripcion {
        static func transcribiendo(_ name: String) -> String { "transcribiendo \(name)" }
        static func transcribiendo(_ name: String, enCola queued: Int) -> String {
            "transcribiendo \(name) · \(queued) en cola"
        }
        static func fallo(_ name: String) -> String { "falló la transcripción · \(name)" }
    }

    // MARK: - Minutes status (menu)

    enum Minuta {
        static func generando(_ name: String) -> String { "generando minuta · \(name)" }
        static func generando(_ name: String, enCola queued: Int) -> String {
            "generando minuta · \(name) · \(queued) en cola"
        }
        static func esperandoReintento(_ name: String) -> String { "minuta en espera de reintento · \(name)" }
        static func fallo(_ name: String) -> String { "falló la minuta · \(name)" }
    }

    // MARK: - Summary status (menu)

    enum Resumen {
        static func generando(_ name: String) -> String { "generando resumen · \(name)" }
        static func generando(_ name: String, enCola queued: Int) -> String {
            "generando resumen · \(name) · \(queued) en cola"
        }
        static func esperandoReintento(_ name: String) -> String { "resumen en espera de reintento · \(name)" }
        static func fallo(_ name: String) -> String { "falló el resumen · \(name)" }
        static func extrayendoTareas(_ name: String) -> String { "extrayendo tareas · \(name)" }
        static func extrayendoTareas(_ name: String, enCola queued: Int) -> String {
            "extrayendo tareas · \(name) · \(queued) en cola"
        }
    }

    // MARK: - Sessions (menu)

    enum Sesiones {
        static let abrirCarpeta = "Abrir carpeta"
        static let abrirTranscripcion = "Abrir transcripción"
        static let abrirMinuta = "Abrir minuta"
        static func abrirMinuta(_ plantilla: String) -> String { "Abrir minuta (\(plantilla))" }
        static let generarCon = "Generar minuta con…"
        static let regenerarCon = "Regenerar minuta con"
        static let sinTranscripcion = "Requiere una transcripción"
        static let sinClave = "Falta la clave de API de OpenRouter (Ajustes…)"
        static let sinModelo = "Falta elegir un modelo de OpenRouter (Ajustes…)"
        static let sinPlantillas = "No hay plantillas"
        static let reintentarMinuta = "Reintentar minuta"
        static let aplicarGlosario = "Aplicar glosario"
        static let quitarEventoCalendario = "Quitar evento del calendario"
        static let quitarEventoFallo = "No se pudo quitar el evento del calendario."
        static let reconstruirIndice = "Reconstruir índice"
    }

    // MARK: - Mover a la papelera

    enum Papelera {
        static let mover = "Mover a la papelera…"
        static let confirmar = "Mover a la papelera"
        static let cancelar = "Cancelar"
        static let entendido = "Entendido"
        static func titulo(_ n: Int) -> String {
            n == 1 ? "¿Mover 1 reunión a la Papelera?" : "¿Mover \(n) reuniones a la Papelera?"
        }
        static func detalle(_ n: Int) -> String {
            n == 1 ? "Podrás recuperarla desde la Papelera de macOS." : "Podrás recuperarlas desde la Papelera de macOS."
        }
        static let ningunaSePuede = "Ninguna de estas reuniones se puede mover ahora"
        static let omitidas = "No se moverán:"
        /// Why a session is skipped, in the sheet's list.
        static func motivo(_ razon: TrashPlan.BlockReason) -> String {
            switch razon {
            case .recording: "se está grabando"
            case .working(.transcription): "se está transcribiendo"
            case .working(.minutes): "se está generando la minuta"
            case .working(.summary): "se está generando el resumen"
            case .working(.memory): "se está enviando a memoria"
            case .pending: "todavía se está procesando"
            }
        }
        static let memoriaCasilla = "Borrar también de la memoria (Hindsight)"
        static let memoriaNota = "Es permanente: también borra los recuerdos extraídos de esa reunión."
        static let memoriaFallo = "No se pudo borrar de la memoria; la reunión sigue aquí."
        static let noSePudoMover = "No se pudo mover a la papelera; la reunión sigue aquí."
        static let problemaTitulo = "Mover a la papelera"
    }

    // MARK: - Meeting list (filters, ámbito, row header pieces)

    enum Indice {
        static let todosLosClientes = "Todos los clientes"
        static let cliente = "Cliente"
        static let periodo = "Periodo"
        static let cualquierFecha = "Cualquier fecha"
        static let ultimos7Dias = "Últimos 7 días"
        static let esteMes = "Este mes"
        static let sinReuniones = "No hay reuniones que coincidan con el filtro"
        static func contador(_ shown: Int, _ total: Int) -> String { "\(shown) de \(total) reuniones" }
        static let tipo = "Tipo"
        static let todosLosTipos = "Todos"
        static let trabajo = "Trabajo"
        static let profesional = "Profesional"
        static let personal = "Personal"
        static let sinClasificar = "Sin clasificar"
        static let sinMinuta = "Sin minuta"
        static let sinPlantilla = "Sin plantilla"
        static let clasificarComo = "Clasificar como"
        static func seleccionadas(_ n: Int) -> String { "\(n) seleccionadas" }
        /// Row header pieces; index 0 = Sunday (`Calendar` weekday 1). Fixed
        /// here instead of a `DateFormatter` so the output doesn't depend on
        /// ICU's Spanish abbreviations ("sept." vs "sep").
        static let diasCortos = ["Dom", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb"]
        static let mesesCortos = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]
        static func duracion(minutos: Int) -> String {
            if minutos < 1 { return "<1 min" }
            if minutos < 60 { return "\(minutos) min" }
            let horas = minutos / 60, resto = minutos % 60
            return resto == 0 ? "\(horas) h" : "\(horas) h \(resto) min"
        }
    }

    // MARK: - Notifications

    enum Notificacion {
        static let grabacionFallida = "MeetingVox — falló la grabación"
        static let yaEnEjecucionTitulo = "MeetingVox — ya está abierto"
        static let yaEnEjecucion = "Ya hay una copia de MeetingVox en ejecución; esta se cierra."
        static let quillAnteriorEnEjecucion =
            "El quill anterior sigue en ejecución. Ciérralo (sin cortar una grabación) antes de abrir MeetingVox."

        // The single "ready" notice (settlement: everything the session was
        // going to get is done) — replaces the old per-stage success notices.
        static let reunionLista = "MeetingVox — reunión lista"
        static let parteTranscripcion = "transcripción"
        static let parteMinuta = "minuta"
        static let parteResumen = "resumen"
        /// What failed after the ready parts, when the ready notice still goes out.
        static let fallaResumen = "el resumen no se pudo generar"
        static let fallaMemoria = "no se pudo enviar a memoria"
        /// "<titulo> — transcripción, minuta y resumen", plus
        /// " · el resumen no se pudo generar" for each failure.
        static func reunionListaCuerpo(_ label: String, partes: [String], fallos: [String] = []) -> String {
            let list: String
            switch partes.count {
            case 0, 1: list = partes.first ?? ""
            default: list = partes.dropLast().joined(separator: ", ") + " y " + partes[partes.count - 1]
            }
            return "\(label) — \(([list] + fallos).joined(separator: " · "))"
        }

        // Failure notices: say what failed, never send the user to a log
        // file, and never name a button (osascript shows none).
        static let transcripcionFallida = "MeetingVox — falló la transcripción"
        static func transcripcionFallidaCuerpo(_ name: String) -> String {
            "\(name) — no se pudo transcribir la grabación. El audio sigue guardado en la carpeta de la reunión."
        }
        /// A minutes request the user made (manual, from the window, regenerate)
        /// finished; the body is the session folder, as before.
        static let minutaLista = "MeetingVox — minuta lista"
        static let minutaFallida = "MeetingVox — falló la minuta"
        static func minutaFallidaCuerpo(_ name: String) -> String {
            "\(name) — no se pudo generar la minuta. La transcripción está disponible; puedes volver a intentarlo desde la ventana de MeetingVox."
        }
        static let microfonoMudo = "MeetingVox — el micrófono no está captando audio"
        static let revisaMicrofono = "Revisa el micrófono o reconéctalo."
        static let sinMicrofono = "MeetingVox — grabando sin micrófono"
        static let sinAudioSistema = "MeetingVox — grabando sin el audio del sistema"
        static func minutaSigue(_ name: String) -> String {
            "\(name) — no se pudo contactar a OpenRouter; queda pendiente: se reintentará al abrir MeetingVox o con «Reintentar minuta»"
        }
        /// Exhausted-retry text for a minutes request made from the main
        /// window's Minuta tab: unlike `minutaSigue`, that request is not
        /// resumed at launch and has no "Reintentar minuta" menu item, so
        /// it must not claim either.
        static func minutaNoGeneradaDesdeVentana(_ name: String) -> String {
            "No se pudo generar la minuta de \(name). Puedes volver a intentarlo desde la ventana de MeetingVox."
        }
        /// Exhausted-retry text for "Regenerar minuta con": the current
        /// minutes were kept, nothing is resumed at launch.
        static func minutaNoRegenerada(_ name: String) -> String {
            "No se pudo regenerar la minuta de \(name). La minuta actual sigue igual; puedes volver a intentarlo."
        }
        static let resumenFallido = "MeetingVox — falló el resumen"
        static func resumenFallidoCuerpo(_ name: String) -> String {
            "\(name) — no se pudo generar el resumen. La transcripción y la minuta no se ven afectadas."
        }
        static func resumenSigue(_ name: String) -> String {
            "\(name) — no se pudo contactar a OpenRouter; el resumen queda pendiente: se reintentará al abrir MeetingVox o con «Reconstruir índice»"
        }
        // Buttons on the native notices (bundled app only).
        static let accionAbrir = "Abrir"
        static let accionMemoria = "Enviar a memoria"
        static let accionReintentar = "Reintentar"
        static let accionVerReunion = "Ver reunión"
        static let glosarioAplicado = "MeetingVox — glosario aplicado"
        static let glosarioFallido = "MeetingVox — no se pudo aplicar el glosario"
        static func glosarioFallidoCuerpo(_ name: String) -> String {
            "\(name) — no se pudo aplicar el glosario a la transcripción."
        }
        static func reemplazos(_ name: String, _ n: Int) -> String {
            "\(name) — \(n == 1 ? "1 reemplazo" : "\(n) reemplazos")"
        }
        static func sinCambiosGlosario(_ name: String) -> String { "\(name) — la transcripción ya estaba al día" }
    }

    // MARK: - Recorder errors

    /// Recorder error descriptions surface verbatim in the recording-failed
    /// notification, so they are user-visible copy.
    enum Errores {
        static func microfonoNoInicia(_ e: Error) -> String {
            "no se pudo iniciar el micrófono: \(e)"
        }
        static func archivoMicrofono(_ e: Error) -> String {
            "no se pudo crear el archivo del micrófono: \(e)"
        }
        static let sinMicrofono = "no hay ningún micrófono disponible"
        static func sinPistas(mic: Error, system: Error) -> String {
            "no se pudo grabar el micrófono (\(mic)) ni el audio del sistema (\(system))"
        }
        static let microfonoSinPermiso =
            "MeetingVox no tiene permiso para usar el micrófono — revisa Ajustes del Sistema → Privacidad y seguridad → Micrófono"
        static func formatoMicrofono(_ f: some CustomStringConvertible) -> String {
            "no se puede convertir el formato del micrófono \(f)"
        }
        static func tapNoCreado(_ s: OSStatus) -> String {
            "no se pudo crear el tap de audio del sistema (OSStatus \(s)) — revisa Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema"
        }
        static func formatoTap(_ s: OSStatus) -> String {
            "no se pudo leer el formato del tap (OSStatus \(s))"
        }
        static func agregadoNoCreado(_ s: OSStatus) -> String {
            "no se pudo crear el dispositivo agregado (OSStatus \(s))"
        }
        static func ioProcNoCreado(_ s: OSStatus) -> String {
            "no se pudo crear el IO proc (OSStatus \(s))"
        }
        static func dispositivoNoInicia(_ s: OSStatus) -> String {
            "no se pudo iniciar el dispositivo (OSStatus \(s))"
        }
        static func archivoSalida(_ e: Error) -> String {
            "no se pudo crear el archivo de salida: \(e)"
        }
    }

    // MARK: - Main menu

    /// The accessory app shows no menu bar, but key equivalents (⌘C/⌘V…) in
    /// text fields are dispatched through `NSApp.mainMenu`, so it must exist.
    enum MenuPrincipal {
        static let ajustes = "Ajustes…"
        static let salir = "Salir de MeetingVox"
        static let cerrarVentana = "Cerrar ventana"
        static let edicion = "Edición"
        static let deshacer = "Deshacer"
        static let rehacer = "Rehacer"
        static let cortar = "Cortar"
        static let copiar = "Copiar"
        static let pegar = "Pegar"
        static let seleccionarTodo = "Seleccionar todo"
    }

    // MARK: - Quit

    /// ⌘Q / Salir while a recording is in progress.
    enum Salir {
        static let pregunta = "Hay una grabación en curso. ¿Detener y salir?"
        static let detalle = "La grabación se detiene y se guarda antes de salir; la transcripción sigue al volver a abrir MeetingVox."
        static let detenerYSalir = "Detener y salir"
        static let cancelar = "Cancelar"
        static func plantillaSinGuardar(_ nombre: String) -> String { "Hay cambios sin guardar en la plantilla «\(nombre)»." }
        static let plantillaDetalle = "Si sales sin guardar, los cambios se pierden."
        static let guardar = "Guardar"
        static let descartar = "Descartar"
    }

    // MARK: - Main window

    /// The Tareas page and the Resumen tab's tasks column.
    enum Tareas {
        static let titulo = "Tareas"
        static let nota = "Los compromisos de todas tus reuniones, tal como los extrajo el resumen de cada una."
        static let buscar = "Buscar en las tareas"
        static let responsable = "Responsable"
        static let todos = "Todos"
        static let sinResponsable = "Sin responsable"
        static func contador(_ mostradas: Int, de total: Int) -> String { "\(mostradas) de \(total) tareas" }
        static func sinExtraer(_ n: Int) -> String {
            n == 1
                ? "1 reunión todavía no tiene las tareas extraídas. «Reconstruir índice» (⌥ en el menú de la barra) las extrae."
                : "\(n) reuniones todavía no tienen las tareas extraídas. «Reconstruir índice» (⌥ en el menú de la barra) las extrae."
        }
        static let cargando = "Cargando tareas…"
        static let vacioTitulo = "Todavía no hay tareas"
        static let vacioDetalle = "Las tareas salen del resumen de cada reunión. Para las reuniones anteriores, usa «Reconstruir índice» (⌥ en el menú de la barra)."
        static let sinCoincidencias = "Ninguna tarea coincide con los filtros."
        static let quitarFiltros = "Quitar filtros"
        static func para(_ cuando: String) -> String { "Para: \(cuando)" }
        static func abrirReunion(_ titulo: String) -> String { "Abrir la reunión «\(titulo)»" }
        // Resumen tab column
        static let columnaSinExtraer = "Las tareas de esta reunión todavía no se extrajeron. «Reconstruir índice» (⌥ en el menú de la barra) las extrae."
        static let columnaSinTareas = "No se encontraron tareas en esta reunión."
    }

    /// The main window (list, sidebar, detail). Weekday and month names are
    /// fixed here, like `Indice.diasCortos`, so the section titles don't
    /// depend on ICU's Spanish data.
    enum Principal {
        // List sections
        static let hoy = "Hoy"
        static let ayer = "Ayer"
        static let sinFecha = "Sin fecha"
        /// Index 0 = Sunday (`Calendar` weekday 1).
        static let diasLargos = ["Domingo", "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado"]
        /// Index 0 = January.
        static let mesesLargos = [
            "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio",
            "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre",
        ]
        static func mes(_ mes: Int, _ anio: Int) -> String { "\(mesesLargos[mes - 1]) \(anio)" }

        // Sidebar
        static let reuniones = "Reuniones"
        static let tareas = "Tareas"
        static let ambito = "Ámbito"
        static let biblioteca = "Biblioteca"
        static let plantillas = "Plantillas"
        static let glosario = "Glosario"
        static let audioNoSale = "El audio no sale de este Mac"

        // Row status pill
        static let pildoraGrabando = "Grabando"
        static let pildoraError = "Error"
        static let pildoraTranscribiendo = "Transcribiendo"
        static let pildoraMinuta = "Generando minuta"
        static let pildoraResumen = "Resumiendo"
        static let pildoraEnviando = "Enviando"
        static let pildoraPendiente = "Pendiente"
        static let pildoraEnMemoria = "En memoria"

        // Title strip
        static let grabar = "Grabar"
        static func detener(_ elapsed: String) -> String { "Detener \(elapsed)" }
        static let atajoGrabar = "⌘R"

        // List
        static let buscar = "Buscar en reuniones, transcripciones y minutas"
        static let filtros = "Filtros"
        static let mesesAnteriores = "Meses anteriores"
        static let cargando = "Cargando reuniones…"
        static let sinReunionesTitulo = "Todavía no hay reuniones"
        static let sinReunionesDetalle = "Empieza con Grabar (⌘R), o deja que MeetingVox detecte tu próxima reunión."
        static let sinResumenFila = "Sin título"
        static let sinDuracion = "Sin duración"
        static let grabacionManual = "Grabación manual"

        // Accessibility
        static func ambitoDe(_ label: String) -> String { "Ámbito: \(label)" }
        static let enCurso = "En curso"

        // Detail area
        static let elegirReunion = "Elige una reunión"
        static let elegirReunionDetalle = "Selecciona una reunión de la lista para ver su detalle."

        // Pipeline stepper
        static let pasoGrabada = "Grabada"
        static let pasoTranscrita = "Transcrita"
        static let pasoMinuta = "Minuta"
        static let pasoResumen = "Resumen"
        static let pasoMemoria = "Memoria"
        static let reintentarPaso = "Reintentar"
        static func estadoPaso(_ paso: String, _ estado: String) -> String { "\(paso): \(estado)" }
        static let estadoHecho = "listo"
        static let estadoEnCurso = "en curso"
        static let estadoPendiente = "pendiente"
        static let estadoError = "con error"
        static let estadoOmitido = "no aplica"

        // Session detail: header chips and toolbar
        static let pistaYo = "Yo"
        static let pistaOtros = "Otros"
        static func plantillaDe(_ nombre: String) -> String { "Plantilla: \(nombre)" }
        static let clasificarAmbito = "Ámbito de la reunión"
        static let regenerar = "Regenerar"
        static let mostrarCarpeta = "Mostrar carpeta"
        static let masAcciones = "Más acciones"
        static let enviarPaso = "Enviar"
        static func nadaQueReintentar(_ razon: String) -> String { "No hay nada que reintentar: \(razon)" }
        static let razonTranscripcion = "la transcripción está desactivada."
        static let razonMinuta = "la minuta no está pendiente ni con error."
        static let razonResumen = "los resúmenes están desactivados o falta la clave o el modelo de OpenRouter."
        static let memoriaCambio = "El estado de la memoria cambió; se actualizó la reunión. Revisa y vuelve a intentar."
        static let cerrarAviso = "Cerrar aviso"

        // Tabs
        static let tabResumen = "Resumen"
        static let tabMinuta = "Minuta"
        static let tabTranscripcion = "Transcripción"

        // Resumen tab
        static let etiquetaResumen = "Resumen"
        static let etiquetaTemas = "Temas"
        static let etiquetaParticipantes = "Participantes"
        static let etiquetaTareas = "Tareas"
        static let resumenGenerando = "El resumen se está generando…"
        static let resumenFallo = "No se pudo generar el resumen. Usa Reintentar en el paso Resumen."
        static let resumenAun = "Todavía no hay resumen de esta reunión."
        static let resumenDesactivado = "Los resúmenes están desactivados, o falta la clave o el modelo de OpenRouter (Ajustes)."
        static let sinTemas = "Sin temas"
        static let sinParticipantes = "Sin participantes"

        // Minuta tab
        static let minutaGenerando = "Generando la minuta…"
        static let minutaEsperandoReintento = "La generación falló; se reintentará en unos minutos…"
        static let minutaRegenerando = "Regenerando la minuta…"
        static let minutaFallo = "La minuta no se pudo generar."
        static let minutaPendiente = "La minuta quedó pendiente."
        static let minutaSinCrear = "Esta reunión todavía no tiene minuta."
        static let minutaPlantilla = "Plantilla"
        static let generarMinuta = "Generar minuta"
        static let minutaSinTranscripcion = "Sin transcripción no se puede generar una minuta."
        static let minutaSinLeer = "No se pudo leer la minuta."
        static let minutaCambio = "La minuta cambió; se actualizó la reunión. Revisa y vuelve a intentar."
        static let plantillaNoGuardada = "No se pudo guardar la plantilla elegida en la reunión; no se generó la minuta."

        // Transcripción tab
        static let transcripcionSinArchivo = "Todavía no hay transcripción de esta reunión."
        static let transcripcionSinLeer = "No se pudo leer la transcripción."
        static let transcripcionVacia = "La transcripción no tiene texto."
        static let cargandoDetalle = "Cargando…"
        /// Where a search snippet in the list came from (accessibility hint of its button).
        static let coincidenciaEnTranscripcion = "Coincidencia en la transcripción. Abrir en la línea."
        static let coincidenciaEnMinuta = "Coincidencia en la minuta. Abrir la minuta."
        /// The hover on a transcript line the glossary corrected: «original» → corrected.
        static let glosarioCorregido = "Corregido por el glosario"
    }

    // MARK: - Settings window

    /// Biblioteca: the template editor (Plantillas) and the strings around the
    /// moved Glosario page. The glossary rows keep their `Ajustes` copy.
    /// The Transcripción tab's player bar.
    enum Reproductor {
        static let reproducir = "Reproducir"
        static let pausar = "Pausar"
        static let posicion = "Posición"
        static let velocidad = "Velocidad"
        /// The two tracks, named as the transcript names their speakers.
        static let pistaYo = "Yo"
        static let pistaOtros = "Otros"
        static func silenciar(_ pista: String) -> String { "Silenciar \(pista)" }
        static func volumen(_ pista: String) -> String { "Volumen de \(pista)" }
        static let pausadoGrabando = "La reproducción se pausa mientras grabas."
        static let estaSesionGrabando = "Esta reunión se está grabando."
        static let sinAudio = "Esta reunión no tiene audio."
        static let noSeAbrio = "No se pudo abrir el audio de esta reunión."
        static let seDetuvo = "La reproducción se detuvo."
        static let clickEnLinea = "Reproducir desde aquí"
    }

    enum Biblioteca {
        static let plantillasTitulo = "Plantillas de minuta"
        static let nuevaPlantilla = "Nueva plantilla"
        static let nuevaPlantillaTitulo = "Nueva plantilla"
        static let nuevaPlantillaMensaje = "Escribe un identificador para el archivo, sin espacios ni barras (por ejemplo, cliente-nuevo). Después podrás editar su contenido."
        static let identificador = "Identificador"
        static let crear = "Crear"
        static let elegirPlantilla = "Elige una plantilla"
        static let elegirPlantillaDetalle = "Selecciona una plantilla de la lista para editarla."
        static let vistaPrevia = "Vista previa"
        static let editor = "Editor"
        static let guardar = "Guardar"
        static let revertir = "Revertir"
        static let restaurarFabrica = "Restaurar de fábrica"
        static let sinGuardar = "Cambios sin guardar"
        static let deFabrica = "De fábrica"
        static let advertenciaBytes = "Este archivo tiene caracteres que no son UTF-8 válido y se muestran como «�». Si lo guardas, se reemplazan de forma definitiva."
        static func noSePudoLeer(_ detalle: String) -> String { "No se pudo leer el archivo: \(detalle)" }
        static let archivoCambio = "El archivo cambió en disco"
        static let archivoCambioDetalle = "Otra herramienta modificó esta plantilla después de abrirla. Recárgala para ver la versión actual; tus cambios sin guardar se descartan."
        static let recargar = "Recargar"
        static func errorEscritura(_ detalle: String) -> String { "No se pudo guardar la plantilla: \(detalle). El archivo original no se modificó." }
        static let idInvalido = "Identificador no válido: no puede estar vacío, tener espacios, contener «/» ni empezar con un punto."
        static func copiaGuardada(_ nombre: String) -> String { "Se guardó una copia del archivo original como «\(nombre)», junto a la plantilla." }
        static func errorCopia(_ detalle: String) -> String { "No se pudo guardar una copia del original (\(detalle)), así que no se guardó nada." }
        static let crearConCambios = "Guarda o revierte los cambios de la plantilla abierta antes de crear una nueva."
        static let idExiste = "Ya existe una plantilla con ese identificador."
        static let noEditable = "Este archivo no se puede leer, así que no se puede guardar encima."
        static let noEsDeFabrica = "Solo las plantillas de fábrica se pueden restaurar."
        static func errorRestaurar(_ detalle: String) -> String { "No se pudo restaurar la plantilla: \(detalle)" }
        static let restaurarTitulo = "¿Restaurar esta plantilla de fábrica?"
        static let restaurarMensaje = "Se sobrescribe el archivo con la versión incluida en MeetingVox y se pierden los cambios que haya hecho. Las demás plantillas no se modifican."
        static let restaurar = "Restaurar"
        static let cancelar = "Cancelar"
        static let descartarTitulo = "¿Descartar los cambios?"
        static let descartarMensaje = "Esta plantilla tiene cambios sin guardar. Si cambias de plantilla, se pierden."
        static let descartar = "Descartar cambios"
        static let sinPlantillas = "No hay plantillas todavía."
        static let glosarioTitulo = "Glosario"
        static let nuevoTerminoTitulo = "Nuevo término"

        // MARK: Glosario (moved from Ajustes)
        static let glosarioNota = "Escribe el término correcto (nombres propios, siglas, términos técnicos) y, opcionalmente, cómo suele transcribirse mal (por ejemplo, MeetingVox: «miting vox», «mitin vox»). Con «Corregir en la transcripción», esas variantes se reemplazan en la transcripción al terminar de transcribir (el texto original se conserva); sin ella, solo se sugieren al modelo en la minuta y el resumen. Para una reunión anterior, usa «Aplicar glosario»."
        static let nuevoTermino = "Nuevo término"
        static let variantesCampo = "Variantes (separadas por coma)"
        static let editarVariantes = "Editar variantes"
        static let corregirEnTranscripcion = "Corregir en la transcripción"
        static let corregirEnTranscripcionAyuda = "Reemplaza las variantes por el término en la transcripción. Desmárcalo si una variante también es una frase legítima."
        static func variantesDe(_ term: String) -> String { "Variantes de «\(term)»" }
        static let variantesEdicionNota = "Cómo suele transcribirse mal, separadas por coma. Déjalo vacío para quitar las variantes."
        static let agregar = "Agregar"
        static let eliminar = "Eliminar"
        static let glosarioVacio = "El glosario está vacío."
    }

    enum Ajustes {
        static let tituloVentana = "Configuración de MeetingVox"
        static let primerosPasos = "Primeros pasos…"
        static func errorGuardar(_ detail: String) -> String {
            "No se pudo guardar la configuración: \(detail)"
        }
        static func errorLeer(_ detail: String) -> String {
            "No se pudo leer la configuración: \(detail)"
        }
        static func configNoLegible(_ path: String) -> String { "no se puede leer \(path)" }
        static func configInvalida(_ path: String) -> String { "\(path) no es un objeto JSON válido" }
        static func valorInvalido(_ key: String, _ path: String) -> String {
            "\(key) en \(path) no tiene el formato esperado; corrígelo a mano"
        }
        static func configNoEscrita(_ path: String) -> String { "no se puede escribir \(path)" }
        static let reintentar = "Reintentar"

        // Tabs
        static let pestanaOpenRouter = "OpenRouter"
        static let pestanaReuniones = "Reuniones"

        // Section headings inside tabs
        static let seccionPrivacidad = "Privacidad"
        static let seccionDeteccion = "Detección"
        static let seccionGrabacion = "Grabación"
        static let seccionMinutas = "Minutas"

        // OpenRouter tab
        static let claveAPI = "Clave de API"
        static let clavePlaceholder = "sk-or-…"
        static let guardar = "Guardar"
        static let borrar = "Borrar"
        static let claveGuardada = "Clave guardada en el llavero de macOS"
        static let sinClave = "No hay una clave guardada"
        static let claveNota = "La clave se guarda en el llavero de macOS, nunca en config.json."
        static func errorLlavero(_ status: OSStatus, _ message: String?) -> String {
            "Error del llavero (OSStatus \(status))" + (message.map { ": \($0)" } ?? ".")
        }
        static func claveNoAccesible(_ status: OSStatus) -> String {
            "No se pudo acceder a la clave guardada en el llavero (OSStatus \(status)). Si se denegó el acceso, vuelva a probar y permítalo, o guarde la clave de nuevo."
        }
        static let modelo = "Modelo"
        static let modeloPlaceholder = "proveedor/modelo (p. ej. openai/gpt-4o-mini)"
        static let buscarModelos = "Buscar por nombre o ID"
        static let recargar = "Recargar"
        static let cargandoModelos = "Cargando modelos…"
        static func errorModelos(_ detail: String) -> String { "No se pudo cargar la lista de modelos: \(detail)" }
        static let sinResultados = "Ningún modelo coincide con la búsqueda"
        static func contexto(_ tokens: Int) -> String {
            "\(tokens.formatted()) tokens de contexto"
        }
        static let probarConexion = "Probar conexión"
        static let probando = "Probando…"
        static let necesitaClave = "Primero guarde una clave de API."

        // Minutes tab
        static let minutasAutomaticas = "Generar minuta automáticamente al terminar"
        static let minutasNota = "Al activarlo, el texto de la transcripción se envía a OpenRouter para redactar la minuta."
        static let resumenAutomatico = "Generar resumen automáticamente para el índice de reuniones"
        static let resumenAutomaticoNota = "Al activarlo, el texto de la transcripción (o de la minuta, si existe) se envía a OpenRouter para generar un resumen breve."
        static let plantilla = "Plantilla predeterminada"
        static func plantillaNoEncontrada(_ id: String) -> String { "\(id) (no encontrada)" }
        static let idioma = "Idioma de la minuta"
        static let cancelar = "Cancelar"
        static let abrirBiblioteca = "Abrir Biblioteca"
        static let bibliotecaNota = "Las plantillas de minuta y el glosario se editan en la Biblioteca de la ventana de MeetingVox. Aquí solo eliges la plantilla predeterminada."

        // Recording tab
        static let carpetaGrabaciones = "Carpeta de grabaciones"
        static let elegir = "Elegir…"
        static let carpetaNota = "El cambio se aplica después de reiniciar MeetingVox."
        static let carpetaNoValida = "La carpeta elegida no existe o no es una carpeta."
        static let carpetaNoEscribible = "No se puede escribir en esa carpeta. Elige otra."
        static let carpetaDentroDeLaApp = "Esa carpeta está dentro de la app MeetingVox y se perdería al actualizarla. Elige otra."
        static let procesamientoVoz = "Cancelación de eco en el micrófono"
        static let procesamientoVozNota = "Úselo al escuchar la reunión por los altavoces: evita que el sonido de los altavoces entre al micrófono y se transcriba como propio. Con auriculares no es necesario. Se aplica a la siguiente grabación."
        static let transcribirAutomaticamente = "Transcribir automáticamente"
        static let transcribirNota = "La transcripción se realiza en este Mac al detener la grabación."

        // Glossary tab

        // Meetings tab
        static let detectarReuniones = "Detectar reuniones y preguntar si grabar"
        static let reunionesNota = "Cuando una de estas aplicaciones empieza a usar el micrófono, MeetingVox muestra un aviso para grabar. Nunca graba por sí solo. Para detectarlo no se lee ningún audio: solo se consulta qué aplicación está usando el micrófono."
        static let aplicaciones = "Aplicaciones"
        static let preguntarDetener = "Preguntar si detener la grabación cuando termine la reunión"
        static let preguntarDetenerNota = "Mientras graba, si las aplicaciones de reunión dejan de usar el micrófono durante \(Int(MeetingEndMachine.grace)) segundos, MeetingVox pregunta si detener la grabación. Nunca la detiene por sí solo."

        static let pildoraGrabando = "Mostrar la píldora flotante mientras graba"
        static let pildoraGrabandoNota = "Muestra el tiempo, los niveles de tu micrófono y del audio de la reunión, y el botón Detener. Los avisos de reunión se muestran igual aunque esté desactivada."
        static let detenerSola = "Detener la grabación sola si nadie responde"
        static let detenerSolaNota = "Cuando la app de la reunión libera el micrófono, MeetingVox pregunta si detener la grabación. Si no respondes, se detiene sola 45 segundos después del aviso (unos 60 segundos desde que se libera el micrófono). Algunas apps lo liberan también cuando silencias tu micrófono, así que puede pasar con la reunión en curso. «Seguir grabando» cancela la cuenta."
        static let autoStopRequierePregunta = "Requiere activar la detección de reuniones y «Preguntar si detener la grabación cuando termine la reunión»."

        // Privacy tab
        static let denegarRecoleccion = "Pedir a OpenRouter que los proveedores no guarden ni entrenen con los datos"
        static let privacidadNota = "El audio nunca sale de este Mac. Solo se envía a OpenRouter el texto de la transcripción, y únicamente al generar una minuta o un resumen: automáticamente, si están activados, o al elegir «Generar minuta con…» en el menú. Cuando ya existe la minuta, el resumen se genera a partir del texto de la minuta en vez de la transcripción. Extraer las tareas y el país de una reunión (junto con el resumen, o al reconstruir el índice) también envía ese mismo texto a OpenRouter. Con esta opción, OpenRouter usa solo proveedores que no almacenan ni entrenan con los datos; puede reducir los modelos disponibles. Si una reunión está vinculada a un evento de tu calendario (hasta que uses «Quitar evento del calendario»), el título del evento y los nombres de los invitados también se envían a OpenRouter junto con la transcripción; los correos de los invitados nunca salen de este Mac."
    }

    // MARK: - Calendar

    enum Calendario {
        static let seccion = "Calendario"
        static let activar = "Usar mi calendario para nombrar las reuniones"
        static let nota = "Opcional. Al terminar una grabación, MeetingVox busca en tu calendario el evento que coincide y usa su título y los nombres de los invitados para nombrar la reunión y ayudar a redactar la minuta y el resumen. Solo lee: nunca modifica tus calendarios ni lee las notas de los eventos. Los correos de los invitados nunca salen de este Mac."
        static let sinResponder = "macOS todavía no te ha preguntado. Desactiva y vuelve a activar esta opción para que aparezca el aviso."
        static let solicitando = "Esperando tu respuesta al aviso de macOS…"
        static let autorizado = "MeetingVox puede leer tu calendario."
        static let denegado = "macOS no permite que MeetingVox lea tu calendario. Actívalo en Privacidad y seguridad › Calendarios."
        static let restringido = "El acceso al calendario está restringido en este Mac (por ejemplo, por un perfil de administración)."
        static let noDisponible = "Solo funciona en MeetingVox.app, no en el binario de desarrollo."
        static let abrirPrivacidad = "Abrir Privacidad › Calendarios"
    }

    // MARK: - Memory (Hindsight export)

    enum Memoria {
        static let envioRechazado = "MeetingVox — Hindsight rechazó una reunión"
        static func envioRechazadoCuerpo(_ name: String) -> String {
            "\(name) — el servidor de memoria rechazó la transcripción; no se envió."
        }
        static let tokenInvalido = "Token de Hindsight inválido"
        static let noEnviar = "No enviar a memoria"
        static let enviar = "Enviar a memoria"
        static let enviarIgual = "Enviar igual"
        static let reenviar = "Reenviar a memoria"

        // Memory status sentence (the detail beside the stepper)
        static func enMemoria(_ fecha: String, banco: String?) -> String {
            banco.map { "En memoria (\($0)) — \(fecha)" } ?? "En memoria — \(fecha)"
        }
        static func bancoPredeterminado(_ banco: String) -> String { "\(banco) (predeterminado)" }
        static let errorEnvio = "Error al enviar"
        static let noSeEnvia = "No se envía"
        static let pendienteEnvio = "Pendiente"
        static let muyCorta = "Muy corta"
        static let reintentarEnvio = "Reintentar envío"

        // Settings tab
        static let pestana = "Memoria"
        static let activar = "Usar la memoria de Hindsight"
        static let nota = "Solo se envía la transcripción de las reuniones que elijas en la ventana de MeetingVox o en el menú (o de todas, con el envío automático). La minuta nunca se envía. Además, el cliente y el país de la reunión (si el resumen los detectó) viajan como etiquetas. Si la reunión está vinculada a un evento de tu calendario (hasta que uses «Quitar evento del calendario»), el título del evento y los nombres de los invitados viajan como titulo y asistentes; los correos nunca. El audio nunca sale de este Mac. El token se guarda en el llavero."
        static let url = "URL del servidor"
        static let urlPlaceholder = "http://192.168.1.10:8888"
        static let bancoPorDefecto = "Banco por defecto"
        static let bancoSinElegir = "—"
        static let bancosSinLista = "No se pudo leer la lista de bancos del servidor; escribe el nombre del banco."
        static let propietario = "Tu nombre"
        static let descripcionDueno = "Descripción del dueño"
        static let descripcionDuenoPlaceholder = "Descripción de tu rol"
        static let autoEnviar = "Enviar automáticamente"
        static let notaAuto = "Envía cada reunión al terminar su procesamiento, desde la fecha elegida. Las reuniones cortas se omiten."
        static let desde = "Enviar automáticamente desde"
        static func minPalabras(_ n: Int) -> String { "Mínimo de palabras: \(n)" }
        static func minMinutos(_ n: Int) -> String { "Mínimo de minutos: \(n)" }
        static let token = "Token"
        static let tokenPlaceholder = "Pega el token de Hindsight"
        static let tokenGuardado = "Token guardado en el llavero"
        static let sinToken = "Sin token"
        static let necesitaToken = "Guarda un token primero."
        static let conexionCorrecta = "Conexión correcta"
        static let tokenRechazado = "El token no es válido."
        static func noAlcanzable(_ detail: String) -> String { "No se pudo contactar al servidor: \(detail)" }
        static func respuestaInesperada(_ status: Int) -> String { "Respuesta inesperada del servidor (HTTP \(status))." }
        static let faltaURL = "Escribe una URL válida (http:// o https://)."
    }

    // MARK: - OpenRouter

    enum OpenRouter {
        static func conexionCorrecta(label: String?, usage: Double?, limit: Double?) -> String {
            var parts = ["Conexión correcta"]
            if let label, !label.isEmpty { parts.append("clave \(label)") }
            if let usage { parts.append("uso: \(dolares(usage))") }
            parts.append(limit.map { "límite: \(dolares($0))" } ?? "sin límite")
            return parts.joined(separator: " · ")
        }

        private static func dolares(_ value: Double) -> String {
            String(format: "US$ %.2f", value)
        }

        static func errorRed(_ detail: String) -> String { "Error de red: \(detail)" }
        static let errorClave = "La clave de API no es válida o fue revocada."
        static func errorSolicitud(_ message: String?) -> String {
            "Solicitud rechazada" + (message.map { ": \($0)" } ?? ".")
        }
        static let errorCreditos = "La cuenta de OpenRouter no tiene créditos suficientes."
        static let errorLimite = "OpenRouter limitó las solicitudes; intente de nuevo en unos minutos."
        static func errorServidor(_ status: Int) -> String { "Error del servidor de OpenRouter (HTTP \(status))." }
        static func errorInesperado(_ status: Int, _ message: String?) -> String {
            "Respuesta inesperada (HTTP \(status))" + (message.map { ": \($0)" } ?? ".")
        }
        static let errorRespuesta = "No se pudo interpretar la respuesta de OpenRouter."
        static let respuestaNoHTTP = "respuesta no HTTP"
        static let errorVacia = "El modelo devolvió una respuesta vacía."
        static let errorTruncada = "El modelo agotó el límite de salida sin responder."
    }

    // MARK: - Onboarding ("Primeros pasos")

    enum Onboarding {
        static let tituloVentana = "Primeros pasos"
        static let nombreApp = "MeetingVox"

        // Rail and footer
        static let atras = "Atrás"
        static let continuar = "Continuar"
        static let empezar = "Empezar"

        static let pasoPermisos = "Permisos"
        static let pasoModelo = "Modelo"
        static let pasoMinutas = "Minutas"
        static let pasoListo = "Listo"

        static let subtituloPermisos = "MeetingVox pide cada permiso solo cuando haces clic en «Permitir». Puedes cambiarlos después en Ajustes del Sistema."
        static let subtituloModelo = "La transcripción ocurre en este Mac."
        static let subtituloMinutas = "Minutas y resúmenes con OpenRouter, si quieres."
        static let subtituloListo = "Todo queda en Ajustes por si quieres cambiarlo."

        // Permission rows
        static let microfono = "Micrófono"
        static let microfonoDetalle = "Tu voz en las reuniones."
        static let audioSistema = "Audio del sistema"
        static let audioSistemaDetalle = "La voz de las otras personas, capturada de la app de la reunión."
        static let notificaciones = "Notificaciones"
        static let notificacionesDetalle = "Avisos cuando una reunión está lista."
        static let redLocal = "Red local"
        static let redLocalDetalle = "Para enviar transcripciones a tu servidor de memoria."

        static let estadoPermitido = "Permitido"
        static let estadoPendiente = "Pendiente"
        static let estadoDenegado = "Denegado"
        static let estadoSolicitado = "Solicitado"
        static let estadoNoAplica = "No aplica"
        static let comprobando = "Comprobando…"

        static let permitir = "Permitir"
        static let abrirAjustes = "Abrir Ajustes del Sistema"
        static let esperarGrabacion = "Disponible al terminar la grabación"

        static let notaMemoria = "Cuando actives la memoria"
        static let notaRestringido = "Un perfil de administración lo restringe; abrir Ajustes no lo cambia."
        static let notaGrabando = "No se puede pedir mientras se graba."
        static let notaServidor = "El servidor no respondió; el permiso no es el problema."
        static let notaFueraDeApp = "Solo disponible en la app instalada."

        // Model step
        static let modeloTitulo = "Modelo de transcripción"
        static let modeloDescripcion = "MeetingVox transcribe con Parakeet Ultra, un modelo que se descarga una sola vez y corre en este Mac."
        static let audioPrivado = "El audio nunca sale de este Mac."
        static let descargarModelo = "Descargar modelo"
        static let reintentar = "Reintentar"
        static let modeloComprobando = "Comprobando el modelo…"
        static let modeloAusente = "El modelo aún no está en este Mac."
        static let modeloPresente = "El modelo está en este Mac."
        static let modeloNoAplica = "La transcripción está desactivada, así que no hace falta el modelo."
        static func modeloDescargando(_ porcentaje: Int) -> String { "Descargando… \(porcentaje) %" }
        static func modeloPreparando(_ porcentaje: Int) -> String { "Preparando el modelo… \(porcentaje) %" }
        static let modeloSinConexion = "Sin conexión a internet"
        static let modeloFallo = "No se pudo descargar el modelo"
        static func esperandoPermiso(_ nombre: String) -> String { "Esperando tu respuesta: \(nombre)" }

        // Minutas step
        static let minutasIntro = "Las minutas y los resúmenes se redactan con OpenRouter. Se envía el texto de la transcripción, nunca el audio. Puedes saltarte este paso y usar solo la transcripción."
        static let claveTitulo = "Clave de OpenRouter"
        static let claveGuardada = "Hay una clave guardada en el llavero de macOS."
        static let claveNueva = "Pega tu clave de OpenRouter"
        static let guardarClave = "Guardar clave"
        static let claveLegadoTitulo = "Hay una clave de la versión anterior"
        static let claveLegadoConsentimiento = "Para copiarla a MeetingVox, macOS mostrará un aviso del llavero y puede pedir la contraseña del Mac. Conviene elegir «Permitir siempre»: con «Permitir» a secas volverá a preguntar cada vez. La clave de la versión anterior no se modifica ni se borra. Si se prefiere no hacerlo, se puede pegar una clave nueva."
        static let migrarClave = "Migrar clave"
        static let migrando = "Esperando el permiso del llavero…"
        static let claveNoMigrada = "No se pudo copiar la clave anterior: macOS no dio permiso. Puedes intentarlo de nuevo o pegar una clave nueva."
        static let modeloOpenRouter = "Modelo de OpenRouter"
        static let modeloOpenRouterPlaceholder = "proveedor/modelo (p. ej. openai/gpt-4o-mini)"
        static let verModelos = "Ver modelos"
        static let modelosNota = "Ver los modelos consulta a OpenRouter; solo ocurre al hacer clic."
        static let privacidadTitulo = "Privacidad"
        static let omitirMinutas = "Omitir y usar solo la transcripción"
        static let omitirNota = "Omitir no cambia ninguna opción de minutas ni de resúmenes que ya tengas configurada."

        // Listo step
        static let carpetaTitulo = "Carpeta de grabaciones"
        static let carpetaElegir = "Elegir…"
        static let carpetaNotaGeneral = "Aquí se guardan las grabaciones y las transcripciones."
        static let carpetaNotaReinicio = "El cambio se aplica al reiniciar MeetingVox. La app no se reinicia sola."
        static let inicioTitulo = "Abrir al iniciar sesión"
        static let inicioActivo = "MeetingVox se abre al iniciar sesión."
        static let inicioActivar = "Activar"
        static let inicioDesactivar = "Desactivar"
        static let inicioPendiente = "macOS espera tu aprobación en Ajustes del Sistema."
        static let inicioNoDisponible = "Solo disponible en la app instalada en Aplicaciones."
        static let inicioFallo = "No se pudo cambiar el inicio de sesión."
        static let inicioGrabando = "Detén la grabación para cambiar esto."
        static let deteccionTitulo = "Detectar reuniones"
        static let deteccionDescripcion = "Avisa cuando una app de reunión empieza a usar el micrófono, para que decidas si grabar. Nunca graba sola."
        static let minutasAutoTitulo = "Generar la minuta al terminar"
        static let minutasAutoDescripcion = "Al activarlo, el texto de la transcripción se envía a OpenRouter para redactar la minuta."
        static let minutasAutoRequisito = "Necesita una clave de OpenRouter y un modelo (paso Minutas)."
        static let minutasAutoRequisitoMigrar = "La clave sigue en la versión anterior: pulsa «Migrar clave» en el paso Minutas y elige un modelo."

        // Stand-in for a step with no view behind it (the controller's default)
        static let pasoPendiente = "Este paso llega en la siguiente actualización."
    }

    // MARK: - transcript.md

    /// Display label for the engine line in transcript.md.
    static func motor(_ engine: String, _ model: String) -> String { "motor: \(engine) (\(model))" }

    /// Display name for a speaker id in transcript.md. transcript.json keeps
    /// the stable ids (`me`/`them`); unknown ids pass through unchanged.
    static func hablante(_ id: String) -> String {
        switch id {
        case "me": return "Yo"
        case "them": return "Otros"
        default: return id
        }
    }
}
