import Foundation

/// The synthetic sessions the headless snapshots render (VS-4): Spanish,
/// realistic and varied, written into the fixture recordings root of a
/// `SnapshotEnvironment` and nowhere else. One session per state the main
/// window shows (complete, minutes error, no minutes, memory pending, sent,
/// in progress) plus older history so the list has Hoy, Ayer, weekday and
/// month sections against the fixed clock. Everything is a function of the
/// environment's clock: two installs produce byte-identical files.
enum SnapshotFixtures {
    /// The state a session is meant to show.
    enum Kind: CaseIterable, Sendable {
        /// Transcript, minutes and summary done; long enough to send, not in memory.
        case complete
        /// `minuta.error` and a memory send requested: the row shows the error pill.
        case minutesError
        /// Transcript and summary, no minutes at all.
        case noMinutes
        /// Finished, with a memory send requested and not done yet.
        case pendingMemory
        /// Finished and in memory (current content).
        case sent
        /// `minuta.pendiente` and `resumen.pendiente`: work still owed.
        case inProgress
        /// Older, finished sessions that fill the weekday and month sections.
        case history
    }

    struct Installed {
        struct Session {
            let kind: Kind
            let dir: URL
        }

        let sessions: [Session]

        func dirs(of kind: Kind) -> [URL] { sessions.filter { $0.kind == kind }.map(\.dir) }

        /// Three rows for the bulk panel: a complete, an unfinished and a
        /// sent session, so the selection is not uniform.
        var bulkSelection: [URL] {
            [dirs(of: .complete), dirs(of: .minutesError), dirs(of: .sent)].compactMap(\.first)
        }
    }

    // MARK: - Install

    static func install(in env: SnapshotEnvironment) throws -> Installed {
        var sessions: [Installed.Session] = []
        for spec in specs {
            let dir = try write(spec, in: env)
            sessions.append(Installed.Session(kind: spec.kind, dir: dir))
        }
        return Installed(sessions: sessions)
    }

    private struct Spec {
        let kind: Kind
        /// Local start, `(year, month, day, hour, minute)`.
        let start: (Int, Int, Int, Int, Int)
        let minutes: Int
        let app: String?
        let ambito: Ambito?
        /// The minutes' template; nil = no minutes file.
        let template: String?
        let summary: SummaryFixture?
        let script: Script
        let memory: Memory
        var minutesState: MinutesState = .done
        var summaryState: SummaryState = .done
    }

    private enum Script { case trabajo, familia }
    private enum Memory { case none, requested, sent }
    private enum MinutesState { case done, error, pending, absent }
    private enum SummaryState { case done, pending }

    private struct SummaryFixture {
        let title: String
        let text: String
        let client: String?
        let topics: [String]
        let participants: [String]
        let source: MeetingSummary.Source
        /// nil = a summary from before task extraction (no `tasks` key);
        /// `[]` = extracted, the meeting had none.
        var tasks: [MeetingTask]? = nil
        var country: String? = nil
    }

    private static func task(_ who: String?, _ what: String, _ when: String? = nil) -> MeetingTask {
        MeetingTask(who: who, what: what, when: when)
    }

    private static let specs: [Spec] = [
        Spec(
            kind: .complete, start: (2026, 9, 29, 9, 0), minutes: 47, app: "teams", ambito: .trabajo,
            template: "comercial",
            summary: SummaryFixture(
                title: "Plan del cuarto trimestre con el cliente",
                text: "Se acordó separar el proyecto en dos fases; la primera cubre pagos y tablero de seguimiento. "
                    + "El inicio depende de que el cliente apruebe el presupuesto antes del 7 de octubre.",
                client: "Cliente A", topics: ["Integración de pagos", "Presupuesto", "Plan por fases"],
                participants: ["Yo", "Participante 1", "Participante 2"], source: .minutes,
                tasks: [
                    task("Yo", "Enviar la propuesta de fases al cliente", "el viernes 2 de octubre"),
                    task("Participante 1", "Confirmar la aprobación del presupuesto", "7 de octubre"),
                    task("Participante 2", "Compartir el acceso al ambiente de pruebas"),
                    task(nil, "Definir quién lidera el tablero de seguimiento"),
                ], country: "Colombia"),
            script: .trabajo, memory: .none),
        Spec(
            kind: .inProgress, start: (2026, 9, 29, 10, 15), minutes: 32, app: nil, ambito: nil,
            template: nil, summary: nil, script: .trabajo, memory: .none,
            minutesState: .pending, summaryState: .pending),
        Spec(
            kind: .minutesError, start: (2026, 9, 28, 16, 30), minutes: 38, app: "safari", ambito: .profesional,
            template: nil,
            summary: SummaryFixture(
                title: "Revisión de alcance del portal de clientes",
                text: "El equipo revisó las historias pendientes del portal y priorizó el módulo de facturas. "
                    + "Quedó abierta la definición del ambiente de pruebas.",
                client: "Cliente B", topics: ["Portal de clientes", "Facturación", "Ambiente de pruebas"],
                participants: ["Yo", "Participante 1"], source: .transcript),
            script: .trabajo, memory: .requested, minutesState: .error),
        Spec(
            kind: .noMinutes, start: (2026, 9, 28, 9, 30), minutes: 26, app: "whatsapp", ambito: .personal,
            template: nil,
            summary: SummaryFixture(
                title: "Organización de la reunión de vecinos",
                text: "Se acordó enviar hoy la convocatoria y reservar la sala común para el sábado. "
                    + "También se anotó la revisión del presupuesto de mantención del 6 de octubre.",
                client: nil, topics: ["Reunión de vecinos", "Convocatoria", "Presupuesto"],
                participants: ["Yo"], source: .transcript,
                tasks: []),
            script: .familia, memory: .none, minutesState: .absent),
        Spec(
            kind: .pendingMemory, start: (2026, 9, 26, 11, 0), minutes: 55, app: "zoom", ambito: .personal,
            template: "familiar",
            summary: SummaryFixture(
                title: "Conversación familiar: organización del mes",
                text: "Se acordó repartir las tareas de la casa y revisar el calendario del mes el fin de semana. "
                    + "El sábado se hace el orden general.",
                client: nil, topics: ["Tareas de la casa", "Calendario del mes"],
                participants: ["Yo"], source: .minutes,
                tasks: [
                    task("Yo", "Revisar el calendario del mes", "el domingo"),
                    task("Yo", "Comprar lo necesario para el orden del sábado"),
                ]),
            script: .familia, memory: .requested),
        Spec(
            kind: .sent, start: (2026, 9, 24, 15, 0), minutes: 61, app: "teams", ambito: .trabajo,
            template: "general",
            summary: SummaryFixture(
                title: "Retrospectiva del sprint de plataforma",
                text: "El equipo identificó tres mejoras para el proceso de despliegue y acordó una prueba de dos semanas. "
                    + "Se mantiene la cadencia de revisión semanal.",
                client: "Equipo interno", topics: ["Despliegue", "Retrospectiva", "Cadencia"],
                participants: ["Yo", "Participante 1", "Participante 2"], source: .minutes,
                tasks: [
                    task("Participante 1", "Automatizar el paso de despliegue a producción", "en dos semanas"),
                    task("Participante 2", "Documentar la prueba de dos semanas"),
                    task("Yo", "Mantener la revisión semanal en el calendario"),
                ], country: "Chile"),
            script: .trabajo, memory: .sent),
        Spec(
            kind: .history, start: (2026, 9, 15, 10, 0), minutes: 18, app: "teams", ambito: .trabajo,
            template: "daily",
            summary: SummaryFixture(
                title: "Daily del equipo de plataforma",
                text: "Se revisaron los bloqueos del día; la migración de la base queda para el jueves.",
                client: "Equipo interno", topics: ["Migración", "Bloqueos"],
                participants: ["Yo", "Participante 1"], source: .minutes,
                tasks: [
                    task("Participante 1", "Migrar la base de datos", "el jueves"),
                ]),
            script: .trabajo, memory: .sent),
        Spec(
            kind: .history, start: (2026, 8, 20, 16, 0), minutes: 40, app: "safari", ambito: .profesional,
            template: "uno-a-uno",
            summary: SummaryFixture(
                title: "Reunión uno a uno: objetivos del semestre",
                text: "Se definieron tres objetivos para el segundo semestre y una sesión mensual de seguimiento.",
                client: nil, topics: ["Objetivos", "Seguimiento"],
                participants: ["Yo", "Participante 1"], source: .minutes,
                tasks: [
                    task("Participante 1", "Proponer tres objetivos para el semestre"),
                    task("Yo", "Agendar la sesión mensual de seguimiento", "esta semana"),
                ]),
            script: .trabajo, memory: .none),
        Spec(
            kind: .history, start: (2026, 7, 30, 12, 0), minutes: 52, app: nil, ambito: nil,
            template: "entrevista",
            summary: SummaryFixture(
                title: "Entrevista para arquitecto de datos",
                text: "La candidata tiene experiencia sólida en modelado y pipelines; queda pendiente una segunda ronda técnica.",
                client: nil, topics: ["Entrevista", "Modelado de datos"],
                participants: ["Yo", "Participante 1"], source: .minutes),
            script: .familia, memory: .none),
    ]

    // MARK: - Writing one session

    private static let modelName = "provider/model"

    private static func write(_ spec: Spec, in env: SnapshotEnvironment) throws -> URL {
        let fm = FileManager.default
        let (y, mo, d, h, mi) = spec.start
        let started = env.calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        let ended = started.addingTimeInterval(TimeInterval(spec.minutes * 60))
        let folder = String(format: "%04d.%02d.%02d-%02d%02d", y, mo, d, h, mi)
        let dir = env.recordingsRoot.appendingPathComponent(folder, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let iso = ISO8601DateFormatter()
        var meta: [String: Any] = [
            "started": iso.string(from: started),
            "ended": iso.string(from: ended),
            "duration_seconds": spec.minutes * 60,
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": ["mic": 0, "system": 120],
        ]
        if let app = spec.app { meta[SessionFiles.metaMeetingAppKey] = app }
        if let ambito = spec.ambito { meta[SessionFiles.metaAmbitoKey] = ambito.rawValue }
        if let template = spec.template { meta[SessionFiles.metaMinutesTemplateKey] = template }
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent(SessionFiles.meta))

        try transcript(spec.script, minutes: spec.minutes, created: ended).write(to: dir)

        try writeMinutes(spec, in: dir, generatedAt: ended.addingTimeInterval(180))
        if let summary = spec.summary, spec.summaryState == .done {
            try write(MeetingSummary(
                title: summary.title, summary: summary.text, client: summary.client, topics: summary.topics,
                participants: summary.participants, source: summary.source, model: modelName,
                generatedAt: ended.addingTimeInterval(240), tasks: summary.tasks, country: summary.country
            ), to: dir, name: SessionFiles.summaryJSON)
        }
        if spec.summaryState == .pending { try marker(SessionFiles.summaryPending, in: dir) }

        switch spec.memory {
        case .none: break
        case .requested:
            try HindsightFacts.writeJSON(
                HindsightRequestMarker(force: false, requestedAt: ended.addingTimeInterval(300), bank: "meetingvox"),
                dir, SessionFiles.hindsightRequested)
        case .sent:
            let hash = try contentHash(of: dir, started: started, env: env)
            try HindsightFacts.writeJSON(
                HindsightSentRecord(
                    documentID: "mv-\(folder)", contentHash: hash,
                    operationID: HindsightPayloadBuilder.operationID(forHash: hash),
                    sentAt: ended.addingTimeInterval(360), bank: "meetingvox"),
                dir, SessionFiles.hindsightSent)
        }
        return dir
    }

    private static func writeMinutes(_ spec: Spec, in dir: URL, generatedAt: Date) throws {
        switch spec.minutesState {
        case .absent: break
        case .pending: try marker(SessionFiles.minutesPending, in: dir)
        case .error:
            try Data("El modelo no respondió a tiempo (408).\n".utf8)
                .write(to: dir.appendingPathComponent(SessionFiles.minutesError))
        case .done:
            guard let template = spec.template else { return }
            let body = template == "comercial" ? sampleMinutesBody : genericMinutes(spec.summary)
            let header = MinutesCoordinator.provenance(
                model: modelName, templateID: template, generatedAt: generatedAt, chunked: false)
            try Data((header + "\n" + body).utf8).write(to: dir.appendingPathComponent(SessionFiles.minutes))
        }
    }

    private static func marker(_ name: String, in dir: URL) throws {
        try Data().write(to: dir.appendingPathComponent(name))
    }

    private static func write(_ summary: MeetingSummary, to dir: URL, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(summary).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    private static func contentHash(of dir: URL, started: Date, env: SnapshotEnvironment) throws -> String {
        let input = try TranscriptInput.read(from: dir)
        let turns = HindsightPayloadBuilder.turns(
            input.segments, started: started, ownerName: env.config.hindsightOwnerName,
            glossary: HindsightPayloadBuilder.exportGlossary(env.config.glossary, glossaryApplied: input.glossaryApplied),
            timeZone: env.timeZone)
        return HindsightPayloadBuilder.contentHash(try HindsightPayloadBuilder.content(turns))
    }

    /// Short minutes for the sessions whose text is not on show.
    private static func genericMinutes(_ summary: SummaryFixture?) -> String {
        guard let summary else { return "# Reunión\n" }
        let topics = summary.topics.map { "- \($0)" }.joined(separator: "\n")
        return "# \(summary.title)\n\n## Resumen\n\(summary.text)\n\n## Temas\n\(topics)\n"
    }

    // MARK: - Transcripts

    private static func transcript(_ script: Script, minutes: Int, created: Date) -> TranscriptDocument {
        let lines = script == .trabajo ? trabajoLines : familiaLines
        let step = (minutes * 60 * 1000) / lines.count
        let segments = lines.enumerated().map { index, line in
            TranscriptDocument.Segment(
                speaker: line.0, start_ms: index * step, end_ms: index * step + step * 4 / 5, text: line.1,
                text_raw: script == .trabajo ? trabajoRaw[index] : nil)
        }
        return TranscriptDocument(
            engine: "parakeet", model: "parakeet-ultra-coreml",
            created_at: ISO8601DateFormatter().string(from: created), segments: segments)
    }

    /// What the recognizer wrote before the glossary corrected `trabajoLines[index]`
    /// (the transcript's `text_raw`): the Transcripción tab marks the differing words.
    private static let trabajoRaw: [Int: String] = [
        0: "Buenos días a todos, gracias por juntarse. La idea de hoy es revisar el plan del cuarto trimestre para la integración con miting vox y cerrar qué entra en la primera fase.",
        3: "Me parece bien, pero necesitamos confirmar el presupuesto. Finanzas tiene que revisar cuánto queda disponible para este trimestre antes de aprobar las dos fases de mitin vox.",
    ]

    private static let trabajoLines: [(String, String)] = [
        ("me", "Buenos días a todos, gracias por juntarse. La idea de hoy es revisar el plan del cuarto trimestre para la integración con MeetingVox y cerrar qué entra en la primera fase."),
        ("them", "Buenos días. Desde nuestro lado lo más urgente es la integración con el sistema de pagos, porque el equipo de riesgo necesita verla funcionando antes de fin de octubre."),
        ("me", "Entendido. Con lo que conversamos la semana pasada, la primera fase cubriría la integración de pagos y el tablero de seguimiento, y la segunda fase quedaría para noviembre."),
        ("them", "Me parece bien, pero necesitamos confirmar el presupuesto. Finanzas tiene que revisar cuánto queda disponible para este trimestre antes de aprobar las dos fases de MeetingVox."),
        ("me", "Perfecto. Yo puedo enviarles una propuesta ajustada con las dos fases separadas, con sus plazos y sus montos, para que la revisen internamente."),
        ("them", "Eso ayudaría bastante. ¿Podrías incluir también el equipo que va a trabajar, con los nombres y la dedicación de cada persona?"),
        ("me", "Sí, claro. Serían tres personas a tiempo completo en la primera fase, y en la segunda se suma una persona más para las pruebas."),
        ("them", "Otra cosa, nuestro equipo técnico les va a compartir los accesos al ambiente de pruebas esta semana, así ustedes pueden empezar a validar las conexiones."),
        ("me", "Excelente, con eso podemos arrancar el lunes 5 de octubre si el presupuesto queda aprobado a más tardar el miércoles 7."),
        ("them", "Ese plazo es razonable. Quedamos entonces en que tú envías la propuesta el viernes y nosotros respondemos con el presupuesto la semana siguiente."),
        ("me", "Perfecto, lo dejo anotado. Si surge cualquier duda antes, me escriben directamente y lo resolvemos rápido."),
        ("them", "Gracias a todos. Nos vemos el próximo jueves para la revisión de avance."),
    ]

    private static let familiaLines: [(String, String)] = [
        ("me", "Hola, ¿cómo va todo por allá? Quería que viéramos lo de la reunión de vecinos y la reserva de la sala común."),
        ("them", "Todo bien. Ya pregunté en la administración y la sala común está libre el sábado en la mañana, sin costo para los vecinos."),
        ("me", "Está bien. ¿Y la convocatoria? La vez pasada la enviamos muy tarde y llegó poca gente a la reunión."),
        ("them", "Esta vez la podemos enviar hoy mismo. Si sale hoy, todos tienen una semana completa para organizarse."),
        ("me", "Perfecto, entonces la enviamos hoy. ¿Puedes encargarte tú de la reserva de la sala y yo de la convocatoria?"),
        ("them", "Sí, yo hago la reserva esta tarde. Además tenemos que acordarnos de revisar el presupuesto de mantención, que vence el martes 6 de octubre."),
        ("me", "Es verdad, lo anoto ahora. También hay que preparar una lista corta de temas para que la reunión no se alargue."),
        ("them", "Buena idea. Puedo proponer tres temas y tú los ordenas antes de enviar la convocatoria."),
        ("me", "Genial. Y para el café de la reunión, ¿lo compramos nosotros o pedimos un aporte a cada vecino?"),
        ("them", "Prefiero comprarlo nosotros, es más simple. Lo conversamos con calma el fin de semana y vemos el resto de los detalles."),
    ]

    // MARK: - The minutes on show

    /// A realistic commercial-meeting minuta with its provenance line and a
    /// tasks table: what the Minuta tab renders in the snapshots.
    static let sampleMinutes: String =
        MinutesCoordinator.provenance(
            model: modelName, templateID: "comercial", generatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            chunked: false)
        + "\n" + sampleMinutesBody

    private static let sampleMinutesBody = """
        # Reunión comercial: plan del cuarto trimestre

        ## Participantes
        - Yo
        - Otros: Participante 1 y Participante 2 (por el cliente)

        ## Resumen ejecutivo
        Se revisó el plan del cuarto trimestre. La **primera fase** cubre la integración con el sistema de pagos y el tablero de seguimiento; la segunda fase queda para noviembre. El inicio del trabajo depende de que el cliente apruebe el presupuesto a más tardar el **miércoles 7 de octubre**.

        ## Puntos tratados
        - Integración con el sistema de pagos: el equipo de riesgo necesita verla funcionando antes de fin de octubre.
        - Alcance de la primera fase: integración de pagos y tablero de seguimiento.
        - Equipo propuesto: tres personas a tiempo completo en la primera fase; en la segunda se suma una persona para las pruebas.
        - Ambiente de pruebas: el cliente compartirá los accesos esta semana para validar las conexiones.

        ## Decisiones y acuerdos
        1. Se separan las dos fases, cada una con sus plazos y sus montos.
        2. El trabajo puede partir el lunes 5 de octubre si el presupuesto queda aprobado.
        3. Revisión de avance el próximo jueves.

        ## Tareas
        | Quién | Qué | Para cuándo |
        |---|---|---|
        | Yo | Enviar la propuesta ajustada con las dos fases, plazos, montos y equipo | Viernes 2 de octubre |
        | Participante 1 | Confirmar el presupuesto disponible del trimestre | Miércoles 7 de octubre |
        | Participante 2 | Compartir los accesos al ambiente de pruebas | Esta semana |

        ## Cifras y fechas mencionadas
        - Cierre de la integración de pagos: antes de fin de octubre.
        - Inicio propuesto: lunes 5 de octubre.
        - Segunda fase: noviembre.

        ## Pendientes para la próxima reunión
        - Revisar el detalle del presupuesto de la segunda fase.
        - Confirmar quién del cliente aprueba los cambios de alcance.

        """
}

extension SnapshotFixtures {
    /// One long session (about 50 minutes, 160 ASR segments with runs of the
    /// same speaker, so the merge and the 60 s split both fire) in its own
    /// recordings folder, for the Transcripción tab's long-list state.
    /// Returns the session folder.
    static func installLongSession(in recordings: URL, env: SnapshotEnvironment) throws -> URL {
        let fm = FileManager.default
        let started = env.calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 8, minute: 0))!
        let minutes = 50
        let dir = recordings.appendingPathComponent("2026.09.29-0800", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        let meta: [String: Any] = [
            "started": iso.string(from: started),
            "ended": iso.string(from: started.addingTimeInterval(TimeInterval(minutes * 60))),
            "duration_seconds": minutes * 60,
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "meeting_app": "teams",
            SessionFiles.metaAmbitoKey: Ambito.trabajo.rawValue,
        ]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent(SessionFiles.meta))

        let phrases = longPhrases
        let count = 160
        let step = (minutes * 60 * 1000) / count
        let segments = (0..<count).map { index -> TranscriptDocument.Segment in
            // Runs of 1 to 4 segments per speaker, deterministic.
            let speaker = (index / 3) % 2 == 0 ? "me" : "them"
            return TranscriptDocument.Segment(
                speaker: speaker, start_ms: index * step, end_ms: index * step + step * 9 / 10,
                text: phrases[index % phrases.count], text_raw: nil)
        }
        try TranscriptDocument(
            engine: "parakeet", model: "parakeet-ultra-coreml",
            created_at: iso.string(from: started.addingTimeInterval(TimeInterval(minutes * 60))), segments: segments
        ).write(to: dir)
        return dir
    }

    private static let longPhrases = [
        "Retomando lo de la semana pasada, quedamos en revisar el alcance de la primera fase.",
        "Sí, y además tenemos que confirmar quién de tu lado aprueba los cambios de alcance.",
        "Eso lo decide la gerencia, pero conviene que lo dejemos por escrito en la propuesta.",
        "De acuerdo. Lo incluyo en el documento y se lo envío antes del viernes.",
        "Perfecto. Otra cosa: el ambiente de pruebas todavía no está disponible para nosotros.",
        "El equipo técnico dijo que lo tendría listo esta semana, le escribo hoy para confirmar la fecha.",
        "Gracias. Sin ese ambiente no podemos validar la integración de pagos.",
        "Entendido, lo trato como prioridad y les aviso apenas tenga respuesta.",
    ]
}
