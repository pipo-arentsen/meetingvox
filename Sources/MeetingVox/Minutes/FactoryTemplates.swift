import Foundation

/// The templates MeetingVox ships with. They live as Swift literals because the
/// bare binary has no bundle to carry resources; `TemplateStore` writes them
/// to `~/.config/meetingvox/plantillas/` where the user can edit them freely.
///
/// Bodies are instructions for an LLM. The prompt builder wraps them with the
/// transcript, glossary and metadata, so they must not contain placeholders.
/// "Restaurar" writes these exact bodies back, so it never brings back
/// older versions.
enum FactoryTemplates {
    // MARK: - Catalog

    /// Stable order: the order the user first sees them in docs and menus
    /// before `TemplateStore.list` re-sorts by name.
    static let all: [MinutesTemplate] = [general, comercial, daily, unoAUno, levantamiento, entrevista, familiar]

    static var ids: [String] { all.map(\.id) }

    // MARK: - Templates

    static let general = MinutesTemplate(
        id: "general",
        nombre: "Minuta general",
        descripcion: "Resumen estándar de cualquier reunión.",
        cuerpo: #"""
        Objetivo: redactar una minuta útil para quien no asistió y para dar seguimiento a los acuerdos. Debe permitir reconstruir qué se habló, qué se decidió, qué datos concretos aparecieron y qué quedó abierto.

        Reglas generales:
        - Usa ÚNICAMENTE información presente en la transcripción. No inventes nombres, cifras, montos, fechas ni compromisos.
        - Hablantes: "Yo" es la persona que grabó la reunión. "Otros" agrupa en una sola pista a todos los demás participantes, que pueden ser varias personas. Atribuye una intervención de "Otros" a una persona concreta solo si se la nombra al hablarle, se presenta o el contexto lo deja inequívoco. Si no, escribe "Otros".
        - Asistentes y mencionados no son lo mismo. Una persona es asistente solo si habla, se le habla directamente o se presenta. Nombrar a alguien no lo convierte en asistente.
        - La transcripción es automática y tiene errores. Corrige nombres de productos o términos solo cuando el contexto lo hace evidente (apóyate en el glosario). Si un nombre propio es dudoso, escríbelo como aparece y agrega "(?)". Nunca corrijas ni redondees cifras.
        - Conserva siempre y en forma literal: montos, cifras, porcentajes, fechas, plazos, alcances, nombres de sistemas y compromisos hechos a clientes, socios o terceros. Estos datos no se omiten aunque parezcan secundarios.
        - Las fechas relativas ("el viernes", "la próxima semana") se escriben tal como se dijeron.
        - La extensión es proporcional al contenido. Una reunión corta produce una minuta corta. No rellenes.
        - Si la transcripción parece incompleta (empieza o termina a mitad de una conversación, es muy breve o tiene tramos ininteligibles), agrega al inicio una línea "> Registro parcial:" con una frase que explique por qué.
        - Si una sección no tiene información, escribe "No se mencionó."
        - Estilo: español neutro legible en toda Latinoamérica, frases breves y concretas. No uses guiones largos ni dobles; usa comas, dos puntos o punto. Evita fórmulas de relleno como "cabe destacar", "es importante mencionar" o "en resumen". Mantén en inglés los términos técnicos que se usan habitualmente en inglés y los nombres de productos.
        - Responde solo con la minuta en Markdown, con la estructura indicada, sin texto antes ni después y sin envolverla en un bloque de código.

        Glosario (términos que la transcripción suele deformar):
        - Si junto a la transcripción viene un glosario, úsalo para escribir correctamente nombres propios, productos y términos técnicos. Los términos se agregan en Biblioteca › Glosario.

        Reglas específicas:
        - Cada tema debe explicar qué se dijo y qué posición tomó cada parte, no solo nombrar el tema.
        - Una decisión es algo que se cerró explícitamente. Si algo se propuso pero no se confirmó, va en Pendientes.
        - En Riesgos incluye solo lo que se expresó o lo que se desprende directamente de un hecho dicho en la reunión; en ese caso, menciona el hecho.

        Estructura de salida:

        # Minuta de reunión

        ## Asistentes
        - Yo: el nombre de quien grabó la reunión si se menciona; si no, "No se mencionó".
        - Otros: nombres identificados según las reglas. Si no se identifica a nadie, escribe "participantes no identificados".

        ## Personas mencionadas
        - Nombre: motivo por el que se mencionó, en una línea. Solo personas que no son asistentes.

        ## Temas tratados
        ### <Nombre del tema>
        - Entre dos y cinco viñetas: qué se planteó, qué respondió cada parte y los datos concretos asociados.

        (Repite el bloque por cada tema, en el orden en que se trataron.)

        ## Datos clave
        - Una viñeta por dato duro (monto, cifra, plazo, alcance, sistema o compromiso con terceros), con el contexto mínimo para entenderlo sin leer la transcripción.

        ## Decisiones
        - Decisiones tomadas explícitamente.

        ## Acuerdos
        | Acuerdo | Responsable | Fecha |
        |---|---|---|
        | ... | ... | ... |

        En Responsable: el nombre si se dijo; "Yo" si lo asumió "Yo"; "Otros" si lo asumió alguien de esa pista sin nombre; "No se mencionó" si no quedó claro. En Fecha: la fecha o plazo tal como se dijo, o "No se mencionó".

        ## Riesgos y alertas
        - Riesgos de alcance, plazo, costo o relación con el cliente o socio, y expectativas desalineadas.

        ## Pendientes
        - Temas abiertos o preguntas sin resolver, y a quién le corresponde, si se dijo.
        """#
    )

    static let comercial = MinutesTemplate(
        id: "comercial",
        nombre: "Llamada comercial",
        descripcion: "Descubrimiento con clientes o prospectos: dolores, necesidades y próximos pasos.",
        cuerpo: #"""
        Objetivo: resumir una llamada comercial para evaluar la oportunidad y preparar el seguimiento. En general, "Yo" y quienes hablan por su empresa representan al equipo que vende, y el resto de "Otros" al cliente o prospecto. Si en "Otros" hay personas del equipo de "Yo" o de un socio, identifícalas como tales cuando el contexto lo permita.

        Reglas generales:
        - Usa ÚNICAMENTE información presente en la transcripción. No inventes nombres, cifras, montos, fechas ni compromisos.
        - Hablantes: "Yo" es la persona que grabó la reunión. "Otros" agrupa en una sola pista a todos los demás participantes, que pueden ser varias personas. Atribuye una intervención de "Otros" a una persona concreta solo si se la nombra al hablarle, se presenta o el contexto lo deja inequívoco. Si no, escribe "Otros".
        - Asistentes y mencionados no son lo mismo. Una persona es asistente solo si habla, se le habla directamente o se presenta. Nombrar a alguien no lo convierte en asistente.
        - La transcripción es automática y tiene errores. Corrige nombres de productos o términos solo cuando el contexto lo hace evidente (apóyate en el glosario). Si un nombre propio es dudoso, escríbelo como aparece y agrega "(?)". Nunca corrijas ni redondees cifras.
        - Conserva siempre y en forma literal: montos, cifras, porcentajes, fechas, plazos, alcances, nombres de sistemas y compromisos hechos a clientes, socios o terceros. Estos datos no se omiten aunque parezcan secundarios.
        - Las fechas relativas ("el viernes", "la próxima semana") se escriben tal como se dijeron.
        - La extensión es proporcional al contenido. Una reunión corta produce una minuta corta. No rellenes.
        - Si la transcripción parece incompleta (empieza o termina a mitad de una conversación, es muy breve o tiene tramos ininteligibles), agrega al inicio una línea "> Registro parcial:" con una frase que explique por qué.
        - Si una sección no tiene información, escribe "No se mencionó."
        - Estilo: español neutro legible en toda Latinoamérica, frases breves y concretas. No uses guiones largos ni dobles; usa comas, dos puntos o punto. Evita fórmulas de relleno como "cabe destacar", "es importante mencionar" o "en resumen". Mantén en inglés los términos técnicos que se usan habitualmente en inglés y los nombres de productos.
        - Responde solo con la minuta en Markdown, con la estructura indicada, sin texto antes ni después y sin envolverla en un bloque de código.

        Glosario (términos que la transcripción suele deformar):
        - Si junto a la transcripción viene un glosario, úsalo para escribir correctamente nombres propios, productos y términos técnicos. Los términos se agregan en Biblioteca › Glosario.

        Reglas específicas:
        - Registra los dolores con las palabras del cliente cuando sea posible.
        - En Calificación no deduzcas presupuesto ni urgencia: escribe solo lo que se dijo.
        - Registra textualmente cualquier cosa que el equipo vendedor haya prometido o dado por incluida, porque después define el alcance.

        Estructura de salida:

        # Llamada comercial

        ## Participantes
        - Por nuestro equipo: ...
        - Por el cliente: nombre y rol, según se mencionen.
        - Socios u otros: ...

        ## Contexto del cliente
        - Empresa, industria, área y situación actual.

        ## Situación actual y competencia
        - Sistemas, proveedores o soluciones que usan hoy, y competidores o alternativas que están evaluando.

        ## Dolores detectados
        - ...

        ## Necesidades
        - Lo que el cliente busca resolver o lograr.

        ## Objeciones
        - Duda o reparo planteado y cómo se respondió.

        ## Compromisos y promesas del equipo vendedor
        - Lo que se ofreció, se dio por incluido o se prometió entregar.

        ## Calificación
        - **Presupuesto:** montos o rangos mencionados, literal.
        - **Autoridad:** quién decide y quién influye.
        - **Necesidad:** urgencia o prioridad, según lo dicho.
        - **Plazos:** fechas o hitos mencionados.

        ## Próximos pasos
        | Acción | Responsable | Fecha |
        |---|---|---|
        | ... | ... | ... |

        ## Riesgos del negocio
        - Señales que podrían retrasar o impedir el cierre, o que anticipan conflictos de alcance.
        """#
    )

    static let daily = MinutesTemplate(
        id: "daily",
        nombre: "Daily",
        descripcion: "Reunión diaria del equipo: avances, planes, bloqueos y estado de oportunidades.",
        cuerpo: #"""
        Objetivo: registrar el estado de cada integrante en la reunión diaria, destacando los bloqueos y el movimiento de las oportunidades comerciales.

        Reglas generales:
        - Usa ÚNICAMENTE información presente en la transcripción. No inventes nombres, cifras, montos, fechas ni compromisos.
        - Hablantes: "Yo" es la persona que grabó la reunión. "Otros" agrupa en una sola pista a todos los demás participantes, que pueden ser varias personas. Atribuye una intervención de "Otros" a una persona concreta solo si se la nombra al hablarle, se presenta o el contexto lo deja inequívoco. Si no, escribe "Otros".
        - Asistentes y mencionados no son lo mismo. Una persona es asistente solo si habla, se le habla directamente o se presenta. Nombrar a alguien no lo convierte en asistente.
        - La transcripción es automática y tiene errores. Corrige nombres de productos o términos solo cuando el contexto lo hace evidente (apóyate en el glosario). Si un nombre propio es dudoso, escríbelo como aparece y agrega "(?)". Nunca corrijas ni redondees cifras.
        - Conserva siempre y en forma literal: montos, cifras, porcentajes, fechas, plazos, alcances, nombres de sistemas y compromisos hechos a clientes, socios o terceros. Estos datos no se omiten aunque parezcan secundarios.
        - Las fechas relativas ("el viernes", "la próxima semana") se escriben tal como se dijeron.
        - La extensión es proporcional al contenido. Una reunión corta produce una minuta corta. No rellenes.
        - Si la transcripción parece incompleta (empieza o termina a mitad de una conversación, es muy breve o tiene tramos ininteligibles), agrega al inicio una línea "> Registro parcial:" con una frase que explique por qué.
        - Si una sección no tiene información, escribe "No se mencionó."
        - Estilo: español neutro legible en toda Latinoamérica, frases breves y concretas. No uses guiones largos ni dobles; usa comas, dos puntos o punto. Evita fórmulas de relleno como "cabe destacar", "es importante mencionar" o "en resumen". Mantén en inglés los términos técnicos que se usan habitualmente en inglés y los nombres de productos.
        - Responde solo con la minuta en Markdown, con la estructura indicada, sin texto antes ni después y sin envolverla en un bloque de código.

        Glosario (términos que la transcripción suele deformar):
        - Si junto a la transcripción viene un glosario, úsalo para escribir correctamente nombres propios, productos y términos técnicos. Los términos se agregan en Biblioteca › Glosario.

        Reglas específicas:
        - Repite el bloque de persona solo para quienes intervinieron. Si no puedes atribuir una intervención de "Otros" a alguien concreto, agrúpala bajo "Otros".
        - En Oportunidades mencionadas registra cada cliente o deal que se nombró, aunque la mención sea breve.

        Estructura de salida:

        # Daily

        ## <Nombre, "Yo" u "Otros">
        - **Qué hizo:** ...
        - **Qué hará:** ...
        - **Bloqueos:** ...

        ## Oportunidades mencionadas
        | Cliente u oportunidad | Estado o avance | Próximo paso | Responsable |
        |---|---|---|---|
        | ... | ... | ... | ... |

        ## Bloqueos que requieren seguimiento
        - Bloqueo, persona afectada y quién puede ayudar a resolverlo.

        ## Acuerdos
        | Acuerdo | Responsable | Fecha |
        |---|---|---|
        | ... | ... | ... |

        ## Otros temas
        - Anuncios o temas que surgieron fuera de la ronda.
        """#
    )

    static let unoAUno = MinutesTemplate(
        id: "uno-a-uno",
        nombre: "Reunión 1:1",
        descripcion: "Conversación individual: temas, feedback y acuerdos.",
        cuerpo: #"""
        Objetivo: dejar registro de una conversación individual para dar continuidad a los temas y acuerdos en la próxima reunión.

        Reglas generales:
        - Usa ÚNICAMENTE información presente en la transcripción. No inventes nombres, cifras, montos, fechas ni compromisos.
        - Hablantes: "Yo" es la persona que grabó la reunión. "Otros" agrupa en una sola pista a todos los demás participantes, que pueden ser varias personas. Atribuye una intervención de "Otros" a una persona concreta solo si se la nombra al hablarle, se presenta o el contexto lo deja inequívoco. Si no, escribe "Otros".
        - Asistentes y mencionados no son lo mismo. Una persona es asistente solo si habla, se le habla directamente o se presenta. Nombrar a alguien no lo convierte en asistente.
        - La transcripción es automática y tiene errores. Corrige nombres de productos o términos solo cuando el contexto lo hace evidente (apóyate en el glosario). Si un nombre propio es dudoso, escríbelo como aparece y agrega "(?)". Nunca corrijas ni redondees cifras.
        - Conserva siempre y en forma literal: montos, cifras, porcentajes, fechas, plazos, alcances, nombres de sistemas y compromisos hechos a clientes, socios o terceros. Estos datos no se omiten aunque parezcan secundarios.
        - Las fechas relativas ("el viernes", "la próxima semana") se escriben tal como se dijeron.
        - La extensión es proporcional al contenido. Una reunión corta produce una minuta corta. No rellenes.
        - Si la transcripción parece incompleta (empieza o termina a mitad de una conversación, es muy breve o tiene tramos ininteligibles), agrega al inicio una línea "> Registro parcial:" con una frase que explique por qué.
        - Si una sección no tiene información, escribe "No se mencionó."
        - Estilo: español neutro legible en toda Latinoamérica, frases breves y concretas. No uses guiones largos ni dobles; usa comas, dos puntos o punto. Evita fórmulas de relleno como "cabe destacar", "es importante mencionar" o "en resumen". Mantén en inglés los términos técnicos que se usan habitualmente en inglés y los nombres de productos.
        - Responde solo con la minuta en Markdown, con la estructura indicada, sin texto antes ni después y sin envolverla en un bloque de código.

        Glosario (términos que la transcripción suele deformar):
        - Si junto a la transcripción viene un glosario, úsalo para escribir correctamente nombres propios, productos y términos técnicos. Los términos se agregan en Biblioteca › Glosario.

        Reglas específicas:
        - Recoge el feedback con tono respetuoso y objetivo, tal como se dijo, sin interpretarlo ni suavizarlo.
        - Usa el nombre de la otra persona en los encabezados si se identificó; si no, usa "Otros".

        Estructura de salida:

        # Reunión 1:1

        ## Participante
        - Nombre y rol de la otra persona, según se mencionen.

        ## Seguimiento de acuerdos anteriores
        - Acuerdos previos que se revisaron y su estado.

        ## Temas conversados
        - Un punto por tema, con un resumen breve.

        ## Feedback
        ### De mí hacia <nombre>
        - ...

        ### De <nombre> hacia mí
        - ...

        ## Acuerdos
        | Acuerdo | Responsable | Fecha |
        |---|---|---|
        | ... | ... | ... |

        ## Temas para la próxima reunión
        - Puntos que quedaron pendientes o que se acordó retomar.
        """#
    )

    static let levantamiento = MinutesTemplate(
        id: "levantamiento",
        nombre: "Levantamiento técnico / workshop",
        descripcion: "Captura de requerimientos, sistemas, volumetría, supuestos y preguntas abiertas.",
        cuerpo: #"""
        Objetivo: documentar la información técnica obtenida en un levantamiento o workshop, como insumo para diseño, estimación o propuesta.

        Reglas generales:
        - Usa ÚNICAMENTE información presente en la transcripción. No inventes nombres, cifras, montos, fechas ni compromisos.
        - Hablantes: "Yo" es la persona que grabó la reunión. "Otros" agrupa en una sola pista a todos los demás participantes, que pueden ser varias personas. Atribuye una intervención de "Otros" a una persona concreta solo si se la nombra al hablarle, se presenta o el contexto lo deja inequívoco. Si no, escribe "Otros".
        - Asistentes y mencionados no son lo mismo. Una persona es asistente solo si habla, se le habla directamente o se presenta. Nombrar a alguien no lo convierte en asistente.
        - La transcripción es automática y tiene errores. Corrige nombres de productos o términos solo cuando el contexto lo hace evidente (apóyate en el glosario). Si un nombre propio es dudoso, escríbelo como aparece y agrega "(?)". Nunca corrijas ni redondees cifras.
        - Conserva siempre y en forma literal: montos, cifras, porcentajes, fechas, plazos, alcances, nombres de sistemas y compromisos hechos a clientes, socios o terceros. Estos datos no se omiten aunque parezcan secundarios.
        - Las fechas relativas ("el viernes", "la próxima semana") se escriben tal como se dijeron.
        - La extensión es proporcional al contenido. Una reunión corta produce una minuta corta. No rellenes.
        - Si la transcripción parece incompleta (empieza o termina a mitad de una conversación, es muy breve o tiene tramos ininteligibles), agrega al inicio una línea "> Registro parcial:" con una frase que explique por qué.
        - Si una sección no tiene información, escribe "No se mencionó."
        - Estilo: español neutro legible en toda Latinoamérica, frases breves y concretas. No uses guiones largos ni dobles; usa comas, dos puntos o punto. Evita fórmulas de relleno como "cabe destacar", "es importante mencionar" o "en resumen". Mantén en inglés los términos técnicos que se usan habitualmente en inglés y los nombres de productos.
        - Responde solo con la minuta en Markdown, con la estructura indicada, sin texto antes ni después y sin envolverla en un bloque de código.

        Glosario (términos que la transcripción suele deformar):
        - Si junto a la transcripción viene un glosario, úsalo para escribir correctamente nombres propios, productos y términos técnicos. Los términos se agregan en Biblioteca › Glosario.

        Reglas específicas:
        - Marca cada requerimiento con [Afirmado] si se dijo como hecho, [Deseado] si se planteó como aspiración o [Supuesto] si se asumió sin confirmar.
        - Registra la volumetría y las cifras técnicas tal como se dijeron, con su unidad. Si no hay unidad, no la agregues.
        - Registra por separado lo que se declaró fuera de alcance.

        Estructura de salida:

        # Levantamiento técnico

        ## Participantes
        - Nombre y rol, según se mencionen.

        ## Contexto y objetivo
        - Qué se busca resolver y alcance conversado.

        ## Requerimientos funcionales
        - [Afirmado | Deseado | Supuesto] Qué debe hacer la solución, un punto por requerimiento.

        ## Requerimientos no funcionales
        - [Afirmado | Deseado | Supuesto] Rendimiento, seguridad, disponibilidad, normativa u otros atributos de calidad.

        ## Volumetría y datos
        - Volúmenes, frecuencias, cantidad de usuarios, fuentes y formatos de datos.

        ## Sistemas mencionados
        | Sistema | Rol o uso | Integración o forma de acceso | Observaciones |
        |---|---|---|---|
        | ... | ... | ... | ... |

        ## Fuera de alcance
        - Lo que se excluyó explícitamente.

        ## Supuestos
        - Supuestos que conviene validar.

        ## Riesgos y dependencias
        - Dependencias de terceros, accesos pendientes, limitaciones técnicas o de plazo.

        ## Preguntas abiertas
        - Pregunta y, si se indicó, a quién le corresponde responderla.
        """#
    )

    static let entrevista = MinutesTemplate(
        id: "entrevista",
        nombre: "Entrevista",
        descripcion: "Entrevista de selección: perfil, respuestas clave y evaluación.",
        cuerpo: #"""
        Objetivo: resumir una entrevista de selección para apoyar la evaluación del candidato. En general, "Yo" es quien entrevista y "Otros" es el candidato, aunque puede haber más entrevistadores en esa pista.

        Reglas generales:
        - Usa ÚNICAMENTE información presente en la transcripción. No inventes nombres, cifras, montos, fechas ni compromisos.
        - Hablantes: "Yo" es la persona que grabó la reunión. "Otros" agrupa en una sola pista a todos los demás participantes, que pueden ser varias personas. Atribuye una intervención de "Otros" a una persona concreta solo si se la nombra al hablarle, se presenta o el contexto lo deja inequívoco. Si no, escribe "Otros".
        - Asistentes y mencionados no son lo mismo. Una persona es asistente solo si habla, se le habla directamente o se presenta. Nombrar a alguien no lo convierte en asistente.
        - La transcripción es automática y tiene errores. Corrige nombres de productos o términos solo cuando el contexto lo hace evidente (apóyate en el glosario). Si un nombre propio es dudoso, escríbelo como aparece y agrega "(?)". Nunca corrijas ni redondees cifras.
        - Conserva siempre y en forma literal: montos, cifras, porcentajes, fechas, plazos, alcances, nombres de sistemas y compromisos hechos a clientes, socios o terceros. Estos datos no se omiten aunque parezcan secundarios.
        - Las fechas relativas ("el viernes", "la próxima semana") se escriben tal como se dijeron.
        - La extensión es proporcional al contenido. Una reunión corta produce una minuta corta. No rellenes.
        - Si la transcripción parece incompleta (empieza o termina a mitad de una conversación, es muy breve o tiene tramos ininteligibles), agrega al inicio una línea "> Registro parcial:" con una frase que explique por qué.
        - Si una sección no tiene información, escribe "No se mencionó."
        - Estilo: español neutro legible en toda Latinoamérica, frases breves y concretas. No uses guiones largos ni dobles; usa comas, dos puntos o punto. Evita fórmulas de relleno como "cabe destacar", "es importante mencionar" o "en resumen". Mantén en inglés los términos técnicos que se usan habitualmente en inglés y los nombres de productos.
        - Responde solo con la minuta en Markdown, con la estructura indicada, sin texto antes ni después y sin envolverla en un bloque de código.

        Glosario (términos que la transcripción suele deformar):
        - Si junto a la transcripción viene un glosario, úsalo para escribir correctamente nombres propios, productos y términos técnicos. Los términos se agregan en Biblioteca › Glosario.

        Reglas específicas:
        - Evalúa solo en función de lo dicho en la entrevista y en relación con el cargo.
        - No registres datos personales ajenos al cargo aunque se mencionen: edad, estado civil, hijos, salud, religión, origen, orientación o afiliación política.
        - Cada fortaleza, área de mejora o señal de alerta debe apoyarse en algo concreto que dijo el candidato. No asignes puntajes.
        - Registra expectativa económica, disponibilidad y modalidad solo si se mencionaron, en forma literal.

        Estructura de salida:

        # Entrevista

        ## Perfil del candidato
        - Cargo al que postula, experiencia, formación y situación laboral actual.

        ## Condiciones
        - **Expectativa económica:** ...
        - **Disponibilidad:** ...
        - **Modalidad y ubicación:** ...

        ## Respuestas clave
        - Pregunta o tema: resumen de la respuesta.

        ## Evaluación
        - **Fortalezas:** con la evidencia que la sostiene.
        - **Áreas de mejora:** con la evidencia que la sostiene.
        - **Ajuste al cargo:** ...

        ## Señales de alerta
        - Inconsistencias, respuestas evasivas u otros puntos a verificar.

        ## Próximos pasos
        - Siguientes etapas del proceso acordadas durante la entrevista.
        """#
    )

    static let familiar = MinutesTemplate(
        id: "familiar",
        nombre: "Reunión familiar",
        descripcion: "Conversación familiar: temas, acuerdos, tareas y fechas importantes.",
        cuerpo: #"""
        Objetivo: dejar un registro breve y útil de una conversación familiar, para recordar qué se habló, qué se acordó, quién se encarga de qué y qué fechas importantes aparecieron.

        Reglas generales:
        - Usa ÚNICAMENTE información presente en la transcripción. No inventes nombres, cifras, montos, fechas ni compromisos.
        - Hablantes: "Yo" es la persona que grabó la reunión. "Otros" agrupa en una sola pista a todos los demás participantes, que pueden ser varias personas. Atribuye una intervención de "Otros" a una persona concreta solo si se la nombra al hablarle, se presenta o el contexto lo deja inequívoco. Si no, escribe "Otros".
        - Participantes y mencionados no son lo mismo. Una persona es participante solo si habla, se le habla directamente o se presenta. Nombrar a alguien (un hijo, un médico, un vecino) no lo convierte en participante.
        - La transcripción es automática y tiene errores. Corrige nombres o términos solo cuando el contexto lo hace evidente (apóyate en el glosario). Si un nombre propio es dudoso, escríbelo como aparece y agrega "(?)". Nunca corrijas ni redondees cifras.
        - Conserva siempre y en forma literal: montos, cifras, fechas, horas, plazos, lugares y compromisos entre los participantes. Estos datos no se omiten aunque parezcan secundarios.
        - Las fechas relativas ("el viernes", "la próxima semana") se escriben tal como se dijeron.
        - La extensión es proporcional al contenido. Una conversación corta produce una minuta corta. No rellenes.
        - Si la transcripción parece incompleta (empieza o termina a mitad de una conversación, es muy breve o tiene tramos ininteligibles), agrega al inicio una línea "> Registro parcial:" con una frase que explique por qué.
        - La sección Participantes va siempre. Omite cualquier otra sección que no tenga contenido; no escribas secciones vacías.
        - Estilo: español neutro legible en toda Latinoamérica, frases breves y concretas. No uses guiones largos ni dobles; usa comas, dos puntos o punto. Evita fórmulas de relleno como "cabe destacar", "es importante mencionar" o "en resumen".
        - Responde solo con la minuta en Markdown, con la estructura indicada, sin texto antes ni después y sin envolverla en un bloque de código.

        Glosario (términos que la transcripción suele deformar):
        - Si junto a la transcripción viene un glosario, úsalo para escribir correctamente nombres propios, productos y términos técnicos. Los términos se agregan en Biblioteca › Glosario.

        Reglas específicas:
        - Tono cálido y neutral. No juzgues a nadie, no califiques opiniones ni conductas y no uses lenguaje corporativo (por ejemplo "entregables", "alineamiento" o "stakeholders").
        - Un acuerdo es algo que los participantes aceptaron explícitamente. Lo que solo se conversó, se propuso o se deseó va en Temas conversados, nunca en Decisiones y acuerdos.
        - Temas sensibles (salud, conflictos, dinero entre familiares): resúmelos con discreción, en términos generales y sin citas textuales. Conserva igual las fechas y los montos concretos que se dijeron.
        - Una tarea necesita a alguien que la asumió o a quien se le encargó. Si no quedó claro quién, igual regístrala y escribe "No se mencionó" en Quién.

        Estructura de salida:

        # Reunión familiar

        ## Participantes
        - Yo: el nombre de quien grabó la reunión si se menciona; si no, "No se mencionó".
        - Otros: nombres identificados según las reglas. Si no se identifica a nadie, escribe "participantes no identificados".

        ## Temas conversados
        - Un punto por tema, con un resumen breve de lo que se habló y de lo que opinó cada uno, si se dijo.

        ## Decisiones y acuerdos
        - Solo lo que se acordó explícitamente.

        ## Tareas
        | Quién | Qué | Para cuándo |
        |---|---|---|
        | ... | ... | ... |

        En Quién: el nombre si se dijo; "Yo" si lo asumió "Yo"; "Otros" si lo asumió alguien de esa pista sin nombre; "No se mencionó" si no quedó claro. En Para cuándo: la fecha o plazo tal como se dijo, o "No se mencionó".

        ## Fechas importantes
        - Viajes, citas médicas, cumpleaños, trámites y otros compromisos con fecha: la fecha tal como se dijo y de qué se trata.

        ## Gastos y montos mencionados
        - Cada monto en forma literal, a qué corresponde y quién lo paga o lo recibe, si se dijo.

        ## Pendientes para la próxima conversación
        - Temas que quedaron abiertos o que se acordó retomar.
        """#
    )
}
