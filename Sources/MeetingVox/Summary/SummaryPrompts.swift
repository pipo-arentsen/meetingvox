import Foundation

/// Every piece of LLM prompt text the summary pipeline sends, in one place.
/// Kept apart from `Textos` on purpose: this copy is read by the model, not
/// by the user (see `MinutesPrompts`, the same convention for minutes).
enum SummaryPrompts {
    static let rol = "Eres un asistente que genera un resumen breve de una reunión a partir de su transcripción o de la minuta ya redactada."

    static let instrucciones = """
    Responde EXCLUSIVAMENTE con un objeto JSON, sin texto antes ni después y sin bloques de código, con estas claves:
    - "title": título breve de la reunión (máximo 80 caracteres).
    - "summary": resumen de la reunión en máximo 2 líneas (máximo 280 caracteres).
    - "client": nombre del cliente o empresa externa mencionado, o null si no aplica.
    - "topics": lista de hasta 5 temas tratados, como frases cortas.
    - "participants": lista de hasta 10 nombres de personas mencionadas.
    \(tareasClave)
    \(paisClave)
    """

    /// The `country` key's rule, shared by the full summary and the
    /// tasks-only request: the value is read from what the meeting says, never
    /// guessed from the client's name, the language or the accents.
    static let paisSoloExplicito = "Indica el país solo si se menciona explícitamente en la reunión; si no se dice, usa null. No lo deduzcas del nombre del cliente ni del idioma."

    static let paisClave = "- \"country\": país del cliente, únicamente si se nombra de forma explícita, o null. \(paisSoloExplicito)"

    static let tareasClave = """
    - "tasks": lista de tareas o compromisos acordados (hasta \(SummaryParser.maxTasks)), cada una como {"who": ..., "what": ..., "when": ...}. \
    "who" es quién debe hacerla, tal como se le nombra ("Yo" si es quien graba), o null si no se sabe; \
    "what" es la tarea, breve y concreta; "when" es el plazo dicho en la reunión, o null. Usa [] si no hay tareas.
    """

    /// Reply shape of the tasks-only (backfill) request.
    static let tareasInstrucciones = """
    Responde EXCLUSIVAMENTE con un objeto JSON, sin texto antes ni después y sin bloques de código, con estas claves:
    \(tareasClave)
    \(paisClave)
    """

    static let tareasRol = "Eres un asistente que extrae las tareas y compromisos acordados en una reunión a partir de su transcripción o de la minuta ya redactada."

    /// Appended to the chunk-notes and reduction prompts of a chunked run, so
    /// the who/what/when of every task survives until the consolidation call.
    static let tareasNotasInstrucciones = """
    Conserva en las notas, palabra por palabra cuando puedas, cada tarea o compromiso acordado con quién debe hacerlo, qué debe hacer y cuándo (plazo). \
    Anota también si se nombra explícitamente el país del cliente. No resumas estos datos: se necesitan tal cual en la consolidación final.
    """

    static let encabezadoContenido = "Contenido de la reunión:"

    /// Extra user message on the one allowed retry after invalid JSON.
    static let recordatorioJSON = "Tu respuesta anterior no era JSON válido. Responde EXCLUSIVAMENTE con el objeto JSON pedido, sin texto adicional ni bloques de código."

    /// The glossary (shared text with the minutes, `MinutesPrompts.glosario`)
    /// helps names and clients come out spelled right in title/summary/client.
    static func systemPrompt(glossary: [GlossaryEntry]) -> String {
        var parts = [rol, instrucciones]
        if let block = MinutesPrompts.glosarioBloque(glossary) { parts.append(block) }
        return parts.joined(separator: "\n\n")
    }

    /// System prompt of the tasks-only backfill request (same glossary block).
    static func tareasSystemPrompt(glossary: [GlossaryEntry]) -> String {
        var parts = [tareasRol, tareasInstrucciones]
        if let block = MinutesPrompts.glosarioBloque(glossary) { parts.append(block) }
        return parts.joined(separator: "\n\n")
    }

    /// With a linked calendar event (`calendarTitle`, `invitees`: names only)
    /// the event rows and the "invited is not attended" caveat follow the
    /// session line; without one the text is exactly what it always was.
    static func userPrompt(
        sessionName: String, content: String, calendarTitle: String? = nil, invitees: [String] = []
    ) -> String {
        let event = MinutesPrompts.eventoCalendario(title: calendarTitle, invitees: invitees)
        guard !event.isEmpty else { return "Sesión: \(sessionName)\n\n\(encabezadoContenido)\n\(content)" }
        let header = (["Sesión: \(sessionName)"] + event).joined(separator: "\n")
        return "\(header)\n\n\(encabezadoContenido)\n\(content)"
    }
}
