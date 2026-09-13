//  Notifier.swift
//  Los avisos: anotaciones y cambios en el parte de lesiones.
//
//  Vive fuera del controlador de la Live Activity porque también lo usa el
//  refresco en segundo plano, que corre sin interfaz.

import Foundation
import UserNotifications

enum Notifier {
    /// Sonidos propios, dentro del paquete de la app. iOS solo admite WAV, CAF
    /// o AIFF de menos de 30 segundos, y hay que nombrarlos con su extensión.
    /// Se generan con `tools/generate_sounds.py`.
    private enum Sonido {
        /// Dos notas subiendo una quinta: anotó uno de los tuyos.
        static let anotacion = UNNotificationSound(named: UNNotificationSoundName("anotacion.wav"))
        /// Una nota grave y sola: una lesión, nada que celebrar.
        static let aviso = UNNotificationSound(named: UNNotificationSoundName("aviso.wav"))
        /// Dos notas iguales: te han pasado (o has vuelto a pasar tú).
        static let alerta = UNNotificationSound(named: UNNotificationSoundName("alerta.wav"))
    }

    /// Cuánto tiene que pasar para que un aviso vuelva a sonar. Los demás
    /// llegan igual, pero en silencio.
    ///
    /// Una tarde de domingo puede haber veinte anotaciones. Veinte sonidos
    /// seguidos hacen que la gente apague las notificaciones de la app, y
    /// entonces se pierde también el aviso que sí importaba.
    private static let silencioEntreSonidos: TimeInterval = 90
    private static let claveUltimoSonido = "lastNotificationSound"

    /// Con una sola liga, decir de qué liga es cada aviso sobra. Con dos o
    /// más es imprescindible: el mismo jugador puede estar en tus dos equipos,
    /// y "Vas ganando" no significa nada si no se sabe dónde.
    private static var variasLigas: Bool {
        SharedStore.loadBook().leagues.count > 1
    }

    /// El nombre de la liga cuando hace falta distinguirla, y nada si no.
    private static func etiqueta(_ league: LeagueConfig?) -> String? {
        guard variasLigas, let league else { return nil }
        let nombre = league.displayName
        return nombre.isEmpty ? nil : nombre
    }

    /// Un montón por liga y por tema en la pantalla de bloqueo, en vez de
    /// veinte tarjetas de tres ligas revueltas.
    private static func hilo(_ tema: String, _ league: LeagueConfig?) -> String {
        guard let league else { return tema }
        return "\(tema)-\(league.id)"
    }

    /// El sonido que toca, o nada si acaba de sonar uno.
    private static func sonido(_ propuesto: UNNotificationSound) -> UNNotificationSound? {
        let ahora = Date()
        if let ultimo = SharedStore.defaults.object(forKey: claveUltimoSonido) as? Date,
           ahora.timeIntervalSince(ultimo) < silencioEntreSonidos {
            return nil
        }
        SharedStore.defaults.set(ahora, forKey: claveUltimoSonido)
        return propuesto
    }

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    private static func authorized() async -> Bool {
        let ajustes = await UNUserNotificationCenter.current().notificationSettings()
        return ajustes.authorizationStatus == .authorized
            || ajustes.authorizationStatus == .provisional
    }

    // MARK: - Anotación

    /// Lo mínimo que tiene que sumar uno de los tuyos para merecer un aviso.
    ///
    /// El marcador de la app enseña cualquier movimiento de una décima, que es
    /// lo que se quiere en una lista en directo. Pero un aviso que dice
    /// "+0.2" —dos yardas de carrera— no informa de nada y gasta la paciencia
    /// del que lo recibe. Dos puntos es una recepción larga, un field goal,
    /// un touchdown: algo que ha pasado de verdad.
    private static let minimoMio = 2.0
    /// Del rival solo interesa lo gordo: un touchdown, un field goal largo.
    private static let minimoRival = 4.0

    /// Un aviso por tanda, no uno por jugador. Si tres de los tuyos anotan
    /// entre dos lecturas, tres notificaciones seguidas son ruido.
    static func plays(
        _ plays: [ScoringPlay], in snapshot: MatchupSnapshot, league: LeagueConfig? = nil
    ) async {
        let dignas = plays.filter { $0.delta >= ($0.isMine ? minimoMio : minimoRival) }
        guard !dignas.isEmpty else { return }
        if dignas.count == 1 {
            await play(dignas[0], in: snapshot, league: league)
        } else {
            await resumen(dignas, in: snapshot, league: league)
        }
    }

    /// "Vas ganando 94.7 – 69.2". Sin esto, un aviso de anotación no dice lo
    /// único que de verdad se quiere saber al mirar el teléfono: cómo voy.
    private static func marcador(
        _ snapshot: MatchupSnapshot, league: LeagueConfig? = nil
    ) -> String {
        let mios = snapshot.me.points.fantasyPoints
        let suyos = snapshot.opponentPoints.fantasyPoints
        let estado: String
        if snapshot.opponent == nil {
            estado = String(localized: "Llevas \(mios)")
        } else if abs(snapshot.difference) < 0.05 {
            estado = String(localized: "Empate a \(mios)")
        } else if snapshot.isLeading {
            estado = String(localized: "Vas ganando \(mios) – \(suyos)")
        } else {
            estado = String(localized: "Vas perdiendo \(mios) – \(suyos)")
        }
        // La liga delante: es lo primero que hay que saber cuando se siguen
        // dos, antes incluso de por cuánto vas.
        guard let liga = etiqueta(league) else { return estado }
        return "\(liga) · \(estado)"
    }

    private static func resumen(
        _ plays: [ScoringPlay], in snapshot: MatchupSnapshot, league: LeagueConfig?
    ) async {
        guard await authorized() else { return }
        let mias = plays.filter(\.isMine)
        let suyas = plays.filter { !$0.isMine }

        let contenido = UNMutableNotificationContent()
        // Sin contar "cuántas son tuyas" aparte: se ve en el cuerpo, y así no
        // hay que escoger entre "1 tuyas" y "2 tuyas".
        if suyas.isEmpty {
            contenido.title = String(localized: "\(plays.count) anotaciones tuyas")
        } else if mias.isEmpty {
            contenido.title = String(localized: "\(plays.count) anotaciones del rival")
        } else {
            contenido.title = String(localized: "\(plays.count) anotaciones")
        }
        contenido.subtitle = marcador(snapshot, league: league)

        var partes: [String] = []
        if !mias.isEmpty {
            partes.append(String(localized: "Tuyas: \(lista(mias))"))
        }
        if !suyas.isEmpty {
            partes.append(String(localized: "Del rival: \(lista(suyas))"))
        }
        contenido.body = partes.joined(separator: "\n")

        contenido.sound = sonido(Sonido.anotacion)
        let hayTouchdownMio = mias.contains(where: { $0.delta >= 5 })
        contenido.interruptionLevel = hayTouchdownMio ? .timeSensitive : .active
        contenido.threadIdentifier = hilo("anotaciones", league)

        // La foto de la jugada más gorda representa a la tanda.
        if let principal = plays.max(by: { $0.delta < $1.delta }),
           let adjunto = await attachment(
               playerID: principal.playerID, position: principal.position, team: principal.team
           ) {
            contenido.attachments = [adjunto]
        }
        await add(contenido, id: "resumen-\(Int(Date().timeIntervalSince1970))")
    }

    /// "Herbert +6.4, Hall +3.1". Como mucho tres, que es lo que cabe leer.
    private static func lista(_ plays: [ScoringPlay]) -> String {
        let nombres = plays
            .prefix(3)
            .map { "\($0.name) \($0.delta.signedFantasyPoints)" }
            .joined(separator: ", ")
        let restantes = plays.count - 3
        guard restantes > 0 else { return nombres }
        return String(localized: "\(nombres) y \(restantes) más")
    }

    static func play(
        _ play: ScoringPlay, in snapshot: MatchupSnapshot, league: LeagueConfig? = nil
    ) async {
        guard await authorized() else { return }

        let contenido = UNMutableNotificationContent()
        // El nombre y lo que acaba de sumar, que es lo que se lee de un
        // vistazo. Lo del rival lleva marca; lo tuyo no la necesita.
        let titular = "\(play.name)  \(play.delta.signedFantasyPoints)"
        contenido.title = play.isMine
            ? titular
            : String(localized: "Rival · \(titular)")
        contenido.subtitle = marcador(snapshot, league: league)

        // Qué hizo, y cuánto lleva en la jornada.
        let detalle = play.stats ?? play.subtitle
        let total = String(localized: "lleva \(play.total.fantasyPoints)")
        contenido.body = detalle.isEmpty ? total : "\(detalle) · \(total)"

        contenido.sound = sonido(Sonido.anotacion)
        // Solo un touchdown (seis puntos y pico) de los tuyos merece romper un
        // modo de concentración.
        contenido.interruptionLevel = (play.isMine && play.delta >= 5) ? .timeSensitive : .active
        contenido.threadIdentifier = hilo("anotaciones", league)

        if let adjunto = await attachment(
            playerID: play.playerID, position: play.position, team: play.team
        ) {
            contenido.attachments = [adjunto]
        }
        await add(contenido, id: play.id)
    }

    // MARK: - Noticia

    static func news(_ item: NewsItem, playerName: String?, league: LeagueConfig? = nil) async {
        guard await authorized() else { return }

        let contenido = UNMutableNotificationContent()
        contenido.title = playerName
            .map { String(localized: "Noticia de \($0)") }
            ?? String(localized: "Noticia de tu equipo")
        contenido.body = item.headline
        let liga = etiqueta(league)
        if let resumen = item.summary, !resumen.isEmpty {
            contenido.subtitle = [liga, resumen].compactMap { $0 }.joined(separator: " · ")
        } else if let liga {
            contenido.subtitle = liga
        }
        contenido.sound = nil
        // Una noticia no interrumpe ni suele merecer sonido: no es una jugada
        // en directo y puede esperar a que mires el teléfono.
        contenido.interruptionLevel = .passive
        contenido.threadIdentifier = hilo("noticias", league)
        await add(contenido, id: "news-\(item.id.hashValue)")
    }

    // MARK: - Cambio de liderato

    static func leadChange(
        tookLead: Bool, difference: Double, opponent: String, league: LeagueConfig? = nil
    ) async {
        guard await authorized() else { return }

        let contenido = UNMutableNotificationContent()
        contenido.title = tookLead
            ? String(localized: "Vuelves a ir ganando")
            : String(localized: "Te acaban de pasar")
        contenido.body = tookLead
            ? String(localized: "Vas por delante de \(opponent) por \(abs(difference).fantasyPoints).")
            : String(localized: "\(opponent) se pone por delante por \(abs(difference).fantasyPoints).")
        if let liga = etiqueta(league) { contenido.subtitle = liga }
        contenido.sound = sonido(Sonido.alerta)
        contenido.interruptionLevel = .timeSensitive
        contenido.threadIdentifier = hilo("marcador", league)
        // Con varias ligas puede haber dos adelantamientos en el mismo minuto:
        // el identificador lleva la liga para que no se pisen.
        await add(contenido, id: "lead-\(league?.id ?? "")-\(Int(Date().timeIntervalSince1970))")
    }

    // MARK: - Lesión

    static func injury(_ change: InjuryChange, league: LeagueConfig? = nil) async {
        guard await authorized() else { return }

        let contenido = UNMutableNotificationContent()
        contenido.title = change.isWorse
            ? String(localized: "Parte de lesión")
            : String(localized: "Buenas noticias")
        contenido.body = change.headline
        let posicion = [change.position, change.team].compactMap { $0 }.joined(separator: " ")
        let cabecera = [etiqueta(league), posicion.isEmpty ? nil : posicion]
            .compactMap { $0 }
            .joined(separator: " · ")
        if !cabecera.isEmpty { contenido.subtitle = cabecera }
        // Un parte a peor es raro y no espera: suena aunque acabe de sonar otro.
        // El alta médica puede llegar callada si hay ruido.
        contenido.sound = change.isWorse ? Sonido.aviso : sonido(Sonido.aviso)
        // Un cambio a peor el domingo por la mañana sí interrumpe.
        contenido.interruptionLevel = change.isWorse ? .timeSensitive : .active
        contenido.threadIdentifier = hilo("lesiones", league)

        if let adjunto = await attachment(
            playerID: change.playerID, position: change.position, team: change.team
        ) {
            contenido.attachments = [adjunto]
        }
        await add(contenido, id: change.id)
    }

    // MARK: - Interno

    private static func add(_ content: UNNotificationContent, id: String) async {
        let peticion = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(peticion)
    }

    /// Las notificaciones exigen un archivo con extensión reconocible, así que
    /// la foto cacheada se copia a temporales como .jpg.
    private static func attachment(
        playerID: String, position: String?, team: String?
    ) async -> UNNotificationAttachment? {
        guard
            let datos = await HeadshotCache.prefetch(
                playerID: playerID, position: position, team: team
            )
        else { return nil }

        let destino = FileManager.default.temporaryDirectory
            .appendingPathComponent("aviso-\(playerID).jpg")
        do {
            try datos.write(to: destino, options: .atomic)
            return try UNNotificationAttachment(identifier: playerID, url: destino)
        } catch {
            return nil
        }
    }
}
