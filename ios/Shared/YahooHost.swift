//  YahooHost.swift
//  Leer una liga de Yahoo y devolver el mismo `MatchupSnapshot` que Sleeper.
//
//  Toda la rareza de Yahoo se queda aquí dentro. Fuera, una liga de Yahoo y una
//  de Sleeper son lo mismo: la pantalla, el widget, la Live Activity y los
//  avisos no saben de dónde salen los puntos.
//
//  Tres cosas que Yahoo hace distinto y conviene saber antes de leer esto:
//
//  1. Las claves. Una liga es "449.l.123456" (juego, liga) y un equipo
//     "449.l.123456.t.7". El número suelto no sirve para nada.
//  2. La puntuación ya viene hecha. Yahoo aplica las reglas de la liga y
//     devuelve los puntos; no hay que multiplicar estadísticas por nada, que
//     es justo lo contrario de Sleeper.
//  3. La jornada la manda la liga, no el deporte. Cada liga trae su
//     `current_week`, `start_week` y `end_week`.

import Foundation

struct YahooHost {
    var session: YahooSession = .shared

    // MARK: - Ligas de la cuenta

    /// Las ligas de NFL de quien ha entrado, para el selector.
    func leagues() async throws -> [YahooLeagueSummary] {
        let arbol = try await session.get("users;use_login=1/games;game_keys=nfl/leagues")
        return arbol.findAll("league").flatMap { nodo -> [YahooLeagueSummary] in
            // Puede venir una liga suelta o una colección de ellas.
            let candidatos = nodo.find("league_key") != nil ? [nodo] : nodo.elements
            return candidatos.compactMap { liga in
                guard let clave = liga.text("league_key") else { return nil }
                return YahooLeagueSummary(
                    leagueKey: clave,
                    name: liga.text("name") ?? "Liga de Yahoo",
                    season: liga.text("season"),
                    teamCount: liga.int("num_teams")
                )
            }
        }
    }

    /// Los equipos de una liga, para elegir el tuyo.
    ///
    /// Cuál es el tuyo se pregunta aparte, en vez de buscar una marca dentro de
    /// cada equipo: Yahoo tiene una ruta que devuelve **solo** los equipos del
    /// usuario que ha entrado, y eso no hay que adivinarlo.
    func teams(in leagueKey: String) async throws -> (leagueName: String, teams: [LeagueTeam]) {
        async let arbolTask = session.get("league/\(leagueKey)/teams")
        async let miosTask = myTeamKeys()

        let arbol = try await arbolTask
        let mios = await miosTask

        let nombre = arbol.find("league")?.text("name") ?? "Liga de Yahoo"
        let equipos = arbol.findAll("team").flatMap { nodo -> [JSONValue] in
            nodo.find("team_key") != nil ? [nodo] : nodo.elements
        }
        .compactMap { equipo -> LeagueTeam? in
            guard let clave = equipo.text("team_key") else { return nil }
            return LeagueTeam(
                rosterID: Self.teamNumber(from: clave) ?? 0,
                name: equipo.text("name") ?? "Equipo",
                avatarURL: equipo.find("team_logos")?.url("url"),
                record: equipo.find("outcome_totals").map { resultado in
                    "\(resultado.int("wins") ?? 0)-\(resultado.int("losses") ?? 0)"
                },
                ownerIDs: mios.contains(clave) ? ["me"] : []
            )
        }
        return (nombre, equipos)
    }

    /// Las claves de los equipos que lleva quien ha entrado, en todas sus
    /// ligas de NFL. Si falla, no pasa nada: se elige el equipo a mano.
    private func myTeamKeys() async -> Set<String> {
        guard let arbol = try? await session.get(
            "users;use_login=1/games;game_keys=nfl/teams"
        ) else { return [] }
        return Set(arbol.findAll("team_key").compactMap(\.text))
    }

    // MARK: - Marcador

    func snapshot(for config: LeagueConfig, week semanaPedida: Int?) async throws -> MatchupSnapshot {
        let leagueKey = config.leagueID.trimmingCharacters(in: .whitespaces)
        guard !leagueKey.isEmpty else { throw SleeperError.leagueNotSet }

        // Una sola llamada trae la liga, su jornada actual y el marcador
        // entero: Yahoo permite pedir varios recursos a la vez.
        let meta = try await session.get("league/\(leagueKey)")
        let liga = meta.find("league") ?? meta
        let jornadaEnCurso = liga.int("current_week") ?? 1
        let ultima = liga.int("end_week") ?? MatchupSnapshot.lastWeek
        let primera = liga.int("start_week") ?? 1
        let week = semanaPedida.map { min(ultima, max(primera, $0)) } ?? jornadaEnCurso

        let marcador = try await session.get("league/\(leagueKey)/scoreboard;week=\(week)")
        let miClave = "\(leagueKey).t.\(config.rosterID)"

        guard let enfrentamiento = Self.matchup(containing: miClave, in: marcador) else {
            throw YahooError.teamNotFound(miClave)
        }
        let lados = enfrentamiento.findAll("team").flatMap { nodo -> [JSONValue] in
            nodo.find("team_key") != nil ? [nodo] : nodo.elements
        }
        guard let mio = lados.first(where: { $0.text("team_key") == miClave }) else {
            throw YahooError.teamNotFound(miClave)
        }
        let suyo = lados.first { $0.text("team_key") != miClave }

        // Las dos alineaciones a la vez: son dos llamadas que no dependen
        // entre sí y juntas tardan lo que la más lenta.
        let suClave = suyo?.text("team_key")
        async let miAlineacionTask = roster(teamKey: miClave, week: week)
        async let suAlineacionTask = roster(teamKey: suClave, week: week)
        let miAlineacion = await miAlineacionTask
        let suAlineacion = await suAlineacionTask

        var me = Self.side(from: mio, fallbackName: "Tu equipo", starters: miAlineacion)
        var opponent = suyo.map { Self.side(from: $0, fallbackName: "Rival", starters: suAlineacion) }

        // Los escudos, en bytes: el widget y la Live Activity no pueden salir a
        // la red mientras se pintan, así que viajan con el marcador.
        async let miEscudoTask = AvatarLoader.data(for: me.avatarURL)
        async let suEscudoTask = AvatarLoader.data(for: opponent?.avatarURL)
        me.avatarData = await miEscudoTask
        opponent?.avatarData = await suEscudoTask

        var snapshot = MatchupSnapshot(
            leagueName: liga.text("name") ?? config.displayName,
            week: week,
            me: me,
            opponent: opponent,
            lineup: Self.lineup(mine: miAlineacion, theirs: suAlineacion),
            updatedAt: Date(),
            isStale: false,
            recentPlays: nil
        )
        snapshot.liveWeek = jornadaEnCurso
        // Yahoo da hechas las dos cosas que en Sleeper hay que calcular: el
        // total proyectado de cada equipo y la probabilidad de ganar. Usar las
        // suyas es mejor que estimarlas —son las que ve el usuario en su app—
        // y de paso desaparece la discusión de si la proyección cuadra.
        snapshot.projection = Self.projection(
            mine: mio, theirs: suyo, snapshot: snapshot
        ) ?? WinProbability.compute(for: snapshot)
        // Yahoo ya aplica las reglas de la liga antes de dar los puntos, así
        // que no hay nada que etiquetar: no existe un "PPR" que enseñar.
        snapshot.scoringLabel = nil
        snapshot.bench = miAlineacion.filter(\.isBench).map(\.line)
        snapshot.benchReport = nil
        return snapshot
    }

    // MARK: - Clasificación

    func standings(in leagueKey: String, myRosterID: Int?) async throws -> [TeamStanding] {
        let arbol = try await session.get("league/\(leagueKey)/standings")
        let equipos = arbol.findAll("team").flatMap { nodo -> [JSONValue] in
            nodo.find("team_key") != nil ? [nodo] : nodo.elements
        }

        /// Lo de cada equipo antes de saber en qué puesto va.
        struct Fila {
            let numero: Int
            let puesto: Int
            let nombre: String
            let escudo: URL?
            let ganados: Int
            let perdidos: Int
            let empatados: Int
            let aFavor: Double
            let enContra: Double
        }

        let filas = equipos.compactMap { equipo -> Fila? in
            guard let clave = equipo.text("team_key") else { return nil }
            let numero = Self.teamNumber(from: clave) ?? 0
            let resultado = equipo.find("outcome_totals")
            let posicion = equipo.find("team_standings")
            return Fila(
                numero: numero,
                puesto: equipo.int("rank") ?? 0,
                nombre: equipo.text("name") ?? "Equipo \(numero)",
                escudo: equipo.find("team_logos")?.url("url"),
                ganados: resultado?.int("wins") ?? 0,
                perdidos: resultado?.int("losses") ?? 0,
                empatados: resultado?.int("ties") ?? 0,
                aFavor: posicion?.double("points_for") ?? 0,
                enContra: posicion?.double("points_against") ?? 0
            )
        }

        // Yahoo ya los manda ordenados, pero si algún `rank` faltara quedarían
        // revueltos; se ordena igual y se numera al final.
        let ordenadas = filas.sorted { izquierda, derecha in
            if izquierda.puesto > 0, derecha.puesto > 0, izquierda.puesto != derecha.puesto {
                return izquierda.puesto < derecha.puesto
            }
            if izquierda.ganados != derecha.ganados { return izquierda.ganados > derecha.ganados }
            return izquierda.aFavor > derecha.aFavor
        }

        return ordenadas.enumerated().map { indice, fila in
            TeamStanding(
                rosterID: fila.numero,
                rank: indice + 1,
                name: fila.nombre,
                avatarURL: fila.escudo,
                wins: fila.ganados,
                losses: fila.perdidos,
                ties: fila.empatados,
                pointsFor: fila.aFavor,
                pointsAgainst: fila.enContra,
                isMine: fila.numero == myRosterID
            )
        }
    }

    // MARK: - Alineación

    /// Un titular o suplente ya traducido, con el hueco que ocupa.
    struct RosterEntry {
        var line: PlayerLine
        var slot: String
        var isBench: Bool
    }

    private func roster(teamKey: String?, week: Int) async -> [RosterEntry] {
        // Sin rival (jornada de descanso) no hay nada que pedir.
        guard let teamKey else { return [] }
        // La ruta documentada. `players` es el sub-recurso por defecto del
        // roster, así que ponerlo explícito es lo máximo que se puede pedir
        // sin salirse de lo que Yahoo garantiza.
        let ruta = "team/\(teamKey)/roster;week=\(week)/players"
        guard let arbol = try? await session.get(ruta) else { return [] }

        return arbol.findAll("player").flatMap { nodo -> [JSONValue] in
            nodo.find("player_key") != nil ? [nodo] : nodo.elements
        }
        .compactMap { jugador -> RosterEntry? in
            guard let id = jugador.text("player_id") ?? jugador.text("player_key") else { return nil }
            let hueco = jugador.find("selected_position")?.text("position") ?? "BN"
            let estado = jugador.text("status_full") ?? jugador.text("status")
            return RosterEntry(
                line: PlayerLine(
                    playerID: "yahoo:\(id)",
                    points: jugador.find("player_points")?.double("total") ?? 0,
                    name: jugador.find("name")?.text("full") ?? jugador.text("full"),
                    position: jugador.text("display_position"),
                    team: jugador.text("editorial_team_abbr")?.uppercased(),
                    stats: nil,
                    projected: jugador.find("player_projected_points")?.double("total"),
                    injury: estado,
                    gameFinished: nil,
                    gameRemaining: nil
                ),
                slot: hueco.uppercased(),
                isBench: ["BN", "IR", "IL", "IL+", "NA"].contains(hueco.uppercased())
            )
        }
    }

    /// Empareja hueco a hueco los titulares de los dos equipos, que es como lo
    /// pinta la pantalla. Yahoo ya devuelve la alineación en su orden.
    private static func lineup(mine: [RosterEntry], theirs: [RosterEntry]) -> [LineupRow] {
        let mios = mine.filter { !$0.isBench }
        let suyos = theirs.filter { !$0.isBench }
        let total = max(mios.count, suyos.count)
        guard total > 0 else { return [] }

        return (0..<total).map { indice in
            LineupRow(
                index: indice,
                slot: indice < mios.count ? mios[indice].slot : suyos[indice].slot,
                mine: indice < mios.count ? mios[indice].line : nil,
                theirs: indice < suyos.count ? suyos[indice].line : nil
            )
        }
    }

    private static func side(
        from equipo: JSONValue, fallbackName: String, starters: [RosterEntry]
    ) -> TeamSide {
        let clave = equipo.text("team_key") ?? ""
        return TeamSide(
            rosterID: teamNumber(from: clave) ?? 0,
            name: equipo.text("name") ?? fallbackName,
            avatarURL: equipo.find("team_logos")?.url("url"),
            avatarData: nil,
            points: equipo.find("team_points")?.double("total") ?? 0,
            startersCount: starters.filter { !$0.isBench }.count,
            record: equipo.find("outcome_totals").map { resultado in
                "\(resultado.int("wins") ?? 0)-\(resultado.int("losses") ?? 0)"
            }
        )
    }

    /// La proyección tal cual la da Yahoo, si la da.
    ///
    /// `team_projected_points` y `win_probability` vienen en el marcador. Si
    /// faltan (jornada sin empezar, liga rara), se vuelve a la estimación
    /// propia, que es la misma que usa Sleeper.
    private static func projection(
        mine: JSONValue, theirs: JSONValue?, snapshot: MatchupSnapshot
    ) -> MatchupProjection? {
        guard
            let theirs,
            let proyectadoMio = mine.find("team_projected_points")?.double("total"),
            let proyectadoSuyo = theirs.find("team_projected_points")?.double("total")
        else { return nil }

        // Yahoo la da de 0 a 1 en el equipo que gana la ve; si no viene, se
        // deduce de los dos proyectados.
        let probabilidad = mine.double("win_probability")
            ?? (proyectadoMio + proyectadoSuyo > 0
                ? proyectadoMio / (proyectadoMio + proyectadoSuyo)
                : 0.5)

        let titulares = snapshot.lineup
        return MatchupProjection(
            mine: proyectadoMio,
            theirs: proyectadoSuyo,
            remainingMine: max(0, proyectadoMio - snapshot.me.points),
            remainingTheirs: max(0, proyectadoSuyo - snapshot.opponentPoints),
            winProbability: min(max(probabilidad, 0.01), 0.99),
            playersLeftMine: titulares.filter { ($0.mine?.points ?? 0) == 0 }.count,
            playersLeftTheirs: titulares.filter { ($0.theirs?.points ?? 0) == 0 }.count
        )
    }

    /// El enfrentamiento en el que juega ese equipo esta jornada.
    private static func matchup(containing teamKey: String, in marcador: JSONValue) -> JSONValue? {
        let enfrentamientos = marcador.findAll("matchup").flatMap { nodo -> [JSONValue] in
            nodo.find("teams") != nil ? [nodo] : nodo.elements
        }
        return enfrentamientos.first { enfrentamiento in
            enfrentamiento.findAll("team_key").contains { $0.text == teamKey }
        }
    }

    /// "449.l.123456.t.7" -> 7.
    static func teamNumber(from teamKey: String) -> Int? {
        guard let ultimo = teamKey.split(separator: ".").last else { return nil }
        return Int(ultimo)
    }
}

struct YahooLeagueSummary: Identifiable, Hashable {
    let leagueKey: String
    let name: String
    let season: String?
    let teamCount: Int?

    var id: String { leagueKey }
}
