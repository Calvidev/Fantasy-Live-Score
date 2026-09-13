//  MatchupService.swift
//  Monta el marcador a partir de cinco llamadas a Sleeper.
//
//  Es el mismo camino que hacía el widget de Scriptable: estado -> jornada,
//  liga, managers, rosters y enfrentamientos de esa jornada. Lo usan igual la
//  app y el widget, así que los dos enseñan exactamente lo mismo.

import Foundation

struct MatchupService {
    var api: SleeperAPI = .shared

    func snapshot(for config: LeagueConfig) async throws -> MatchupSnapshot {
        guard config.isComplete else { throw SleeperError.leagueNotSet }
        let leagueID = config.leagueID.trimmingCharacters(in: .whitespaces)

        let state = try await api.state()
        let week = state.currentWeek

        // Las cuatro llamadas de liga no dependen entre sí: van a la vez.
        async let leagueTask = api.league(leagueID)
        async let usersTask = api.users(leagueID: leagueID)
        async let rostersTask = api.rosters(leagueID: leagueID)
        async let matchupsTask = api.matchups(leagueID: leagueID, week: week)

        let league = try await leagueTask
        let users = try await usersTask
        let rosters = try await rostersTask
        let matchups = try await matchupsTask

        guard let mineMatchup = matchups.first(where: { $0.rosterID == config.rosterID }) else {
            throw SleeperError.rosterNotFound(config.rosterID)
        }

        // El rival es el otro equipo con el mismo `matchup_id`. En semana de
        // descanso no hay ninguno, y eso es válido.
        let theirsMatchup = matchups.first { other in
            other.rosterID != mineMatchup.rosterID
                && other.matchupID != nil
                && other.matchupID == mineMatchup.matchupID
        }

        let rosterByID = Dictionary(rosters.map { ($0.rosterID, $0) }, uniquingKeysWith: { first, _ in first })
        let userByID = Dictionary(users.map { ($0.userID, $0) }, uniquingKeysWith: { first, _ in first })

        let myUser = user(for: mineMatchup.rosterID, rosters: rosterByID, users: userByID)
        let theirUser = theirsMatchup.flatMap {
            user(for: $0.rosterID, rosters: rosterByID, users: userByID)
        }

        // Los avatares se piden a la vez y no interrumpen nada si fallan.
        async let myAvatarTask = AvatarLoader.data(for: myUser?.avatarURL)
        async let theirAvatarTask = AvatarLoader.data(for: theirUser?.avatarURL)
        let myAvatar = await myAvatarTask
        let theirAvatar = await theirAvatarTask

        let me = TeamSide(
            rosterID: mineMatchup.rosterID,
            name: config.teamName ?? myUser?.preferredName ?? "Tu equipo",
            avatarURL: myUser?.avatarURL,
            avatarData: myAvatar,
            points: mineMatchup.points ?? 0,
            startersCount: mineMatchup.filledStarters.count,
            record: rosterByID[mineMatchup.rosterID]?.record
        )

        var opponent: TeamSide?
        if let theirsMatchup {
            opponent = TeamSide(
                rosterID: theirsMatchup.rosterID,
                name: theirUser?.preferredName ?? "Rival",
                avatarURL: theirUser?.avatarURL,
                avatarData: theirAvatar,
                points: theirsMatchup.points ?? 0,
                startersCount: theirsMatchup.filledStarters.count,
                record: rosterByID[theirsMatchup.rosterID]?.record
            )
        }

        let catalog = await PlayerCatalog.shared.cached()
        // Las estadísticas de la jornada son un extra: si no están descargadas,
        // el marcador sale igual, solo que sin yardas.
        let weekStats = await WeekStatsStore.shared.cached()
        let projections = await ProjectionStore.shared.cached()
        let gameStatus = await GameStatusStore.shared.cached()
        let lineup = buildLineup(
            slots: league.starterSlots,
            mine: mineMatchup,
            theirs: theirsMatchup,
            catalog: catalog,
            weekStats: weekStats,
            projections: projections,
            scoring: league.scoringSettings,
            gameStatus: gameStatus
        )

        // El banquillo sale del mismo enfrentamiento: trae la plantilla entera.
        let bench = mineMatchup.benchIDs.compactMap { playerID -> PlayerLine? in
            let entry = catalog[playerID]
            return PlayerLine(
                playerID: playerID,
                points: mineMatchup.playersPoints?[playerID] ?? 0,
                name: entry?.name,
                position: entry?.position,
                team: entry?.team,
                stats: weekStats?.line(for: playerID, position: entry?.position),
                projected: projections?.projected(for: playerID, scoring: league.scoringSettings),
                injury: entry?.injuryStatus,
                gameFinished: gameStatus?.hasFinished(entry?.team),
                gameRemaining: gameStatus?.remaining(for: entry?.team)
            )
        }

        var snapshot = MatchupSnapshot(
            leagueName: league.name ?? "Liga de Sleeper",
            week: week,
            me: me,
            opponent: opponent,
            lineup: lineup,
            updatedAt: Date(),
            isStale: false,
            recentPlays: nil
        )
        snapshot.projection = WinProbability.compute(for: snapshot)
        snapshot.scoringLabel = Self.scoringLabel(for: league.scoringSettings)
        snapshot.bench = bench
        snapshot.benchReport = OptimalLineup.report(
            starters: lineup.compactMap(\.mine),
            bench: bench,
            slots: league.starterSlots
        )
        return snapshot
    }

    /// El formato de puntuación en dos palabras. Lo decide el valor de la
    /// recepción, que es lo que separa a las ligas más comunes.
    static func scoringLabel(for scoring: [String: Double]?) -> String? {
        guard let scoring, !scoring.isEmpty else { return "sin reglas de liga" }
        guard let recepcion = scoring["rec"] else { return "personalizada" }
        switch recepcion {
        case 1: return "PPR"
        case 0.5: return "media PPR"
        case 0: return "estándar"
        default: return "\(recepcion.fantasyPoints) por recepción"
        }
    }

    // MARK: - Piezas

    private func user(
        for rosterID: Int,
        rosters: [Int: Roster],
        users: [String: LeagueUser]
    ) -> LeagueUser? {
        guard let ownerID = rosters[rosterID]?.ownerID else { return nil }
        return users[ownerID]
    }

    /// Empareja hueco a hueco las dos alineaciones. Sleeper ordena `starters`
    /// igual que `roster_positions`, así que el índice ya es el hueco.
    private func buildLineup(
        slots: [String],
        mine: Matchup,
        theirs: Matchup?,
        catalog: [String: CatalogPlayer],
        weekStats: WeekStats?,
        projections: Projections?,
        scoring: [String: Double]?,
        gameStatus: GameStatus?
    ) -> [LineupRow] {
        let count = max(
            slots.count,
            max(mine.starters?.count ?? 0, theirs?.starters?.count ?? 0)
        )
        guard count > 0 else { return [] }

        var rows: [LineupRow] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            let slot = index < slots.count ? slots[index] : "FLEX"
            let row = LineupRow(
                index: index,
                slot: slot,
                mine: line(
                    from: mine, at: index, catalog: catalog,
                    weekStats: weekStats, projections: projections,
                    scoring: scoring, gameStatus: gameStatus
                ),
                theirs: theirs.flatMap {
                    line(
                        from: $0, at: index, catalog: catalog,
                        weekStats: weekStats, projections: projections,
                        scoring: scoring, gameStatus: gameStatus
                    )
                }
            )
            if row.mine == nil && row.theirs == nil { continue }
            rows.append(row)
        }
        return rows
    }

    private func line(
        from matchup: Matchup,
        at index: Int,
        catalog: [String: CatalogPlayer],
        weekStats: WeekStats?,
        projections: Projections?,
        scoring: [String: Double]?,
        gameStatus: GameStatus?
    ) -> PlayerLine? {
        guard let starters = matchup.starters, index < starters.count else { return nil }
        let playerID = starters[index]
        guard playerID != "0", !playerID.isEmpty else { return nil }
        let entry = catalog[playerID]
        return PlayerLine(
            playerID: playerID,
            points: matchup.pointsForSlot(index),
            name: entry?.name,
            position: entry?.position,
            team: entry?.team,
            stats: weekStats?.line(for: playerID, position: entry?.position),
            projected: projections?.projected(for: playerID, scoring: scoring),
            injury: entry?.injuryStatus,
            gameFinished: gameStatus?.hasFinished(entry?.team),
            gameRemaining: gameStatus?.remaining(for: entry?.team)
        )
    }
}

// MARK: - Clasificación

struct TeamStanding: Identifiable, Hashable {
    let rosterID: Int
    let rank: Int
    let name: String
    let avatarURL: URL?
    let wins: Int
    let losses: Int
    let ties: Int
    let pointsFor: Double
    let pointsAgainst: Double
    let isMine: Bool

    var id: Int { rosterID }

    var record: String {
        ties > 0 ? "\(wins)-\(losses)-\(ties)" : "\(wins)-\(losses)"
    }
}

extension MatchupService {
    /// La tabla de la liga. Sale de los rosters, que ya traen récord y puntos:
    /// no hace falta ninguna llamada nueva.
    func standings(in leagueID: String, myRosterID: Int?) async throws -> [TeamStanding] {
        let clean = leagueID.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { throw SleeperError.leagueNotSet }

        async let usersTask = api.users(leagueID: clean)
        async let rostersTask = api.rosters(leagueID: clean)
        let users = try await usersTask
        let rosters = try await rostersTask

        let userByID = Dictionary(users.map { ($0.userID, $0) }, uniquingKeysWith: { first, _ in first })

        // Se ordena como cualquier liga: victorias primero, y los puntos a
        // favor deshacen el empate.
        let ordenados = rosters.sorted { izquierda, derecha in
            let victoriasIzq = izquierda.settings?.wins ?? 0
            let victoriasDer = derecha.settings?.wins ?? 0
            if victoriasIzq != victoriasDer { return victoriasIzq > victoriasDer }
            return (izquierda.settings?.pointsFor ?? 0) > (derecha.settings?.pointsFor ?? 0)
        }

        return ordenados.enumerated().map { indice, roster in
            let owner = roster.ownerID.flatMap { userByID[$0] }
            return TeamStanding(
                rosterID: roster.rosterID,
                rank: indice + 1,
                name: owner?.preferredName ?? "Equipo \(roster.rosterID)",
                avatarURL: owner?.avatarURL,
                wins: roster.settings?.wins ?? 0,
                losses: roster.settings?.losses ?? 0,
                ties: roster.settings?.ties ?? 0,
                pointsFor: roster.settings?.pointsFor ?? 0,
                pointsAgainst: roster.settings?.pointsAgainst ?? 0,
                isMine: roster.rosterID == myRosterID
            )
        }
    }
}

// MARK: - Equipos de una liga (para la pantalla de ajustes)

struct LeagueTeam: Identifiable, Hashable {
    let rosterID: Int
    let name: String
    let avatarURL: URL?
    let record: String?
    /// Quién lo lleva. Sirve para reconocer cuál es el tuyo sin preguntártelo.
    let ownerIDs: [String]

    var id: Int { rosterID }

    func belongs(to userID: String) -> Bool { ownerIDs.contains(userID) }
}

/// Lo que hace falta para no pedirle a nadie un id de liga: quién eres y en
/// qué ligas juegas esta temporada.
struct SleeperAccount {
    let user: SleeperUser
    let season: String
    let leagues: [LeagueSummary]
}

extension MatchupService {
    /// Tu cuenta y tus ligas a partir del nombre de usuario. La API de Sleeper
    /// es de lectura y pública: no hay contraseña ni OAuth de por medio.
    func account(username: String) async throws -> SleeperAccount {
        let user = try await api.user(username: username)
        let season = try await currentSeason()
        let leagues = (try? await api.leagues(userID: user.userID, season: season)) ?? []
        return SleeperAccount(user: user, season: season, leagues: leagues)
    }

    /// La temporada en curso según Sleeper; si el estado falla, se deduce de la
    /// fecha (la temporada NFL arranca en septiembre).
    func currentSeason() async throws -> String {
        if let season = try? await api.state().season, !season.isEmpty {
            return season
        }
        let calendario = Calendar(identifier: .gregorian)
        let hoy = Date()
        let año = calendario.component(.year, from: hoy)
        let mes = calendario.component(.month, from: hoy)
        return String(mes >= 3 ? año : año - 1)
    }

    /// Los equipos de una liga, para elegir el tuyo sin saberte el número de roster.
    func teams(in leagueID: String) async throws -> (leagueName: String, teams: [LeagueTeam]) {
        let clean = leagueID.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { throw SleeperError.leagueNotSet }

        async let leagueTask = api.league(clean)
        async let usersTask = api.users(leagueID: clean)
        async let rostersTask = api.rosters(leagueID: clean)

        let league = try await leagueTask
        let users = try await usersTask
        let rosters = try await rostersTask

        let userByID = Dictionary(users.map { ($0.userID, $0) }, uniquingKeysWith: { first, _ in first })
        let teams = rosters
            .sorted { $0.rosterID < $1.rosterID }
            .map { roster -> LeagueTeam in
                let owner = roster.ownerID.flatMap { userByID[$0] }
                var dueños: [String] = []
                if let ownerID = roster.ownerID { dueños.append(ownerID) }
                dueños.append(contentsOf: roster.coOwners ?? [])
                return LeagueTeam(
                    rosterID: roster.rosterID,
                    name: owner?.preferredName ?? "Equipo \(roster.rosterID)",
                    avatarURL: owner?.avatarURL,
                    record: roster.record,
                    ownerIDs: dueños
                )
            }
        return (league.name ?? "Liga de Sleeper", teams)
    }
}
